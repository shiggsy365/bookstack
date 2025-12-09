-- Refactored OPDS Browser Plugin
--
-- WORKFLOW:
-- 1. DETECT: onReaderReady checks if opened file is a placeholder
-- 2. DOWNLOAD: Downloads real book to temp file
-- 3. CLOSE & SWAP: Close Reader -> Switch to FM -> Replace File
-- 4. OPEN: Opens the new book file directly

local BD = require("ui/bidi")
local DataStorage = require("datastorage")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local socket = require("socket")
local _ = require("gettext")
local T = require("ffi/util").template
local lfs = require("libs/libkoreader-lfs")
local json = require("json")
local url = require("socket.url")

-- Plugin modules
local Constants = require("constants")
local Utils = require("utils")
local UIHelpers = require("ui_helpers")
local CacheManager = require("cache_manager")
local SettingsManager = require("settings_manager")
local HistoryManager = require("history_manager")
local OPDSClient = require("opds_client")
local HardcoverClient = require("hardcover_client")
local EphemeraClient = require("ephemera_client")
local HttpClient = require("http_client_new")
local PlaceholderGenerator = require("placeholder_generator")
local LibrarySyncManager = require("library_sync_manager")

local OPDSBrowser = WidgetContainer:extend{
    name = "opdsbrowser",
    is_doc_only = false,
}

function OPDSBrowser:init()
    SettingsManager:init()
    CacheManager:init()
    HistoryManager:init()
    
    local settings = SettingsManager:getAll()
    self.opds_url = settings.opds_url
    self.opds_username = settings.opds_username
    self.opds_password = settings.opds_password
    self.ephemera_url = settings.ephemera_url
    self.download_dir = settings.download_dir
    self.hardcover_token = settings.hardcover_token
    self.use_publisher_as_series = settings.use_publisher_as_series
    self.enable_library_check = settings.enable_library_check
    self.library_check_page_limit = settings.library_check_page_limit
    
    self.opds_client = OPDSClient:new()
    self.opds_client:setCredentials(self.opds_url, self.opds_username, self.opds_password)
    
    self.hardcover_client = HardcoverClient:new()
    self.hardcover_client:setToken(self.hardcover_token)
    
    self.ephemera_client = EphemeraClient:new()
    self.ephemera_client:setBaseURL(self.ephemera_url)
    
    local base_download_dir = settings.download_dir or "/mnt/us/books"
    base_download_dir = base_download_dir:gsub("/$", "")
    local library_path = settings.library_sync_path or (base_download_dir .. "/Library")
    LibrarySyncManager:init(library_path, self.opds_username, self.opds_password)
    self.library_sync = LibrarySyncManager

    self.ui.menu:registerToMainMenu(self)
    _G.opds_plugin_instance = self
    self.queue_refresh_action = nil
    
    -- State flag to prevent recursive download loops
    self.processing_download = false
    
    self:registerFileManagerHooks()

    logger.info("OPDS Browser: Initialized")
end

-- ============================================================================
-- PLACEHOLDER DETECTION & DOWNLOAD LOGIC
-- ============================================================================

function OPDSBrowser:registerFileManagerHooks()
end

function OPDSBrowser:onMenuHold(item)
    if self.ui.name ~= "FileManager" then return false end
    if not item or not item.path or item.is_directory then return false end
    
    local filepath = item.path
    local book_info = self.library_sync:getBookInfo(filepath)
    if not book_info then return false end
    
    return {
        {
            text = _("Download from OPDS"),
            callback = function()
                self:handlePlaceholderDownloadFromFileManager(filepath, book_info)
            end,
        },
    }
end

function OPDSBrowser:onFileSelect(filepath)
    return false
end

function OPDSBrowser:ensureNetwork()
    if not NetworkMgr:isOnline() then
        NetworkMgr:beforeWifiAction()
        socket.sleep(1)
        if not NetworkMgr:isOnline() then
            UIHelpers.showError(_("Network unavailable"))
            return false
        end
    end
    return true
end

function OPDSBrowser:handlePlaceholderDownloadFromFileManager(filepath, book_info)
    if not self:ensureNetwork() then return end
    
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = T(_("Download '%1' from OPDS server?\n\nThis will replace the placeholder with the real book."), 
                 book_info.title),
        ok_text = _("Download"),
        ok_callback = function()
            self:downloadPlaceholderAndRefresh(filepath, book_info)
        end,
    })
end

