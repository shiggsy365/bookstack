local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")
local Utils = require("utils")
local Archiver = require("ffi/archiver")
local Constants = require("constants")

local PlaceholderGenerator = {}

-- Maximum cover image size to embed in EPUB (100KB)
local MAX_COVER_SIZE = 100 * 1024

-- EPUB internal paths
local CONTENT_OPF_PATH = "OEBPS/content.opf"

-- Download cover image data for embedding in EPUB
local function download_cover_image(cover_url)
    logger.info("PlaceholderGenerator: download_cover_image called with URL:", cover_url or "nil")
    
    if not cover_url or cover_url == "" then 
        logger.warn("PlaceholderGenerator: No cover URL provided")
        return nil, nil, nil 
    end
    
    local ok, https = pcall(require, "ssl.https")
    if not ok then
        logger.warn("PlaceholderGenerator: ssl.https not available")
        return nil, nil, nil
    end
    
    logger.info("PlaceholderGenerator: Attempting to download cover from:", cover_url)
    
    local ltn12 = require("ltn12")
    local socket = require("socket")
    local response_body = {}
    
    -- Add timeout and proper error handling
    local res, code, headers, status = https.request{
        url = cover_url,
        method = "GET",
        sink = ltn12.sink.table(response_body),
        headers = { 
            ["Cache-Control"] = "no-cache",
            ["User-Agent"] = "KOReader/BookStack"
        },
        -- Add timeout for cover downloads (5 seconds)
        create = function()
            local sock = socket.tcp()
            sock:settimeout(5)
            return sock
        end
    }
    
    logger.info("PlaceholderGenerator: Cover download response code:", code, "status:", status)
    
    if not res or (code ~= 200 and code ~= 304) then
        logger.warn("PlaceholderGenerator: Failed to download cover, code:", code, "status:", status)
        return nil, nil, nil
    end
    
    local data = table.concat(response_body)
    local size = #data
    
    logger.info("PlaceholderGenerator: Cover download size:", size, "bytes")
    
    -- Skip empty or very small responses
    if size < Constants.MIN_COVER_SIZE then
        logger.warn("PlaceholderGenerator: Cover data too small:", size, "bytes, likely error")
        return nil, nil, nil
    end
    
    -- Only use if size <= MAX_COVER_SIZE
    if size > MAX_COVER_SIZE then
        logger.info("PlaceholderGenerator: Cover too large:", size, "bytes, skipping")
        return nil, nil, nil
    end
    
    -- Determine file extension and media type from content-type
    local content_type = (headers and (headers["content-type"] or headers["Content-Type"])) or "image/jpeg"
    local ext = "jpg"
    local media_type = "image/jpeg"
    
    if content_type:match("png") then
        ext = "png"
        media_type = "image/png"
    elseif content_type:match("gif") then
        ext = "gif"
        media_type = "image/gif"
    elseif content_type:match("webp") then
        ext = "webp"
        media_type = "image/webp"
    end
    
    logger.info("PlaceholderGenerator: Cover downloaded successfully:", size, "bytes, type:", media_type)
    
    return data, ext, media_type
end

