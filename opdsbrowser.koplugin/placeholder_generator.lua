local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")
local Utils = require("utils")

local PlaceholderGenerator = {}

-- Create a placeholder file (HTML format, no zip required)
function PlaceholderGenerator:createMinimalEPUB(book_info, output_path)
    logger.info("PlaceholderGenerator: Creating placeholder for:", book_info.title)
    
    local book_title = Utils.safe_string(book_info.title, "Unknown Title")
    local book_author = Utils.safe_string(book_info.author, "Unknown Author")
    local book_id = Utils.safe_string(book_info.id, "")
    local series = Utils.safe_string(book_info.series, "")
    local series_index = Utils.safe_string(book_info.series_index, "")
    
    -- Create HTML file instead of EPUB (no zip required)
    output_path = output_path:gsub("%.epub$", ".html")
    
    -- Build series info
    local series_html = ""
    if series ~= "" then
        series_html = string.format("<p class='info'><strong>Series:</strong> %s%s</p>", 
            Utils.html_escape(series),
            series_index ~= "" and " #" .. Utils.html_escape(series_index) or "")
    end
    
    -- Build cover image if available
    local cover_html = ""
    if book_info.cover_url and book_info.cover_url ~= "" then
        cover_html = string.format([[
            <div class="cover">
                <img src="%s" alt="Cover" onerror="this.style.display='none'"/>
            </div>
        ]], Utils.html_escape(book_info.cover_url))
    end
    
    -- Create HTML content
    local html_content = string.format([[
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <meta name="opdsbrowser:placeholder" content="true">
    <meta name="opdsbrowser:book_id" content="%s">
    <title>%s - Library Placeholder</title>
    <style>
        body { 
            font-family: Georgia, serif;
            padding: 1em;
            background: linear-gradient(135deg, #667eea 0%%, #764ba2 100%%);
            min-height: 100vh;
            margin: 0;
        }
        .container {
            max-width: 600px;
            margin: 2em auto;
            background: white;
            border-radius: 15px;
            box-shadow: 0 10px 40px rgba(0,0,0,0.3);
            overflow: hidden;
        }
        .header {
            background: linear-gradient(135deg, #4a90e2 0%%, #357abd 100%%);
            color: white;
            padding: 1.5em;
            text-align: center;
        }
        .header h1 {
            margin: 0;
            font-size: 1.3em;
            font-weight: normal;
        }
        .cover {
            text-align: center;
            padding: 2em;
            background: #f8f9fa;
        }
        .cover img {
            max-width: 250px;
            max-height: 350px;
            border-radius: 8px;
            box-shadow: 0 4px 15px rgba(0,0,0,0.2);
        }
        .content {
            padding: 2em;
        }
        .book-title {
            font-size: 1.8em;
            color: #333;
            margin: 0 0 0.5em 0;
            font-weight: bold;
        }
        .info {
            color: #666;
            margin: 0.5em 0;
            font-size: 1.1em;
        }
        .instructions {
            background: #e8f4f8;
            border-left: 4px solid #4a90e2;
            padding: 1.5em;
            margin: 2em 0;
            border-radius: 4px;
        }
        .instructions h3 {
            margin-top: 0;
            color: #357abd;
        }
        .instructions ol {
            margin: 0.5em 0;
            padding-left: 1.5em;
        }
        .instructions li {
            margin: 0.5em 0;
        }
        .footer {
            text-align: center;
            padding: 1em;
            color: #999;
            font-size: 0.9em;
            border-top: 1px solid #eee;
        }
        .icon {
            font-size: 2em;
            margin-bottom: 0.2em;
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <div class="icon">📚</div>
            <h1>Library Placeholder</h1>
        </div>
        
        %s
        
        <div class="content">
            <h2 class="book-title">%s</h2>
            <p class="info"><strong>Author:</strong> %s</p>
            %s
            
            <div class="instructions">
                <h3>📥 To Download This Book:</h3>
                <ol>
                    <li>Open the <strong>OPDS Browser</strong> plugin menu</li>
                    <li>Select <strong>"Library Sync - Download from Placeholder"</strong></li>
                    <li>The book will download and replace this file</li>
                </ol>
                <p style="margin: 1em 0 0 0; font-size: 0.95em;">
                    Or search for "<em>%s</em>" in your OPDS library manually.
                </p>
            </div>
        </div>
        
        <div class="footer">
            Book ID: %s<br/>
            This placeholder will be replaced with the actual EPUB when downloaded.
        </div>
    </div>
</body>
</html>
]], 
        Utils.html_escape(book_id),
        Utils.html_escape(book_title),
        cover_html,
        Utils.html_escape(book_title),
        Utils.html_escape(book_author),
        series_html,
        Utils.html_escape(book_title),
        Utils.html_escape(book_id)
    )
    
    -- Write HTML file
    local file, err = io.open(output_path, "w")
    if not file then
        logger.err("PlaceholderGenerator: Failed to create placeholder:", err)
        return false
    end
    
    file:write(html_content)
    file:close()
    
    logger.info("PlaceholderGenerator: Created HTML placeholder:", output_path)
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
    
    -- Use .html extension
    return safe_author .. "_-_" .. safe_title .. ".html"
end

-- Check if a file is a placeholder
function PlaceholderGenerator:isPlaceholder(filepath)
    if not filepath:match("%.html$") then
        return false
    end
    
    local attr = lfs.attributes(filepath)
    if not attr or not attr.size then
        return false
    end
    
    -- Placeholders are small HTML files
    if attr.size < 50000 then -- 50KB
        local file = io.open(filepath, "r")
        if file then
            local content = file:read(500)
            file:close()
            if content and content:match("opdsbrowser:placeholder") then
                return true
            end
        end
    end
    
    return false
end

-- Extract book ID from placeholder (not used but kept for compatibility)
function PlaceholderGenerator:extractBookID(filepath)
    return nil
end

return PlaceholderGenerator