function OPDSBrowser:downloadPlaceholderAndRefresh(placeholder_path, book_info)
    if not self:ensureNetwork() then return end
    
    -- Set processing flag immediately to stop other events
    self.processing_download = true
    
    local book_id = book_info.book_id
    if book_id then book_id = book_id:match("book:(%d+)$") or book_id end
    
    if not book_id or book_id == "" then
        self.processing_download = false
        UIHelpers.showError(_("Cannot download: Book ID not found"))
        return
    end

    local extension = ".epub"
    if book_info.download_url and book_info.download_url:lower():match("kepub") then
        extension = ".kepub.epub"
    end

    local timestamp = os.time()
    local temp_filepath = placeholder_path:gsub("%.epub$", string.format(".downloading_%d.tmp", timestamp))
    
    -- CHANGE: Strip the suffix " - (PH)" from the filename if present
    -- This converts ".../Title - (PH).epub" to ".../Title.epub"
    -- Pattern matches " - (PH)" specifically at the end of the filename stem
    local clean_path = placeholder_path:gsub(" %- %(PH%)", "")
    local filepath = clean_path:gsub("%.epub$", extension)

    if filepath == placeholder_path then
        logger.info("OPDS: No ' - (PH)' suffix found, overwriting existing filename")
    else
        logger.info("OPDS: Converting placeholder filename to clean filename")
        logger.info("OPDS: From:", placeholder_path)
        logger.info("OPDS: To:  ", filepath)
    end

    local download_url = book_info.download_url
    if not download_url or download_url == "" then
        download_url = self.opds_url .. "/" .. book_id .. "/download"
    end

    local loading = UIHelpers.createProgressMessage(_("Downloading book..."))
    UIManager:show(loading)
    
    local https = require("ssl.https")
    local ltn12 = require("ltn12")
    local mime = require("mime")
    
    local response_body = {}
    local headers = { ["Cache-Control"] = "no-cache", ["Pragma"] = "no-cache" }
    
    if self.opds_username and self.opds_password then
        local credentials = mime.b64(self.opds_username .. ":" .. self.opds_password)
        headers["Authorization"] = "Basic " .. credentials
    end
    
    local res, code = https.request{
        url = download_url,
        method = "GET",
        headers = headers,
        sink = ltn12.sink.table(response_body)
    }
    
    UIManager:close(loading)
    
    if not res or code ~= 200 then
        self.processing_download = false
        UIHelpers.showError(T(_("Download failed: HTTP %1"), code or "error"))
        return
    end
    
    local data = table.concat(response_body)
    if #data < Constants.MIN_VALID_BOOK_SIZE then
        self.processing_download = false
        UIHelpers.showError(_("Downloaded file appears invalid (too small)"))
        return
    end

    local file, err = io.open(temp_filepath, "wb")
    if not file then
        self.processing_download = false
        UIHelpers.showError(T(_("Failed to create file: %1"), err or "unknown"))
        return
    end

    file:write(data)
    file:close()

    local temp_attr = lfs.attributes(temp_filepath)
    if not temp_attr or temp_attr.mode ~= "file" then
        self.processing_download = false
        UIHelpers.showError(_("Download succeeded but temp file not found"))
        return
    end

    self:performSafeTransition(placeholder_path, temp_filepath, filepath)
end

function OPDSBrowser:performSafeTransition(placeholder_path, temp_filepath, filepath)
    local ReaderUI = require("apps/reader/readerui")
    local FileManager = require("apps/filemanager/filemanager")
    
    local blocking_ui = UIHelpers.showLoading(_("Finalizing download...\n\nReplacing placeholder..."))
    UIManager:show(blocking_ui)
    UIManager:forceRePaint()

    -- Step 1: Close Reader if open
    if ReaderUI.instance then
        logger.info("OPDS: Closing ReaderUI instance")
        UIManager:close(ReaderUI.instance)
        ReaderUI.instance = nil
    end

    collectgarbage()
    collectgarbage()

    -- Step 2: Switch to File Manager
    UIManager:scheduleIn(0.5, function()
        logger.info("OPDS: Transitioning to FileManager")
        local folder_path = filepath:match("(.*/)")
        
        if FileManager.instance then
            FileManager.instance:reinit(folder_path)
        else
            FileManager:showFiles(folder_path)
        end
        
        -- Step 3: Perform file operations
        UIManager:scheduleIn(0.5, function()
            self:_swapFilesAndOpen(placeholder_path, temp_filepath, filepath, blocking_ui)
        end)
    end)
end

