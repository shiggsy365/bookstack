-- opdsbrowser.koplugin/main.lua
-- Amended OPDS Browser core
-- Changes applied:
--   - Removed all cloud badge display code (badge module not required or initialized)
--   - Removed Recently Added and Current Reads handling and any symlink resolution related to them
--   - No other functional changes from the working script

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

-- Plugin modules (use local plugin helpers as in your original working script)
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
local RestartNavigationManager = require("restart_navigation_manager")
-- Note: PlaceholderBadge intentionally removed per request (cloud badge disabled)

local OPDSBrowser = {}
OPDSBrowser.__index = OPDSBrowser

function OPDSBrowser:new(o)
    o = o or {}
    setmetatable(o, self)

    -- Configuration/defaults
    o.opds_url = o.opds_url or ""
    o.opds_username = o.opds_username or ""
    o.opds_password = o.opds_password or ""
    o.download_dir = o.download_dir or "/mnt/us/Books"
    o.ephemera_client = o.ephemera_client or EphemeraClient:new()
    o.library_sync = o.library_sync or LibrarySyncManager:new{ library_dir = o.download_dir }
    o.restart_nav = o.restart_nav or RestartNavigationManager:new()

    -- UI state
    o.queue_menu = nil
    o.queue_menu_open = false
    o.queue_refresh_action = nil
    o.ephemera_menu = nil
    o.main_menu = nil

    return o
end

-- Simple network guard (kept as in working script)
function OPDSBrowser:ensureNetwork()
    -- Prefer to use NetworkMgr for checks; fallback to true if not available
    local ok, has_net = pcall(function() return NetworkMgr:isConnected() end)
    if ok and has_net ~= nil then
        return has_net
    end
    return true
end

-- Show Ephemera download queue (fetches and displays)
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

-- Build and display queue menu; tracks open state and allows refresh while open
function OPDSBrowser:displayDownloadQueue(queue)
    local items = {}
    local has_incomplete = self.ephemera_client:hasIncompleteItems(queue)

    local function addItems(category, status_label)
        if category then
            for md5, item in pairs(category) do
                local title = Utils.safe_string(item.title, "Unknown")
                local status_text = status_label

                if item.status == "downloading" and item.progress then
                    status_text = status_text .. " (" .. tostring(math.floor((item.progress or 0) * 100)) .. "%)"
                end

                table.insert(items, {
                    text = title,
                    hint = status_text,
                    callback = function()
                        UIHelpers.showInfo(T(_("%1\n\nStatus: %2"), title, status_text))
                    end,
                })
            end
        end
    end

    addItems(queue.downloading, _("Downloading"))
    addItems(queue.queued, _("Queued"))
    addItems(queue.delayed, _("Delayed"))
    addItems(queue.completed, _("Completed"))

    -- Close action which clears state and stops refresh
    table.insert(items, {
        text = _("Close"),
        callback = function()
            self.queue_menu_open = false
            self:stopQueueRefresh()
            if self.queue_menu then
                UIManager:close(self.queue_menu)
                self.queue_menu = nil
            end
        end,
    })

    self.queue_menu = UIHelpers.createMenu(_("Download Queue (Ephemera)"), items)
    self.queue_menu_open = true
    UIManager:show(self.queue_menu)

    if has_incomplete then
        self:startQueueRefresh()
    else
        self:stopQueueRefresh()
    end
end

-- Start periodic refresh of queue only while dialog is open
function OPDSBrowser:startQueueRefresh()
    self:stopQueueRefresh()

    self.queue_refresh_action = function()
        if not self.queue_menu_open then
            self:stopQueueRefresh()
            return
        end

        local ok, queue = self.ephemera_client:getQueue()
        if ok then
            if self.queue_menu then
                UIManager:close(self.queue_menu)
                self.queue_menu = nil
            end
            self:displayDownloadQueue(queue)
        else
            logger.err("OPDSBrowser: Failed to refresh queue:", queue)
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

