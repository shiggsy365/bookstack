local logger = require("logger")
local json = require("json")
local url = require("socket.url")
local HttpClient = require("http_client_new")
local Constants = require("constants")
local Utils = require("utils")

local EphemeraClient = {
    base_url = "",
}

function EphemeraClient:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

function EphemeraClient:setBaseURL(base_url)
    self.base_url = base_url
end

function EphemeraClient:isConfigured()
    return self.base_url and self.base_url ~= ""
end

function EphemeraClient:search(search_string)
    if not self:isConfigured() then
        return false, "Ephemera not configured"
    end
    
    local query = url.escape(search_string)
    local full_url = self.base_url .. "/api/search?q=" .. query
    
    logger.info("Ephemera: Searching for:", search_string)
    
    local ok, response_or_err = HttpClient:request_with_retry(full_url, "GET")
    if not ok then
        logger.err("Ephemera: Search failed:", response_or_err)
        return false, response_or_err
    end
    
    local success, data = pcall(json.decode, response_or_err)
    if not success or not data or not data.results then
        logger.err("Ephemera: Failed to parse search results")
        return false, "Failed to parse search results"
    end
    
    return true, data.results
end

function EphemeraClient:filterResults(results, options)
    options = options or {}
    local english_only = options.english_only or false
    local epub_only = options.epub_only ~= false -- default true
    
    local filtered = {}
    
    for _, book in ipairs(results) do
        -- Check format
        if epub_only then
            local is_epub = false
            if book.format and type(book.format) == "string" then
                is_epub = book.format:upper() == "EPUB"
            elseif book.extension and type(book.extension) == "string" then
                is_epub = book.extension:lower() == "epub"
            elseif book.type and type(book.type) == "string" then
                is_epub = book.type:lower() == "epub"
            end
            
            if not is_epub then
                goto continue
            end
        end
        
        -- Check language
        if english_only then
            local is_english = false
            if book.language and type(book.language) == "string" then
                local lang = book.language:lower()
                is_english = Constants.ENGLISH_LANGUAGE_CODES[lang] == true
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
    
    logger.info("Ephemera: Filtered", #filtered, "results from", #results)
    return filtered
end

function EphemeraClient:requestDownload(book)
    if not self:isConfigured() then
        return false, "Ephemera not configured"
    end
    
    if not book.md5 or book.md5 == "" then
        return false, "Book MD5 not available"
    end
    
    local full_url = self.base_url .. "/api/download/" .. book.md5
    logger.info("Ephemera: Requesting download:", full_url)
    
    local body = json.encode({ title = book.title })
    local ok, response_or_err = HttpClient:request(full_url, "POST", body, "application/json")
    
    if not ok then
        logger.err("Ephemera: Download request failed:", response_or_err)
        return false, response_or_err
    end
    
    local success, result = pcall(json.decode, response_or_err)
    if not success or not result then
        -- Even if JSON parse fails, consider it queued
        logger.warn("Ephemera: Couldn't parse response, assuming success")
        return true, { status = "queued" }
    end
    
    return true, result
end

function EphemeraClient:getQueue()
    if not self:isConfigured() then
        return false, "Ephemera not configured"
    end
    
    local full_url = self.base_url .. "/api/queue"
    logger.info("Ephemera: Fetching queue")
    
    local ok, response_or_err = HttpClient:request_with_retry(full_url, "GET")
    if not ok then
        logger.err("Ephemera: Failed to fetch queue:", response_or_err)
        return false, response_or_err
    end
    
    local success, queue = pcall(json.decode, response_or_err)
    if not success or not queue then
        logger.err("Ephemera: Failed to parse queue data")
        return false, "Failed to parse queue data"
    end
    
    return true, queue
end

-- Format author from array
function EphemeraClient:formatAuthor(authors)
    if not authors or type(authors) ~= "table" or #authors == 0 then
        return "Unknown Author"
    end
    
    return table.concat(authors, " ")
end

-- Check if queue has incomplete items
function EphemeraClient:hasIncompleteItems(queue)
    local categories = {"downloading", "queued", "delayed"}
    
    for _, category in ipairs(categories) do
        if queue[category] and next(queue[category]) ~= nil then
            return true
        end
    end
    
    return false
end

return EphemeraClient
