local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")
local Utils = require("utils")
local ZipWriter = require("ffi/zipwriter")

-- Escape a string for safe use in shell commands
local function shell_escape(str)
    if not str then return "''" end
    -- Replace single quotes with '\'' (end quote, escaped quote, start quote)
    return "'" .. str:gsub("'", "'\\''") .. "'"
end

local PlaceholderGenerator = {}

-- Maximum cover image size to embed in EPUB (100KB)
local MAX_COVER_SIZE = 100 * 1024

-- EPUB internal paths
local CONTENT_OPF_PATH = "OEBPS/content.opf"

-- Helper function to create a reader for ZipWriter from string data
local function make_string_reader(data, is_text, compressed)
    local pos = 1
    local chunk_size = 8192
    local desc = {
        istext = is_text or false,
        isfile = true,
        isdir = false,
        mtime = os.time(),
        platform = 'unix',
        method = compressed and nil or ZipWriter.STORE,  -- STORE means uncompressed
        level = compressed and nil or 0,                  -- level 0 = no compression
    }
    return desc, function()
        if pos > #data then return nil end
        local chunk = data:sub(pos, pos + chunk_size - 1)
        pos = pos + chunk_size
        return chunk
    end
end

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
    
    -- Build cover.xhtml (blank page)
    local cover_xhtml = [[<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml">
<head>
  <title>Placeholder</title>
</head>
<body>
  <div style="text-align: center; padding: 2em;">
    <p style="font-size: 1.2em; color: #666;">This is a library placeholder.</p>
    <p>Open the OPDS Browser plugin menu to download this book.</p>
  </div>
</body>
</html>]]
    
    -- Create EPUB zip file using ZipWriter
    -- IMPORTANT: mimetype MUST be first and uncompressed for EPUB spec compliance
    local zip = ZipWriter:new()
    local zip_file = io.open(output_path, "w+b")
    if not zip_file then
        logger.err("PlaceholderGenerator: Failed to open output file for writing")
        return false
    end
    
    local ok_open = zip:open(zip_file)
    if not ok_open then
        logger.err("PlaceholderGenerator: Failed to open zip writer")
        zip_file:close()
        return false
    end
    
    -- Add mimetype first (MUST be uncompressed and first in archive)
    local mimetype_content = "application/epub+zip"
    local mimetype_desc, mimetype_reader = make_string_reader(mimetype_content, true, false)
    local ok_mimetype = zip:write("mimetype", mimetype_desc, mimetype_reader)
    if not ok_mimetype then
        logger.err("PlaceholderGenerator: Failed to write mimetype to zip")
        zip:close()
        return false
    end
    
    -- Add META-INF/container.xml (compressed)
    local container_desc, container_reader = make_string_reader(container_xml, true, true)
    local ok = zip:write("META-INF/container.xml", container_desc, container_reader)
    if not ok then
        logger.err("PlaceholderGenerator: Failed to write container.xml to zip")
        zip:close()
        return false
    end
    
    -- Add OEBPS/content.opf (compressed)
    local opf_desc, opf_reader = make_string_reader(content_opf, true, true)
    ok = zip:write("OEBPS/content.opf", opf_desc, opf_reader)
    if not ok then
        logger.err("PlaceholderGenerator: Failed to write content.opf to zip")
        zip:close()
        return false
    end
    
    -- Add OEBPS/cover.xhtml (compressed)
    local xhtml_desc, xhtml_reader = make_string_reader(cover_xhtml, true, true)
    ok = zip:write("OEBPS/cover.xhtml", xhtml_desc, xhtml_reader)
    if not ok then
        logger.err("PlaceholderGenerator: Failed to write cover.xhtml to zip")
        zip:close()
        return false
    end
    
    -- Add cover image if we have it (compressed)
    if has_cover then
        local cover_desc, cover_reader = make_string_reader(cover_data, false, true)
        ok = zip:write("OEBPS/" .. cover_filename, cover_desc, cover_reader)
        if not ok then
            logger.warn("PlaceholderGenerator: Failed to write cover image to zip")
            -- Continue anyway, cover is optional
        end
    end
    
    -- Close the zip file
    local ok_close = zip:close()
    if not ok_close then
        logger.err("PlaceholderGenerator: Failed to close zip file")
        return false
    end
    
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
        -- Try to use LuaZip for reading, fallback to unzip command if not available
        local ok_zip, zip_module = pcall(require, "zip")
        
        if ok_zip then
            -- Use LuaZip to read the file
            local zfile, err = zip_module.open(filepath)
            if not zfile then
                logger.warn("PlaceholderGenerator: Failed to open zip file:", filepath, err)
                return false
            end
            
            local content = ""
            local found = false
            for file in zfile:files() do
                if file.filename == CONTENT_OPF_PATH then
                    local currFile, open_err = zfile:open(file.filename)
                    if currFile then
                        local success_read, read_data = pcall(function()
                            return currFile:read("*a") or ""
                        end)
                        currFile:close()
                        if success_read then
                            content = read_data
                            found = true
                        end
                    end
                    break
                end
            end
            zfile:close()
            
            if found and content:match("opdsbrowser:placeholder") then
                return true
            end
        else
            -- Fallback to unzip command if zip module not available
            local unzip_cmd = string.format('unzip -p %s %s 2>/dev/null', 
                shell_escape(filepath), 
                shell_escape(CONTENT_OPF_PATH))
            local handle = io.popen(unzip_cmd)
            if not handle then
                logger.warn("PlaceholderGenerator: Failed to execute unzip command for:", filepath)
                return false
            end
            
            local success, content = pcall(function()
                return handle:read("*a") or ""
            end)
            handle:close()
            
            if not success then
                logger.warn("PlaceholderGenerator: Failed to read content from:", filepath)
                return false
            end
            
            -- Check for our placeholder marker (set in createMinimalEPUB)
            if content:match("opdsbrowser:placeholder") then
                return true
            end
        end
    end

    return false
end

return PlaceholderGenerator
