local BD = require("ui/bidi")
local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local DocSettings = require("docsettings")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local socket = require("socket")
local _ = require("gettext")
local T = require("ffi/util").template
local DocSettings = require("docsettings")
local ReadHistory = require("readhistory")

local HttpClient = require("http_client")
local lfs = require("libs/libkoreader-lfs")
local json = require("json")
local url = require("socket.url")

local OPDSBrowser = WidgetContainer:extend{
    name = "opdsbrowser",
    is_doc_only = false,
}

-- Helpers: unescape common HTML entities and strip HTML tags
local function html_unescape(s)
    if not s then return "" end
    s = tostring(s)
    -- numeric entities
    s = s:gsub("&#(%d+);", function(n) local v = tonumber(n); return v and string.char(v) or "" end)
    -- common named entities
    s = s:gsub("&lt;", "<")
    s = s:gsub("&gt;", ">")
    s = s:gsub("&quot;", '"')
    s = s:gsub("&#39;", "'")
    s = s:gsub("&nbsp;", " ")
    s = s:gsub("&amp;", "&")
    return s
end

local function strip_html(s)
    if not s then return "" end
    s = tostring(s)
    -- Unescape first so encoded tags become visible
    s = html_unescape(s)
    -- Remove comments
    s = s:gsub("<!--.-?-->", "")
    -- Remove script/style blocks conservatively
    s = s:gsub("<script.-</script>", "")
    s = s:gsub("<style.-</style>", "")
    -- Remove all tags (tolerant)
    s = s:gsub("<[^>]->", "") -- tolerant attempt for malformed tags
    s = s:gsub("<[^>]+>", "")
    -- Remove stray angle brackets
    s = s:gsub("[<>]", "")
    -- Collapse whitespace and trim
    s = s:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    return s
end

function OPDSBrowser:init()
    self.ui.menu:registerToMainMenu(self)
    self.settings_file = DataStorage:getSettingsDir() .. "/opdsbrowser.lua"
    self.settings = LuaSettings:open(self.settings_file)

    -- Load settings with defaults
    self.opds_url = self.settings:readSetting("opds_url") or ""
    self.opds_username = self.settings:readSetting("opds_username") or ""
    self.opds_password = self.settings:readSetting("opds_password") or ""
    self.ephemera_url = self.settings:readSetting("ephemera_url") or ""
    self.download_dir = self.settings:readSetting("download_dir") or DataStorage:getDataDir() .. "/mnt/us/books"
end

function OPDSBrowser:addToMainMenu(menu_items)
    menu_items.opdsbrowser = {
        text = _("Cloud Book Library"),
        sub_item_table = {
            { text = _("Browse by Author"), callback = function() self:browseAuthors() end, enabled_func = function() return self.opds_url ~= "" end },
            { text = _("Request Book (Ephemera)"), callback = function() self:requestBook() end, enabled_func = function() return self.ephemera_url ~= "" end },
            { text = _("Download Queue (Ephemera)"), callback = function() self:showDownloadQueue() end, enabled_func = function() return self.ephemera_url ~= "" end },
            { text = _("Settings"), callback = function() self:showSettings() end },
        },
    }
end

