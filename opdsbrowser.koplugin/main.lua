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
    -- numeric entities (with range check for string.char)
    s = s:gsub("&#(%d+);", function(n)
        local v = tonumber(n)
        if v and v > 0 and v < 256 then
            return string.char(v)
        end
        return "" -- Skip characters outside ASCII range
    end)
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
    self.use_publisher_as_series = self.settings:readSetting("use_publisher_as_series")
    if self.use_publisher_as_series == nil then
        self.use_publisher_as_series = false
    end
    self.enable_library_check = self.settings:readSetting("enable_library_check")
    if self.enable_library_check == nil then
        self.enable_library_check = true -- Default enabled for backwards compatibility
    end
    self.library_check_page_limit = self.settings:readSetting("library_check_page_limit") or 5 -- Limit to 5 pages (250 books at 50/page)

    -- Initialize library cache (session-based, cleared on plugin reload)
    self.library_cache = {}
end

function OPDSBrowser:addToMainMenu(menu_items)
    menu_items.opdsbrowser = {
        text = _("Cloud Book Library"),
        sub_item_table = {
            { text = _("Library - Browse by Author"), callback = function() self:browseAuthors() end, enabled_func = function() return self.opds_url ~= "" end },
            { text = _("Library - Recently Added"), callback = function() self:browseRecentlyAdded() end, enabled_func = function() return self.opds_url ~= "" end },
            { text = _("Library - Random Choice"), callback = function() self:getRandomBook() end, enabled_func = function() return self.opds_url ~= "" end },
            { text = _("Library - Search"), callback = function() self:searchLibrary() end, enabled_func = function() return self.opds_url ~= "" end },
            { text = "────────────────────", enabled_func = function() return false end },
            { text = _("Ephemera - Request New Book"), callback = function() self:requestBook() end, enabled_func = function() return self.ephemera_url ~= "" end },
            { text = _("Ephemera - View Download Queue"), callback = function() self:showDownloadQueue() end, enabled_func = function() return self.ephemera_url ~= "" end },
            { text = "────────────────────", enabled_func = function() return false end },
            { text = _("Hardcover - Search Author"), callback = function() self:hardcoverSearchAuthor() end, enabled_func = function() return self.hardcover_token ~= "" end },
            { text = "────────────────────", enabled_func = function() return false end },
            { text = _("Plugin - Settings"), callback = function() self:showSettings() end },
        },
    }
end

function OPDSBrowser:browseRecentlyAdded()
    if not NetworkMgr:isOnline() then
        NetworkMgr:beforeWifiAction()
        socket.sleep(1)
        if not NetworkMgr:isOnline() then
            UIManager:show(InfoMessage:new{ text = _("Network unavailable"), timeout = 3 })
            return
        end
    end

    UIManager:show(InfoMessage:new{ text = _("Loading recently added books..."), timeout = 2 })
    
    local full_url = self.opds_url .. "/recent"
    local all_xml = self:fetchAllPages(full_url, 50)
    
    if not all_xml then
        UIManager:show(InfoMessage:new{ text = _("Failed to load recent books"), timeout = 3 })
        return
    end

    local books = self:parseBookloreOPDSFeed(all_xml)
    if #books > 0 then
        self:showBookList(books, _("Recently Added"))
    else
        UIManager:show(InfoMessage:new{ text = _("No recent books found."), timeout = 3 })
    end
end

function OPDSBrowser:getRandomBook()
    if not NetworkMgr:isOnline() then
        NetworkMgr:beforeWifiAction()
        socket.sleep(1)
        if not NetworkMgr:isOnline() then
            UIManager:show(InfoMessage:new{ text = _("Network unavailable"), timeout = 3 })
            return
        end
    end

    UIManager:show(InfoMessage:new{ text = _("Getting random book..."), timeout = 2 })
    
    local full_url = self.opds_url .. "/surprise"
    local ok, response_or_err = self:httpGet(full_url)
    
    if not ok then
        UIManager:show(InfoMessage:new{ text = _("Failed to get random book"), timeout = 3 })
        return
    end

    local books = self:parseBookloreOPDSFeed(response_or_err)
    if #books > 0 then
        -- Show the single random book
        self:showBookDetails(books[1])
    else
        UIManager:show(InfoMessage:new{ text = _("No book found."), timeout = 3 })
    end
end

function OPDSBrowser:getLastPageNumber(xml_data)
    -- Extract last page from link rel="last" href
    local last_link = xml_data:match('<link rel="last" href="([^"]+)"')
    if last_link then
        local page_num = last_link:match('page=(%d+)')
        if page_num then
            return tonumber(page_num)
        end
    end
    return 1
end