-- Create a minimal EPUB placeholder file with embedded cover
function PlaceholderGenerator:createMinimalEPUB(book_info, output_path)
    logger.info("PlaceholderGenerator: Creating EPUB placeholder for:", book_info.title)

    local book_title = Utils.safe_string(book_info.title, "Unknown Title")
    local book_author = Utils.safe_string(book_info.author, "Unknown Author")
    local book_id = Utils.safe_string(book_info.id, "")
    local series = Utils.safe_string(book_info.series, "")
    local series_index = Utils.safe_string(book_info.series_index, "")
    local description = Utils.safe_string(book_info.summary, "")

    -- Ensure output path ends with .epub
    output_path = output_path:gsub("%.html$", ".epub")
    
    -- Download cover image if available
    local cover_url = Utils.safe_string(book_info.cover_url, "")
    local cover_data, cover_ext, cover_media_type = download_cover_image(cover_url)
    local has_cover = (cover_data ~= nil)
    local cover_filename = "cover." .. (cover_ext or "jpg")
    
    logger.info("PlaceholderGenerator: Cover URL:", cover_url)
    logger.info("PlaceholderGenerator: Cover data:", cover_data ~= nil, "ext:", cover_ext, "type:", cover_media_type)
    logger.info("PlaceholderGenerator: has_cover:", has_cover)
    
    -- Build container.xml
    local container_xml = [[<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>]]
    
    -- Build metadata for content.opf
    local series_meta = ""
    if series ~= "" then
        series_meta = string.format([[
    <meta property="belongs-to-collection" id="series">%s</meta>
    <meta refines="#series" property="collection-type">series</meta>]], 
            Utils.html_escape(series))
        if series_index ~= "" then
            series_meta = series_meta .. string.format([[
    <meta refines="#series" property="group-position">%s</meta>]], 
                Utils.html_escape(series_index))
        end
    end
    
    -- Build description metadata
    local description_meta = ""
    if description ~= "" then
        description_meta = string.format([[
    <dc:description>%s</dc:description>]], Utils.html_escape(description))
    end
    
    -- Build manifest entries
    local cover_manifest = ""
    local cover_guide = ""
    if has_cover then
        cover_manifest = string.format([[
    <item id="cover-image" href="%s" media-type="%s" properties="cover-image"/>]], 
            cover_filename, cover_media_type or "image/jpeg")
        cover_guide = [[
  <reference type="cover" title="Cover" href="cover.xhtml"/>]]
    end
    
    -- Build content.opf
    local content_opf = string.format([[<?xml version="1.0" encoding="UTF-8"?>
<package version="3.0" unique-identifier="bookid" xmlns="http://www.idpf.org/2007/opf">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
    <dc:title>%s</dc:title>
    <dc:creator>%s</dc:creator>
    <dc:identifier id="bookid">%s</dc:identifier>
    <dc:language>en</dc:language>%s
    <!-- Marker to identify this as a placeholder EPUB (checked by isPlaceholder()) -->
    <meta property="opdsbrowser:placeholder">true</meta>
    <meta property="opdsbrowser:book_id">%s</meta>
    <meta property="opdsbrowser:download_url">%s</meta>%s
  </metadata>
  <manifest>
    <item id="cover" href="cover.xhtml" media-type="application/xhtml+xml"/>%s
  </manifest>
  <spine>
    <itemref idref="cover"/>
  </spine>
  <guide>%s
  </guide>
</package>]],
        Utils.html_escape(book_title),
        Utils.html_escape(book_author),
        Utils.html_escape(book_id),
        description_meta,
        Utils.html_escape(book_id),
        Utils.html_escape(Utils.safe_string(book_info.download_url, "")),
        series_meta,
        cover_manifest,
        cover_guide
    )
    
    -- Build cover.xhtml with book details
    local book_summary = Utils.html_escape(Utils.safe_string(book_info.summary, "No description available."))

    local cover_xhtml
    if has_cover then
        -- Include cover image and book details
        cover_xhtml = string.format([[<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml">
<head>
  <title>%s</title>
  <style type="text/css">
    body { margin: 20px; font-family: serif; }
    .cover { text-align: center; margin-bottom: 20px; }
    img { max-width: 100%%; max-height: 400px; }
    h1 { font-size: 1.5em; margin: 10px 0; }
    .author { font-style: italic; color: #666; margin-bottom: 20px; }
    .series { color: #0066cc; margin-bottom: 10px; }
    .description { line-height: 1.6; text-align: justify; }
    .notice { background: #ffffcc; padding: 10px; margin: 20px 0; border-left: 4px solid #ffcc00; }
  </style>
</head>
<body>
  <div class="cover">
    <img src="%s" alt="Cover"/>
  </div>
  <h1>%s</h1>
  <div class="author">by %s</div>
  %s
  <div class="notice">
    <strong>Auto-Download Placeholder</strong><br/>
    This book will automatically download when you open it.
  </div>
  <div class="description">
    %s
  </div>
</body>
</html>]],
            Utils.html_escape(book_title),
            cover_filename,
            Utils.html_escape(book_title),
            Utils.html_escape(book_author),
            series ~= "" and string.format('<div class="series">%s%s</div>',
                Utils.html_escape(series),
                series_index ~= "" and " #" .. Utils.html_escape(series_index) or ""
            ) or "",
            book_summary
        )
    else
        -- No cover, just show book details
        cover_xhtml = string.format([[<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml">
<head>
  <title>%s</title>
  <style type="text/css">
    body { margin: 20px; font-family: serif; }
    h1 { font-size: 1.5em; margin: 10px 0; }
    .author { font-style: italic; color: #666; margin-bottom: 20px; }
    .series { color: #0066cc; margin-bottom: 10px; }
    .description { line-height: 1.6; text-align: justify; }
    .notice { background: #ffffcc; padding: 10px; margin: 20px 0; border-left: 4px solid #ffcc00; }
  </style>
</head>
<body>
  <h1>%s</h1>
  <div class="author">by %s</div>
  %s
  <div class="notice">
    <strong>Auto-Download Placeholder</strong><br/>
    This book will automatically download when you open it.
  </div>
  <div class="description">
    %s
  </div>
</body>
</html>]],
            Utils.html_escape(book_title),
            Utils.html_escape(book_title),
            Utils.html_escape(book_author),
            series ~= "" and string.format('<div class="series">%s%s</div>',
                Utils.html_escape(series),
                series_index ~= "" and " #" .. Utils.html_escape(series_index) or ""
            ) or "",
            book_summary
        )
    end
    
    -- Create EPUB zip file using Archiver.Writer API
    -- IMPORTANT: mimetype MUST be first and uncompressed for EPUB spec compliance
    local writer = Archiver.Writer:new()
    if not writer then
        logger.err("PlaceholderGenerator: Failed to create archiver writer")
        return false
    end
    
    if not writer:open(output_path, "epub") then
        logger.err("PlaceholderGenerator: Failed to open archiver writer for:", output_path)
        return false
    end
    
    -- Add mimetype first (MUST be uncompressed and first in archive)
    writer:setZipCompression("store")
    local mimetype_content = "application/epub+zip"
    if not writer:addFileFromMemory("mimetype", mimetype_content) then
        logger.err("PlaceholderGenerator: Failed to write mimetype")
        writer:close()
        return false
    end
    
    -- Switch to compressed for all other files
    writer:setZipCompression("deflate")
    
    -- Add META-INF/container.xml (compressed)
    if not writer:addFileFromMemory("META-INF/container.xml", container_xml) then
        logger.err("PlaceholderGenerator: Failed to write container.xml")
        writer:close()
        return false
    end
    
    -- Add OEBPS/content.opf (compressed)
    if not writer:addFileFromMemory("OEBPS/content.opf", content_opf) then
        logger.err("PlaceholderGenerator: Failed to write content.opf")
        writer:close()
        return false
    end
    
    -- Add OEBPS/cover.xhtml (compressed)
    if not writer:addFileFromMemory("OEBPS/cover.xhtml", cover_xhtml) then
        logger.err("PlaceholderGenerator: Failed to write cover.xhtml")
        writer:close()
        return false
    end
    
    -- Add cover image if we have it (compressed, binary data)
    if has_cover then
        logger.info("PlaceholderGenerator: Adding cover to EPUB, filename:", cover_filename, "size:", #cover_data, "bytes")
        local cover_path_in_epub = "OEBPS/" .. cover_filename
        logger.info("PlaceholderGenerator: Cover path in EPUB:", cover_path_in_epub)
        
        if not writer:addFileFromMemory(cover_path_in_epub, cover_data) then
            logger.err("PlaceholderGenerator: Failed to write cover image to EPUB")
            -- Continue anyway, cover is optional
        else
            logger.info("PlaceholderGenerator: Successfully added cover image to EPUB")
        end
    else
        logger.warn("PlaceholderGenerator: No cover image to add for:", book_info.title)
        logger.warn("PlaceholderGenerator: cover_url was:", Utils.safe_string(book_info.cover_url, "empty"))
    end
    
    -- Close the archive
    writer:close()
    
    logger.info("PlaceholderGenerator: Created EPUB placeholder:", output_path)
    return true
end

-- Generate filename
function PlaceholderGenerator:generateFilename(book_info)
    local title = Utils.safe_string(book_info.title, "Unknown")
    local author = Utils.safe_string(book_info.author, "Unknown")

    -- Sanitize for filesystem
    local safe_title = title:gsub('[/:*?"<>|\\]', '_'):gsub('%s+', '_')
    local safe_author = author:gsub('[/:*?"<>|\\]', '_'):gsub('%s+', '_')

    -- Limit length
    if #safe_title > 100 then
        safe_title = safe_title:sub(1, 100)
    end

    -- Use .epub extension for placeholders
    return safe_author .. "_-_" .. safe_title .. ".epub"
end

-- Check if a file is a placeholder
function PlaceholderGenerator:isPlaceholder(filepath)
    logger.info("PlaceholderGenerator:isPlaceholder checking:", filepath)

    if not filepath:match("%.epub$") then
        logger.info("PlaceholderGenerator:isPlaceholder - not an epub file")
        return false
    end

    local attr = lfs.attributes(filepath)
    if not attr or not attr.size then
        logger.info("PlaceholderGenerator:isPlaceholder - no file attributes")
        return false
    end

    logger.info("PlaceholderGenerator:isPlaceholder - file size:", attr.size, "bytes")

    -- Check if it's a valid EPUB by reading the content.opf for our marker
    -- Use Archiver.Reader API from ffi/archiver
    -- NOTE: Removed size check - placeholders with embedded covers can exceed 200KB
    logger.info("PlaceholderGenerator:isPlaceholder - attempting to open EPUB archive")
    local ok, reader = pcall(function()
        local r = Archiver.Reader:new()
        if not r then
            return nil
        end
        if not r:open(filepath) then
            return nil
        end
        return r
    end)

    if not ok or not reader then
        logger.warn("PlaceholderGenerator: Failed to open EPUB file:", filepath, "error:", ok)
        return false
    end

    logger.info("PlaceholderGenerator:isPlaceholder - EPUB opened, extracting content.opf")

    -- Extract OEBPS/content.opf
    local ok_extract, content = pcall(function()
        return reader:extractToMemory(CONTENT_OPF_PATH)
    end)

    -- Always close the reader, log any errors
    local ok_close, close_err = pcall(function() reader:close() end)
    if not ok_close then
        logger.warn("PlaceholderGenerator: Error closing reader:", close_err)
    end

    if not ok_extract or not content then
        logger.warn("PlaceholderGenerator: Failed to extract content.opf from:", filepath, "error:", ok_extract)
        return false
    end

    logger.info("PlaceholderGenerator:isPlaceholder - content.opf extracted, checking for marker")

    -- Check for our placeholder marker (set in createMinimalEPUB)
    if content:match("opdsbrowser:placeholder") then
        logger.info("PlaceholderGenerator:isPlaceholder - FOUND placeholder marker!")
        return true
    end

    logger.info("PlaceholderGenerator:isPlaceholder - no placeholder marker found")
    return false
end

return PlaceholderGenerator