function OPDSBrowser:showSettings()
    local MultiInputDialog = require("ui/widget/multiinputdialog")
    self.settings_dialog = MultiInputDialog:new{
        title = _("Book Download Settings"),
        fields = {
            { text = self.opds_url, hint = _("Base URL (e.g., https://example.com)"), input_type = "string" },
            { text = self.opds_username, hint = _("OPDS Username (optional)"), input_type = "string" },
            { text = self.opds_password, hint = _("OPDS Password (optional)"), input_type = "string" },
            { text = self.ephemera_url, hint = _("Ephemera URL (e.g., http://example.com:8286)"), input_type = "string" },
            { text = self.download_dir, hint = _("Download Directory"), input_type = "string" },
        },
        buttons = {
            {
                { text = _("Cancel"), id = "close", callback = function()
                    self.settings_dialog:onClose()
                    UIManager:close(self.settings_dialog)
                end },
                { text = _("Save"), callback = function()
                    local fields = self.settings_dialog:getFields()
                    local new_opds_url = (fields[1] or ""):gsub("/$", ""):gsub("%s+", "")
                    local new_opds_username = fields[2] or ""
                    local new_opds_password = fields[3] or ""
                    local new_ephemera_url = (fields[4] or ""):gsub("/$", ""):gsub("%s+", "")
                    local new_download_dir = fields[5] or self.download_dir

                    if new_opds_url ~= "" and not new_opds_url:match("^https?://") then
                        UIManager:show(InfoMessage:new{ text = _("Invalid OPDS URL!\n\nURL must start with http:// or https://"), timeout = 3 })
                        return
                    end

                    if new_ephemera_url ~= "" and not new_ephemera_url:match("^https?://") then
                        UIManager:show(InfoMessage:new{ text = _("Invalid Ephemera URL!\n\nURL must start with http:// or https://"), timeout = 3 })
                        return
                    end

                    self.opds_url = new_opds_url
                    self.opds_username = new_opds_username
                    self.opds_password = new_opds_password
                    self.ephemera_url = new_ephemera_url
                    self.download_dir = new_download_dir

                    self.settings:saveSetting("opds_url", self.opds_url)
                    self.settings:saveSetting("opds_username", self.opds_username)
                    self.settings:saveSetting("opds_password", self.opds_password)
                    self.settings:saveSetting("ephemera_url", self.ephemera_url)
                    self.settings:saveSetting("download_dir", self.download_dir)
                    self.settings:flush()

                    UIManager:show(InfoMessage:new{ text = _("Settings saved successfully!"), timeout = 3 })
                    UIManager:close(self.settings_dialog)
                end },
            },
        },
    }
    UIManager:show(self.settings_dialog)
    self.settings_dialog:onShowKeyboard()
end

function OPDSBrowser:makeAuthHeader()
    if self.opds_username ~= "" and self.opds_password ~= "" then
        local mime = require("mime")
        local credentials = mime.b64(self.opds_username .. ":" .. self.opds_password)
        return "Basic " .. credentials
    end
    return nil
end

function OPDSBrowser:httpGet(url_str)
    if not NetworkMgr:isOnline() then
        NetworkMgr:beforeWifiAction()
        socket.sleep(1)
        if not NetworkMgr:isOnline() then
            return false, "Network unavailable"
        end
    end

    logger.info("OPDS Browser: Requesting URL:", url_str)

    local user = (self.opds_username and self.opds_username ~= "") and self.opds_username or nil
    local pass = (self.opds_password and self.opds_password ~= "") and self.opds_password or nil

    local ok, content_or_err = HttpClient:request(url_str, "GET", nil, nil, user, pass)
    if ok then
        return true, content_or_err
    end
    return false, content_or_err
end

