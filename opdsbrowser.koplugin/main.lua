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
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template

-- HTTP libraries - using same approach as working plugin
local http = require("socket.http")
local https = require("ssl.https")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")
local url = require("socket.url")

local OPDSBrowser = WidgetContainer:extend{
    name = "opdsbrowser",
    is_doc_only = false,
}

function OPDSBrowser:init()
    self.ui.menu:registerToMainMenu(self)
    self.settings_file = DataStorage:getSettingsDir() .. "/opdsbrowser.lua"
    self.settings = LuaSettings:open(self.settings_file)
    
    -- Load settings with defaults
    self.opds_url = self.settings:readSetting("opds_url") or ""
    self.opds_username = self.settings:readSetting("opds_username") or ""
    self.opds_password = self.settings:readSetting("opds_password") or ""
    self.ephemera_url = self.settings:readSetting("ephemera_url") or ""
    self.download_dir = self.settings:readSetting("download_dir") or DataStorage:getDataDir() .. "/books"
end

function OPDSBrowser:addToMainMenu(menu_items)
    menu_items.opdsbrowser = {
        text = _("OPDS Browser"),
        sub_item_table = {
            {
                text = _("Browse by Author"),
                callback = function()
                    self:browseAuthors()
                end,
                enabled_func = function()
                    return self.opds_url ~= ""
                end,
            },
            {
                text = _("Browse New Books"),
                callback = function()
                    self:browseOPDS()
                end,
                enabled_func = function()
                    return self.opds_url ~= ""
                end,
            },
            {
                text = _("Search OPDS"),
                callback = function()
                    self:searchOPDS()
                end,
                enabled_func = function()
                    return self.opds_url ~= ""
                end,
            },
            {
                text = _("Request Book (Ephemera)"),
                callback = function()
                    self:requestBook()
                end,
                enabled_func = function()
                    return self.ephemera_url ~= ""
                end,
            },
            {
                text = _("Settings"),
                callback = function()
                    self:showSettings()
                end,
            },
        },
    }
end

