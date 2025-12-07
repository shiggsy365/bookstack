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
    logger.info("OPDS: Parsing feed, XML length:", #xml_data)

    local entry_count = 0
    for entry in xml_data:gmatch("<entry>(.-)</entry>") do
        entry_count = entry_count + 1
        local book = {}

        book.title = entry:match("<title>(.-)</title>") or "Unknown Title"
        book.title = Utils.html_unescape(book.title)

        local author_name = entry:match("<author><name>(.-)</name></author>")
        book.author = author_name and Utils.html_unescape(author_name) or "Unknown Author"

        local raw_summary = entry:match('<summary>(.-)</summary>') or ""
        raw_summary = Utils.html_unescape(raw_summary)

        -- Extract publisher
        local publisher = entry:match('<dc:publisher>(.-)</dc:publisher>') or ""
        publisher = Utils.html_unescape(publisher)
        
        -- Initialize series fields
        book.series = ""
        book.series_index = ""
        
        -- NEW: Method 0: Parse standard OPDS series metadata (highest priority)
        -- Try schema.org/Series and belongs-to-collection metadata
        local series_meta = entry:match('<meta property="belongs%-to%-collection"[^>]*>(.-)</meta>')
        if series_meta then
            series_meta = Utils.html_unescape(series_meta)
            book.series = Utils.trim(series_meta)
            logger.dbg("OPDS: Extracted series from belongs-to-collection:", book.series)
            
            -- Try to find series position/index
            local series_pos = entry:match('<meta property="group%-position"[^>]*>(.-)</meta>')
            if series_pos then
                book.series_index = Utils.trim(Utils.html_unescape(series_pos))
                logger.dbg("OPDS: Extracted series index from group-position:", book.series_index)
            end
        end
        
        -- Try calibre:series metadata if not found
        if book.series == "" then
            local calibre_series = entry:match('<meta name="calibre:series"[^>]*content="([^"]+)"')
            if calibre_series then
                book.series = Utils.trim(Utils.html_unescape(calibre_series))
                logger.dbg("OPDS: Extracted series from calibre:series:", book.series)
                
                -- Try calibre:series_index
                local calibre_index = entry:match('<meta name="calibre:series_index"[^>]*content="([^"]+)"')
                if calibre_index then
                    book.series_index = Utils.trim(Utils.html_unescape(calibre_index))
                    logger.dbg("OPDS: Extracted series index from calibre:series_index:", book.series_index)
                end
            end
        end
        
        -- Method 1: Use publisher as series if enabled (only if no standard series found)
        if book.series == "" and use_publisher_as_series and publisher ~= "" then
            local series_name, series_num = publisher:match(Constants.SERIES_PATTERNS.PUBLISHER_WITH_NUMBER)
            if series_name and series_num then
                book.series = Utils.trim(series_name)
                book.series_index = series_num
                logger.dbg("OPDS: Extracted series from publisher:", book.series, "#", book.series_index)
            else
                book.series = Utils.trim(publisher)
                logger.dbg("OPDS: Using publisher as series:", book.series)
            end
        end
        
        -- Method 2: Extract series from summary (lowest priority fallback)
        if book.series == "" then
            local series_match = raw_summary:match(Constants.SERIES_PATTERNS.SUMMARY_SERIES)
            if series_match then
                local series_name, series_num = series_match:match(Constants.SERIES_PATTERNS.SERIES_WITH_NUMBER)
                if series_name and series_num then
                    book.series = Utils.trim(series_name)
                    book.series_index = series_num
                    logger.dbg("OPDS: Extracted series from summary:", book.series, "#", book.series_index)
                else
                    book.series = Utils.trim(series_match)
                    logger.dbg("OPDS: Extracted series from summary (no number):", book.series)
                end
            end
        end

        -- Clean summary
        book.summary = Utils.strip_html(raw_summary)

        book.id = entry:match('<id>(.-)</id>') or ""

        -- Extract updated timestamp
        book.updated = entry:match('<updated>(.-)</updated>') or ""

        -- Extract download link
        local download_link = entry:match('<link href="([^"]+)" rel="http://opds%-spec%.org/acquisition"')
        if download_link then
            -- Resolve relative URLs against base_url
            book.download_url = Utils.resolve_url(self.base_url, download_link)
            book.media_type = "application/epub+zip"
        end
        
        -- Extract cover image URL - try multiple patterns for better coverage
        local cover_link = entry:match('<link href="([^"]+)" rel="http://opds%-spec%.org/image"')
        if not cover_link then
            -- Try with rel and type in different order
            cover_link = entry:match('<link rel="http://opds%-spec%.org/image"[^>]*href="([^"]+)"')
        end
        if not cover_link then
            -- Try thumbnail pattern
            cover_link = entry:match('<link href="([^"]+)" rel="http://opds%-spec%.org/image/thumbnail"')
        end
        if not cover_link then
            cover_link = entry:match('<link rel="http://opds%-spec%.org/image/thumbnail"[^>]*href="([^"]+)"')
        end
        if not cover_link then
            -- Try alternative cover link patterns with image type
            cover_link = entry:match('<link href="([^"]+)" type="image/[^"]*"[^>]*rel="[^"]*cover[^"]*"')
        end
        if not cover_link then
            -- Try without rel restriction, just image type
            cover_link = entry:match('<link href="([^"]+)" type="image/jpeg"')
            if not cover_link then
                cover_link = entry:match('<link href="([^"]+)" type="image/png"')
            end
        end
        if not cover_link then
            -- Try generic image link without specific type - more flexible pattern
            cover_link = entry:match('<link[^>]+type="image/[^"]*"[^>]+href="([^"]+)"')
            if not cover_link then
                -- Try reverse attribute order
                cover_link = entry:match('<link[^>]+href="([^"]+)"[^>]+type="image/[^"]*"')
            end
        end
        
        if cover_link then
            -- Resolve relative URLs against base_url
            book.cover_url = Utils.resolve_url(self.base_url, cover_link)
            logger.info("OPDS: Extracted cover URL for", book.title, ":", book.cover_url)
        else
            logger.warn("OPDS: No cover URL found for:", book.title)
            -- Log all link elements for debugging
            local link_count = 0
            for link in entry:gmatch('<link[^>]*>') do
                link_count = link_count + 1
                if link_count <= 3 then -- Only log first 3 to avoid spam
                    logger.dbg("OPDS: Available link:", link)
                end
            end
        end

        if book.download_url then
            table.insert(entries, book)
        else
            logger.warn("OPDS: Skipping entry without download URL:", book.title)
        end
    end

    logger.info("OPDS: Parsed", #entries, "books from", entry_count, "entries")
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

    -- Convert set to sorted array
    local authors = {}
    for name, _ in pairs(author_set) do
        table.insert(authors, { name = name })
    end
    
    table.sort(authors, function(a, b) return a.name < b.name end)
    
    logger.info("OPDS: Found", #authors, "unique authors")
    return authors
end

-- Sort books by series and title
function OPDSClient:sortBooks(books)
    table.sort(books, function(a, b)
        local a_has_series = a.series and type(a.series) == "string" and a.series ~= ""
        local b_has_series = b.series and type(b.series) == "string" and b.series ~= ""
        
        if a_has_series and b_has_series then
            if a.series ~= b.series then
                return a.series < b.series
            end
            
            -- Safe series index comparison
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
