local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")
local Utils = require("utils")

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
    
    -- Create a temporary directory for EPUB contents
    local temp_dir = output_path .. ".tmp"
    local ok, err = lfs.mkdir(temp_dir)
    if not ok and err ~= "File exists" then
        logger.err("PlaceholderGenerator: Failed to create temp directory:", err)
        return false
    end
    
    -- Create META-INF directory
    local meta_inf_dir = temp_dir .. "/META-INF"
    ok, err = lfs.mkdir(meta_inf_dir)
    if not ok and err ~= "File exists" then
        logger.err("PlaceholderGenerator: Failed to create META-INF:", err)
        os.execute('rm -rf ' .. shell_escape(temp_dir))
        return false
    end
    
    -- Create OEBPS directory
    local oebps_dir = temp_dir .. "/OEBPS"
    ok, err = lfs.mkdir(oebps_dir)
    if not ok and err ~= "File exists" then
        logger.err("PlaceholderGenerator: Failed to create OEBPS:", err)
        os.execute('rm -rf ' .. shell_escape(temp_dir))
        return false
    end
    
    -- Write mimetype file (must be first, uncompressed)
    local mimetype_file = io.open(temp_dir .. "/mimetype", "w")
    if not mimetype_file then
        logger.err("PlaceholderGenerator: Failed to create mimetype")
        os.execute('rm -rf ' .. shell_escape(temp_dir))
        return false
    end
    mimetype_file:write("application/epub+zip")
    mimetype_file:close()
    
    -- Write container.xml
    local container_xml = [[<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>]]
    
    local container_file = io.open(meta_inf_dir .. "/container.xml", "w")
    if not container_file then
        logger.err("PlaceholderGenerator: Failed to create container.xml")
        os.execute('rm -rf ' .. shell_escape(temp_dir))
        return false
    end
    container_file:write(container_xml)
    container_file:close()
    
    -- Write cover image if we have it
    local cover_filename = "cover." .. (cover_ext or "jpg")
    if has_cover then
        local cover_file = io.open(oebps_dir .. "/" .. cover_filename, "wb")
        if cover_file then
            cover_file:write(cover_data)
            cover_file:close()
            logger.info("PlaceholderGenerator: Embedded cover image in EPUB")
        else
            logger.warn("PlaceholderGenerator: Failed to write cover image")
            has_cover = false
        end
    end
    
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
    
    -- Write content.opf
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
    
    local opf_file = io.open(oebps_dir .. "/content.opf", "w")
    if not opf_file then
        logger.err("PlaceholderGenerator: Failed to create content.opf")
        os.execute('rm -rf ' .. shell_escape(temp_dir))
        return false
    end
    opf_file:write(content_opf)
    opf_file:close()
    
    -- Write cover.xhtml (blank page)
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
    
    local xhtml_file = io.open(oebps_dir .. "/cover.xhtml", "w")
    if not xhtml_file then
        logger.err("PlaceholderGenerator: Failed to create cover.xhtml")
        os.execute('rm -rf ' .. shell_escape(temp_dir))
        return false
    end
    xhtml_file:write(cover_xhtml)
    xhtml_file:close()
    
    -- Create EPUB zip file
    -- First, add mimetype uncompressed (-X -0 means no compression, store only)
    -- Then add other files compressed (-r for recursive)
    -- Both commands run from temp_dir, so paths are relative to it
    local zip_cmd = string.format(
        'cd %s && zip -X -0 %s mimetype && zip -r %s META-INF OEBPS',
        shell_escape(temp_dir),
        shell_escape(output_path),
        shell_escape(output_path)
    )
    
    local result = os.execute(zip_cmd)
    
    -- Clean up temporary directory
    os.execute('rm -rf ' .. shell_escape(temp_dir))
    
    -- os.execute() returns different types in different Lua versions
    -- Lua 5.1: returns true/false, Lua 5.2+: returns exit code (0 = success)
    if result ~= 0 and result ~= true then
        logger.err("PlaceholderGenerator: Failed to create EPUB zip file")
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

    return false
end

return PlaceholderGenerator
