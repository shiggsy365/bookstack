local logger = require("logger")
local HttpClient = require("http_client_new")
local Constants = require("constants")
local Utils = require("utils")

local OPDSClient = {
    base_url = "",
    username = "",
    password = "",
}

function OPDSClient:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

function OPDSClient:setCredentials(base_url, username, password)
    self.base_url = base_url
    self.username = username
    self.password = password
end

function OPDSClient:httpGet(url_str)
    local user = (self.username and self.username ~= "") and self.username or nil
    local pass = (self.password and self.password ~= "") and self.password or nil
    
    return HttpClient:request_with_retry(url_str, "GET", nil, nil, user, pass)
end

function OPDSClient:getLastPageNumber(xml_data)
    local last_link = xml_data:match('<link rel="last" href="([^"]+)"')
    if last_link then
        local page_num = last_link:match('page=(%d+)')
        if page_num then
            return tonumber(page_num)
        end
    end
    return 1
end

function OPDSClient:fetchAllPages(base_url, size, max_pages)
    size = size or Constants.DEFAULT_PAGE_SIZE
    max_pages = max_pages or 0 -- 0 means unlimited
    
    local separator = base_url:match("%?") and "&" or "?"
    local page1_url = base_url .. separator .. "page=1&size=" .. size
    
    logger.info("OPDS: Fetching first page:", page1_url)
    
    local ok, response_or_err = self:httpGet(page1_url)
    if not ok then
        logger.err("OPDS: Failed to fetch first page:", response_or_err)
        return nil
    end
    
    logger.info("OPDS: First page response length:", #response_or_err)
    
    local last_page = self:getLastPageNumber(response_or_err)
    
    -- Apply page limit
    if max_pages > 0 and last_page > max_pages then
        logger.info("OPDS: Limiting to", max_pages, "pages instead of", last_page)
        last_page = max_pages
    end
    
    logger.info("OPDS: Found", last_page, "pages to fetch")
    
    local all_xml = response_or_err
    
    -- Fetch remaining pages
    if last_page > 1 then
        for page = 2, last_page do
            local page_url = base_url .. separator .. "page=" .. page .. "&size=" .. size
            logger.info("OPDS: Fetching page", page, "of", last_page)
            
            ok, response_or_err = self:httpGet(page_url)
            if ok then
                all_xml = all_xml .. response_or_err
            else
                logger.warn("OPDS: Failed to fetch page", page, ":", response_or_err)
            end
        end
    end
    
    return all_xml
end

function OPDSClient:parseBookloreOPDSFeed(xml_data, use_publisher_as_series)
    local entries = {}
    logger.info("OPDS: Parsing feed with updated series logic")

    local entry_count = 0
    for entry in xml_data:gmatch("<entry>(.-)</entry>") do
        entry_count = entry_count + 1
        local book = {}

        book.title = entry:match("<title>(.-)</title>") or "Unknown Title"
        book.title = Utils.html_unescape(book.title)
        book.title = book.title:gsub("&apos;", "'")

        local author_name = entry:match("<author><name>(.-)</name></author>")
        book.author = author_name and Utils.html_unescape(author_name) or "Unknown Author"

        local raw_summary = entry:match('<summary>(.-)</summary>') or ""
        raw_summary = Utils.html_unescape(raw_summary)

        local publisher = entry:match('<dc:publisher>(.-)</dc:publisher>') or ""
        publisher = Utils.html_unescape(publisher)
        
        -- Initialize series fields
        book.series = ""
        book.series_index = ""
        
        -- ==================================================================================
        -- SERIES EXTRACTION LOGIC (ORDER 1 -> 4)
        -- ==================================================================================

        -- 1. Search OPDS feed for belongs-to-collection and group-position
        --    Format: <meta property="belongs-to-collection" id="series">The Nero Trilogy</meta>
        --            <meta property="group-position" refines="#series">1.0</meta>
        local series_meta = entry:match('<meta property="belongs%-to%-collection"[^>]*id="series"[^>]*>(.-)</meta>')
        
        -- Fallback: Try match without id="series" check just in case, but prioritize the specific one
        if not series_meta then
            series_meta = entry:match('<meta property="belongs%-to%-collection"[^>]*>(.-)</meta>')
        end

        if series_meta then
            book.series = Utils.trim(series_meta)
            logger.dbg("OPDS (Step 1): Found series in metadata:", book.series)
            
            -- Extract and normalize position
            local series_pos = entry:match('<meta property="group%-position"[^>]*refines="#series"[^>]*>(.-)</meta>')
            
            -- Fallback: Try without refines if not found (loose match)
            if not series_pos then
                 series_pos = entry:match('<meta property="group%-position"[^>]*>(.-)</meta>')
            end

            if series_pos then
                local pos_str = Utils.trim(Utils.html_unescape(series_pos))
                local pos_num = tonumber(pos_str)
                
                -- Normalize: 1.0 -> 1, 1.5 -> 1.5
                if pos_num then
                    if pos_num == math.floor(pos_num) then
                        book.series_index = string.format("%d", pos_num)
                    else
                        book.series_index = tostring(pos_num)
                    end
                else
                    book.series_index = pos_str
                end
                logger.dbg("OPDS (Step 1): Extracted normalized index:", book.series_index)
            end
        end

        -- 2. If 'use publisher for series' is YES, use publisher data
        --    (Only if series not already found in step 1)
        if book.series == "" and use_publisher_as_series and publisher ~= "" then
            -- Pattern: "Series Name Number" or "Series Name #Number"
            -- Try to capture the number at the end
            local series_name, series_num = publisher:match("^(.-)%s+(%d+%.?%d*)$")
            
            if series_name and series_num then
                book.series = Utils.trim(series_name)
                book.series_index = series_num
                logger.dbg("OPDS (Step 2): Found series in publisher:", book.series, "#", book.series_index)
            else
                -- Fallback: use whole publisher as series name
                book.series = Utils.trim(publisher)
                logger.dbg("OPDS (Step 2): Using publisher as series name:", book.series)
            end
        end

        -- 3. If description contains |Reacher 3|, use this
        --    (Only if series not already found in steps 1 or 2)
        if book.series == "" then
            -- Look for content explicitly inside pipes |...|
            local desc_tag = raw_summary:match("|([^|]+)|")
            
            if desc_tag then
                -- Try to parse "Name Number" from inside the tag
                local series_name, series_num = desc_tag:match("^(.-)%s+(%d+%.?%d*)$")
                
                if not series_name then
                    -- Try "Name #Number"
                    series_name, series_num = desc_tag:match("^(.-)%s+#(%d+%.?%d*)$")
                end

                if series_name and series_num then
                    book.series = Utils.trim(series_name)
                    book.series_index = series_num
                    logger.dbg("OPDS (Step 3): Found series in description tag:", book.series, "#", book.series_index)
                else
                    -- Use the whole tag content as series name
                    book.series = Utils.trim(desc_tag)
                    logger.dbg("OPDS (Step 3): Using description tag as series:", book.series)
                end
            end
        end

        -- 4. Scrape Hardcover
        --    If book.series is still empty at this point, the plugin's Hardcover integration
        --    (logic in main.lua/hardcover_client) will handle the lookup lazily or on demand.
        --    We leave the fields empty here to signal that fallback is needed.

        -- Clean series name: replace underscores with spaces
        if book.series ~= "" then
            book.series = book.series:gsub("_", " ")
        end

        -- Clean summary
        book.summary = Utils.strip_html(raw_summary)

        book.id = entry:match('<id>(.-)</id>') or ""
        book.updated = entry:match('<updated>(.-)</updated>') or ""

        -- Extract download link
        local download_link = entry:match('<link href="([^"]+)" rel="http://opds%-spec%.org/acquisition"')
        if download_link then
            book.download_url = Utils.resolve_url(self.base_url, download_link)
            book.media_type = "application/epub+zip"
        end
        
        -- Extract cover image URL
        local cover_link = entry:match('<link href="([^"]+)" rel="http://opds%-spec%.org/image"')
        if not cover_link then
            cover_link = entry:match('<link rel="http://opds%-spec%.org/image"[^>]*href="([^"]+)"')
        end
        if not cover_link then
            cover_link = entry:match('<link href="([^"]+)" rel="http://opds%-spec%.org/image/thumbnail"')
        end
        if not cover_link then
            cover_link = entry:match('<link rel="http://opds%-spec%.org/image/thumbnail"[^>]*href="([^"]+)"')
        end
        if not cover_link then
            cover_link = entry:match('<link href="([^"]+)" type="image/[^"]*"[^>]*rel="[^"]*cover[^"]*"')
        end
        if not cover_link then
            cover_link = entry:match('<link href="([^"]+)" type="image/jpeg"')
            if not cover_link then
                cover_link = entry:match('<link href="([^"]+)" type="image/png"')
            end
        end
        
        if cover_link then
            book.cover_url = Utils.resolve_url(self.base_url, cover_link)
        end

        if book.download_url then
            table.insert(entries, book)
        end
    end

    logger.info("OPDS: Parsed", #entries, "books")
    return entries
end

function OPDSClient:parseAuthorsFromBooklore(xml_data)
    local author_set = {}
    logger.info("OPDS: Parsing authors from XML")

    for entry in xml_data:gmatch("<entry>(.-)</entry>") do
        local author_name = entry:match("<author><name>(.-)</name></author>")
        if author_name then
            author_name = Utils.html_unescape(author_name)
            author_set[author_name] = true
        end
    end

    local authors = {}
    for name, _ in pairs(author_set) do
        table.insert(authors, { name = name })
    end
    
    table.sort(authors, function(a, b) return a.name < b.name end)
    
    return authors
end

function OPDSClient:sortBooks(books)
    table.sort(books, function(a, b)
        local a_has_series = a.series and type(a.series) == "string" and a.series ~= ""
        local b_has_series = b.series and type(b.series) == "string" and b.series ~= ""
        
        if a_has_series and b_has_series then
            if a.series ~= b.series then
                return a.series < b.series
            end
            
            local a_idx = Utils.safe_number(a.series_index, 0)
            local b_idx = Utils.safe_number(b.series_index, 0)
            
            if a_idx ~= b_idx then
                return a_idx < b_idx
            end
            return a.title < b.title
        end
        
        if a_has_series then return true end
        if b_has_series then return false end
        
        return a.title < b.title
    end)
    
    return books
end

return OPDSClient
