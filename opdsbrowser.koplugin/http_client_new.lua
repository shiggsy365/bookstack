local socket = require("socket")
local http = require("socket.http")
local https = require("ssl.https")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local logger = require("logger")
local url = require("socket.url")
local Constants = require("constants")
local Utils = require("utils")

local HttpClient = {}

-- Request with retry logic and exponential backoff
function HttpClient:request_with_retry(url_str, method, body, content_type, username, password, max_retries)
    max_retries = max_retries or Constants.MAX_RETRIES
    local delay = Constants.RETRY_DELAY
    
    for attempt = 1, max_retries do
        local ok, response = self:request(url_str, method, body, content_type, username, password)
        
        if ok then
            return true, response
        end
        
        -- Check if error is retryable (network errors, 5xx errors)
        local is_retryable = response and (
            response:match("timeout") or 
            response:match("connection") or
            response:match("50%d") -- 500-599 status codes
        )
        
        if attempt < max_retries and is_retryable then
            logger.warn("HttpClient: Attempt", attempt, "failed, retrying in", delay, "seconds")
            socket.sleep(delay)
            delay = delay * Constants.BACKOFF_MULTIPLIER
        else
            return false, response
        end
    end
    
    return false, "Max retries exceeded"
end

-- Original request function with timeout
function HttpClient:request(url_str, method, body, content_type, username, password, timeout)
    method = method or "GET"
    timeout = timeout or Constants.TOTAL_TIMEOUT
    
    logger.info("HttpClient: Requesting URL:", url_str, "method:", method)

    local sink = {}
    socketutil:set_timeout(Constants.BLOCK_TIMEOUT, timeout)

    local parsed = url.parse(url_str)
    local host = parsed and parsed.host or nil
    local req_id = Utils.create_request_id()

    local request_params = {
        url = url_str,
        method = method,
        headers = {
            ["Accept-Encoding"] = "identity",
            ["User-Agent"] = Constants.USER_AGENT,
            ["Connection"] = "close",
            ["Cache-Control"] = "no-cache",
            ["Pragma"] = "no-cache",
            ["Accept"] = "application/epub+zip, application/octet-stream, */*",
            ["X-Request-ID"] = req_id,
        },
        sink = ltn12.sink.table(sink),
    }

    if host then
        request_params.headers["Host"] = host
    end

    if body then
        request_params.source = ltn12.source.string(body)
        if content_type then
            request_params.headers["Content-Type"] = content_type
            request_params.headers["Content-Length"] = tostring(#body)
        end
    end

    if username and username ~= "" then
        request_params.user = username
        request_params.password = password or ""
    end

    local requester = http
    if parsed and parsed.scheme == "https" then
        requester = https
        request_params.verify = "none"
        request_params.protocol = "tlsv1_2"
    end

    local code, headers, status = socket.skip(1, requester.request(request_params))
    socketutil:reset_timeout()

    local body_str = table.concat(sink)

    logger.info("HttpClient: Response code:", code, "status:", status or "nil", "req_id:", req_id)
    if headers then
        if headers["content-type"] then
            logger.dbg("HttpClient: Content-Type:", headers["content-type"])
        end
        if headers["content-length"] then
            logger.dbg("HttpClient: Content-Length:", headers["content-length"])
        end
        if headers["x-deny-reason"] then
            logger.warn("HttpClient: Network denied:", headers["x-deny-reason"])
            return false, "Network access denied: " .. headers["x-deny-reason"]
        end
    end

    if code == 200 then
        return true, body_str
    elseif code == nil then
        logger.warn("HttpClient: Request failed (no code):", headers)
        return false, tostring(headers)
    else
        logger.warn("HttpClient: Request failed:", status or code)
        return false, status or tostring(code)
    end
end

-- Stream to file with progress callback
function HttpClient:request_to_file(url_str, file_handle, username, password, progress_callback)
    logger.info("HttpClient: Streaming URL to file:", url_str)
    socketutil:set_timeout(Constants.BLOCK_TIMEOUT, Constants.TOTAL_TIMEOUT)

    local parsed = url.parse(url_str)
    local host = parsed and parsed.host or nil
    local req_id = Utils.create_request_id()
    
    local bytes_received = 0
    local total_size = nil

    -- Custom sink that writes chunks and reports progress
    local function file_sink(chunk)
        if chunk then
            local ok, err = pcall(function() file_handle:write(chunk) end)
            if not ok then
                logger.err("HttpClient: Error writing chunk to file:", tostring(err))
                return nil, err
            end
            
            bytes_received = bytes_received + #chunk
            
            -- Call progress callback if provided
            if progress_callback then
                local progress = total_size and (bytes_received / total_size * 100) or nil
                progress_callback(bytes_received, total_size, progress)
            end
            
            return true
        end
        return true
    end

    local request_params = {
        url = url_str,
        method = "GET",
        headers = {
            ["User-Agent"] = Constants.USER_AGENT,
            ["Connection"] = "close",
            ["Cache-Control"] = "no-cache",
            ["Pragma"] = "no-cache",
            ["Accept"] = "application/epub+zip, application/octet-stream, */*",
            ["X-Request-ID"] = req_id,
        },
        sink = file_sink,
        user = username,
        password = password,
    }

    if host then
        request_params.headers["Host"] = host
    end

    local requester = http
    if parsed and parsed.scheme == "https" then
        requester = https
        request_params.verify = "none"
        request_params.protocol = "tlsv1_2"
    end

    local code, headers, status = socket.skip(1, requester.request(request_params))
    socketutil:reset_timeout()
    
    -- Get total size from headers
    if headers and headers["content-length"] then
        total_size = tonumber(headers["content-length"])
    end

    logger.info("HttpClient: Stream response code:", code, "status:", status or "nil", "req_id:", req_id)
    if headers then
        if headers["content-type"] then
            logger.dbg("HttpClient: Stream Content-Type:", headers["content-type"])
        end
        if headers["content-length"] then
            logger.dbg("HttpClient: Stream Content-Length:", headers["content-length"])
        end
    end

    if code == 200 then
        return true, bytes_received
    elseif code == nil then
        logger.warn("HttpClient: Stream request failed (no code):", headers)
        return false, tostring(headers)
    else
        logger.warn("HttpClient: Stream request failed:", status or code)
        return false, status or tostring(code)
    end
end

-- Make a request with timeout
function HttpClient:request_with_timeout(url_str, timeout, method, body, content_type, username, password)
    return self:request(url_str, method, body, content_type, username, password, timeout)
end

return HttpClient