function OPDSBrowser:parseOPDSFeed(xml_data)
    local entries = {}
    logger.info("OPDS Browser: Parsing OPDS feed, length:", #xml_data)
    logger.info("OPDS Browser: First 500 chars:", xml_data:sub(1, 500))

    local entry_count = 0
    for entry in xml_data:gmatch("<entry>(.-)</entry>") do
        entry_count = entry_count + 1
        local book = {}

        book.title = entry:match("<title[^>]*>(.-)</title>") or "Unknown Title"
        book.title = book.title:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&amp;", "&"):gsub("&quot;", '"')

        local author_block = entry:match("<author>(.-)</author>")
        if author_block then
            book.author = author_block:match("<name>(.-)</name>") or "Unknown Author"
        else
            book.author = "Unknown Author"
        end
        book.author = book.author:gsub("&amp;", "&")

        -- prefer <content> (xhtml) then <summary>
        local raw_summary = entry:match('<content[^>]*>(.-)</content>') or entry:match('<summary[^>]*>(.-)</summary>') or ""

        -- Extract SERIES from content BEFORE cleaning HTML.
        -- Capture the full SERIES line up to the first <br> (handles <br>, <br/>, <br />).
        do
            local un = html_unescape(raw_summary)
            -- collapse CR/LF to spaces so patterns work
            un = un:gsub("\r", " "):gsub("\n", " ")
            -- try to capture up to a <br ...> tag
            local s = un:match("[Ss][Ee][Rr][Ii][Ee][Ss]:%s*(.-)%s*<%s*br[^>]*>")
            if not s then
                -- fallback: capture up to a literal '</br>' or end, or up to next '<'
                s = un:match("[Ss][Ee][Rr][Ii][Ee][Ss]:%s*(.-)%s*</%s*br%s*>") or un:match("[Ss][Ee][Rr][Ii][Ee][Ss]:%s*([^<%r\n]+)")
            end
            if s then
                -- Clean the extracted series fragment (strip remaining tags/entities)
                s = strip_html(s)
                -- Try to split name and index like "Name [5]"
                local name, idx = s:match("^(.-)%s*%[([%d%-]+)%]$")
                if name and name ~= "" then
                    book.series = name
                    book.series_index = idx or ""
                else
                    book.series = s
                    book.series_index = ""
                end
            else
                -- fallback to dc/category tags if no inline SERIES line
                book.series = entry:match('category term="([^"]*)" label="[Ss]eries"') or entry:match('<dc:series>(.-)</dc:series>') or ""
                book.series_index = entry:match('<calibre:series_index>(.-)</calibre:series_index>') or ""
            end
        end

        -- Clean summary text for display (remove HTML markup)
        book.summary = strip_html(raw_summary)

        book.id = entry:match('<id>(.-)</id>') or ""

        for link in entry:gmatch('<link[^>]*rel="http://opds%-spec%.org/acquisition[^"]*"[^>]*>') do
            local href = link:match('href="([^"]*)"')
            local media_type = link:match('type="([^"]*)"')
            if href and not book.download_url then
                book.download_url = href
                book.media_type = media_type or "application/epub+zip"
            end
        end

        if not book.download_url then
            for link in entry:gmatch('<link[^>]*type="application/epub%+zip"[^>]*>') do
                local href = link:match('href="([^"]*)"')
                if href then
                    book.download_url = href
                    book.media_type = "application/epub+zip"
                    break
                end
            end
        end

        for link in entry:gmatch('<link[^>]*rel="http://opds%-spec%.org/image"[^>]*>') do
            local href = link:match('href="([^"]*)"')
            if href then
                book.cover_url = href
                break
            end
        end

        if book.download_url then
            table.insert(entries, book)
        else
            logger.warn("OPDS Browser: Skipping entry without download URL:", book.title)
        end
    end

    logger.info("OPDS Browser: Found", entry_count, "entries, parsed", #entries, "books")
    return entries
end

function OPDSBrowser:showBookList(books, title)
    local Menu = require("ui/widget/menu")
    local Screen = require("device").screen

    local items = {}
    for _, book in ipairs(books) do
        local series_info = ""
        if book.series ~= "" then
            series_info = " (" .. book.series
            if book.series_index ~= "" then
                series_info = series_info .. " #" .. book.series_index
            end
            series_info = series_info .. ")"
        end

        table.insert(items, {
            text = book.title .. series_info,
            subtitle = book.author,
            callback = function() self:showBookDetails(book) end,
        })
    end

    self.book_menu = Menu:new{
        title = title or _("OPDS Books"),
        item_table = items,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        onMenuHold = function() return true end,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
    }

    UIManager:show(self.book_menu)
end

function OPDSBrowser:showBookDetails(book)
    local ButtonDialog = require("ui/widget/buttondialog")
    local TextViewer = require("ui/widget/textviewer")

    local series_text = ""
    if book.series ~= "" then
        series_text = "\n\n" .. T(_("Series: %1"), book.series)
        if book.series_index ~= "" then
            series_text = series_text .. " #" .. book.series_index
        end
    end

    local details = T(_("Title: %1\n\nAuthor: %2"), book.title, book.author) .. series_text .. "\n\n" .. book.summary

    local buttons = {
        {
            { text = _("Download"), callback = function()
                UIManager:close(self.book_details)
                self:downloadBook(book)
            end },
        },
        {
            { text = _("Close"), callback = function() UIManager:close(self.book_details) end },
        },
    }

    self.book_details = TextViewer:new{ title = book.title, text = details, buttons_table = buttons }
    UIManager:show(self.book_details)
end

function OPDSBrowser:browseAuthors()
    local full_url = self.opds_url .. "/opds/author/letter/00"
    local ok, response_or_err = self:httpGet(full_url)
    if not ok then
        UIManager:show(InfoMessage:new{ text = T(_("Failed to load authors: %1"), response_or_err), timeout = 3 })
        return
    end

    local authors = self:parseAuthorsFromOPDS(response_or_err)
    if #authors > 0 then
        self:showAuthorList(authors)
    else
        UIManager:show(InfoMessage:new{ text = _("No authors found."), timeout = 3 })
    end
end

function OPDSBrowser:parseAuthorsFromOPDS(xml_data)
    local authors = {}
    logger.info("OPDS Browser: Parsing authors, XML length:", #xml_data)
    logger.info("OPDS Browser: First 500 chars:", xml_data:sub(1, 500))

    local entry_count = 0
    for entry in xml_data:gmatch("<entry>(.-)</entry>") do
        entry_count = entry_count + 1
        local author = {}
        author.name = entry:match("<title[^>]*>(.-)</title>") or "Unknown Author"
        author.name = author.name:gsub("&amp;", "&")

        local found_link = false

        for link in entry:gmatch('<link[^>]*type="application/atom%+xml"[^>]*>') do
            local href = link:match('href="([^"]*)"')
            if href then
                author.url = href
                found_link = true
                break
            end
        end

        if not found_link then
            for link in entry:gmatch('<link[^>]*rel="subsection"[^>]*>') do
                local href = link:match('href="([^"]*)"')
                if href then
                    author.url = href
                    found_link = true
                    break
                end
            end
        end

        if not found_link then
            local href = entry:match('<link[^>]*href="([^"]*)"')
            if href then
                author.url = href
                found_link = true
            end
        end

        if author.url then
            table.insert(authors, author)
        else
            logger.warn("OPDS Browser: Skipping author without URL:", author.name)
        end
    end

    logger.info("OPDS Browser: Found", entry_count, "entries, parsed", #authors, "authors")
    return authors
end

function OPDSBrowser:showAuthorList(authors)
    local Menu = require("ui/widget/menu")
    local Screen = require("device").screen

    local items = {}
    for _, author in ipairs(authors) do
        table.insert(items, {
            text = author.name,
            callback = function() self:browseBooksByAuthor(author.name, author.url) end,
        })
    end

    self.author_menu = Menu:new{
        title = _("Authors"),
        item_table = items,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
    }

    UIManager:show(self.author_menu)
end

function OPDSBrowser:browseBooksByAuthor(author_name, author_url)
    local full_url = self.opds_url .. author_url
    local ok, response_or_err = self:httpGet(full_url)
    if not ok then
        UIManager:show(InfoMessage:new{ text = T(_("Failed to load books. Code: %1"), response_or_err), timeout = 3 })
        return
    end

    local books = self:parseOPDSFeed(response_or_err)
    if #books > 0 then
        self:showBookList(books, T(_("Books by %1"), author_name))
    else
        UIManager:show(InfoMessage:new{ text = _("No books found for this author."), timeout = 3 })
    end
end

function OPDSBrowser:downloadBook(book)
    -- Ensure download directory exists
    local dir_exists = lfs.attributes(self.download_dir, "mode") == "directory"
    if not dir_exists then
        local ok = lfs.mkdir(self.download_dir)
        if not ok then
            UIManager:show(InfoMessage:new{ text = _("Failed to create download directory"), timeout = 3 })
            return
        end
    end

    -- Extract filename from URL or generate from title
    local filename = book.download_url:match("([^/]+)$")
    if not filename or filename == "" or not filename:match("%.") then
        filename = book.title:gsub("[^%w%s%-]", ""):gsub("%s+", "_") .. ".epub"
    end

    local filepath = self.download_dir .. "/" .. filename
    
    -- Check if download_url is already absolute
    local download_url
    if book.download_url:match("^https?://") then
        download_url = book.download_url
    else
        -- Ensure there's a leading slash if the URL is relative
        local relative_url = book.download_url
        if not relative_url:match("^/") then
            relative_url = "/" .. relative_url
        end
        download_url = self.opds_url .. relative_url
    end
    
    logger.info("OPDS Browser: Downloading:", book.title)
    logger.info("OPDS Browser: URL:", download_url)

    -- Credentials (may be nil)
    local user = (self.opds_username and self.opds_username ~= "") and self.opds_username or nil
    local pass = (self.opds_password and self.opds_password ~= "") and self.opds_password or nil

    UIManager:show(InfoMessage:new{ text = _("Downloading..."), timeout = 3 })

    -- Use HttpClient which works properly
    local ok, response_or_err = HttpClient:request(download_url, "GET", nil, nil, user, pass)
    
    if not ok then
        logger.err("OPDS Browser: Download failed:", response_or_err)
        UIManager:show(InfoMessage:new{ text = T(_("Download failed: %1"), tostring(response_or_err)), timeout = 3 })
        return
    end
    
    local data = response_or_err
    logger.info("OPDS Browser: Downloaded", #data, "bytes")
    
    if #data < 100 then
        logger.warn("OPDS Browser: Downloaded file too small")
        UIManager:show(InfoMessage:new{ text = _("Downloaded file appears invalid (too small)"), timeout = 3 })
        return
    end
    
    -- Write to file
    local file, err = io.open(filepath, "wb")
    if not file then
        logger.err("OPDS Browser: Failed to open file for writing:", err)
        UIManager:show(InfoMessage:new{ text = T(_("Failed to create file: %1"), err or "unknown"), timeout = 3 })
        return
    end
    
    file:write(data)
    file:close()
    
    logger.info("OPDS Browser: Download successful:", filepath)

-- Invalidate cache and trigger metadata refresh
local doc_settings = DocSettings:open(filepath)
if doc_settings then
    doc_settings:flush()
end

-- Clear any cached metadata
pcall(function()
    local DocSettings = require("docsettings")
    DocSettings:open(filepath):purge()
end)

-- Optionally add to read history to trigger indexing
if ReadHistory then
    pcall(function()
        ReadHistory:addItem(filepath)
    end)
end

UIManager:show(InfoMessage:new{ text = T(_("Downloaded: %1\n\nRefreshing metadata..."), book.title), timeout = 3 })

-- Schedule a small delay before notifying file manager to rescan
UIManager:scheduleIn(1, function()
    UIManager:broadcastEvent(require("ui/event").Event:new("FileManagerRefresh"))
end)
end

function OPDSBrowser:requestBook()
    local input_dialog
    input_dialog = MultiInputDialog:new{
        title = _("Request Book via Ephemera"),
        fields = {
            { text = "", hint = _("Book Title"), input_type = "string" },
            { text = "", hint = _("Author (optional)"), input_type = "string" },
        },
        buttons = {
            {
                { text = _("Cancel"), id = "close", callback = function() UIManager:close(input_dialog) end },
                { text = _("Search & Request"), is_enter_default = true, callback = function()
                    local fields = input_dialog:getFields()
                    local title = fields[1]
                    local author = fields[2]
                    UIManager:close(input_dialog)
                    if title and title ~= "" then self:searchEphemera(title, author) end
                end },
            },
        },
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

function OPDSBrowser:searchEphemera(title, author)
    UIManager:show(InfoMessage:new{ text = _("Searching Ephemera..."), timeout = 3 })
    local search_string = title
    if author and author ~= "" then search_string = search_string .. " " .. author end
    local query = url.escape(search_string)
    local full_url = self.ephemera_url .. "/api/search?q=" .. query

    local ok, response_or_err = self:httpGet(full_url)
    if not ok then
        UIManager:show(InfoMessage:new{ text = T(_("Ephemera search failed: %1"), response_or_err), timeout = 3 })
        return
    end

    local success, data = pcall(json.decode, response_or_err)
    if success and data and data.results then
        self:showEphemeraResults(data.results)
    else
        UIManager:show(InfoMessage:new{ text = _("Failed to parse search results"), timeout = 3 })
    end
end

function OPDSBrowser:showEphemeraResults(results)
    local Menu = require("ui/widget/menu")
    local Screen = require("device").screen

    if #results == 0 then
        UIManager:show(InfoMessage:new{ text = _("No books found in Ephemera"), timeout = 3 })
        return
    end

    local items = {}
    for _, book in ipairs(results) do
        local title = book.title or "Unknown Title"
        local author = book.author or "Unknown Author"
        table.insert(items, { text = title, subtitle = author, callback = function() self:requestEphemeraBook(book) end })
    end

    self.ephemera_menu = Menu:new{ title = _("Ephemera Search Results"), item_table = items, is_borderless = true, is_popout = false, title_bar_fm_style = true, width = Screen:getWidth(), height = Screen:getHeight() }
    UIManager:show(self.ephemera_menu)
end

function OPDSBrowser:requestEphemeraBook(book)
    UIManager:show(InfoMessage:new{ text = _("Requesting download..."), timeout = 3 })
    if not book.md5 or book.md5 == "" then
        UIManager:show(InfoMessage:new{ text = _("Error: Book MD5 not available"), timeout = 3 })
        return
    end

    local full_url = self.ephemera_url .. "/api/download/" .. book.md5
    logger.info("OPDS Browser: Queueing download at:", full_url)

    local body = json.encode({ title = book.title })
    local ok, response_or_err = HttpClient:request(full_url, "POST", body, "application/json")
    if not ok then
        UIManager:show(InfoMessage:new{ text = T(_("Download request failed: %1"), tostring(response_or_err)), timeout = 3 })
        return
    end

    local suc, result = pcall(json.decode, response_or_err)
    if suc and result then
        local message = ""
        if result.status == "queued" then
            message = T(_("Book queued for download!\n\nPosition: %1\n\nCheck 'Download Queue (Ephemera)' for progress."), result.position or "unknown")
        elseif result.status == "already_downloaded" then
            message = _("Book already downloaded!\n\nAvailable in your Ephemera library.")
        elseif result.status == "already_in_queue" then
            message = T(_("Book already in queue!\n\nPosition: %1\n\nCheck 'Download Queue (Ephemera)' for progress."), result.position or "unknown")
        else
            message = T(_("Status: %1\n\nCheck 'Download Queue (Ephemera)' for details."), result.status or "unknown")
        end
        UIManager:show(InfoMessage:new{ text = message, timeout = 3 })
    else
        UIManager:show(InfoMessage:new{ text = _("Book queued successfully!\n\nCheck 'Download Queue (Ephemera)' for progress."), timeout = 3 })
    end

    if self.ephemera_menu then UIManager:close(self.ephemera_menu) end
end

function OPDSBrowser:showDownloadQueue()
    UIManager:show(InfoMessage:new{ text = _("Loading queue..."), timeout = 3 })
    local full_url = self.ephemera_url .. "/api/queue"
    local ok, response_or_err = self:httpGet(full_url)
    if not ok then
        UIManager:show(InfoMessage:new{ text = T(_("Failed to load queue: %1"), response_or_err), timeout = 3 })
        return
    end

    local suc, queue = pcall(json.decode, response_or_err)
    if not suc or not queue then
        UIManager:show(InfoMessage:new{ text = _("Failed to parse queue data"), timeout = 3 })
        return
    end

    self:displayDownloadQueue(queue)
end

function OPDSBrowser:displayDownloadQueue(queue)
    local Menu = require("ui/widget/menu")
    local Screen = require("device").screen

    local items = {}
    local has_incomplete = false

    local function addItems(category, status_label, icon)
        if category then
            for md5, item in pairs(category) do
                local title = item.title or "Unknown"
                local status_text = status_label
                if item.status == "downloading" and item.progress then
                    status_text = status_text .. string.format(" (%d%%)", math.floor(item.progress))
                    has_incomplete = true
                elseif item.status == "queued" or item.status == "delayed" then
                    has_incomplete = true
                end
                if item.error then status_text = status_text .. " - " .. item.error end
                table.insert(items, { text = icon .. " " .. title, subtitle = status_text, md5 = md5, status = item.status, item = item })
            end
        end
    end

    addItems(queue.downloading, "Downloading", "⬇")
    addItems(queue.queued, "Queued", "⏳")
    addItems(queue.delayed, "Delayed", "⏸")
    addItems(queue.available, "Available", "✓")
    addItems(queue.done, "Done", "✓")
    addItems(queue.error, "Error", "✗")
    addItems(queue.cancelled, "Cancelled", "⊘")

    if #items == 0 then
        UIManager:show(InfoMessage:new{ text = _("Download queue is empty"), timeout = 3 })
        return
    end

    self.queue_menu = Menu:new{ title = _("Download Queue (Ephemera)"), item_table = items, is_borderless = true, is_popout = false, title_bar_fm_style = true, width = Screen:getWidth(), height = Screen:getHeight() }
    UIManager:show(self.queue_menu)

    if has_incomplete then self:startQueueRefresh() else self:stopQueueRefresh() end
end

function OPDSBrowser:startQueueRefresh()
    self:stopQueueRefresh()
    self.queue_refresh_action = function()
        if self.queue_menu then
            local full_url = self.ephemera_url .. "/api/queue"
            local ok, response_or_err = self:httpGet(full_url)
            if ok then
                local suc, queue = pcall(json.decode, response_or_err)
                if suc and queue then
                    UIManager:close(self.queue_menu)
                    self:displayDownloadQueue(queue)
                end
            end
        else
            self:stopQueueRefresh()
        end
    end
    UIManager:scheduleIn(5, self.queue_refresh_action)
end

function OPDSBrowser:stopQueueRefresh()
    if self.queue_refresh_action then
        UIManager:unschedule(self.queue_refresh_action)
        self.queue_refresh_action = nil
    end
end

function OPDSBrowser:onCloseDocument()
    self:stopQueueRefresh()
end

function OPDSBrowser:onSuspend()
    self:stopQueueRefresh()
end

return OPDSBrowser
