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
local UIEvent = require("ui/event")

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
    self.hardcover_token = self.settings:readSetting("hardcover_token") or ""
    
    -- Initialize library cache
    self.library_cache = {}
    self.library_cache_timestamp = 0
    self.library_cache_ttl = 300 -- 5 minutes cache lifetime
end

function OPDSBrowser:addToMainMenu(menu_items)
    menu_items.opdsbrowser = {
        text = _("Cloud Book Library"),
        sub_item_table = {
            { text = _("Library - Browse by Author"), callback = function() self:browseAuthors() end, enabled_func = function() return self.opds_url ~= "" end },
            { text = _("Library - Browse by Title"), callback = function() self:browseTitles() end, enabled_func = function() return self.opds_url ~= "" end },
            { text = _("Library - Browse New Titles"), callback = function() self:browseNewTitles() end, enabled_func = function() return self.opds_url ~= "" end },
            { text = _("Library - Search"), callback = function() self:searchLibrary() end, enabled_func = function() return self.opds_url ~= "" end },
            { text = "────────────────────", enabled_func = function() return false end },
            { text = _("Hardcover - Search Author"), callback = function() self:hardcoverSearchAuthor() end, enabled_func = function() return self.hardcover_token ~= "" end },
            { text = _("Ephemera - Request New Book"), callback = function() self:requestBook() end, enabled_func = function() return self.ephemera_url ~= "" end },
            { text = _("Ephemera - View Download Queue"), callback = function() self:showDownloadQueue() end, enabled_func = function() return self.ephemera_url ~= "" end },
            { text = "────────────────────", enabled_func = function() return false end },
            { text = _("Plugin - Settings"), callback = function() self:showSettings() end },
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
            { text = self.hardcover_token, hint = _("Hardcover Bearer Token (e.g., Bearer ABC...)"), input_type = "string" },
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
                    local new_hardcover_token = fields[6] or ""

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
                    self.hardcover_token = new_hardcover_token

                    self.settings:saveSetting("opds_url", self.opds_url)
                    self.settings:saveSetting("opds_username", self.opds_username)
                    self.settings:saveSetting("opds_password", self.opds_password)
                    self.settings:saveSetting("ephemera_url", self.ephemera_url)
                    self.settings:saveSetting("download_dir", self.download_dir)
                    self.settings:saveSetting("hardcover_token", self.hardcover_token)
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

        -- Extract SERIES from content BEFORE cleaning HTML (Method 1).
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

        -- Method 2: Check if title contains series info like "Title |Series Name #2|"
        if (not book.series or book.series == "") then
            local title_without_series, series_part = book.title:match("^(.-)%s*|([^|]+)|%s*$")
            if title_without_series and series_part then
                -- Extract series name and number from the series_part
                local series_name, series_num = series_part:match("^(.-)%s*#(%d+)$")
                if series_name and series_num then
                    book.series = series_name:gsub("^%s+", ""):gsub("%s+$", "")
                    book.series_index = series_num
                    book.title = title_without_series:gsub("^%s+", ""):gsub("%s+$", "")
                    logger.info("OPDS Browser: Extracted series from title:", book.series, "#", book.series_index)
                else
                    -- No number, just use the whole series part as series name
                    book.series = series_part:gsub("^%s+", ""):gsub("%s+$", "")
                    book.series_index = ""
                    book.title = title_without_series:gsub("^%s+", ""):gsub("%s+$", "")
                    logger.info("OPDS Browser: Extracted series from title (no number):", book.series)
                end
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
        local display_text = book.title
        
        -- Add series info if available
        if book.series ~= "" then
            display_text = display_text .. " - " .. book.series
            if book.series_index ~= "" then
                display_text = display_text .. " #" .. book.series_index
            end
        end
        
        -- Add author
        display_text = display_text .. " - " .. book.author

        table.insert(items, {
            text = display_text,
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
            series_text = series_text .. " - " .. book.series_index
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

function OPDSBrowser:browseTitles()
    local full_url = self.opds_url .. "/opds/books/letter/00"
    local ok, response_or_err = self:httpGet(full_url)
    if not ok then
        UIManager:show(InfoMessage:new{ text = T(_("Failed to load titles: %1"), response_or_err), timeout = 3 })
        return
    end

    local books = self:parseOPDSFeed(response_or_err)
    if #books > 0 then
        self:showBookList(books, _("Browse by Title"))
    else
        UIManager:show(InfoMessage:new{ text = _("No titles found."), timeout = 3 })
    end
end

function OPDSBrowser:browseNewTitles()
    local full_url = self.opds_url .. "/opds/new"
    local ok, response_or_err = self:httpGet(full_url)
    if not ok then
        UIManager:show(InfoMessage:new{ text = T(_("Failed to load new titles: %1"), response_or_err), timeout = 3 })
        return
    end

    local books = self:parseOPDSFeed(response_or_err)
    if #books > 0 then
        self:showBookList(books, _("New Titles"))
    else
        UIManager:show(InfoMessage:new{ text = _("No new titles found."), timeout = 3 })
    end
end

function OPDSBrowser:searchLibrary()
    local input_dialog
    input_dialog = InputDialog:new{
        title = _("Search Library"),
        input = "",
        input_hint = _("Enter title, author, or keywords"),
        input_type = "text",
        buttons = {
            {
                { text = _("Cancel"), id = "close", callback = function() UIManager:close(input_dialog) end },
                { text = _("Search"), is_enter_default = true, callback = function()
                    local search_term = input_dialog:getInputText()
                    UIManager:close(input_dialog)
                    if search_term and search_term ~= "" then
                        self:performLibrarySearch(search_term)
                    end
                end },
            },
        },
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

function OPDSBrowser:performLibrarySearch(search_term)
    UIManager:show(InfoMessage:new{ text = _("Searching library..."), timeout = 2 })
    
    local query = url.escape(search_term)
    local full_url = self.opds_url .. "/opds/search?query=" .. query
    
    local ok, response_or_err = self:httpGet(full_url)
    if not ok then
        UIManager:show(InfoMessage:new{ text = T(_("Search failed: %1"), response_or_err), timeout = 3 })
        return
    end

    local books = self:parseOPDSFeed(response_or_err)
    if #books > 0 then
        self:showBookList(books, T(_("Search Results: %1"), search_term))
    else
        UIManager:show(InfoMessage:new{ text = _("No books found matching your search."), timeout = 3 })
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
    if #books == 0 then
        UIManager:show(InfoMessage:new{ text = _("No books found for this author."), timeout = 3 })
        return
    end

    -- Fetch series data from Hardcover as fallback
    local loading_msg = InfoMessage:new{ text = _("Loading series information...") }
    UIManager:show(loading_msg)
    
    local series_lookup = self:getHardcoverSeriesData(author_name)
    
    -- Apply series data to books only if OPDS series is missing
    for _, book in ipairs(books) do
        if (not book.series or book.series == "") and series_lookup then
            local normalized_title = book.title:lower():gsub("[^%w]", "")
            if series_lookup[normalized_title] then
                book.series = series_lookup[normalized_title].name
                book.series_index = series_lookup[normalized_title].details
                logger.info("Applied Hardcover series to", book.title, ":", book.series, book.series_index)
            end
        else
            logger.info("Using OPDS series for", book.title, ":", book.series, book.series_index)
        end
    end

    -- Sort books: series first (with numeric index sorting), then standalone by title
    table.sort(books, function(a, b)
        local a_has_series = a.series and a.series ~= ""
        local b_has_series = b.series and b.series ~= ""
        
        -- Both have series
        if a_has_series and b_has_series then
            -- Different series: sort by series name
            if a.series ~= b.series then
                return a.series < b.series
            end
            -- Same series: sort by series index
            local a_idx = tonumber(a.series_index) or 0
            local b_idx = tonumber(b.series_index) or 0
            if a_idx ~= b_idx then
                return a_idx < b_idx
            end
            -- Same index or no numeric index: sort by title
            return a.title < b.title
        end
        
        -- Only a has series: a comes first
        if a_has_series then
            return true
        end
        
        -- Only b has series: b comes first
        if b_has_series then
            return false
        end
        
        -- Neither has series: sort by title
        return a.title < b.title
    end)

    -- Close the loading message before showing the book list
    UIManager:close(loading_msg)
    
    -- Force a screen refresh
    UIManager:setDirty("all", "full")
    
    self:showBookList(books, T(_("Books by %1"), author_name))
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
pcall(function()
    local DocSettings = require("docsettings")
    DocSettings:open(filepath):purge()
end)

-- Optionally add to read history to trigger indexing
pcall(function()
    local ReadHistory = require("readhistory")
    ReadHistory:addItem(filepath)
end)

UIManager:show(InfoMessage:new{ text = T(_("Downloaded: %1\n\nRefreshing metadata..."), book.title), timeout = 3 })

UIManager:scheduleIn(0.5, function()
    -- Get the file manager instance
    local FileManager = require("apps/filemanager/filemanager")
    if FileManager.instance then
        FileManager.instance:onRefresh()
    end
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

function OPDSBrowser:hardcoverSearchAuthor()
    local input_dialog
    input_dialog = InputDialog:new{
        title = _("Search Author on Hardcover"),
        input = "",
        input_hint = _("Enter author name"),
        input_type = "text",
        buttons = {
            {
                { text = _("Cancel"), id = "close", callback = function() UIManager:close(input_dialog) end },
                { text = _("Search"), is_enter_default = true, callback = function()
                    local author_name = input_dialog:getInputText()
                    UIManager:close(input_dialog)
                    if author_name and author_name ~= "" then
                        self:performHardcoverAuthorSearch(author_name)
                    end
                end },
            },
        },
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

function OPDSBrowser:performHardcoverAuthorSearch(author_name)
    if not NetworkMgr:isOnline() then
        NetworkMgr:beforeWifiAction()
        socket.sleep(1)
        if not NetworkMgr:isOnline() then
            UIManager:show(InfoMessage:new{ text = _("Network unavailable"), timeout = 3 })
            return
        end
    end

    UIManager:show(InfoMessage:new{ text = _("Searching Hardcover..."), timeout = 2 })

    local query = {
        query = string.format([[
            query BooksbyAuthor {
                search(query: "%s", query_type: "Author") {
                    results
                }
            }
        ]], author_name:gsub('"', '\\"'))
    }

    local body = json.encode(query)
    logger.info("Hardcover: Searching for author:", author_name)

    -- Use raw socket.http for custom headers
    local http = require("socket.http")
    local https = require("ssl.https")
    local ltn12 = require("ltn12")
    
    local response_body = {}
    
    local res, code, response_headers = https.request{
        url = "https://api.hardcover.app/v1/graphql",
        method = "POST",
        headers = {
            ["Content-Type"] = "application/json",
            ["Authorization"] = self.hardcover_token,
            ["Content-Length"] = tostring(#body)
        },
        source = ltn12.source.string(body),
        sink = ltn12.sink.table(response_body)
    }

    if not res or code ~= 200 then
        logger.err("Hardcover: Request failed with code:", code)
        UIManager:show(InfoMessage:new{ text = T(_("Hardcover search failed: HTTP %1"), code or "error"), timeout = 3 })
        return
    end

    local response_text = table.concat(response_body)
    logger.info("Hardcover: Response length:", #response_text)

    local success, data = pcall(json.decode, response_text)
    if success and data and data.data and data.data.search and data.data.search.results then
        self:showHardcoverAuthorResults(data.data.search.results)
    else
        logger.err("Hardcover: Failed to parse response")
        if success and data then
            logger.err("Hardcover: Response structure:", json.encode(data))
        end
        UIManager:show(InfoMessage:new{ text = _("Failed to parse Hardcover results"), timeout = 3 })
    end
end

function OPDSBrowser:showHardcoverAuthorResults(results)
    local Menu = require("ui/widget/menu")
    local Screen = require("device").screen

    if not results.hits or #results.hits == 0 then
        UIManager:show(InfoMessage:new{ text = _("No authors found on Hardcover"), timeout = 3 })
        return
    end

    local items = {}
    for _, hit in ipairs(results.hits) do
        local author = hit.document
        local display_text = author.name or "Unknown Author"
        
        -- Add "Known for" with first book if available
        if author.books and #author.books > 0 then
            display_text = display_text .. " - Known for " .. author.books[1]
        end

        table.insert(items, {
            text = display_text,
            callback = function() 
                self:hardcoverGetAuthorBooks(author.id, author.name)
            end,
        })
    end

    self.hardcover_menu = Menu:new{
        title = _("Hardcover Authors"),
        item_table = items,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
    }

    UIManager:show(self.hardcover_menu)
end

function OPDSBrowser:hardcoverGetAuthorBooks(author_id, author_name)
    if not NetworkMgr:isOnline() then
        NetworkMgr:beforeWifiAction()
        socket.sleep(1)
        if not NetworkMgr:isOnline() then
            UIManager:show(InfoMessage:new{ text = _("Network unavailable"), timeout = 3 })
            return
        end
    end

    UIManager:show(InfoMessage:new{ text = _("Loading books..."), timeout = 2 })

    local query = {
        query = string.format([[
            query BooksByAuthor {
                books(
                    where: {contributions: {author: {id: {_eq: "%s"}}}}
                    order_by: {users_count: desc}
                ) {
                    id
                    title
                    pages
                    book_series {
                        series {
                            id
                            slug
                        }
                        details
                    }
                    release_date
                    description
                    rating
                    ratings_count
                    contributions(where: {author_id: {_eq: "%s"}}) {
                        author {
                            name
                        }
                    }
                }
            }
        ]], author_id, author_id)
    }

    local body = json.encode(query)
    logger.info("Hardcover: Loading books for author ID:", author_id)

    local https = require("ssl.https")
    local ltn12 = require("ltn12")
    
    local response_body = {}
    
    local res, code, response_headers = https.request{
        url = "https://api.hardcover.app/v1/graphql",
        method = "POST",
        headers = {
            ["Content-Type"] = "application/json",
            ["Authorization"] = self.hardcover_token,
            ["Content-Length"] = tostring(#body)
        },
        source = ltn12.source.string(body),
        sink = ltn12.sink.table(response_body)
    }

    if not res or code ~= 200 then
        logger.err("Hardcover: Request failed with code:", code)
        UIManager:show(InfoMessage:new{ text = T(_("Failed to load books: HTTP %1"), code or "error"), timeout = 3 })
        return
    end

    local response_text = table.concat(response_body)
    logger.info("Hardcover: Response length:", #response_text)

    local success, data = pcall(json.decode, response_text)
    if success and data and data.data and data.data.books then
        self:showHardcoverBookList(data.data.books, author_name)
    else
        logger.err("Hardcover: Failed to parse books response")
        UIManager:show(InfoMessage:new{ text = _("Failed to parse books"), timeout = 3 })
    end
end

function OPDSBrowser:showHardcoverBookList(books, author_name)
    local Menu = require("ui/widget/menu")
    local Screen = require("device").screen

    if #books == 0 then
        UIManager:show(InfoMessage:new{ text = _("No books found for this author"), timeout = 3 })
        return
    end

    -- Store books for reference
    self.hardcover_books_data = books
    self.hardcover_books_author = author_name
    self.hardcover_books_checked = {} -- Track which books have been checked

    local items = {}
    for i, book in ipairs(books) do
        local display_text = book.title or "Unknown Title"
        
        -- Extract author name for comparison
        local book_author = author_name
        if book.contributions and #book.contributions > 0 and book.contributions[1].author then
            book_author = book.contributions[1].author.name
        end
        
        -- Store author with book for later checking
        book._display_author = book_author

        table.insert(items, {
            text = display_text,
            book_index = i,
            callback = function() 
                self:showHardcoverBookDetails(book, author_name)
            end,
        })
    end

    self.hardcover_books_menu = Menu:new{
        title = T(_("Books by %1"), author_name),
        item_table = items,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        onMenuHold = function() return true end,
    }

    -- Hook into the menu's page change to check visible books
    local original_onNextPage = self.hardcover_books_menu.onNextPage
    self.hardcover_books_menu.onNextPage = function(menu)
        if original_onNextPage then
            original_onNextPage(menu)
        end
        self:checkVisibleHardcoverBooks()
        return true
    end

    local original_onPrevPage = self.hardcover_books_menu.onPrevPage
    self.hardcover_books_menu.onPrevPage = function(menu)
        if original_onPrevPage then
            original_onPrevPage(menu)
        end
        self:checkVisibleHardcoverBooks()
        return true
    end

    UIManager:show(self.hardcover_books_menu)
    
    -- Check visible books on initial display
    UIManager:scheduleIn(0.1, function()
        self:checkVisibleHardcoverBooks()
    end)
end

function OPDSBrowser:getHardcoverSeriesData(author_name)
    -- Check if Hardcover is configured
    if not self.hardcover_token or self.hardcover_token == "" then
        logger.info("Hardcover not configured, skipping series lookup")
        return {}
    end

    -- Create a normalized cache key for the author
    local cache_key = "hc_series:" .. author_name:lower():gsub("[^%w]", "")
    
    -- Check cache first
    local current_time = os.time()
    if self.library_cache[cache_key] ~= nil and 
       (current_time - self.library_cache_timestamp) < self.library_cache_ttl then
        logger.info("Hardcover series: Cache hit for author", author_name)
        return self.library_cache[cache_key]
    end

    if not NetworkMgr:isOnline() then
        logger.warn("Network unavailable for Hardcover series lookup")
        return {}
    end

    local query = {
        query = string.format([[
            query BooksByAuthorSeries {
                books(
                    where: {contributions: {author: {name: {_eq: "%s"}}}}
                    order_by: {users_count: desc}
                ) {
                    title
                    book_series {
                        series {
                            id
                            slug
                        }
                        details
                    }
                }
            }
        ]], author_name:gsub('"', '\\"'))
    }

    local body = json.encode(query)
    logger.info("Hardcover: Fetching series data for author:", author_name)

    local https = require("ssl.https")
    local ltn12 = require("ltn12")
    
    local response_body = {}
    
    local res, code, response_headers = https.request{
        url = "https://api.hardcover.app/v1/graphql",
        method = "POST",
        headers = {
            ["Content-Type"] = "application/json",
            ["Authorization"] = self.hardcover_token,
            ["Content-Length"] = tostring(#body)
        },
        source = ltn12.source.string(body),
        sink = ltn12.sink.table(response_body)
    }

    if not res or code ~= 200 then
        logger.err("Hardcover series: Request failed with code:", code)
        self.library_cache[cache_key] = {}
        return {}
    end

    local response_text = table.concat(response_body)
    local success, data = pcall(json.decode, response_text)
    
    if not success or not data or not data.data or not data.data.books then
        logger.err("Hardcover series: Failed to parse response")
        self.library_cache[cache_key] = {}
        return {}
    end

    -- Build lookup table: normalized_title -> series info
    local series_lookup = {}
    for _, book in ipairs(data.data.books) do
        local normalized_title = book.title:lower():gsub("[^%w]", "")
        if book.book_series and #book.book_series > 0 then
            local series_info = book.book_series[1]
            if series_info.series then
                series_lookup[normalized_title] = {
                    name = series_info.series.slug or "Unknown Series",
                    details = series_info.details or ""
                }
                logger.info("Hardcover series:", book.title, "->", series_lookup[normalized_title].name, series_lookup[normalized_title].details)
            end
        end
    end

    logger.info("Hardcover: Found series info for", table.getn and table.getn(series_lookup) or "unknown", "books")

    -- Cache the result
    self.library_cache[cache_key] = series_lookup
    self.library_cache_timestamp = current_time
    
    return series_lookup
end

function OPDSBrowser:checkVisibleHardcoverBooks()
    if not self.hardcover_books_menu or not self.hardcover_books_data then
        logger.warn("checkVisibleHardcoverBooks: Menu or data not available")
        return
    end

    local menu = self.hardcover_books_menu
    local perpage = menu.perpage or 10
    local page = menu.page or 1
    
    -- Calculate visible range
    local start_idx = (page - 1) * perpage + 1
    local end_idx = math.min(start_idx + perpage - 1, #self.hardcover_books_data)
    
    logger.info("Checking library for books", start_idx, "to", end_idx, "on page", page)
    
    -- Get author's books from library once (will use cache if available)
    local author_books_lookup = self:getAuthorBooksFromLibrary(self.hardcover_books_author)
    logger.info("Author lookup table has", table.getn or function(t) local n=0; for _ in pairs(t) do n=n+1 end return n end, "entries")
    
    -- Track how many checks we're doing
    local checks_scheduled = 0
    
    -- Check each visible book asynchronously
    for i = start_idx, end_idx do
        if not self.hardcover_books_checked[i] then
            local book = self.hardcover_books_data[i]
            local book_author = book._display_author or self.hardcover_books_author
            
            logger.info("Scheduling check for book", i, ":", book.title)
            checks_scheduled = checks_scheduled + 1
            
            -- Schedule async check (still async to avoid blocking UI)
            UIManager:scheduleIn(0.01 * (i - start_idx), function()
                logger.info("Checking library for:", book.title, "by", book_author)
                local in_library = self:checkBookExistsInLibrary(book.title, book_author, author_books_lookup)
                
                logger.info("Book", book.title, "in library:", in_library)
                
                if in_library then
                    -- Update the menu item text
                    local item_idx = i
                    if menu.item_table and menu.item_table[item_idx] then
                        local original_text = book.title or "Unknown Title"
                        local new_text = "✓ " .. original_text .. " (In Library)"
                        logger.info("Updating menu item", item_idx, "from", menu.item_table[item_idx].text, "to", new_text)
                        menu.item_table[item_idx].text = new_text
                        
                        -- Force menu refresh - try multiple methods
                        if menu.updateItems then
                            menu:updateItems()
                        end
                        if menu.show_page then
                            menu:show_page(menu.page)
                        end
                        UIManager:setDirty(menu, "ui")
                    else
                        logger.warn("Could not find menu item", item_idx)
                    end
                end
                
                -- Mark as checked
                self.hardcover_books_checked[i] = true
            end)
        else
            logger.info("Book", i, "already checked, skipping")
        end
    end
    
    logger.info("Scheduled", checks_scheduled, "library checks")
end

function OPDSBrowser:getAuthorBooksFromLibrary(author)
    -- Check if the library path exists
    if not self.opds_url or self.opds_url == "" then
        return {}
    end
    
    -- Create a normalized cache key for the author
    local cache_key = "author:" .. author:lower():gsub("[^%w]", "")
    
    -- Check cache first
    local current_time = os.time()
    if self.library_cache[cache_key] ~= nil and 
       (current_time - self.library_cache_timestamp) < self.library_cache_ttl then
        logger.info("Library check: Cache hit for author", author)
        return self.library_cache[cache_key]
    end
    
    -- Search the library for this author
    local search_query = url.escape(author)
    local full_url = self.opds_url .. "/opds/search?query=" .. search_query
    
    logger.info("Fetching all books by author from library:", author)
    local ok, response_or_err = self:httpGet(full_url)
    if not ok then
        logger.warn("Library check failed:", response_or_err)
        self.library_cache[cache_key] = {}
        return {}
    end
    
    local books = self:parseOPDSFeed(response_or_err)
    logger.info("Found", #books, "books in library for author:", author)
    
    -- Create a lookup table of normalized titles for quick comparison
    local title_lookup = {}
    for _, book in ipairs(books) do
        local normalized_title = book.title:lower():gsub("[^%w]", "")
        title_lookup[normalized_title] = true
        logger.info("Library book:", book.title, "->", normalized_title)
    end
    
    -- Cache the result
    self.library_cache[cache_key] = title_lookup
    self.library_cache_timestamp = current_time
    
    return title_lookup
end

function OPDSBrowser:checkBookExistsInLibrary(title, author, author_books_lookup)
    -- If we have a pre-fetched lookup table, use it
    if author_books_lookup then
        local normalized_title = title:lower():gsub("[^%w]", "")
        local found = author_books_lookup[normalized_title] == true
        logger.info("Checking", title, "->", normalized_title, "Found:", found)
        return found
    end
    
    -- Fallback: get author books (will use cache if available)
    local lookup = self:getAuthorBooksFromLibrary(author)
    local normalized_title = title:lower():gsub("[^%w]", "")
    return lookup[normalized_title] == true
end

function OPDSBrowser:showHardcoverBookDetails(book, author_name)
    local TextViewer = require("ui/widget/textviewer")
    
    -- Extract author name from contributions
    local book_author = author_name
    if book.contributions and #book.contributions > 0 and book.contributions[1].author then
        book_author = book.contributions[1].author.name
    end
    
    -- Build details text
    local details = T(_("Title: %1\n\nAuthor: %2"), book.title or "Unknown", book_author)
    
    -- Add rating if available
    if book.rating and book.rating > 0 then
        local rating_text = string.format("%.2f", book.rating)
        if book.ratings_count and book.ratings_count > 0 then
            rating_text = rating_text .. " (" .. book.ratings_count .. " ratings)"
        end
        details = details .. "\n\n" .. T(_("Rating: %1"), rating_text)
    end
    
    -- Add series info if available
    if book.book_series and #book.book_series > 0 then
        local series_info = book.book_series[1]
        if series_info.series then
            local series_text = series_info.series.slug or "Unknown Series"
            if series_info.details then
                series_text = series_text .. " - " .. series_info.details
            end
            details = details .. "\n\n" .. T(_("Series: %1"), series_text)
        end
    end
    
    -- Add description
    if book.description and book.description ~= "" then
        local clean_description = strip_html(book.description)
        details = details .. "\n\n" .. clean_description
    end
    
    -- Add release date if available
    if book.release_date then
        details = details .. "\n\n" .. T(_("Released: %1"), book.release_date)
    end
    
    -- Add pages if available
    if book.pages and book.pages > 0 then
        details = details .. "\n" .. T(_("Pages: %1"), book.pages)
    end

    local buttons = {
        {
            { text = _("Search Ephemera"), callback = function()
                UIManager:close(self.hardcover_book_details)
                self:searchEphemeraFromHardcover(book.title, book_author)
            end },
        },
        {
            { text = _("Close"), callback = function() 
                UIManager:close(self.hardcover_book_details) 
            end },
        },
    }

    self.hardcover_book_details = TextViewer:new{
        title = book.title,
        text = details,
        buttons_table = buttons
    }
    
    UIManager:show(self.hardcover_book_details)
end

function OPDSBrowser:searchEphemeraFromHardcover(title, author)
    if not self.ephemera_url or self.ephemera_url == "" then
        UIManager:show(InfoMessage:new{ text = _("Ephemera URL not configured"), timeout = 3 })
        return
    end
    
    UIManager:show(InfoMessage:new{ text = _("Searching Ephemera..."), timeout = 3 })
    
    local search_string = title
    if author and author ~= "" then 
        search_string = search_string .. " " .. author 
    end
    
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




return OPDSBrowser
