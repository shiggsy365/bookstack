local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")
local Utils = require("utils")
local Archiver = require("ffi/archiver")

local PlaceholderGenerator = {}

-- Maximum cover image size to embed in EPUB (100KB)
local MAX_COVER_SIZE = 100 * 1024

-- EPUB internal paths
local CONTENT_OPF_PATH = "OEBPS/content.opf"

-- Download cover image data for embedding in EPUB
local function download_cover_image(cover_url)
    if not cover_url or cover_url == "" then 
        return nil, nil, nil 
    end
    
    local ok, https = pcall(require, "ssl.https")
    if not ok then
        logger.warn("PlaceholderGenerator: ssl.https not available")
        return nil, nil, nil
    end
    
    local ltn12 = require("ltn12")
    local response_body = {}
    
    local res, code, headers = https.request{
        url = cover_url,
        method = "GET",
        sink = ltn12.sink.table(response_body),
        headers = { ["Cache-Control"] = "no-cache" }
    }
    
    if not res or code ~= 200 then
        logger.warn("PlaceholderGenerator: Failed to download cover:", code)
        return nil, nil, nil
    end
    
    local data = table.concat(response_body)
    local size = #data
    
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
    
    logger.info("PlaceholderGenerator: Downloaded cover:", size, "bytes, type:", media_type)
    
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

    -- Ensure output path ends with .epub
    output_path = output_path:gsub("%.html$", ".epub")
    
    -- Download cover image if available
    local cover_url = Utils.safe_string(book_info.cover_url, "")
    local cover_data, cover_ext, cover_media_type = download_cover_image(cover_url)
    local has_cover = (cover_data ~= nil)
    local cover_filename = "cover." .. (cover_ext or "jpg")
    
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
    <dc:language>en</dc:language>
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
        Utils.html_escape(book_id),
        Utils.html_escape(Utils.safe_string(book_info.download_url, "")),
        series_meta,
        cover_manifest,
        cover_guide
    )
    
    -- Build cover.xhtml (completely blank - user should never see this)
    local cover_xhtml = [[<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml">
<head>
  <title>Auto-Download Placeholder</title>
</head>
<body>
</body>
</html>]]
    
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
        logger.info("PlaceholderGenerator: Adding cover image, size:", #cover_data, "bytes")
        if not writer:addFileFromMemory("OEBPS/" .. cover_filename, cover_data) then
            logger.warn("PlaceholderGenerator: Failed to write cover image")
            -- Continue anyway, cover is optional
        else
            logger.info("PlaceholderGenerator: Successfully added cover image:", cover_filename)
        end
    else
        logger.warn("PlaceholderGenerator: No cover image available for:", book_info.title)
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
    if not filepath:match("%.epub$") then
        return false
    end

    local attr = lfs.attributes(filepath)
    if not attr or not attr.size then
        return false
    end

    -- Placeholders are small EPUB files
    -- A minimal EPUB with embedded cover should be < 200KB
    if attr.size < 200000 then
        -- Check if it's a valid EPUB by reading the content.opf for our marker
        -- Use Archiver.Reader API from ffi/archiver
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
            logger.warn("PlaceholderGenerator: Failed to open EPUB file:", filepath)
            return false
        end
        
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
            logger.warn("PlaceholderGenerator: Failed to extract content.opf from:", filepath)
            return false
        end
        
        -- Check for our placeholder marker (set in createMinimalEPUB)
        if content:match("opdsbrowser:placeholder") then
            return true
        end
    end

    return false
end

return PlaceholderGenerator
