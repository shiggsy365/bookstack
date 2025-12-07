local logger = require("logger")

local Utils = {}

-- Safe type conversion with defaults
function Utils.safe_string(val, default)
    return (val and type(val) == "string") and val or (default or "")
end

function Utils.safe_number(val, default)
    if type(val) == "number" then
        return val
    elseif type(val) == "string" then
        return tonumber(val) or (default or 0)
    else
        return default or 0
    end
end

function Utils.safe_boolean(val, default)
    if type(val) == "boolean" then
        return val
    elseif type(val) == "string" then
        return val:upper() == "YES" or val:upper() == "TRUE"
    else
        return default or false
    end
end

-- Table utilities
function Utils.table_count(t)
    if not t then return 0 end
    local count = 0
    for _ in pairs(t) do 
        count = count + 1 
    end
    return count
end

function Utils.table_slice(tbl, first, last)
    local sliced = {}
    for i = first or 1, last or #tbl do
        sliced[#sliced + 1] = tbl[i]
    end
    return sliced
end

-- String utilities
function Utils.trim(s)
    if not s then return "" end
    return s:gsub("^%s+", ""):gsub("%s+$", "")
end

function Utils.normalize_title(title)
    if not title then return "" end
    return title:lower():gsub("[^%w]", "")
end

-- HTML utilities
function Utils.html_unescape(s)
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

function Utils.html_escape(s)
    if not s then return "" end
    s = tostring(s)
    -- Escape in correct order (& must be first)
    s = s:gsub("&", "&amp;")
    s = s:gsub("<", "&lt;")
    s = s:gsub(">", "&gt;")
    s = s:gsub('"', "&quot;")
    s = s:gsub("'", "&#39;")
    return s
end

function Utils.strip_html(s)
    if not s then return "" end
    s = tostring(s)
    -- Unescape first so encoded tags become visible
    s = Utils.html_unescape(s)
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

-- URL validation
function Utils.validate_url(url_str)
    if not url_str or url_str == "" then
        return false, "URL is empty"
    end
    
    -- Must start with http:// or https://
    if not url_str:match("^https?://") then
        return false, "URL must start with http:// or https://"
    end
    
    -- Basic structure check
    if not url_str:match("^https?://[%w%.%-]+") then
        return false, "Invalid URL format"
    end
    
    return true, nil
end

-- Sanitize input to prevent injection
function Utils.sanitize_input(input)
    if not input then return "" end
    -- Remove null bytes and control characters
    input = input:gsub("%z", ""):gsub("[\001-\031]", "")
    return input
end

-- Debounce function creator
function Utils.debounce(func, delay)
    local timer = nil
    local UIManager = require("ui/uimanager")
    
    return function(...)
        local args = {...}
        
        if timer then
            UIManager:unschedule(timer)
        end
        
        timer = function()
            func(table.unpack(args))
            timer = nil
        end
        
        UIManager:scheduleIn(delay, timer)
    end
end

-- Format file size
function Utils.format_file_size(bytes)
    if not bytes or bytes < 1024 then
        return tostring(bytes or 0) .. " B"
    elseif bytes < 1024 * 1024 then
        return string.format("%.1f KB", bytes / 1024)
    elseif bytes < 1024 * 1024 * 1024 then
        return string.format("%.1f MB", bytes / (1024 * 1024))
    else
        return string.format("%.1f GB", bytes / (1024 * 1024 * 1024))
    end
end

-- Deep copy table
function Utils.deep_copy(orig)
    local orig_type = type(orig)
    local copy
    if orig_type == 'table' then
        copy = {}
        for orig_key, orig_value in next, orig, nil do
            copy[Utils.deep_copy(orig_key)] = Utils.deep_copy(orig_value)
        end
        setmetatable(copy, Utils.deep_copy(getmetatable(orig)))
    else
        copy = orig
    end
    return copy
end

-- Create a unique request ID
function Utils.create_request_id()
    return tostring(os.time()) .. "-" .. tostring(math.random(1000000))
end

-- Parse ISO date
function Utils.parse_iso_date(date_str)
    if not date_str or type(date_str) ~= "string" then
        return nil
    end
    
    -- Try to extract year at minimum
    local year = date_str:match("^(%d%d%d%d)")
    return year
end

-- Format rating
function Utils.format_rating(rating, count)
    if not rating or type(rating) ~= "number" or rating <= 0 then
        return ""
    end
    
    local rating_text = string.format("%.2f", rating)
    if count and type(count) == "number" and count > 0 then
        rating_text = rating_text .. " (" .. tostring(count) .. " ratings)"
    end
    
    return rating_text
end

-- Check if a value is in a table
function Utils.contains(table, value)
    for _, v in pairs(table) do
        if v == value then
            return true
        end
    end
    return false
end

-- Generate a cache key
function Utils.generate_cache_key(prefix, value)
    return prefix .. ":" .. Utils.normalize_title(value)
end

return Utils