function OPDSBrowser:_swapFilesAndOpen(placeholder_path, temp_filepath, filepath, blocking_ui)
    local function cleanup(err_msg)
        self.processing_download = false
        if blocking_ui then UIManager:close(blocking_ui) end
        if err_msg then 
            UIManager:scheduleIn(0.1, function() UIHelpers.showError(err_msg) end)
        end
    end

    logger.info("OPDS: Swapping files...")

    if PlaceholderGenerator:isPlaceholder(temp_filepath) then
        os.remove(temp_filepath)
        cleanup(_("Download failed: Server returned a placeholder."))
        return
    end

    -- Attempt to clear locks before deleting
    pcall(function()
        require("docsettings"):open(placeholder_path):purge()
    end)

    local delete_success = false
    for i = 1, 5 do
        if os.remove(placeholder_path) then
            delete_success = true
            break
        end
        if not lfs.attributes(placeholder_path) then
            delete_success = true
            break
        end
        logger.warn("OPDS: Failed to delete placeholder, retrying...", i)
        socket.sleep(0.2)
        collectgarbage()
    end

    if not delete_success then
        os.remove(temp_filepath)
        cleanup(_("Failed to delete placeholder file. File may be locked."))
        return
    end

    self.library_sync.placeholder_db[placeholder_path] = nil
    self.library_sync:savePlaceholderDB()

    local rename_ok = os.rename(temp_filepath, filepath)
    if not rename_ok then
        os.remove(temp_filepath)
        cleanup(_("Failed to rename downloaded file"))
        return
    end

    -- Cache Clearing
    pcall(function()
        local DocSettings = require("docsettings")
        local ds_old = DocSettings:open(placeholder_path)
        ds_old:purge()
        ds_old:save() 
        local ds_new = DocSettings:open(filepath)
        ds_new:purge()
        ds_new:save()
    end)
    
    pcall(function()
        local ReadHistory = require("readhistory")
        if ReadHistory then
            ReadHistory:removeItemByPath(placeholder_path)
            ReadHistory:removeItemByPath(filepath)
            if ReadHistory.purge then
                ReadHistory:purge(placeholder_path)
                ReadHistory:purge(filepath)
            end
            ReadHistory:flush()
        end
    end)

    pcall(function()
        local DocumentRegistry = require("documentregistry")
        if DocumentRegistry then
            if DocumentRegistry.registry then
                DocumentRegistry.registry[placeholder_path] = nil
                DocumentRegistry.registry[filepath] = nil
            end
            if DocumentRegistry.provider_cache then
                DocumentRegistry.provider_cache[placeholder_path] = nil
                DocumentRegistry.provider_cache[filepath] = nil
            end
            if DocumentRegistry.purge then
                DocumentRegistry:purge(placeholder_path)
                DocumentRegistry:purge(filepath)
            end
        end
    end)

    pcall(function()
        local GlobalCache = require("cache")
        if GlobalCache then
            if GlobalCache.removeEntry then
                GlobalCache:removeEntry(placeholder_path)
                GlobalCache:removeEntry(filepath)
            end
            if GlobalCache.flush then GlobalCache:flush() end
            if GlobalCache.cache then
                GlobalCache.cache[placeholder_path] = nil
                GlobalCache.cache[filepath] = nil
            end
        end
    end)
    
    pcall(function()
        local DocumentCache = require("ui/document/documentcache")
        if DocumentCache and DocumentCache.discard then
             DocumentCache:discard(placeholder_path)
             DocumentCache:discard(filepath)
        end
    end)

    pcall(function()
        local BookDB = require("apps/filemanager/db")
        if BookDB then
            if BookDB.removeBook then
                BookDB:removeBook(placeholder_path)
                BookDB:removeBook(filepath)
            end
            if BookDB.refreshBook then
                BookDB:refreshBook(filepath)
            end
        end
    end)

    local filename = placeholder_path:match("([^/]+)$") or ""
    if filename ~= "" then
        local book_id_pattern = filename:gsub("%.kepub%.epub$", ""):gsub("%.epub$", "")
        if book_id_pattern ~= "" then
            CacheManager:invalidatePattern(book_id_pattern)
        end
    end
    
    collectgarbage()
    collectgarbage()

    local FileManager = require("apps/filemanager/filemanager")
    if FileManager.instance then
        FileManager.instance:onRefresh()
    end

    logger.info("OPDS: Opening new book:", filepath)
    local ReaderUI = require("apps/reader/readerui")
    
    if blocking_ui then UIManager:close(blocking_ui) end
    
    -- Wait a moment, then allow processing again
    UIManager:scheduleIn(2.0, function()
        self.processing_download = false
    end)
    
    UIManager:scheduleIn(0.5, function()
        ReaderUI:showReader(filepath)
    end)
end

function OPDSBrowser:onReaderReady(config)
    logger.info("OPDS: onReaderReady triggered")

    -- STOP: If we are currently downloading/swapping, do NOT trigger again
    if self.processing_download then
        logger.info("OPDS: Already processing a download, ignoring onReaderReady")
        return
    end

    UIManager:scheduleIn(3.0, function()
        -- Re-check processing flag in case it started during delay
        if self.processing_download then return end

        local ReaderUI = require("apps/reader/readerui")
        if not ReaderUI.instance or not ReaderUI.instance.document then
            return 
        end

        local current_file = ReaderUI.instance.document.file
        logger.info("OPDS: Checking file:", current_file)
        
        local lookup_path = current_file
        local attr = lfs.symlinkattributes(current_file)
        if attr and attr.mode == "link" then
            local target = lfs.readlink(current_file)
            if target then
                if not target:match("^/") then
                    local dir = current_file:match("(.*/)")
                    lookup_path = dir .. target
                else
                    lookup_path = target
                end
                logger.info("OPDS: Resolved symlink to:", lookup_path)
            end
        end

        local book_info = self.library_sync:getBookInfo(lookup_path)
        if book_info then
            logger.info("OPDS: Found in DB, triggering download")
            UIManager:scheduleIn(0.5, function()
                self:downloadPlaceholderAndRefresh(current_file, book_info)
            end)
        else
            local f_attr = lfs.attributes(lookup_path)
            if f_attr and f_attr.size and f_attr.size > 200000 then
                 return
            end

            if PlaceholderGenerator:isPlaceholder(lookup_path) then
                logger.info("OPDS: Detected via file content, triggering download")
                UIManager:scheduleIn(0.5, function()
                    self:handlePlaceholderAutoDownload(lookup_path)
                end)
            end
        end
    end)
end

function OPDSBrowser:handlePlaceholderAutoDownload(filepath)
    if self.processing_download then return end

    local real_filepath = filepath
    local attr = lfs.symlinkattributes(filepath)
    if attr and attr.mode == "link" then
        local target = lfs.readlink(filepath)
        if target then
            if not target:match("^/") then
                local dir = filepath:match("(.*/)")
                real_filepath = dir .. target
            else
                real_filepath = target
            end
        end
    end

    local book_info = self.library_sync:getBookInfo(real_filepath)
    if not book_info then
        UIHelpers.showError(_("Placeholder information not found."))
        return
    end

    self:downloadPlaceholderAndRefresh(real_filepath, book_info)
end

function OPDSBrowser:checkWorkflowHealth()
    local all_ok = true
    local issues = {}
    if not self.library_sync or not self.library_sync.getBookInfo then 
        all_ok = false 
        table.insert(issues, "Library Sync not ready")
    end
    if not self.opds_url or self.opds_url == "" then 
        all_ok = false 
        table.insert(issues, "OPDS URL missing")
    end
    return all_ok, issues
end

-- ============================================================================
-- UI MENUS & BROWSING LOGIC
-- ============================================================================

