local logger = require("logger")
local json = require("json")
local https = require("ssl.https")
local ltn12 = require("ltn12")
local Constants = require("constants")
local Utils = require("utils")
local CacheManager = require("cache_manager")

local HardcoverClient = {
    api_token = "",
}

function HardcoverClient:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

function HardcoverClient:setToken(token)
    self.api_token = token
end

function HardcoverClient:isConfigured()
    return self.api_token and self.api_token ~= ""
end

function HardcoverClient:graphqlRequest(query_body, timeout)
    if not self:isConfigured() then
        return false, "Hardcover not configured"
    end
    
    timeout = timeout or Constants.API_TIMEOUT
    
    local body = json.encode(query_body)
    local response_body = {}
    
    logger.dbg("Hardcover: Sending GraphQL request, timeout:", timeout)
    
    -- Create request with timeout handling
    local request_start = os.time()
    
    local res, code, response_headers = https.request{
        url = Constants.HARDCOVER_API_URL,
        method = "POST",
        headers = {
            ["Content-Type"] = "application/json",
            ["Authorization"] = self.api_token,
            ["Content-Length"] = tostring(#body)
        },
        source = ltn12.source.string(body),
        sink = ltn12.sink.table(response_body),
    }
    
    local request_duration = os.time() - request_start
    
    -- Check for timeout
    if request_duration >= timeout then
        logger.warn("Hardcover: Request timed out after", request_duration, "seconds")
        return false, "Request timed out"
    end
    
    if not res or code ~= 200 then
        logger.err("Hardcover: Request failed with code:", code)
        return false, "HTTP " .. tostring(code or "error")
    end
    
    local response_text = table.concat(response_body)
    local success, data = pcall(json.decode, response_text)
    
    if not success then
        logger.err("Hardcover: JSON parse error:", data)
        return false, "Failed to parse response"
    end
    
    if data.errors then
        logger.err("Hardcover: GraphQL errors:", json.encode(data.errors))
        local error_msg = data.errors[1] and data.errors[1].message or "Unknown GraphQL error"
        return false, error_msg
    end
    
    return true, data
end

function HardcoverClient:searchAuthor(author_name)
    local query = {
        query = string.format([[
            query BooksbyAuthor {
                search(query: "%s", query_type: "Author") {
                    results
                }
            }
        ]], author_name:gsub('"', '\\"'))
    }
    
    logger.info("Hardcover: Searching for author:", author_name)
    
    local ok, data = self:graphqlRequest(query)
    if not ok then
        return false, data
    end
    
    if not data.data or not data.data.search or not data.data.search.results then
        return false, "Invalid response structure"
    end
    
    return true, data.data.search.results
end

function HardcoverClient:getAuthorBooks(author_id, page_limit)
    page_limit = page_limit or 0 -- 0 means all
    
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
                            id
                        }
                        details
                    }
                    release_date
                    description
                    rating
                    ratings_count
                    contributions {
                        author {
                            name
                        }
                    }
                }
            }
        ]], author_id)
    }
    
    logger.info("Hardcover: Loading books for author ID:", author_id)
    
    local ok, data = self:graphqlRequest(query)
    if not ok then
        return false, data
    end
    
    if not data.data or not data.data.books then
        return false, "Invalid response structure"
    end
    
    return true, data.data.books
end

function HardcoverClient:getSeriesData(author_name, use_cache)
    if use_cache == nil then use_cache = true end
    
    -- Check cache first
    if use_cache then
        local cache_key = Utils.generate_cache_key("hc_series", author_name)
        local cached_data, age = CacheManager:get(cache_key)
        if cached_data then
            logger.info("Hardcover: Cache hit for series data, age:", age, "seconds")
            return true, cached_data
        end
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
                            name
                        }
                        details
                    }
                }
            }
        ]], author_name:gsub('"', '\\"'))
    }
    
    logger.info("Hardcover: Fetching series data for author:", author_name)
    
    local ok, data = self:graphqlRequest(query)
    if not ok then
        logger.err("Hardcover: Failed to fetch series data:", data)
        return false, data
    end
    
    if not data.data or not data.data.books then
        return false, "Invalid response structure"
    end
    
    -- Build lookup table
    local series_lookup = {}
    for _, book in ipairs(data.data.books) do
        local normalized_title = Utils.normalize_title(book.title)
        if book.book_series and #book.book_series > 0 then
            local series_info = book.book_series[1]
            if series_info.series then
                series_lookup[normalized_title] = {
                    name = Utils.safe_string(series_info.series.name, "Unknown Series"),
                    details = Utils.safe_string(series_info.details, "")
                }
            end
        end
    end
    
    logger.info("Hardcover: Found series info for", Utils.table_count(series_lookup), "books")
    
    -- Cache the result
    if use_cache then
        local cache_key = Utils.generate_cache_key("hc_series", author_name)
        CacheManager:set(cache_key, series_lookup)
    end
    
    return true, series_lookup
end

function HardcoverClient:getAuthorSeries(author_id)
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
    
    logger.info("Hardcover: Fetching series for author ID:", author_id)
    
    local ok, data = self:graphqlRequest(query)
    if not ok then
        return false, data
    end
    
    if not data.data or not data.data.series then
        return false, "Invalid response structure"
    end
    
    -- Sort alphabetically
    local series_list = data.data.series
    table.sort(series_list, function(a, b) return a.name < b.name end)
    
    return true, series_list
end

function HardcoverClient:getSeriesBooks(series_id)
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
    
    logger.info("Hardcover: Fetching books for series ID:", series_id)
    
    local ok, data = self:graphqlRequest(query)
    if not ok then
        return false, data
    end
    
    if not data.data or not data.data.series_by_pk then
        return false, "Invalid response structure"
    end
    
    return true, data.data.series_by_pk
end

-- New: Top Rated Books
function HardcoverClient:getTopRatedBooks(limit)
    limit = limit or 100
    local query = {
        query = string.format([[
            query TopRatedBooks {
              books(
                where: { ratings_count: { _gt: 500} }
                limit: %d
                order_by: {rating: desc}
              ) {
                id
                title
                description
                release_date
                rating
                ratings_count
                contributions {
                    author {
                        name
                    }
                }
              }
            }
        ]], limit)
    }
    
    logger.info("Hardcover: Fetching top rated books")
    
    local ok, data = self:graphqlRequest(query)
    if not ok then return false, data end
    
    if not data.data or not data.data.books then
        return false, "Invalid response structure"
    end
    
    return true, data.data.books
end

-- New: Recently Released Top Rated
function HardcoverClient:getTopRatedRecent(limit)
    limit = limit or 100
    local query = {
        query = string.format([[
            query TopRatedRecent {
              books(
                where: { ratings_count: { _gt: 2}, rating: {_gt: 3}, release_date: {_is_null: false}}
                limit: %d
                order_by: {release_date: desc}
              ) {
                id
                title
                description
                release_date
                rating
                ratings_count
                contributions {
                    author {
                        name
                    }
                }
              }
            }
        ]], limit)
    }
    
    logger.info("Hardcover: Fetching top rated recent books")
    
    local ok, data = self:graphqlRequest(query)
    if not ok then return false, data end
    
    if not data.data or not data.data.books then
        return false, "Invalid response structure"
    end
    
    return true, data.data.books
end

return HardcoverClient