function OPDSBrowser:fetchAllPages(base_url, size)
    size = size or 50
    
    -- Determine separator - use & if base_url already has query params, otherwise ?
    local separator = base_url:match("%?") and "&" or "?"
    
    -- First, get page 1 to determine total pages
    local page1_url = base_url .. separator .. "page=1&size=" .. size
    logger.info("Booklore: Fetching first page:", page1_url)
    
    local ok, response_or_err = self:httpGet(page1_url)
    if not ok then
        logger.err("Booklore: Failed to fetch first page:", response_or_err)
        return nil
    end
    
    logger.info("Booklore: First page response length:", #response_or_err)
    
    local last_page = self:getLastPageNumber(response_or_err)
    logger.info("Booklore: Found", last_page, "pages to fetch")
    
    local all_xml = response_or_err
    
    -- Fetch remaining pages
    if last_page > 1 then
        for page = 2, last_page do
            local page_url = base_url .. separator .. "page=" .. page .. "&size=" .. size
            logger.info("Booklore: Fetching page", page, "of", last_page)
            
            ok, response_or_err = self:httpGet(page_url)
            if ok then
                -- Append entries from this page
                all_xml = all_xml .. response_or_err
            else
                logger.warn("Booklore: Failed to fetch page", page, ":", response_or_err)
            end
        end
    end
    
    return all_xml
end

function OPDSBrowser:showSettings()
    local MultiInputDialog = require("ui/widget/multiinputdialog")
    
    -- Check if hardcover token exists
    local hardcover_status = self.hardcover_token ~= "" and "✓ Configured" or "✗ Not configured"

    -- Convert boolean to YES/NO for display
    local publisher_setting = self.use_publisher_as_series and "YES" or "NO"
    local library_check_setting = self.enable_library_check and "YES" or "NO"

    logger.info("Settings: Current use_publisher_as_series value:", self.use_publisher_as_series)
    logger.info("Settings: Current enable_library_check value:", self.enable_library_check)

    self.settings_dialog = MultiInputDialog:new{
        title = _("Book Download Settings"),
        fields = {
            { text = self.opds_url, hint = _("Base URL (e.g., https://example.com/api/v1/opds)"), input_type = "string" },
            { text = self.opds_username, hint = _("OPDS Username (optional)"), input_type = "string" },
            { text = self.opds_password, hint = _("OPDS Password (optional)"), input_type = "string" },
            { text = self.ephemera_url, hint = _("Ephemera URL (e.g., http://example.com:8286)"), input_type = "string" },
            { text = self.download_dir, hint = _("Download Directory"), input_type = "string" },
            { text = publisher_setting, hint = _("Use Publisher as Series? (YES/NO)"), input_type = "string" },
            { text = library_check_setting, hint = _("Check 'In Library' for Hardcover? (YES/NO)"), input_type = "string" },
            { text = tostring(self.library_check_page_limit), hint = _("Max pages to check (5=250 books, 0=unlimited)"), input_type = "number" },
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
                    local publisher_input = (fields[6] or "NO"):upper():gsub("%s+", "")
                    local library_check_input = (fields[7] or "YES"):upper():gsub("%s+", "")
                    local page_limit_input = tonumber(fields[8]) or 5

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

                    -- Convert YES/NO to boolean
                    self.use_publisher_as_series = (publisher_input == "YES")
                    self.enable_library_check = (library_check_input == "YES")
                    self.library_check_page_limit = page_limit_input

                    logger.info("Settings: Saving use_publisher_as_series as:", self.use_publisher_as_series)
                    logger.info("Settings: Saving enable_library_check as:", self.enable_library_check)
                    logger.info("Settings: Saving library_check_page_limit as:", self.library_check_page_limit)

                    self.settings:saveSetting("opds_url", self.opds_url)
                    self.settings:saveSetting("opds_username", self.opds_username)
                    self.settings:saveSetting("opds_password", self.opds_password)
                    self.settings:saveSetting("ephemera_url", self.ephemera_url)
                    self.settings:saveSetting("download_dir", self.download_dir)
                    self.settings:saveSetting("use_publisher_as_series", self.use_publisher_as_series)
                    self.settings:saveSetting("enable_library_check", self.enable_library_check)
                    self.settings:saveSetting("library_check_page_limit", self.library_check_page_limit)
                    self.settings:flush()

                    -- Clear cache when settings change
                    self.library_cache = {}

                    UIManager:show(InfoMessage:new{ text = _("Settings saved successfully!"), timeout = 3 })
                    UIManager:close(self.settings_dialog)
                end },
            },
        },
        extra_text = T(_("Hardcover API: %1\n\nTo configure Hardcover, edit:\nkoreader/settings/opdsbrowser.lua"), hardcover_status),
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

        -- Method 1 (Priority 1): Check if title contains series info like "Title |Series Name #2|"
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
        else
            -- No series in title, initialize empty
            book.series = ""
            book.series_index = ""
        end

        -- Clean summary text for display (remove HTML markup)
        book.summary = strip_html(raw_summary)

        book.id = entry:match('<id>(.-)</id>') or ""

        -- Capture both EPUB and KEPUB download links
        local epub_url = nil
        local kepub_url = nil
        
        for link in entry:gmatch('<link[^>]*rel="http://opds%-spec%.org/acquisition[^"]*"[^>]*>') do
            local href = link:match('href="([^"]*)"')
            local media_type = link:match('type="([^"]*)"')
            
            if href then
                if media_type and media_type:match("epub%+zip") then
                    -- Check if it's a kepub by looking at the title attribute or href
                    local title_attr = link:match('title="([^"]*)"') or ""
                    if title_attr:lower():match("kepub") or href:lower():match("kepub") then
                        kepub_url = href
                        logger.info("OPDS Browser: Found KEPUB link:", href)
                    else
                        epub_url = href
                        logger.info("OPDS Browser: Found EPUB link:", href)
                    end
                end
            end
        end

        -- If no acquisition links found, try alternate method
        if not epub_url and not kepub_url then
            for link in entry:gmatch('<link[^>]*type="application/epub%+zip"[^>]*>') do
                local href = link:match('href="([^"]*)"')
                local title_attr = link:match('title="([^"]*)"') or ""
                if href then
                    if title_attr:lower():match("kepub") or href:lower():match("kepub") then
                        kepub_url = href
                    else
                        epub_url = href
                    end
                end
            end
        end

        -- Prefer EPUB, fallback to KEPUB
        if epub_url then
            book.download_url = epub_url
            book.media_type = "application/epub+zip"
            book.kepub_url = kepub_url  -- Store kepub as backup
        elseif kepub_url then
            book.download_url = kepub_url
            book.media_type = "application/kepub+zip"
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
        if book.series and book.series ~= "" then
            display_text = display_text .. " - " .. book.series
            if book.series_index and book.series_index ~= "" then
                display_text = display_text .. " #" .. tostring(book.series_index)
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
    if not NetworkMgr:isOnline() then
        NetworkMgr:beforeWifiAction()
        socket.sleep(1)
        if not NetworkMgr:isOnline() then
            UIManager:show(InfoMessage:new{ text = _("Network unavailable"), timeout = 3 })
            return
        end
    end

    UIManager:show(InfoMessage:new{ text = _("Loading authors..."), timeout = 2 })
    
    local full_url = self.opds_url .. "/catalog"
    local all_xml = self:fetchAllPages(full_url, 50)
    
    if not all_xml then
        UIManager:show(InfoMessage:new{ text = _("Failed to load authors"), timeout = 3 })
        return
    end

    local authors = self:parseAuthorsFromBooklore(all_xml)
    if #authors > 0 then
        self:showAuthorList(authors)
    else
        UIManager:show(InfoMessage:new{ text = _("No authors found."), timeout = 3 })
    end