function OPDSBrowser:getMenuItems()
    return {
        { text = _("Library Sync - OPDS"),
          callback = function() self:buildPlaceholderLibrary() end,
          enabled_func = function() return self.opds_url ~= "" end },
        { text = _("Ephemera - Request New Book"),
          callback = function() self:requestBook() end,
          enabled_func = function() return self.ephemera_client:isConfigured() end },
        { text = _("Ephemera - View Download Queue"),
          callback = function() self:showDownloadQueue() end,
          enabled_func = function() return self.ephemera_client:isConfigured() end },
        { text = _("Hardcover - Search Author"),
          callback = function() self:hardcoverSearchAuthor() end,
          enabled_func = function() return self.hardcover_client:isConfigured() end },
        { text = _("History - Recent Searches"),
          callback = function() self:showSearchHistory() end },
        { text = _("History - Recently Viewed"),
          callback = function() self:showRecentBooks() end },
        { text = _("Plugin - Settings"),
          callback = function() self:showSettings() end },
        { text = _("Plugin - Cache Info"),
          callback = function() self:showCacheInfo() end },
        { text = _("Plugin - Workflow Health Check"),
          callback = function() self:showWorkflowHealthDialog() end },
    }
end

function OPDSBrowser:addToMainMenu(menu_items)
    menu_items.opdsbrowser = {
        text = _("Cloud Book Library"),
        sub_item_table = self:getMenuItems(),
    }
end

function OPDSBrowser:showMainMenu()
    local items = self:getMenuItems()
    local menu = UIHelpers.createMenu(_("Cloud Book Library"), items, { scrollable = true })
    UIManager:show(menu)
end

function OPDSBrowser:showBookList(books, title)
    local items = {}
    for _, book in ipairs(books) do
        local display_text = book.title
        if book.series and book.series ~= "" then
            display_text = display_text .. " - " .. book.series
            if book.series_index and book.series_index ~= "" then
                display_text = display_text .. " #" .. tostring(book.series_index)
            end
        end
        display_text = display_text .. " - " .. book.author

        table.insert(items, {
            text = display_text,
            callback = function()
                HistoryManager:addRecentBook({
                    title = book.title,
                    author = book.author,
                    series = book.series,
                })
                self:showBookDetails(book)
            end,
        })
    end

    self.book_menu = UIHelpers.createMenu(title or _("OPDS Books"), items)
    UIManager:show(self.book_menu)
end

function OPDSBrowser:showBookDetails(book)
    local series_text = ""
    if book.series and book.series ~= "" then
        series_text = "\n\n" .. T(_("Series: %1"), book.series)
        if book.series_index and book.series_index ~= "" then
            series_text = series_text .. " - " .. book.series_index
        end
    end
    
    local bookmark_status = HistoryManager:isBookmarked(book.title, book.author) and " ★" or ""
    local details = T(_("Title: %1%2\n\nAuthor: %3"), book.title, bookmark_status, book.author) .. series_text .. "\n\n" .. book.summary

    local buttons = {
        {
            { text = _("Download"), callback = function()
                UIManager:close(self.book_details)
                self:downloadBook(book)
            end },
            { text = bookmark_status == "" and _("Bookmark") or _("Unbookmark"), callback = function()
                if HistoryManager:isBookmarked(book.title, book.author) then
                    HistoryManager:removeBookmark(book.title, book.author)
                    UIHelpers.showSuccess(_("Bookmark removed"))
                else
                    HistoryManager:addBookmark({
                        title = book.title,
                        author = book.author,
                        series = book.series,
                        summary = book.summary,
                    })
                    UIHelpers.showSuccess(_("Bookmarked!"))
                end
                UIManager:close(self.book_details)
            end },
        },
        {
            { text = _("Close"), callback = function() UIManager:close(self.book_details) end },
        },
    }

    self.book_details = UIHelpers.createTextViewer(book.title, details, buttons)
    UIManager:show(self.book_details)
end

function OPDSBrowser:downloadBook(book)
    local dir_exists = lfs.attributes(self.download_dir, "mode") == "directory"
    if not dir_exists then
        local ok = lfs.mkdir(self.download_dir)
        if not ok then
            UIHelpers.showError(_("Failed to create download directory"))
            return
        end
    end

    local book_id = book.id:match("book:(%d+)$")
    if not book_id or book_id == "" then
        UIHelpers.showError(_("Cannot download: Book ID not found"))
        return
    end

    local extension = ".epub"
    if book.media_type and book.media_type:match("kepub") then
        extension = ".kepub.epub"
    elseif book.download_url and book.download_url:lower():match("kepub") then
        extension = ".kepub.epub"
    end

    local filename = book.title:gsub("[^%w%s%-]", ""):gsub("%s+", "_") .. extension
    local filepath = self.download_dir .. "/" .. filename
    local download_url = self.opds_url .. "/" .. book_id .. "/download"
    
    local loading = UIHelpers.createProgressMessage(_("Downloading..."))
    UIManager:show(loading)
    
    local https = require("ssl.https")
    local ltn12 = require("ltn12")
    local mime = require("mime")
    local response_body = {}
    local headers = { ["Cache-Control"] = "no-cache" }
    
    if self.opds_username and self.opds_password then
        local credentials = mime.b64(self.opds_username .. ":" .. self.opds_password)
        headers["Authorization"] = "Basic " .. credentials
    end
    
    local res, code = https.request{
        url = download_url,
        method = "GET",
        headers = headers,
        sink = ltn12.sink.table(response_body)
    }
    
    UIManager:close(loading)
    
    if not res or code ~= 200 then
        UIHelpers.showError(T(_("Download failed: HTTP %1"), code or "error"))
        return
    end
    
    local file, err = io.open(filepath, "wb")
    if not file then
        UIHelpers.showError(T(_("Failed to create file: %1"), err or "unknown"))
        return
    end
    file:write(table.concat(response_body))
    file:close()
    
    UIHelpers.showSuccess(T(_("Downloaded: %1"), book.title))
