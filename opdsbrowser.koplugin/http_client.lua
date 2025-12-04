local socket = require("socket")
local http = require("socket.http")
local https = require("ssl.https")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local logger = require("logger")
local url = require("socket.url")

local HttpClient = {}

local BLOCK_TIMEOUT = 5
local TOTAL_TIMEOUT = 30
local USER_AGENT = "KOReader-OPDS-Browser"

-- signature: request(url_str, method, body, content_type, username, password)
function HttpClient:request(url_str, method, body, content_type, username, password)
    method = method or "GET"
    logger.info("HttpClient: Requesting URL:", url_str, "method:", method)

    local sink = {}
    socketutil:set_timeout(BLOCK_TIMEOUT, TOTAL_TIMEOUT)

    local parsed = url.parse(url_str)
    local host = parsed and parsed.host or nil
    local req_id = tostring(os.time()) .. "-" .. tostring(math.random(1000000))

    local request_params = {
        url = url_str,
        method = method,
        headers = {
            ["Accept-Encoding"] = "identity",
            ["User-Agent"] = USER_AGENT,
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
    if headers and headers["content-type"] then
        logger.dbg("HttpClient: Content-Type:", headers["content-type"])
    end
    if headers and headers["content-length"] then
        logger.dbg("HttpClient: Content-Length:", headers["content-length"])
    end

    if code == 200 then
        return true, body_str
    elseif code == nil then
        logger.warn("HttpClient: Request failed (no code):", headers)
        return false, tostring(headers)
    else
        logger.warn("HttpClient: Request failed:", status or code)
        return false, status or code
    end
end

-- signature: request_to_file(url_str, file_handle, username, password)
-- Streams response into the provided file handle using a custom sink.
-- The sink will NOT close the file handle; caller must flush/close it.
function HttpClient:request_to_file(url_str, file_handle, username, password)
    logger.info("HttpClient: Streaming URL to file:", url_str)
    socketutil:set_timeout(BLOCK_TIMEOUT, TOTAL_TIMEOUT)

    local parsed = url.parse(url_str)
    local host = parsed and parsed.host or nil
    local req_id = tostring(os.time()) .. "-" .. tostring(math.random(1000000))

    -- custom sink that writes chunks to the provided Lua file handle
    local function file_sink(chunk)
        if chunk then
            local ok, err = pcall(function() file_handle:write(chunk) end)
            if not ok then
                logger.err("HttpClient: Error writing chunk to file:", tostring(err))
                return nil, err
            end
            return true
        end
        -- chunk == nil indicates end of stream
        return true
    end

    local request_params = {
        url = url_str,
        method = "GET",
        headers = {
            ["User-Agent"] = USER_AGENT,
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

    logger.info("HttpClient: Stream response code:", code, "status:", status or "nil", "req_id:", req_id)
    if headers and headers["content-type"] then
        logger.dbg("HttpClient: Stream Content-Type:", headers["content-type"])
    end
    if headers and headers["content-length"] then
        logger.dbg("HttpClient: Stream Content-Length:", headers["content-length"])
    end

    if code == 200 then
        return true, nil
    elseif code == nil then
        logger.warn("HttpClient: Stream request failed (no code):", headers)
        return false, tostring(headers)
    else
        logger.warn("HttpClient: Stream request failed:", status or code)
        return false, status or code
    end
end

return HttpClient