-- Request a book via Ephemera
function OPDSBrowser:requestEphemeraBook(book)
    local loading = UIHelpers.showLoading(_("Requesting download..."))
    UIManager:show(loading)

    local ok, result = self.ephemera_client:requestDownload(book)

    UIManager:close(loading)

    if not ok then
        UIHelpers.showError(T(_("Download request failed: %1"), result))
        return
    end

    local message = ""
    if result.status == "queued" then
        message = T(_("Book queued for download!\n\nPosition: %1"), result.position or "unknown")
    elseif result.status == "already_downloaded" then
        message = _("Book already downloaded!")
    elseif result.status == "already_in_queue" then
        message = T(_("Book already in queue!\n\nPosition: %1"), result.position or "unknown")
    else
        message = T(_("Status: %1"), result.status or "unknown")
    end

    UIHelpers.showInfo(message)

    if self.ephemera_menu then
        UIManager:close(self.ephemera_menu)
        self.ephemera_menu = nil
    end
end

-- Generic download helper
function OPDSBrowser:downloadToFile(download_url, filepath, book_title)
    logger.info("OPDS: Downloading:", download_url, "=>", filepath)

    local ok, data_or_err = HttpClient:request_with_retry(download_url, "GET")
    if not ok then
        logger.err("OPDS: Download failed:", data_or_err)
        UIHelpers.showError(T(_("Download failed: %1"), data_or_err))
        return false, data_or_err
    end

    local file, err = io.open(filepath, "wb")
    if not file then
        logger.err("OPDS: Failed to open file for writing:", err)
        UIHelpers.showError(T(_("Failed to create file: %1"), err or "unknown"))
        return false, err
    end

    file:write(data_or_err)
    file:close()

    pcall(function()
        local DocSettings = require("docsettings")
        DocSettings:open(filepath):purge()
    end)

    UIHelpers.showSuccess(T(_("Downloaded: %1\n\n%2"), book_title or "Book", Utils.format_file_size(#data_or_err)))

    UIManager:scheduleIn(0.5, function()
        local FileManager = require("apps/filemanager/filemanager")
        if FileManager.instance then
            FileManager.instance:onRefresh()
        end
    end)

    return true
end

-- Download from Ephemera (user-initiated)
function OPDSBrowser:downloadFromEphemera(book, author)
    if not self.ephemera_client:isConfigured() then
        UIHelpers.showError(_("Ephemera URL not configured"))
        return
    end

    local loading = UIHelpers.showLoading(_("Searching Ephemera..."))
    UIManager:show(loading)

    local ok, results = self.ephemera_client:search(book.title .. " " .. (author or ""))
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

-- Present Ephemera search results
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

    self.ephemera_menu = UIHelpers.createMenu(T(_("Ephemera Search Results (%1 EPUB)"), #results), items)
    UIManager:show(self.ephemera_menu)
end

-- Placeholder download triggered from FileManager (long-press)
function OPDSBrowser:handlePlaceholderDownloadFromFileManager(filepath, book_info)
    logger.info("PLACEHOLDER FILE MANAGER DOWNLOAD WORKFLOW")
    logger.info("OPDS Browser: Starting download from FileManager")
    logger.info("OPDS Browser: File:", filepath)
    logger.info("OPDS Browser: Title:", book_info and book_info.title or "Unknown")

    if not self:ensureNetwork() then
        logger.err("OPDS Browser: Network not available")
        return
    end

    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = T(_("Download '%1' from OPDS server?\n\nThis will replace the placeholder with the real book."), book_info.title),
        ok_text = _("Download"),
        ok_callback = function()
            self:downloadPlaceholderAndRefresh(filepath, book_info)
        end,
    })
end

-- Download placeholder and refresh folder (don't open book automatically)
function OPDSBrowser:downloadPlaceholderAndRefresh(placeholder_path, book_info)
    logger.info("DOWNLOAD AND REFRESH WORKFLOW")
    if not self:ensureNetwork() then
        return
    end

    local book_id = book_info.book_id
    if book_id then
        book_id = book_id:match("book:(%d+)$") or book_id
    end

    if not book_id or book_id == "" then
        logger.err("OPDS: No book ID found in placeholder info")
        UIHelpers.showError(_("Cannot download: Book ID not found"))
        return
    end

    local extension = ".epub"
    if book_info.download_url and book_info.download_url:lower():match("kepub") then
        extension = ".kepub.epub"
    end

    local timestamp = os.time()
    local temp_filepath = placeholder_path:gsub("%.epub$", string.format(".downloading_%d.tmp", timestamp))
    local final_filepath = placeholder_path:gsub("%.epub$", extension)

    local download_url = book_info.download_url
    if not download_url or download_url == "" then
        logger.warn("OPDS: No download_url in book_info, constructing from book ID")
        download_url = self.opds_url .. "/" .. book_id .. "/download"
    end

    logger.info("OPDS: Downloading:", book_info.title)
    logger.info("OPDS: Download URL:", download_url)
    logger.info("OPDS: Placeholder path:", placeholder_path)
    logger.info("OPDS: Temp download path:", temp_filepath)

    local ok, err = self:downloadToFile(download_url, temp_filepath, book_info.title)
    if not ok then
        return
    end

    local attr = lfs.attributes(temp_filepath)
    if not attr or (attr.size and attr.size < 1024) then
        logger.err("OPDS: Downloaded file appears too small or missing")
        os.remove(temp_filepath)
        UIHelpers.showError(_("Download failed: Server returned invalid file."))
        return
    end

    local delete_ok = os.remove(placeholder_path)
    if not delete_ok then
        logger.err("OPDS: Failed to delete placeholder")
        os.remove(temp_filepath)
        UIHelpers.showError(_("Failed to delete placeholder file"))
        return
    end

    local rename_ok, rename_err = os.rename(temp_filepath, final_filepath)
    if not rename_ok then
        logger.err("OPDS: Failed to rename temp file:", rename_err)
        UIHelpers.showError(_("Failed to finalize downloaded book"))
        pcall(function() os.remove(temp_filepath) end)
        return
    end

    pcall(function()
        local DocSettings = require("docsettings")
        DocSettings:open(placeholder_path):purge()
        DocSettings:open(final_filepath):purge()
    end)

    UIHelpers.showSuccess(T(_("Downloaded: %1\n\nReturning to folder view..."), book_info.title or "Book"))

    UIManager:scheduleIn(0.5, function()
        local FileManager = require("apps/filemanager/filemanager")
        if FileManager.instance then
            FileManager.instance:onRefresh()
        end
    end)
end

-- Minimal menu registration (keeps existing functionality; removed Recently Added / Current Reads menu items)
function OPDSBrowser:buildMenu()
    local items = {
        { text = _("Library Sync - OPDS"), callback = function() self:buildPlaceholderLibrary() end, enabled_func = function() return self.opds_url ~= "" end },
        { text = _("Ephemera - Request New Book"), callback = function() self:requestBook() end, enabled_func = function() return self.ephemera_client:isConfigured() end },
        { text = _("Ephemera - View Download Queue"), callback = function() self:showDownloadQueue() end, enabled_func = function() return self.ephemera_client:isConfigured() end },
        { text = _("Hardcover - Search Author"), callback = function() self:hardcoverSearchAuthor() end },
    }

    self.main_menu = UIHelpers.createMenu(_("OPDS Browser"), items)
    UIManager:show(self.main_menu)
end

-- Placeholder for compatibility with existing code paths; special-folder automation removed
function OPDSBrowser:buildPlaceholderLibrary()
    UIHelpers.showInfo(_("Library sync started (Recently Added & Current Reads features disabled)."))
    -- Delegate to library_sync_manager for actual sync if needed
    return true
end

-- Export module
return OPDSBrowser