end

function OPDSBrowser:requestBook()
    UIHelpers.createMultiInputDialog(
        _("Request Book via Ephemera"),
        {
            { text = "", hint = _("Book Title"), input_type = "string" },
            { text = "", hint = _("Author (optional)"), input_type = "string" },
        },
        function(fields)
            local title = Utils.trim(fields[1] or "")
            local author = Utils.trim(fields[2] or "")
            if title ~= "" then
                self:searchEphemera(title, author)
            end
        end
    )
end

function OPDSBrowser:searchEphemera(title, author)
    if not self:ensureNetwork() then return end
    
    local loading = UIHelpers.showLoading(_("Searching Ephemera..."))
    UIManager:show(loading)
    
    local search_string = title
    if author ~= "" then search_string = search_string .. " " .. author end
    
    local ok, results = self.ephemera_client:search(search_string)
    UIManager:close(loading)
    
    if not ok then
        UIHelpers.showError(T(_("Ephemera search failed: %1"), results))
        return
    end
    
    results = self.ephemera_client:filterResults(results, { epub_only = true })
    if #results == 0 then
        UIHelpers.showInfo(_("No EPUB books found in Ephemera"))
        return
    end
    
    self:showEphemeraResults(results)
end

function OPDSBrowser:showEphemeraResults(results)
    local items = {}
    for _, book in ipairs(results) do
        local title = Utils.safe_string(book.title, "Unknown Title")
        local author = self.ephemera_client:formatAuthor(book.authors)
        local display_text = title .. " - " .. author
        table.insert(items, {
            text = display_text,
            callback = function() self:requestEphemeraBook(book) end
        })
    end
    self.ephemera_menu = UIHelpers.createMenu(T(_("Ephemera Results (%1)"), #results), items)
    UIManager:show(self.ephemera_menu)
end

function OPDSBrowser:requestEphemeraBook(book)
    local loading = UIHelpers.showLoading(_("Requesting download..."))
    UIManager:show(loading)
    local ok, result = self.ephemera_client:requestDownload(book)
    UIManager:close(loading)
    
    if not ok then
        UIHelpers.showError(T(_("Request failed: %1"), result))
        return
    end
    UIHelpers.showInfo(T(_("Status: %1"), result.status or "unknown"))
    if self.ephemera_menu then UIManager:close(self.ephemera_menu) end
end

function OPDSBrowser:showDownloadQueue()
    if not self:ensureNetwork() then return end
    local loading = UIHelpers.showLoading(_("Loading queue..."))
    UIManager:show(loading)
    local ok, queue = self.ephemera_client:getQueue()
    UIManager:close(loading)
    if not ok then
        UIHelpers.showError(T(_("Failed to load queue: %1"), queue))
        return
    end
    self:displayDownloadQueue(queue)
end

function OPDSBrowser:displayDownloadQueue(queue)
    local items = {}
    local has_incomplete = self.ephemera_client:hasIncompleteItems(queue)

    local function addItems(category, status_label, icon)
        if category then
            for md5, item in pairs(category) do
                local title = Utils.safe_string(item.title, "Unknown")
                local status_text = status_label
                if item.status == "downloading" and item.progress then
                    status_text = status_text .. string.format(" (%d%%)", math.floor(item.progress))
                end
                if item.error then status_text = status_text .. " - " .. item.error end
                table.insert(items, {
                    text = icon .. " " .. title,
                    subtitle = status_text,
                    md5 = md5,
                    status = item.status,
                })
            end
        end
    end

    addItems(queue.downloading, "Downloading", Constants.ICONS.DOWNLOADING)
    addItems(queue.queued, "Queued", Constants.ICONS.QUEUED)
    addItems(queue.delayed, "Delayed", Constants.ICONS.DELAYED)
    addItems(queue.available, "Available", Constants.ICONS.AVAILABLE)
    addItems(queue.done, "Done", Constants.ICONS.DONE)
    addItems(queue.error, "Error", Constants.ICONS.ERROR)
    addItems(queue.cancelled, "Cancelled", Constants.ICONS.CANCELLED)

    if #items == 0 then
        UIHelpers.showInfo(_("Download queue is empty"))
        return
    end

    self.queue_menu_open = true
    table.insert(items, { text = _("Close"), callback = function()
        self.queue_menu_open = false
        self:stopQueueRefresh()
        if self.queue_menu then
            UIManager:close(self.queue_menu)
            self.queue_menu = nil
        end
    end })

    self.queue_menu = UIHelpers.createMenu(_("Download Queue (Ephemera)"), items)
    UIManager:show(self.queue_menu)

    if has_incomplete then self:startQueueRefresh() else self:stopQueueRefresh() end
end

function OPDSBrowser:startQueueRefresh()
    self:stopQueueRefresh()
    self.queue_refresh_action = function()
        if not self.queue_menu_open or not self.queue_menu then
            self:stopQueueRefresh()
            return
        end
        local ok, queue = self.ephemera_client:getQueue()
        if ok and self.queue_menu and self.queue_menu_open then
            UIManager:close(self.queue_menu)
            self.queue_menu = nil
            self:displayDownloadQueue(queue)
        end
    end
    UIManager:scheduleIn(Constants.QUEUE_REFRESH_INTERVAL, self.queue_refresh_action)
end

function OPDSBrowser:stopQueueRefresh()
    if self.queue_refresh_action then
        UIManager:unschedule(self.queue_refresh_action)
        self.queue_refresh_action = nil
    end
    self.queue_menu_open = false
end

function OPDSBrowser:hardcoverSearchAuthor()
    UIHelpers.createInputDialog(_("Search Author"), _("Enter author name"), function(author_name)
        if author_name and author_name ~= "" then
            self:performHardcoverAuthorSearch(author_name)
        end
    end)
end

function OPDSBrowser:performHardcoverAuthorSearch(author_name)
    if not self:ensureNetwork() then return end
    local loading = UIHelpers.showLoading(_("Searching Hardcover..."))
    UIManager:show(loading)
    local ok, results = self.hardcover_client:searchAuthor(author_name)
    UIManager:close(loading)
    if not ok then
        UIHelpers.showError(T(_("Hardcover search failed: %1"), results))
        return
    end
    self:showHardcoverAuthorResults(results)
end

function OPDSBrowser:showHardcoverAuthorResults(results)
    if not results.hits or #results.hits == 0 then
        UIHelpers.showInfo(_("No authors found"))
        return
    end
    local items = {}
    for _, hit in ipairs(results.hits) do
        local author = hit.document
        local display_text = Utils.safe_string(author.name, "Unknown Author")
        if author.books and #author.books > 0 then
            display_text = display_text .. " - Known for " .. author.books[1]
        end
        table.insert(items, {
            text = display_text,
            callback = function()
                HistoryManager:addRecentAuthor(author.name)
                self:hardcoverGetAuthorBooks(author.id, author.name)
            end,
        })
    end
    self.hardcover_menu = UIHelpers.createMenu(_("Hardcover Authors"), items)
    UIManager:show(self.hardcover_menu)
end

function OPDSBrowser:hardcoverGetAuthorBooks(author_id, author_name)
    if not self:ensureNetwork() then return end
    local loading = UIHelpers.showLoading(_("Loading books..."))
    UIManager:show(loading)
    local ok, books = self.hardcover_client:getAuthorBooks(author_id)
    UIManager:close(loading)
    if not ok then
        UIHelpers.showError(T(_("Failed to load books: %1"), books))
        return
    end
    self:showHardcoverAuthorFilterOptions(books, author_name, author_id)
end

function OPDSBrowser:showHardcoverAuthorFilterOptions(books, author_name, author_id)
    self.hardcover_all_books = books
    local items = {
        { text = _("Standalone Books"), callback = function() UIManager:close(self.filter_menu); self:showHardcoverStandaloneBooks(books, author_name) end },
        { text = _("Book Series"), callback = function() UIManager:close(self.filter_menu); self:showHardcoverBookSeries(author_id, author_name) end },
        { text = _("All Books"), callback = function() UIManager:close(self.filter_menu); self:showHardcoverAllBooks(books, author_name) end },
    }
    self.filter_menu = UIHelpers.createMenu(T(_("Books by %1"), author_name), items)
    UIManager:show(self.filter_menu)
end

function OPDSBrowser:showHardcoverStandaloneBooks(books, author_name)
    local standalone_books = {}
    for _, book in ipairs(books) do
        if not (book.book_series and #book.book_series > 0) then
            table.insert(standalone_books, book)
        end
    end
    self:showHardcoverBookList(standalone_books, author_name, T(_("Standalone Books - %1"), author_name))
end

function OPDSBrowser:showHardcoverBookSeries(author_id, author_name)
    if not self:ensureNetwork() then return end
    local loading = UIHelpers.showLoading(_("Loading series..."))
    UIManager:show(loading)
    local ok, series_list = self.hardcover_client:getAuthorSeries(author_id)
    UIManager:close(loading)
    if not ok then
        UIHelpers.showError(T(_("Failed to load series: %1"), series_list))
        return
    end
    local items = {}
    for _, series in ipairs(series_list) do
        local book_count = Utils.safe_number(series.books_count, 0)
        table.insert(items, {
            text = series.name .. " (" .. book_count .. ")",
            callback = function() self:showHardcoverSeriesBooks(series.id, series.name, author_name) end,
        })
    end
    self.series_menu = UIHelpers.createMenu(T(_("Book Series - %1"), author_name), items)
    UIManager:show(self.series_menu)
end

function OPDSBrowser:showHardcoverSeriesBooks(series_id, series_name, author_name)
    if not self:ensureNetwork() then return end
    local loading = UIHelpers.showLoading(_("Loading books..."))
    UIManager:show(loading)
    local ok, series_data = self.hardcover_client:getSeriesBooks(series_id)
    UIManager:close(loading)
    if not ok then
        UIHelpers.showError(T(_("Failed to load books: %1"), series_data))
        return
    end
    local items = {}
    for _, book_series in ipairs(series_data.book_series or {}) do
        local book = book_series.book
        local position = Utils.safe_number(book_series.position, 0)
        table.insert(items, {
            text = book.title .. " #" .. position,
            callback = function() self:showHardcoverBookDetails(book, author_name) end,
        })
    end
    self.series_books_menu = UIHelpers.createMenu(series_name, items)
    UIManager:show(self.series_books_menu)
end

function OPDSBrowser:showHardcoverAllBooks(books, author_name)
    self:showHardcoverBookList(books, author_name, T(_("All Books - %1"), author_name))
end

function OPDSBrowser:showHardcoverBookList(books, author_name, title)
    local items = {}
    local author_books_lookup = self:getAuthorBooksFromLibrary(author_name)
    
    for _, book in ipairs(books) do
        local display_text = book.title
        if book.release_date then display_text = display_text .. " (" .. book.release_date .. ")" end
        if self.enable_library_check then
            if author_books_lookup[Utils.normalize_title(book.title)] then
                display_text = Constants.ICONS.IN_LIBRARY .. " " .. display_text
            end
        end
        table.insert(items, {
            text = display_text,
            callback = function() self:showHardcoverBookDetails(book, author_name) end,
        })
    end
    self.all_books_menu = UIHelpers.createMenu(title, items)
    UIManager:show(self.all_books_menu)
end

function OPDSBrowser:showHardcoverBookDetails(book, author_name)
    local book_author = author_name
    if book.contributions and #book.contributions > 0 then book_author = book.contributions[1].author.name end
    
    local details = T(_("Title: %1\n\nAuthor: %2"), book.title, book_author)
    if book.rating then details = details .. "\n\n" .. T(_("Rating: %1"), book.rating) end
    if book.description then details = details .. "\n\n" .. Utils.strip_html(book.description) end
    
    local buttons = {
        { { text = _("Download from Ephemera"), callback = function() UIManager:close(self.hardcover_book_details); self:downloadFromEphemera(book, book_author) end } },
        { { text = _("Close"), callback = function() UIManager:close(self.hardcover_book_details) end } }
    }
    self.hardcover_book_details = UIHelpers.createTextViewer(book.title, details, buttons)
    UIManager:show(self.hardcover_book_details)
end

function OPDSBrowser:downloadFromEphemera(book, author)
    if not self.ephemera_client:isConfigured() then
        UIHelpers.showError(_("Ephemera not configured"))
        return
    end
    local loading = UIHelpers.showLoading(_("Searching Ephemera..."))
    UIManager:show(loading)
    local ok, results = self.ephemera_client:search(author .. " " .. book.title)
    UIManager:close(loading)
    if not ok then
        UIHelpers.showError("Search failed")
        return
    end
    results = self.ephemera_client:filterResults(results, { epub_only = true, english_only = true })
    self:showEphemeraResults(Utils.table_slice(results, 1, 5))
end

function OPDSBrowser:getAuthorBooksFromLibrary(author)
    if not self.enable_library_check or not self.opds_url then return {} end
    local cache_key = Utils.generate_cache_key("author", author)
    local cached = CacheManager:get(cache_key)
    if cached then return cached end
    
    local query = url.escape(author)
    local all_xml = self.opds_client:fetchAllPages(self.opds_url .. "/catalog?q=" .. query, Constants.DEFAULT_PAGE_SIZE, self.library_check_page_limit)
    if not all_xml then return {} end
    
    local books = self.opds_client:parseBookloreOPDSFeed(all_xml, self.use_publisher_as_series)
    local lookup = {}
    for _, b in ipairs(books) do lookup[Utils.normalize_title(b.title)] = true end
    CacheManager:set(cache_key, lookup)
    return lookup
end

function OPDSBrowser:showSearchHistory()
    local history = HistoryManager:getSearchHistory()
    local items = {}
    for _, query in ipairs(history) do
        table.insert(items, {
            text = query,
            callback = function()
                UIManager:close(self.history_menu)
            end,
        })
    end
    self.history_menu = UIHelpers.createMenu(_("Recent Searches"), items)
    UIManager:show(self.history_menu)
end

function OPDSBrowser:showRecentBooks()
    local recent = HistoryManager:getRecentBooks()
    local items = {}
    for _, book in ipairs(recent) do
        table.insert(items, {
            text = book.title,
            callback = function() self:showBookDetails(book) end,
        })
    end
    self.recent_menu = UIHelpers.createMenu(_("Recently Viewed"), items)
    UIManager:show(self.recent_menu)
end

function OPDSBrowser:showSettings()
    local items = {
        { text = _("OPDS Settings"), callback = function() self:showOPDSSettings() end },
        { text = _("Ephemera Settings"), callback = function() self:showEphemeraSettings() end },
        { text = _("Hardcover Settings"), callback = function() self:showHardcoverSettings() end },
        { text = _("Plugin Settings"), callback = function() self:showPluginSettings() end }
    }
    local menu = UIHelpers.createMenu(_("Settings"), items, { scrollable = true })
    UIManager:show(menu)
end

function OPDSBrowser:showOPDSSettings()
    local fields = {
        { text = self.opds_url, hint = _("URL"), input_type = "string" },
        { text = self.opds_username, hint = _("User"), input_type = "string" },
        { text = self.opds_password, hint = _("Pass"), input_type = "string" },
    }
    UIHelpers.createMultiInputDialog(_("OPDS Settings"), fields, function(fv)
        self:saveSettings({ opds_url = fv[1], opds_username = fv[2], opds_password = fv[3] })
    end)
end

function OPDSBrowser:showEphemeraSettings()
    local fields = { { text = self.ephemera_url, hint = _("URL"), input_type = "string" } }
    UIHelpers.createMultiInputDialog(_("Ephemera Settings"), fields, function(fv)
        self:saveSettings({ ephemera_url = fv[1] })
    end)
end

function OPDSBrowser:showHardcoverSettings()
    local fields = {
        { text = self.hardcover_token, hint = _("Token"), input_type = "string" },
        { text = self.enable_library_check and "YES" or "NO", hint = _("Check Lib?"), input_type = "string" },
        { text = tostring(self.library_check_page_limit), hint = _("Limit"), input_type = "number" },
    }
    UIHelpers.createMultiInputDialog(_("Hardcover Settings"), fields, function(fv)
        self:saveSettings({ hardcover_token = fv[1], enable_library_check = fv[2], library_check_page_limit = fv[3] })
    end)
end

function OPDSBrowser:showPluginSettings()
    local fields = {
        { text = self.download_dir, hint = _("Dir"), input_type = "string" },
        { text = self.use_publisher_as_series and "YES" or "NO", hint = _("Pub Series?"), input_type = "string" },
        { text = self.library_sync.base_library_path, hint = _("Sync Path"), input_type = "string" },
    }
    UIHelpers.createMultiInputDialog(_("Plugin Settings"), fields, function(fv)
        self:saveSettings({ download_dir = fv[1], use_publisher_as_series = fv[2], library_sync_path = fv[3] })
    end)
end

function OPDSBrowser:saveSettings(new_values)
    local updates = {}
    if new_values.opds_url then updates.opds_url = new_values.opds_url; self.opds_url = new_values.opds_url end
    if new_values.opds_username then updates.opds_username = new_values.opds_username; self.opds_username = new_values.opds_username end
    if new_values.opds_password then updates.opds_password = new_values.opds_password; self.opds_password = new_values.opds_password end
    if new_values.ephemera_url then updates.ephemera_url = new_values.ephemera_url; self.ephemera_url = new_values.ephemera_url end
    if new_values.download_dir then updates.download_dir = new_values.download_dir; self.download_dir = new_values.download_dir end
    if new_values.hardcover_token then updates.hardcover_token = new_values.hardcover_token; self.hardcover_token = new_values.hardcover_token end
    if new_values.use_publisher_as_series then updates.use_publisher_as_series = Utils.safe_boolean(new_values.use_publisher_as_series); self.use_publisher_as_series = updates.use_publisher_as_series end
    if new_values.enable_library_check then updates.enable_library_check = Utils.safe_boolean(new_values.enable_library_check); self.enable_library_check = updates.enable_library_check end
    if new_values.library_check_page_limit then updates.library_check_page_limit = tonumber(new_values.library_check_page_limit); self.library_check_page_limit = updates.library_check_page_limit end
    if new_values.library_sync_path then updates.library_sync_path = new_values.library_sync_path; LibrarySyncManager:init(new_values.library_sync_path) end

    SettingsManager:setAll(updates)
    self.opds_client:setCredentials(self.opds_url, self.opds_username, self.opds_password)
    self.hardcover_client:setToken(self.hardcover_token)
    self.ephemera_client:setBaseURL(self.ephemera_url)
    if new_values.opds_url or new_values.ephemera_url or new_values.hardcover_token then CacheManager:clear() end
    UIHelpers.showSuccess(_("Settings saved"))
end

function OPDSBrowser:showCacheInfo()
    local stats = CacheManager:getCacheStats()
    local details = string.format("Entries: %d", stats.total_entries)
    local buttons = { { { text = _("Clear"), callback = function() UIManager:close(self.cache_info); CacheManager:clear() end } }, { { text = _("Close"), callback = function() UIManager:close(self.cache_info) end } } }
    self.cache_info = UIHelpers.createTextViewer(_("Cache Info"), details, buttons)
    UIManager:show(self.cache_info)
end

function OPDSBrowser:showWorkflowHealthDialog()
    local ok, issues = self:checkWorkflowHealth()
    local msg = ok and "Status: OK\n\nAll systems operational." or "Status: Issues Detected\n\n" .. table.concat(issues, "\n")
    self.health_dialog = UIHelpers.createTextViewer(_("Workflow Health"), msg, { { { text = _("Close"), callback = function() UIManager:close(self.health_dialog) end } } })
    UIManager:show(self.health_dialog)
end

function OPDSBrowser:buildPlaceholderLibrary()
    if not self:ensureNetwork() then return end
    self:performLibrarySync()
end

function OPDSBrowser:performLibrarySync()
    local loading = UIHelpers.showLoading(_("Fetching library catalog..."))
    UIManager:show(loading)
    
    local all_xml = self.opds_client:fetchAllPages(self.opds_url .. "/catalog", Constants.DEFAULT_PAGE_SIZE, 0)
    
    if not all_xml then
        UIManager:close(loading)
        UIHelpers.showError(_("Failed to fetch library catalog"))
        return
    end

    local books = self.opds_client:parseBookloreOPDSFeed(all_xml, self.use_publisher_as_series)
    
    if #books == 0 then
        UIManager:close(loading)
        UIHelpers.showInfo(_("No books found in library"))
        return
    end
    
    local progress_count = 0
    local last_update_time = os.time()
    local ok, result = self.library_sync:syncLibrary(books, function(current, total)
        progress_count = progress_count + 1
        local current_time = os.time()
        if progress_count % 50 == 0 or (current_time - last_update_time) >= 1 then
            UIManager:close(loading)
            loading = UIHelpers.showLoading(T(_("Syncing... %1/%2"), current, total))
            UIManager:show(loading)
            UIManager:forceRePaint()
            last_update_time = current_time
        end
    end)
    
    UIManager:close(loading)
    
    if not ok then
        UIHelpers.showError(T(_("Sync failed: %1"), result))
        return
    end
    
    local summary = T(_("Library Sync Complete!\n\nCreated: %1\nUpdated: %2\nSkipped: %3\nFailed: %4\nTotal: %5"),
        result.created, result.updated, result.skipped, result.failed, result.total)
    
    UIHelpers.showInfo(summary, 10)

    UIManager:scheduleIn(0.5, function()
        local FileManager = require("apps/filemanager/filemanager")
        if FileManager.instance then
            FileManager.instance:onRefresh()
        end
    end)
end

function OPDSBrowser:onCloseDocument()
    self:stopQueueRefresh()
    CacheManager:savePersistentCache()
end

function OPDSBrowser:onSuspend()
    self:stopQueueRefresh()
    CacheManager:savePersistentCache()
end

function OPDSBrowser:onExit()
    CacheManager:savePersistentCache()
end

return OPDSBrowser