function OPDSBrowser:showSettings()
    local MultiInputDialog = require("ui/widget/multiinputdialog")
    self.settings_dialog = MultiInputDialog:new{
        title = _("OPDS Browser Settings"),
        fields = {
            {
                text = self.opds_url,
                hint = _("Base URL (e.g., https://example.com)"),
                input_type = "string",
            },
            {
                text = self.opds_username,
                hint = _("OPDS Username (optional)"),
                input_type = "string",
            },
            {
                text = self.opds_password,
                hint = _("OPDS Password (optional)"),
                input_type = "string",
            },
            {
                text = self.ephemera_url,
                hint = _("Ephemera URL (e.g., http://example.com:8286)"),
                input_type = "string",
            },
            {
                text = self.download_dir,
                hint = _("Download Directory"),
                input_type = "string",
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        self.settings_dialog:onClose()
                        UIManager:close(self.settings_dialog)
                    end
                },
                {
                    text = _("Save"),
                    callback = function()
                        local fields = self.settings_dialog:getFields()
                        local new_opds_url = fields[1]:gsub("/$", ""):gsub("%s+", "")
                        local new_opds_username = fields[2]
                        local new_opds_password = fields[3]
                        local new_ephemera_url = fields[4]:gsub("/$", ""):gsub("%s+", "")
                        local new_download_dir = fields[5]
                        
                        -- Validate OPDS URL if provided
                        if new_opds_url ~= "" then
                            if not new_opds_url:match("^https?://") then
                                UIManager:show(InfoMessage:new{
                                    text = _("Invalid OPDS URL!\n\nURL must start with http:// or https://\n\nExample: http://192.168.1.100:8080/opds"),
                                    timeout = 5,
                                })
                                return
                            end
                        end
                        
                        -- Validate Ephemera URL if provided
                        if new_ephemera_url ~= "" then
                            if not new_ephemera_url:match("^https?://") then
                                UIManager:show(InfoMessage:new{
                                    text = _("Invalid Ephemera URL!\n\nURL must start with http:// or https://\n\nExample: http://192.168.1.100:8286"),
                                    timeout = 5,
                                })
                                return
                            end
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
                        
                        local message = _("Settings saved successfully!")
                        if new_opds_url ~= "" then
                            message = message .. _("\n\nYou can now browse your OPDS library.")
                        end
                        
                        UIManager:show(InfoMessage:new{
                            text = message,
                            timeout = 3,
                        })
                        UIManager:close(self.settings_dialog)
                    end
                },
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

function OPDSBrowser:httpRequest(url_str, method, body, content_type)
    -- Validate URL format
    if not url_str or url_str == "" then
        logger.err("OPDS Browser: Empty URL provided")
        return nil, 1, "Empty URL"
    end
    
    if not url_str:match("^https?://") then
        logger.err("OPDS Browser: Invalid URL format: ", url_str)
        return nil, 1, "Invalid URL format - must start with http:// or https://"
    end
    
    -- Check network
    if not NetworkMgr:isOnline() then
        logger.info("OPDS Browser: Network offline, attempting to connect...")
        NetworkMgr:beforeWifiAction()
        socket.sleep(1)
        
        if not NetworkMgr:isOnline() then
            logger.err("OPDS Browser: Network still offline")
            return nil, 1, "Network unavailable - enable Wi-Fi in KOReader"
        end
    end
    
    logger.info("OPDS Browser: Requesting URL:", url_str)
    logger.info("OPDS Browser: Method:", method or "GET")
    
    -- Use the same timeout approach as the working plugin
    local BLOCK_TIMEOUT = 5
    local TOTAL_TIMEOUT = 30
    
    socketutil:set_timeout(BLOCK_TIMEOUT, TOTAL_TIMEOUT)
    
    local sink = {}
    
    local request_params = {
        url = url_str,
        method = method or "GET",
        headers = {
            ["Accept"] = "application/atom+xml, application/xml, text/xml, */*",
            ["Accept-Encoding"] = "identity",
            ["User-Agent"] = "KOReader-OPDS-Browser",
        },
        sink = ltn12.sink.table(sink),
    }
    
    -- Add authentication if configured
    local auth = self:makeAuthHeader()
    if auth then
        request_params.headers["Authorization"] = auth
        logger.info("OPDS Browser: Using authentication")
    end
    
    -- Add body for POST requests
    if body then
        request_params.source = ltn12.source.string(body)
        if content_type then
            request_params.headers["Content-Type"] = content_type
            request_params.headers["Content-Length"] = tostring(#body)
        end
    end
    
    -- Parse URL to determine if HTTPS
    local parsed_url = url.parse(url_str)
    local requester = http
    
    if parsed_url.scheme == "https" then
        requester = https
        -- Use the same HTTPS settings as the working plugin
        request_params.verify = "none"
        request_params.protocol = "tlsv1_2"
        logger.info("OPDS Browser: Using HTTPS with TLS 1.2")
    end
    
    -- Make the request using socket.skip like the working plugin
    local code, headers, status = socket.skip(1, requester.request(request_params))
    socketutil:reset_timeout()
    
    local response_body = table.concat(sink)
    
    if code == 200 then
        logger.info("OPDS Browser: Success! Response length:", #response_body)
        return response_body, 200, headers
    elseif code == nil then
        logger.warn("OPDS Browser: Request failed:", headers)
        return nil, 1, tostring(headers)
    else
        logger.warn("OPDS Browser: Request failed with code:", code, "status:", status)
        return response_body, code, status
    end
end

function OPDSBrowser:parseOPDSFeed(xml_data)
    local entries = {}
    
    -- Log a sample of the XML for debugging
    logger.info("OPDS Browser: Parsing OPDS feed, length:", #xml_data)
    logger.info("OPDS Browser: First 500 chars:", xml_data:sub(1, 500))
    
    -- Calibre-Web OPDS uses standard OPDS format
    -- Each book is in an <entry> tag
    local entry_count = 0
    for entry in xml_data:gmatch("<entry>(.-)</entry>") do
        entry_count = entry_count + 1
        local book = {}
        
        -- Extract title (required)
        book.title = entry:match("<title[^>]*>(.-)</title>") or "Unknown Title"
        -- Decode HTML entities
        book.title = book.title:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&amp;", "&"):gsub("&quot;", '"')
        
        -- Extract author - Calibre-Web format
        local author_block = entry:match("<author>(.-)</author>")
        if author_block then
            book.author = author_block:match("<n>(.-)</n>") or 
                         author_block:match("<n>(.-)</n>") or 
                         "Unknown Author"
        else
            book.author = "Unknown Author"
        end
        book.author = book.author:gsub("&amp;", "&")
        
        -- Extract summary/description
        book.summary = entry:match('<summary[^>]*>(.-)</summary>') or 
                      entry:match('<content[^>]*>(.-)</content>') or ""
        -- Strip HTML tags and decode entities
        book.summary = book.summary:gsub("<[^>]+>", ""):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&amp;", "&"):gsub("&nbsp;", " ")
        
        -- Extract series information
        book.series = entry:match('category term="([^"]*)" label="[Ss]eries"') or
                     entry:match('<dc:series>(.-)</dc:series>') or ""
        
        book.series_index = entry:match('<calibre:series_index>(.-)</calibre:series_index>') or ""
        
        -- Extract ID (useful for tracking)
        book.id = entry:match('<id>(.-)</id>') or ""
        
        -- Extract acquisition links - these are download links
        for link in entry:gmatch('<link[^>]*rel="http://opds%-spec%.org/acquisition[^"]*"[^>]*>') do
            local href = link:match('href="([^"]*)"')
            local media_type = link:match('type="([^"]*)"')
            
            if href and not book.download_url then
                book.download_url = href
                book.media_type = media_type or "application/epub+zip"
                logger.dbg("OPDS Browser: Found download link:", href)
            end
        end
        
        -- If no acquisition link found, try alternate patterns
        if not book.download_url then
            for link in entry:gmatch('<link[^>]*type="application/epub%+zip"[^>]*>') do
                local href = link:match('href="([^"]*)"')
                if href then
                    book.download_url = href
                    book.media_type = "application/epub+zip"
                    logger.dbg("OPDS Browser: Found EPUB link:", href)
                    break
                end
            end
        end
        
        -- Extract cover/thumbnail image
        for link in entry:gmatch('<link[^>]*rel="http://opds%-spec%.org/image"[^>]*>') do
            local href = link:match('href="([^"]*)"')
            if href then
                book.cover_url = href
                break
            end
        end
        
        -- Only add books that have a download URL
        if book.download_url then
            table.insert(entries, book)
            logger.dbg("OPDS Browser: Parsed book:", book.title, "by", book.author)
        else
            logger.warn("OPDS Browser: Skipping entry without download URL:", book.title)
        end
    end
    
    logger.info("OPDS Browser: Found", entry_count, "entries, parsed", #entries, "books")
    
    -- If we found no books, log more details for debugging
    if #entries == 0 then
        logger.warn("OPDS Browser: No books parsed. Checking for feed structure...")
        if xml_data:match("<feed") then
            logger.info("OPDS Browser: Feed tag found - this is an OPDS feed")
        else
            logger.warn("OPDS Browser: No feed tag found - may not be OPDS XML")
        end
        
        if xml_data:match("<entry>") then
            logger.info("OPDS Browser: Entry tags found, but no valid books parsed")
            local first_entry = xml_data:gmatch("<entry>(.-)</entry>")()
            if first_entry then
                logger.info("OPDS Browser: First entry sample:", first_entry:sub(1, 500))
            end
        else
            logger.warn("OPDS Browser: No entry tags found in feed")
        end
    end
    
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
            callback = function()
                self:showBookDetails(book)
            end,
        })
    end
    
    self.book_menu = Menu:new{
        title = title or _("OPDS Books"),
        item_table = items,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        onMenuHold = function(item)
            return true
        end,
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
    
    local details = T(_("Title: %1\n\nAuthor: %2"), book.title, book.author) .. 
                   series_text ..
                   "\n\n" .. book.summary
    
    local buttons = {
        {
            {
                text = _("Download"),
                callback = function()
                    UIManager:close(self.book_details)
                    self:downloadBook(book)
                end,
            },
        },
        {
            {
                text = _("Close"),
                callback = function()
                    UIManager:close(self.book_details)
                end,
            },
        },
    }
    
    self.book_details = TextViewer:new{
        title = book.title,
        text = details,
        buttons_table = buttons,
    }
    
    UIManager:show(self.book_details)
end

function OPDSBrowser:browseOPDS()
    local url = self.opds_url .. "/opds/new"
    local response, code, error_msg = self:httpRequest(url, "GET")
    
    if response and code == 200 then
        local books = self:parseOPDSFeed(response)
        if #books > 0 then
            self:showBookList(books, _("New Books"))
        else
            UIManager:show(InfoMessage:new{
                text = _("No books found in catalog.\n\nCheck if your OPDS server has books available."),
                timeout = 5,
            })
        end
    else
        local error_text
        if not code then
            error_text = T(_("Failed to connect to OPDS server.\n\nError: %1\n\nTroubleshooting:\n• Check URL format (must start with http:// or https://)\n• Verify server is running\n• Ensure Wi-Fi is enabled in KOReader\n• Test URL in a web browser first"), 
                error_msg or "Connection failed")
        elseif code == 401 then
            error_text = _("Authentication required.\n\nPlease enter your username and password in Settings.")
        elseif code == 404 then
            error_text = _("OPDS catalog not found (404).\n\nCheck your OPDS URL path is correct.")
        elseif code == 500 then
            error_text = _("Server error (500).\n\nThe OPDS server encountered an error.")
        else
            error_text = T(_("Failed to connect to OPDS server.\n\nHTTP Code: %1\n\nCheck your server settings and network connection."), code)
        end
        
        UIManager:show(InfoMessage:new{
            text = error_text,
            timeout = 8,
        })
    end
end

function OPDSBrowser:browseAuthors()
    local full_url = self.opds_url .. "/opds/author/letter/00"
    local response, code, error_msg = self:httpRequest(full_url, "GET")
    
    if response and code == 200 then
        local authors = self:parseAuthorsFromOPDS(response)
        if #authors > 0 then
            self:showAuthorList(authors)
        else
            UIManager:show(InfoMessage:new{
                text = _("No authors found."),
                timeout = 5,
            })
        end
    else
        UIManager:show(InfoMessage:new{
            text = T(_("Failed to load authors. Code: %1"), code or "unknown"),
        })
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
        
        -- Get link to author's books - try multiple patterns
        local found_link = false
        
        -- Pattern 1: type="application/atom+xml"
        for link in entry:gmatch('<link[^>]*type="application/atom%+xml"[^>]*>') do
            local href = link:match('href="([^"]*)"')
            if href then
                author.url = href
                found_link = true
                logger.dbg("OPDS Browser: Found author link (atom+xml):", href)
                break
            end
        end
        
        -- Pattern 2: rel="subsection"
        if not found_link then
            for link in entry:gmatch('<link[^>]*rel="subsection"[^>]*>') do
                local href = link:match('href="([^"]*)"')
                if href then
                    author.url = href
                    found_link = true
                    logger.dbg("OPDS Browser: Found author link (subsection):", href)
                    break
                end
            end
        end
        
        -- Pattern 3: any link in entry
        if not found_link then
            local href = entry:match('<link[^>]*href="([^"]*)"')
            if href then
                author.url = href
                found_link = true
                logger.dbg("OPDS Browser: Found author link (generic):", href)
            end
        end
        
        if author.url then
            table.insert(authors, author)
            logger.dbg("OPDS Browser: Added author:", author.name)
        else
            logger.warn("OPDS Browser: Skipping author without URL:", author.name)
        end
    end
    
    logger.info("OPDS Browser: Found", entry_count, "entries, parsed", #authors, "authors")
    
    if #authors == 0 and entry_count > 0 then
        logger.warn("OPDS Browser: Entries found but no valid authors. Sample entry:")
        local first_entry = xml_data:gmatch("<entry>(.-)</entry>")()
        if first_entry then
            logger.info(first_entry:sub(1, 500))
        end
    end
    
    return authors
end

function OPDSBrowser:showAuthorList(authors)
    local Menu = require("ui/widget/menu")
    local Screen = require("device").screen
    
    local items = {}
    for _, author in ipairs(authors) do
        table.insert(items, {
            text = author.name,
            callback = function()
                self:browseBooksByAuthor(author.name, author.url)
            end,
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
    -- Construct full URL - author_url is like "/opds/author/53"
    local full_url = self.opds_url .. author_url
    
    local response, code = self:httpRequest(full_url, "GET")
    
    if response and code == 200 then
        local books = self:parseOPDSFeed(response)
        if #books > 0 then
            self:showBookList(books, T(_("Books by %1"), author_name))
        else
            UIManager:show(InfoMessage:new{
                text = _("No books found for this author."),
                timeout = 5,
            })
        end
    else
        UIManager:show(InfoMessage:new{
            text = T(_("Failed to load books. Code: %1"), code or "unknown"),
        })
    end
end


function OPDSBrowser:searchOPDS()
    local input_dialog
    input_dialog = InputDialog:new{
        title = _("Search OPDS"),
        input = "",
        input_hint = _("Enter search term"),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(input_dialog)
                    end,
                },
                {
                    text = _("Search"),
                    is_enter_default = true,
                    callback = function()
                        local search_term = input_dialog:getInputText()
                        UIManager:close(input_dialog)
                        if search_term and search_term ~= "" then
                            self:performSearch(search_term)
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

function OPDSBrowser:performSearch(search_term)
    UIManager:show(InfoMessage:new{
        text = _("Searching..."),
    })
    
    -- OPDS search URL typically follows the pattern: /opds/search?q=term
    local url = self.opds_url .. "/search?q=" .. self:urlEncode(search_term)
    local response, code = self:httpRequest(url, "GET")
    
    if response and code == 200 then
        local books = self:parseOPDSFeed(response)
        if #books > 0 then
            self:showBookList(books, T(_("Search Results: %1"), search_term))
        else
            UIManager:show(InfoMessage:new{
                text = _("No books found"),
            })
        end
    else
        UIManager:show(InfoMessage:new{
            text = T(_("Search failed. Code: %1"), code or "unknown"),
        })
    end
end

function OPDSBrowser:urlEncode(str)
    str = string.gsub(str, "([^%w%-%.%_%~])",
        function(c)
            return string.format("%%%02X", string.byte(c))
        end)
    return str
end

function OPDSBrowser:downloadBook(book)
    -- Ensure download directory exists
    local lfs = require("libs/libkoreader-lfs")
    local dir_exists = lfs.attributes(self.download_dir, "mode") == "directory"
    if not dir_exists then
        local ok = lfs.mkdir(self.download_dir)
        if not ok then
            UIManager:show(InfoMessage:new{
                text = _("Failed to create download directory"),
                timeout = 3,
            })
            return
        end
    end
    
    -- Extract filename from URL or use title
    local filename = book.download_url:match("([^/]+)$")
    if not filename or filename == "" or not filename:match("%.") then
        filename = book.title:gsub("[^%w%s%-]", ""):gsub("%s+", "_") .. ".epub"
    end
    
    local filepath = self.download_dir .. "/" .. filename
    
    logger.info("OPDS Browser: Downloading to:", filepath)
    
    -- Construct full download URL
    local download_url = self.opds_url .. book.download_url
    logger.info("OPDS Browser: Download URL:", download_url)
    
    -- Wrap entire download in pcall to catch crashes
    local success, result = pcall(function()
        -- Open file for writing
        local file, err = io.open(filepath, "wb")
        if not file then
            logger.err("OPDS Browser: Failed to open file:", err)
            return false, "Failed to create file: " .. (err or "unknown")
        end
        
        local BLOCK_TIMEOUT = 5
        local TOTAL_TIMEOUT = 60
        
        socketutil:set_timeout(BLOCK_TIMEOUT, TOTAL_TIMEOUT)
        
        local request_params = {
            url = download_url,
            method = "GET",
            headers = {
                ["User-Agent"] = "KOReader-OPDS-Browser",
            },
            sink = ltn12.sink.file(file),
            user = self.opds_username ~= "" and self.opds_username or nil,
            password = self.opds_password ~= "" and self.opds_password or nil,
        }
        
        local parsed_url = url.parse(download_url)
        local requester = http
        
        if parsed_url.scheme == "https" then
            requester = https
            request_params.verify = "none"
            request_params.protocol = "tlsv1_2"
        end
        
        local code, headers, status = socket.skip(1, requester.request(request_params))
        socketutil:reset_timeout()
        
        file:close()
        
        if code == 200 then
            logger.info("OPDS Browser: Download successful")
            return true, filepath
        else
            logger.warn("OPDS Browser: Download failed, code:", code)
            os.remove(filepath)
            return false, "HTTP Code: " .. tostring(code)
        end
    end)
    
    if success and result then
        if type(result) == "string" then
            -- Success - result is filepath
            UIManager:show(InfoMessage:new{
                text = T(_("Downloaded: %1"), filename),
                timeout = 3,
            })
        else
            -- Failed - result is error message
            UIManager:show(InfoMessage:new{
                text = T(_("Download failed: %1"), result),
                timeout = 3,
            })
        end
    else
        -- pcall failed - crashed during download
        logger.err("OPDS Browser: Download crashed:", result)
        UIManager:show(InfoMessage:new{
            text = T(_("Download error: %1"), tostring(result)),
            timeout = 3,
        })
    end
end

function OPDSBrowser:requestBook()
    local input_dialog
    input_dialog = MultiInputDialog:new{
        title = _("Request Book via Ephemera"),
        fields = {
            {
                text = "",
                hint = _("Book Title"),
                input_type = "string",
            },
            {
                text = "",
                hint = _("Author (optional)"),
                input_type = "string",
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(input_dialog)
                    end,
                },
                {
                    text = _("Search & Request"),
                    is_enter_default = true,
                    callback = function()
                        local fields = input_dialog:getFields()
                        local title = fields[1]
                        local author = fields[2]
                        UIManager:close(input_dialog)
                        if title and title ~= "" then
                            self:searchEphemera(title, author)
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

function OPDSBrowser:searchEphemera(title, author)
    UIManager:show(InfoMessage:new{
        text = _("Searching Ephemera..."),
    })
    
    -- Build search query
    local query = self:urlEncode(title)
    if author and author ~= "" then
        query = query .. " " .. self:urlEncode(author)
    end
    
    local url = self.ephemera_url .. "/api/search?q=" .. query
    local response, code = self:httpRequest(url, "GET")
    
    if response and code == 200 then
        local json = require("json")
        local success, data = pcall(json.decode, response)
        
        if success and data and data.results then
            self:showEphemeraResults(data.results)
        else
            UIManager:show(InfoMessage:new{
                text = _("Failed to parse search results"),
            })
        end
    else
        UIManager:show(InfoMessage:new{
            text = T(_("Ephemera search failed. Code: %1"), code or "unknown"),
        })
    end
end

function OPDSBrowser:showEphemeraResults(results)
    local Menu = require("ui/widget/menu")
    local Screen = require("device").screen
    
    if #results == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No books found in Ephemera"),
        })
        return
    end
    
    local items = {}
    for _, book in ipairs(results) do
        local title = book.title or "Unknown Title"
        local author = book.author or "Unknown Author"
        
        table.insert(items, {
            text = title,
            subtitle = author,
            callback = function()
                self:requestEphemeraBook(book)
            end,
        })
    end
    
    self.ephemera_menu = Menu:new{
        title = _("Ephemera Search Results"),
        item_table = items,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
    }
    
    UIManager:show(self.ephemera_menu)
end

function OPDSBrowser:requestEphemeraBook(book)
    UIManager:show(InfoMessage:new{
        text = _("Requesting book..."),
    })
    
    local json = require("json")
    local request_body = json.encode({
        md5 = book.md5,
        title = book.title,
        author = book.author,
    })
    
    local url = self.ephemera_url .. "/api/requests"
    local response, code = self:httpRequest(url, "POST", request_body, "application/json")
    
    if code == 200 or code == 201 then
        UIManager:show(InfoMessage:new{
            text = _("Book requested successfully! You will be notified when it's available."),
            timeout = 5,
        })
        if self.ephemera_menu then
            UIManager:close(self.ephemera_menu)
        end
    else
        UIManager:show(InfoMessage:new{
            text = T(_("Request failed. Code: %1"), code or "unknown"),
        })
    end
end

function OPDSBrowser:onCloseDocument()
end

function OPDSBrowser:onSuspend()
end

return OPDSBrowser