end

function OPDSBrowser:parseAuthorsFromBooklore(xml_data)
    local author_set = {}
    logger.info("Booklore: Parsing authors from XML")

    for entry in xml_data:gmatch("<entry>(.-)</entry>") do
        local author_name = entry:match("<author><name>(.-)</name></author>")
        if author_name then
            author_name = html_unescape(author_name)
            author_set[author_name] = true
        end
    end

    -- Convert set to sorted array
    local authors = {}
    for name, _ in pairs(author_set) do
        table.insert(authors, { name = name })
    end
    
    table.sort(authors, function(a, b) return a.name < b.name end)
    
    logger.info("Booklore: Found", #authors, "unique authors")
    return authors
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
    if not NetworkMgr:isOnline() then
        NetworkMgr:beforeWifiAction()
        socket.sleep(1)
        if not NetworkMgr:isOnline() then
            UIManager:show(InfoMessage:new{ text = _("Network unavailable"), timeout = 3 })
            return
        end
    end

    UIManager:show(InfoMessage:new{ text = _("Searching library..."), timeout = 2 })
    
    local query = url.escape(search_term)
    local full_url = self.opds_url .. "/catalog?q=" .. query
    
    local all_xml = self:fetchAllPages(full_url, 50)
    
    if not all_xml then
        UIManager:show(InfoMessage:new{ text = _("Search failed"), timeout = 3 })
        return
    end

    local books = self:parseBookloreOPDSFeed(all_xml)
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
            callback = function() self:browseBooksByAuthorBooklore(author.name) end,
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

function OPDSBrowser:browseBooksByAuthorBooklore(author_name)
    UIManager:show(InfoMessage:new{ text = _("Loading books..."), timeout = 2 })
    
    local query = url.escape(author_name)
    local full_url = self.opds_url .. "/catalog?q=" .. query
    
    logger.info("Booklore: Fetching books for author:", author_name)
    logger.info("Booklore: URL:", full_url)
    logger.info("Booklore: use_publisher_as_series:", self.use_publisher_as_series)
    
    local all_xml = self:fetchAllPages(full_url, 50)
    
    if not all_xml then
        UIManager:show(InfoMessage:new{ text = _("Failed to load books"), timeout = 3 })
        return
    end

    local books = self:parseBookloreOPDSFeed(all_xml)
    logger.info("Booklore: Parsed", #books, "books")
    
    if #books == 0 then
        UIManager:show(InfoMessage:new{ text = _("No books found for this author."), timeout = 3 })
        return
    end

    -- Only use Hardcover if publisher series is NOT enabled
    if not self.use_publisher_as_series then
        logger.info("Booklore: Publisher series disabled, using Hardcover fallback")
        local loading_msg = InfoMessage:new{ text = _("Loading series information...") }
        UIManager:show(loading_msg)
        
        local series_lookup = self:getHardcoverSeriesData(author_name)
        
        -- Apply series data to books only if summary parsing didn't find series
        for _, book in ipairs(books) do
            if (not book.series or book.series == "") and series_lookup then
                local normalized_title = book.title:lower():gsub("[^%w]", "")
                if series_lookup[normalized_title] then
                    book.series = series_lookup[normalized_title].name
                    book.series_index = series_lookup[normalized_title].details
                    logger.info("Applied Hardcover series to", book.title, ":", book.series, book.series_index)
                end
            else
                logger.info("Book already has series:", book.title, "->", book.series, book.series_index)
            end
        end
        
        UIManager:close(loading_msg)
        UIManager:setDirty("all", "full")
    else
        logger.info("Booklore: Publisher series enabled, skipping Hardcover")
    end
-- Add this right before the table.sort call
for i, book in ipairs(books) do
    logger.info("Book", i, ":", book.title)
    logger.info("  series:", type(book.series), book.series)
    logger.info("  series_index:", type(book.series_index), tostring(book.series_index))
end
-- Sort books: series first (with numeric index sorting), then standalone by title
table.sort(books, function(a, b)
    local a_has_series = a.series and type(a.series) == "string" and a.series ~= ""
    local b_has_series = b.series and type(b.series) == "string" and b.series ~= ""
    
    if a_has_series and b_has_series then
        if a.series ~= b.series then
            return a.series < b.series
        end
        -- Safely get series index
        local a_idx = 0
        local b_idx = 0
        if a.series_index and type(a.series_index) == "string" then
            a_idx = tonumber(a.series_index) or 0
        elseif a.series_index and type(a.series_index) == "number" then
            a_idx = a.series_index
        end
        if b.series_index and type(b.series_index) == "string" then
            b_idx = tonumber(b.series_index) or 0
        elseif b.series_index and type(b.series_index) == "number" then
            b_idx = b.series_index
        end
        
        if a_idx ~= b_idx then
            return a_idx < b_idx
        end
        return a.title < b.title
    end
    
    if a_has_series then return true end
    if b_has_series then return false end
    
    return a.title < b.title
end)
    self:showBookList(books, T(_("Books by %1"), author_name))
end

function OPDSBrowser:parseBookloreOPDSFeed(xml_data)
    local entries = {}
    logger.info("Booklore: Parsing OPDS feed, XML length:", #xml_data)

    local entry_count = 0
    for entry in xml_data:gmatch("<entry>(.-)</entry>") do
        entry_count = entry_count + 1
        local book = {}

        book.title = entry:match("<title>(.-)</title>") or "Unknown Title"
        book.title = html_unescape(book.title)

        local author_name = entry:match("<author><name>(.-)</name></author>")
        book.author = author_name and html_unescape(author_name) or "Unknown Author"

        local raw_summary = entry:match('<summary>(.-)</summary>') or ""
        raw_summary = html_unescape(raw_summary)

        -- Extract publisher
        local publisher = entry:match('<dc:publisher>(.-)</dc:publisher>') or ""
        publisher = html_unescape(publisher)
        
        -- Initialize series fields
        book.series = ""
        book.series_index = ""
        
        -- Method 1: Use publisher as series if enabled
        if self.use_publisher_as_series and publisher ~= "" then
            local series_name, series_num = publisher:match("^(.-)%s+(%d+)$")
            if series_name and series_num then
                book.series = series_name:gsub("^%s+", ""):gsub("%s+$", "")
                book.series_index = series_num
                logger.info("Booklore: Extracted series from publisher:", book.series, "#", book.series_index)
            else
                -- No number found, use whole publisher as series
                book.series = publisher:gsub("^%s+", ""):gsub("%s+$", "")
                logger.info("Booklore: Using publisher as series (no number):", book.series)
            end
        else
            -- Method 2: Extract series from summary if publisher not used
            local series_match = raw_summary:match("|([^|]+)|")
            if series_match then
                local series_name, series_num = series_match:match("^(.-)%s*#(%d+)$")
                if series_name and series_num then
                    book.series = series_name:gsub("^%s+", ""):gsub("%s+$", "")
                    book.series_index = series_num
                    logger.info("Booklore: Extracted series from summary:", book.series, "#", book.series_index)
                else
                    book.series = series_match:gsub("^%s+", ""):gsub("%s+$", "")
                    logger.info("Booklore: Extracted series from summary (no number):", book.series)
                end
            end
        end

        -- Clean summary
        book.summary = strip_html(raw_summary)

        book.id = entry:match('<id>(.-)</id>') or ""

        -- Extract download link
        local download_link = entry:match('<link href="([^"]+)" rel="http://opds%-spec%.org/acquisition"')
        if download_link then
            book.download_url = download_link
            book.media_type = "application/epub+zip"
        end

        if book.download_url then
            table.insert(entries, book)
            logger.info("Booklore: Parsed book:", book.title, "by", book.author)
        else
            logger.warn("Booklore: Skipping entry without download URL:", book.title)
        end
    end

    logger.info("Booklore: Found", entry_count, "entries, parsed", #entries, "books")
    return entries
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

    -- Fetch series data from Hardcover as fallback (Method 2 / Priority 2)
    local loading_msg = InfoMessage:new{ text = _("Loading series information...") }
    UIManager:show(loading_msg)
    
    local series_lookup = self:getHardcoverSeriesData(author_name)
    
    -- Apply series data to books only if title parsing didn't find series
    for _, book in ipairs(books) do
        if (not book.series or book.series == "") and series_lookup then
            local normalized_title = book.title:lower():gsub("[^%w]", "")
            if series_lookup[normalized_title] then
                book.series = series_lookup[normalized_title].name
                book.series_index = series_lookup[normalized_title].details
                logger.info("Applied Hardcover series to", book.title, ":", book.series, book.series_index)
            end
        else
            logger.info("Using title-based or existing series for", book.title, ":", book.series, book.series_index)
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

    -- Extract book ID from book.id
    -- Format is: urn:booklore:book:178
    local book_id = book.id:match("book:(%d+)$")
    
    if not book_id or book_id == "" then
        logger.err("OPDS Browser: No book ID found in:", book.id)
        UIManager:show(InfoMessage:new{ text = _("Cannot download: Book ID not found"), timeout = 3 })
        return
    end

    -- Determine file extension
    local extension = ".epub"
    if book.media_type and book.media_type:match("kepub") then
        extension = ".kepub.epub"
    elseif book.download_url and book.download_url:lower():match("kepub") then
        extension = ".kepub.epub"
    end

    -- Generate filename from title
    local filename = book.title:gsub("[^%w%s%-]", ""):gsub("%s+", "_") .. extension
    local filepath = self.download_dir .. "/" .. filename
    
    -- Construct download URL: /api/v1/opds/178/download
    local download_url = self.opds_url .. "/" .. book_id .. "/download"
    
    logger.info("OPDS Browser: Downloading:", book.title)
    logger.info("OPDS Browser: Book ID:", book_id)
    logger.info("OPDS Browser: URL:", download_url)
    logger.info("OPDS Browser: Format:", extension)

    -- Credentials (may be nil)
    local user = (self.opds_username and self.opds_username ~= "") and self.opds_username or nil
    local pass = (self.opds_password and self.opds_password ~= "") and self.opds_password or nil

    UIManager:show(InfoMessage:new{ text = _("Downloading..."), timeout = 3 })

    -- Use low-level HTTPS with cache-busting headers
    local https = require("ssl.https")
    local ltn12 = require("ltn12")
    local mime = require("mime")
    
    local response_body = {}
    local headers = {
        ["Cache-Control"] = "no-cache, no-store, must-revalidate",
        ["Pragma"] = "no-cache",
        ["Expires"] = "0"
    }
    
    -- Add Basic Auth if credentials provided
    if user and pass then
        local credentials = mime.b64(user .. ":" .. pass)
        headers["Authorization"] = "Basic " .. credentials
    end
    
    local res, code, response_headers = https.request{
        url = download_url,
        method = "GET",
        headers = headers,
        sink = ltn12.sink.table(response_body)
    }
    
    if not res or code ~= 200 then
        logger.err("OPDS Browser: Download failed with code:", code)
        UIManager:show(InfoMessage:new{ text = T(_("Download failed: HTTP %1"), code or "error"), timeout = 3 })
        return
    end
    
    local data = table.concat(response_body)
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

    -- Clear cached metadata
    pcall(function()
        local DocSettings = require("docsettings")
        DocSettings:open(filepath):purge()
    end)

    UIManager:show(InfoMessage:new{ text = T(_("Downloaded: %1"), book.title), timeout = 3 })

    -- Refresh the file manager view
    UIManager:scheduleIn(0.5, function()
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

    -- Filter to only include EPUB results
    local epub_results = {}
    for _, book in ipairs(results) do
        -- Check if the book has extension field and it's epub
        local is_epub = false
        if book.extension and type(book.extension) == "string" then
            is_epub = book.extension:lower() == "epub"
        elseif book.format and type(book.format) == "string" then
            is_epub = book.format:lower() == "epub"
        elseif book.type and type(book.type) == "string" then
            is_epub = book.type:lower() == "epub"
        else
            -- If no format field, assume epub (fallback for older Ephemera versions)
            is_epub = true
        end
        
        if is_epub then
            table.insert(epub_results, book)
        else
            logger.info("Ephemera: Filtering out non-EPUB book:", book.title or "Unknown", "Format:", book.extension or book.format or book.type or "unknown")
        end
    end

    if #epub_results == 0 then
        UIManager:show(InfoMessage:new{ text = _("No EPUB books found in Ephemera results"), timeout = 3 })
        return
    end

    local items = {}
    for _, book in ipairs(epub_results) do
        local title = book.title or "Unknown Title"
        local author = book.author or "Unknown Author"
        local display_text = title .. " - " .. author
        table.insert(items, { text = display_text, callback = function() self:requestEphemeraBook(book) end })
    end

    self.ephemera_menu = Menu:new{ 
        title = T(_("Ephemera Search Results (%1 EPUB)"), #epub_results), 
        item_table = items, 
        is_borderless = true, 
        is_popout = false, 
        title_bar_fm_style = true, 
        width = Screen:getWidth(), 
        height = Screen:getHeight() 
    }
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
    if not NetworkMgr:isOnline() then
        NetworkMgr:beforeWifiAction()
        socket.sleep(1)
        if not NetworkMgr:isOnline() then
            UIManager:show(InfoMessage:new{ text = _("Network unavailable"), timeout = 3 })
            return
        end
    end

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
                    where: {_and: [
                        {contributions: {author: {id: {_eq: %s}}}},
                        {users_count: {_gt: 0}},
                        {book_status_id: {_eq: "1"}},
                        {compilation: {_eq: false}},
                        {default_physical_edition: {language_id: {_eq: 1}}}
                    ]}
                    order_by: {title: asc}
                ) {
                    id
                    title
                    pages
                    book_series {
                        series {
                            name
                        }
                        details
                    }
                    release_date
                    description
                    rating
                    ratings_count
                }
            }
        ]], author_id)
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
    logger.info("Hardcover: Response preview:", response_text:sub(1, 500))

    local success, data = pcall(json.decode, response_text)
    if not success then
        logger.err("Hardcover: JSON parse error:", data)
        UIManager:show(InfoMessage:new{ text = T(_("JSON parse error: %1"), tostring(data)), timeout = 5 })
        return
    end

    if not data then
        logger.err("Hardcover: No data in response")
        UIManager:show(InfoMessage:new{ text = _("No data in response"), timeout = 3 })
        return
    end

    if data.errors then
        logger.err("Hardcover: GraphQL errors:", json.encode(data.errors))
        local error_msg = data.errors[1] and data.errors[1].message or "Unknown GraphQL error"
        UIManager:show(InfoMessage:new{ text = T(_("GraphQL error: %1"), error_msg), timeout = 5 })
        return
    end

    if not data.data or not data.data.books then
        logger.err("Hardcover: Unexpected response structure")
        logger.err("Hardcover: Response:", json.encode(data):sub(1, 1000))
        UIManager:show(InfoMessage:new{ text = _("Unexpected response structure"), timeout = 3 })
        return
    end

    self:showHardcoverAuthorFilterOptions(data.data.books, author_name, author_id)
end

function OPDSBrowser:showHardcoverAuthorFilterOptions(books, author_name, author_id)
    local Menu = require("ui/widget/menu")
    local Screen = require("device").screen

    -- Store books and author info for later use
    self.hardcover_all_books = books
    self.hardcover_current_author = author_name
    self.hardcover_current_author_id = author_id

    local items = {
        {
            text = _("Standalone Books"),
            callback = function()
                UIManager:close(self.filter_menu)
                self:showHardcoverStandaloneBooks(books, author_name)
            end,
        },
        {
            text = _("Book Series"),
            callback = function()
                UIManager:close(self.filter_menu)
                self:showHardcoverBookSeries(author_id, author_name)
            end,
        },
        {
            text = _("All Books"),
            callback = function()
                UIManager:close(self.filter_menu)
                self:showHardcoverAllBooks(books, author_name)
            end,
        },
    }

    self.filter_menu = Menu:new{
        title = T(_("Books by %1"), author_name),
        item_table = items,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
    }

    UIManager:show(self.filter_menu)
end

function OPDSBrowser:showHardcoverStandaloneBooks(books, author_name)
    local Menu = require("ui/widget/menu")
    local Screen = require("device").screen

    -- Filter to only standalone books (no series)
    local standalone_books = {}
    for _, book in ipairs(books) do
        local has_series = book.book_series and type(book.book_series) == "table" and #book.book_series > 0
        if not has_series then
            table.insert(standalone_books, book)
        end
    end

    if #standalone_books == 0 then
        UIManager:show(InfoMessage:new{ text = _("No standalone books found for this author"), timeout = 3 })
        return
    end

    -- Sort by release_date descending
    table.sort(standalone_books, function(a, b)
        local date_a = a.release_date
        local date_b = b.release_date

        -- Handle nil or non-string values
        if type(date_a) ~= "string" then date_a = "" end
        if type(date_b) ~= "string" then date_b = "" end

        -- If both empty, maintain order
        if date_a == "" and date_b == "" then return false end
        -- Empty dates go to the end
        if date_a == "" then return false end
        if date_b == "" then return true end

        return date_a > date_b
    end)

    -- Get library lookup for "in library" indicator (only if enabled)
    local author_books_lookup = {}
    if self.enable_library_check then
        author_books_lookup = self:getAuthorBooksFromLibrary(author_name)
    end

    local items = {}
    for _, book in ipairs(standalone_books) do
        local display_text = book.title or "Unknown Title"

        -- Add release date (with type checking)
        if book.release_date and type(book.release_date) == "string" and book.release_date ~= "" then
            display_text = display_text .. " (" .. book.release_date .. ")"
        end

        -- Check if in library (only if checking is enabled)
        if self.enable_library_check then
            local normalized_title = book.title:lower():gsub("[^%w]", "")
            if author_books_lookup[normalized_title] then
                display_text = "✓ " .. display_text
            end
        end

        table.insert(items, {
            text = display_text,
            callback = function()
                self:showHardcoverBookDetails(book, author_name)
            end,
        })
    end

    self.standalone_menu = Menu:new{
        title = T(_("Standalone Books - %1"), author_name),
        item_table = items,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
    }

    UIManager:show(self.standalone_menu)
end

function OPDSBrowser:showHardcoverBookSeries(author_id, author_name)
    if not NetworkMgr:isOnline() then
        NetworkMgr:beforeWifiAction()
        socket.sleep(1)
        if not NetworkMgr:isOnline() then
            UIManager:show(InfoMessage:new{ text = _("Network unavailable"), timeout = 3 })
            return
        end
    end

    UIManager:show(InfoMessage:new{ text = _("Loading series..."), timeout = 2 })

    -- Use efficient series query
    local query = {
        query = string.format([[
            query AuthorSeries {
                series(where: {_and: [{author_id: {_eq: %s}}, {books_count: {_gt: 0}}]}) {
                    name
                    id
                    books_count
                }
            }
        ]], author_id)
    }

    local body = json.encode(query)
    logger.info("Hardcover: Fetching series for author ID:", author_id)

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
        logger.err("Hardcover: Series request failed with code:", code)
        UIManager:show(InfoMessage:new{ text = T(_("Failed to load series: HTTP %1"), code or "error"), timeout = 3 })
        return
    end

    local response_text = table.concat(response_body)
    local success, data = pcall(json.decode, response_text)

    if not success or not data or not data.data or not data.data.series then
        logger.err("Hardcover: Failed to parse series response")
        UIManager:show(InfoMessage:new{ text = _("Failed to parse series"), timeout = 3 })
        return
    end

    local series_list = data.data.series

    if #series_list == 0 then
        UIManager:show(InfoMessage:new{ text = _("No series found for this author"), timeout = 3 })
        return
    end

    -- Sort series alphabetically by name
    table.sort(series_list, function(a, b)
        return a.name < b.name
    end)

    local Menu = require("ui/widget/menu")
    local Screen = require("device").screen

    local items = {}
    for _, series in ipairs(series_list) do
        local book_count = series.books_count or 0
        local display_text = series.name .. " (" .. book_count .. " book" .. (book_count > 1 and "s" or "") .. ")"

        table.insert(items, {
            text = display_text,
            callback = function()
                self:showHardcoverSeriesBooks(series.id, series.name, author_name)
            end,
        })
    end

    self.series_menu = Menu:new{
        title = T(_("Book Series - %1"), author_name),
        item_table = items,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
    }

    UIManager:show(self.series_menu)
end

function OPDSBrowser:showHardcoverSeriesBooks(series_id, series_name, author_name)
    if not NetworkMgr:isOnline() then
        NetworkMgr:beforeWifiAction()
        socket.sleep(1)
        if not NetworkMgr:isOnline() then
            UIManager:show(InfoMessage:new{ text = _("Network unavailable"), timeout = 3 })
            return
        end
    end

    UIManager:show(InfoMessage:new{ text = _("Loading books..."), timeout = 2 })

    -- Use efficient series_by_pk query
    local query = {
        query = string.format([[
            query BookSeriesNu {
                series_by_pk(id: %s) {
                    id
                    name
                    book_series(
                        where: {_and: [
                            {book: {
                                book_status_id: {_eq: "1"},
                                compilation: {_eq: false},
                                default_physical_edition: {language_id: {_eq: 1}}
                            }},
                            {position: {_gt: 0}}
                        ]}
                        order_by: {position: asc}
                    ) {
                        position
                        book {
                            id
                            title
                            description
                            release_date
                            pages
                            rating
                            ratings_count
                            contributions {
                                author {
                                    name
                                }
                            }
                        }
                    }
                }
            }
        ]], series_id)
    }

    local body = json.encode(query)
    logger.info("Hardcover: Fetching books for series ID:", series_id)

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
        logger.err("Hardcover: Series books request failed with code:", code)
        UIManager:show(InfoMessage:new{ text = T(_("Failed to load books: HTTP %1"), code or "error"), timeout = 3 })
        return
    end

    local response_text = table.concat(response_body)
    local success, data = pcall(json.decode, response_text)

    if not success or not data or not data.data or not data.data.series_by_pk then
        logger.err("Hardcover: Failed to parse series books response")
        UIManager:show(InfoMessage:new{ text = _("Failed to parse books"), timeout = 3 })
        return
    end

    local series_data = data.data.series_by_pk
    local book_series_list = series_data.book_series or {}

    if #book_series_list == 0 then
        UIManager:show(InfoMessage:new{ text = _("No books found in this series"), timeout = 3 })
        return
    end

    -- Get library lookup (only if enabled)
    local author_books_lookup = {}
    if self.enable_library_check then
        author_books_lookup = self:getAuthorBooksFromLibrary(author_name)
    end

    local Menu = require("ui/widget/menu")
    local Screen = require("device").screen

    local items = {}
    for _, book_series in ipairs(book_series_list) do
        local book = book_series.book
        local position = book_series.position or 0

        local display_text = book.title or "Unknown Title"

        -- Add series position
        if position > 0 then
            display_text = display_text .. " - " .. series_name .. " #" .. position
        else
            display_text = display_text .. " - " .. series_name
        end

        -- Check if in library (only if checking is enabled)
        if self.enable_library_check then
            local normalized_title = book.title:lower():gsub("[^%w]", "")
            if author_books_lookup[normalized_title] then
                display_text = "✓ " .. display_text
            end
        end

        table.insert(items, {
            text = display_text,
            callback = function()
                -- Add series info to book for details view
                book.book_series = {{
                    series = { slug = series_name, id = series_id },
                    details = "#" .. position
                }}
                self:showHardcoverBookDetails(book, author_name)
            end,
        })
    end

    self.series_books_menu = Menu:new{
        title = series_name,
        item_table = items,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
    }

    UIManager:show(self.series_books_menu)
end

function OPDSBrowser:showHardcoverAllBooks(books, author_name)
    local Menu = require("ui/widget/menu")
    local Screen = require("device").screen

    if #books == 0 then
        UIManager:show(InfoMessage:new{ text = _("No books found for this author"), timeout = 3 })
        return
    end

    -- Sort by release_date descending
    table.sort(books, function(a, b)
        local date_a = a.release_date
        local date_b = b.release_date

        -- Handle nil or non-string values
        if type(date_a) ~= "string" then date_a = "" end
        if type(date_b) ~= "string" then date_b = "" end

        -- If both empty, maintain order
        if date_a == "" and date_b == "" then return false end
        -- Empty dates go to the end
        if date_a == "" then return false end
        if date_b == "" then return true end

        return date_a > date_b
    end)

    -- Get library lookup for "in library" indicator (only if enabled)
    local author_books_lookup = {}
    if self.enable_library_check then
        author_books_lookup = self:getAuthorBooksFromLibrary(author_name)
    end

    local items = {}
    for _, book in ipairs(books) do
        local display_text = book.title or "Unknown Title"

        -- Add release date (with type checking)
        if book.release_date and type(book.release_date) == "string" and book.release_date ~= "" then
            display_text = display_text .. " (" .. book.release_date .. ")"
        end

        -- Check if in library (only if checking is enabled)
        if self.enable_library_check then
            local normalized_title = book.title:lower():gsub("[^%w]", "")
            if author_books_lookup[normalized_title] then
                display_text = "✓ " .. display_text
            end
        end

        table.insert(items, {
            text = display_text,
            callback = function()
                self:showHardcoverBookDetails(book, author_name)
            end,
        })
    end

    self.all_books_menu = Menu:new{
        title = T(_("All Books - %1"), author_name),
        item_table = items,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
    }

    UIManager:show(self.all_books_menu)
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
        
        -- Add series info to display if available
        if book.book_series and #book.book_series > 0 then
            local series_info = book.book_series[1]
            if series_info.series then
                display_text = display_text .. " - " .. (series_info.series.name or "Unknown Series")
                -- Check if details is a string before adding it
                if series_info.details and type(series_info.details) == "string" and series_info.details ~= "" then
                    display_text = display_text .. " " .. series_info.details
                end
            end
        end
        
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
                    name = series_info.series.name or "Unknown Series",
                    details = series_info.details or ""
                }
                logger.info("Hardcover series:", book.title, "->", series_lookup[normalized_title].name, series_lookup[normalized_title].details)
            end
        end
    end

    logger.info("Hardcover: Found series info for books")

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
    -- Check if library checking is enabled
    if not self.enable_library_check then
        logger.info("Library check: Disabled in settings")
        return {}
    end

    -- Check if the library path exists
    if not self.opds_url or self.opds_url == "" then
        return {}
    end

    -- Create a normalized cache key for the author
    local cache_key = "author:" .. author:lower():gsub("[^%w]", "")

    -- Check cache first (session-based)
    if self.library_cache[cache_key] ~= nil then
        logger.info("Library check: Cache hit for author", author)
        return self.library_cache[cache_key]
    end

    -- Search the library for this author using Booklore endpoint
    local query = url.escape(author)
    local base_url = self.opds_url .. "/catalog?q=" .. query
    local size = 50

    logger.info("Library check: Fetching books for author:", author)
    logger.info("Library check: Page limit:", self.library_check_page_limit)

    -- Optimized approach: Parse incrementally, keep only title lookup
    local title_lookup = {}
    local separator = base_url:match("%?") and "&" or "?"

    -- Fetch page 1 to get total pages
    local page1_url = base_url .. separator .. "page=1&size=" .. size
    local ok, response_or_err = self:httpGet(page1_url)
    if not ok then
        logger.warn("Library check: Failed to fetch first page:", response_or_err)
        self.library_cache[cache_key] = {}
        return {}
    end

    -- Get last page number
    local last_page = self:getLastPageNumber(response_or_err)

    -- Apply page limit (0 = unlimited)
    if self.library_check_page_limit > 0 and last_page > self.library_check_page_limit then
        logger.info("Library check: Limiting to", self.library_check_page_limit, "pages instead of", last_page)
        last_page = self.library_check_page_limit
    end

    logger.info("Library check: Fetching", last_page, "pages")

    -- Parse page 1 and extract titles
    local books = self:parseBookloreOPDSFeed(response_or_err)
    for _, book in ipairs(books) do
        local normalized_title = book.title:lower():gsub("[^%w]", "")
        title_lookup[normalized_title] = true
    end
    logger.info("Library check: Page 1 -", #books, "books")

    -- Fetch and parse remaining pages incrementally
    if last_page > 1 then
        for page = 2, last_page do
            local page_url = base_url .. separator .. "page=" .. page .. "&size=" .. size
            ok, response_or_err = self:httpGet(page_url)

            if ok then
                books = self:parseBookloreOPDSFeed(response_or_err)
                for _, book in ipairs(books) do
                    local normalized_title = book.title:lower():gsub("[^%w]", "")
                    title_lookup[normalized_title] = true
                end
                logger.info("Library check: Page", page, "-", #books, "books")
            else
                logger.warn("Library check: Failed to fetch page", page)
            end
        end
    end

    local total_count = 0
    for _ in pairs(title_lookup) do total_count = total_count + 1 end
    logger.info("Library check: Found", total_count, "unique books for author:", author)

    -- Cache the result (session-based)
    self.library_cache[cache_key] = title_lookup

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
    if book.rating and type(book.rating) == "number" and book.rating > 0 then
        local rating_text = string.format("%.2f", book.rating)
        if book.ratings_count and type(book.ratings_count) == "number" and book.ratings_count > 0 then
            rating_text = rating_text .. " (" .. tostring(book.ratings_count) .. " ratings)"
        end
        details = details .. "\n\n" .. T(_("Rating: %1"), rating_text)
    end
    
    -- Add series info if available
    if book.book_series and type(book.book_series) == "table" and #book.book_series > 0 then
        local series_info = book.book_series[1]
        if series_info and type(series_info) == "table" and series_info.series then
            local series_text = ""
            if series_info.series.name and type(series_info.series.name) == "string" then
                series_text = series_info.series.name
            else
                series_text = "Unknown Series"
            end
            
            if series_info.details and type(series_info.details) == "string" and series_info.details ~= "" then
                series_text = series_text .. " - " .. series_info.details
            end
            details = details .. "\n\n" .. T(_("Series: %1"), series_text)
        end
    end
    
    -- Add description
    if book.description and type(book.description) == "string" and book.description ~= "" then
        local clean_description = strip_html(book.description)
        details = details .. "\n\n" .. clean_description
    end
    
    -- Add release date if available
    if book.release_date and type(book.release_date) == "string" then
        details = details .. "\n\n" .. T(_("Released: %1"), book.release_date)
    end
    
    -- Add pages if available
    if book.pages and type(book.pages) == "number" and book.pages > 0 then
        details = details .. "\n" .. T(_("Pages: %1"), tostring(book.pages))
    end

    local buttons = {
        {
            { text = _("Download from Ephemera"), callback = function()
                UIManager:close(self.hardcover_book_details)
                self:downloadFromEphemera(book, book_author)
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

function OPDSBrowser:downloadFromEphemera(book, author)
    if not self.ephemera_url or self.ephemera_url == "" then
        UIManager:show(InfoMessage:new{ text = _("Ephemera URL not configured"), timeout = 3 })
        return
    end

    -- Search by author and book name
    logger.info("Ephemera: Searching by author and title:", author, book.title)
    UIManager:show(InfoMessage:new{ text = _("Searching Ephemera..."), timeout = 2 })

    local search_string = author .. " " .. book.title
    local query = url.escape(search_string)
    local full_url = self.ephemera_url .. "/api/search?q=" .. query

    local ok, response_or_err = self:httpGet(full_url)
    if not ok then
        UIManager:show(InfoMessage:new{ text = T(_("Ephemera search failed: %1"), response_or_err), timeout = 3 })
        return
    end

    local success, data = pcall(json.decode, response_or_err)
    if not success or not data or not data.results then
        UIManager:show(InfoMessage:new{ text = _("Failed to parse search results"), timeout = 3 })
        return
    end

    -- Filter for EPUB and English language
    local filtered = self:filterEphemeraResults(data.results, true) -- true = English only

    if #filtered == 0 then
        UIManager:show(InfoMessage:new{ text = _("No English EPUB books found"), timeout = 3 })
        return
    end

    -- Show top 5 results
    local top_results = {}
    for i = 1, math.min(5, #filtered) do
        table.insert(top_results, filtered[i])
    end

    self:showEphemeraResultsLimited(top_results)
end

function OPDSBrowser:showEphemeraResultsLimited(results)
    local Menu = require("ui/widget/menu")
    local Screen = require("device").screen

    local items = {}
    for _, book in ipairs(results) do
        local title = book.title or "Unknown Title"
        local author = book.author or "Unknown Author"
        local display_text = title .. " - " .. author
        table.insert(items, {
            text = display_text,
            callback = function()
                self:requestEphemeraBook(book)
            end
        })
    end

    self.ephemera_menu = Menu:new{
        title = T(_("Top %1 Results"), #results),
        item_table = items,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        width = Screen:getWidth(),
        height = Screen:getHeight()
    }
    UIManager:show(self.ephemera_menu)
end

function OPDSBrowser:filterEphemeraResults(results, english_only)
    local filtered = {}

    for _, book in ipairs(results) do
        -- Check if EPUB
        local is_epub = false
        if book.extension and type(book.extension) == "string" then
            is_epub = book.extension:lower() == "epub"
        elseif book.format and type(book.format) == "string" then
            is_epub = book.format:lower() == "epub"
        elseif book.type and type(book.type) == "string" then
            is_epub = book.type:lower() == "epub"
        else
            is_epub = true -- Fallback for older Ephemera versions
        end

        if not is_epub then
            goto continue
        end

        -- Check if English (if required)
        if english_only then
            local is_english = false
            if book.language and type(book.language) == "string" then
                local lang = book.language:lower()
                is_english = (lang == "english" or lang == "en" or lang == "eng")
            else
                -- If no language field, assume English
                is_english = true
            end

            if not is_english then
                goto continue
            end
        end

        table.insert(filtered, book)
        ::continue::
    end

    return filtered
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
