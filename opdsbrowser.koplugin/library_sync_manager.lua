local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")
local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
local Utils = require("utils")
local PlaceholderGenerator = require("placeholder_generator")

local LibrarySyncManager = {
    settings_file = DataStorage:getSettingsDir() .. "/opdsbrowser_library_sync.lua",
    settings = nil,
    base_library_path = nil,
    placeholder_db = {}, -- Maps filepath -> book_info
}

function LibrarySyncManager:init(base_path)
    self.base_library_path = base_path or "/mnt/us/opdslibrary"
    self.settings = LuaSettings:open(self.settings_file)
    self:loadPlaceholderDB()
    logger.info("LibrarySyncManager: Initialized with base path:", self.base_library_path)
end

function LibrarySyncManager:loadPlaceholderDB()
    self.placeholder_db = self.settings:readSetting("placeholder_db") or {}
    logger.info("LibrarySyncManager: Loaded", Utils.table_count(self.placeholder_db), "placeholder mappings")
end

function LibrarySyncManager:savePlaceholderDB()
    self.settings:saveSetting("placeholder_db", self.placeholder_db)
    self.settings:flush()
    logger.info("LibrarySyncManager: Saved placeholder database")
end

-- Create the folder structure
function LibrarySyncManager:createFolderStructure()
    -- Create base Library directory
    local ok, err = lfs.mkdir(self.base_library_path)
    if not ok and err ~= "File exists" then
        logger.err("LibrarySyncManager: Failed to create base directory:", self.base_library_path, err)
        return false
    end
    
    -- Create authors directory (new structure - all books go under authors)
    local authors_path = self.base_library_path .. "/authors"
    ok, err = lfs.mkdir(authors_path)
    if not ok and err ~= "File exists" then
        logger.err("LibrarySyncManager: Failed to create authors directory:", authors_path, err)
        return false
    end
    
    logger.info("LibrarySyncManager: Created folder structure at:", self.base_library_path)
    return true
end

-- Get the target directory for a book based on author/series
function LibrarySyncManager:getBookDirectory(book)
    local authors_path = self.base_library_path .. "/authors"
    
    -- Sanitize author name
    local author = Utils.safe_string(book.author, "Unknown Author")
    local safe_author = author:gsub('[/:*?"<>|\\]', '_'):gsub('%s+', '_')
    
    local author_dir = authors_path .. "/" .. safe_author
    
    -- Create author directory if needed
    local ok, err = lfs.mkdir(author_dir)
    if not ok and err ~= "File exists" then
        logger.warn("LibrarySyncManager: Failed to create author directory:", author_dir, err)
        return nil
    end
    
    -- Determine if book has series
    local series = Utils.safe_string(book.series, "")
    
    local target_dir
    if series ~= "" then
        -- Book is part of a series - create series subfolder
        local safe_series = series:gsub('[/:*?"<>|\\]', '_'):gsub('%s+', '_')
        target_dir = author_dir .. "/" .. safe_series
    else
        -- Standalone book - use 'standalones' subfolder
        target_dir = author_dir .. "/standalones"
    end
    
    -- Create target directory
    ok, err = lfs.mkdir(target_dir)
    if not ok and err ~= "File exists" then
        logger.warn("LibrarySyncManager: Failed to create target directory:", target_dir, err)
        return nil
    end
    
    return target_dir
end

-- Generate filename with series ordering prefix
function LibrarySyncManager:generateFilename(book)
    local filename = PlaceholderGenerator:generateFilename(book)
    
    -- Add series number prefix for proper sorting if book has series
    local series = Utils.safe_string(book.series, "")
    if series ~= "" then
        local series_idx = Utils.safe_string(book.series_index, "")
        if series_idx ~= "" then
            local num = tonumber(series_idx) or 0
            -- Prefix with zero-padded series number for proper sorting
            filename = string.format("%03d_", num) .. filename
        end
    end
    
    return filename
end

-- Sync library from book list
function LibrarySyncManager:syncLibrary(books, progress_callback)
    if not self:createFolderStructure() then
        return false, "Failed to create folder structure"
    end
    
    local total_books = #books
    local created = 0
    local skipped = 0
    local failed = 0
    
    logger.info("LibrarySyncManager: Syncing", total_books, "books with new authors folder structure")
    
    for i, book in ipairs(books) do
        if progress_callback then
            progress_callback(i, total_books)
        end
        
        logger.dbg("LibrarySyncManager: Processing book", i, "of", total_books, ":", book.title)
        
        -- Get target directory based on author/series
        local target_dir = self:getBookDirectory(book)
        if not target_dir then
            failed = failed + 1
            logger.err("LibrarySyncManager: Failed to determine directory for:", book.title)
            goto continue
        end
        
        -- Generate filename with series prefix if applicable
        local filename = self:generateFilename(book)
        local filepath = target_dir .. "/" .. filename
        
        -- Check if already exists
        if lfs.attributes(filepath, "mode") == "file" then
            skipped = skipped + 1
            logger.dbg("LibrarySyncManager: Skipping existing:", filename)
        else
            -- Create placeholder
            logger.dbg("LibrarySyncManager: Creating placeholder at:", filepath)
            local ok = PlaceholderGenerator:createMinimalEPUB(book, filepath)
            if ok then
                created = created + 1
                logger.dbg("LibrarySyncManager: Successfully created:", filename)
                -- Store mapping
                self.placeholder_db[filepath] = {
                    book_id = book.id,
                    title = book.title,
                    author = book.author,
                    series = book.series,
                    series_index = book.series_index,
                    download_url = book.download_url,
                    cover_url = book.cover_url,
                }
                
                -- Save periodically
                if created % 50 == 0 then
                    logger.info("LibrarySyncManager: Progress - created", created, "placeholders so far")
                    self:savePlaceholderDB()
                end
            else
                failed = failed + 1
                logger.err("LibrarySyncManager: Failed to create placeholder for:", book.title)
                logger.err("LibrarySyncManager: Failed filepath was:", filepath)
            end
        end
        
        ::continue::
    end
    
    -- Final save
    self:savePlaceholderDB()
    
    logger.info("LibrarySyncManager: Sync complete - Created:", created, "Skipped:", skipped, "Failed:", failed)
    
    return true, {
        created = created,
        skipped = skipped,
        failed = failed,
        total = total_books
    }
end

-- Get book info from placeholder filepath
function LibrarySyncManager:getBookInfo(filepath)
    return self.placeholder_db[filepath]
end

-- Clear all placeholders
function LibrarySyncManager:clearLibrary()
    logger.info("LibrarySyncManager: Clearing library")
    
    -- Remove all directories
    os.execute('rm -rf "' .. self.base_library_path .. '"')
    
    -- Clear database
    self.placeholder_db = {}
    self:savePlaceholderDB()
    
    logger.info("LibrarySyncManager: Library cleared")
end

-- Get sync statistics
function LibrarySyncManager:getStats()
    -- Count files in authors folder recursively
    local count = 0
    
    local function count_files(dir)
        if lfs.attributes(dir, "mode") ~= "directory" then
            return
        end
        
        for file in lfs.dir(dir) do
            if file ~= "." and file ~= ".." then
                local path = dir .. "/" .. file
                local attr = lfs.attributes(path)
                if attr then
                    if attr.mode == "directory" then
                        count_files(path)
                    elseif attr.mode == "file" and file:match("%.html$") then
                        count = count + 1
                    end
                end
            end
        end
    end
    
    local authors_path = self.base_library_path .. "/authors"
    if lfs.attributes(authors_path, "mode") == "directory" then
        count_files(authors_path)
    end
    
    return {
        total_placeholders = count,
        db_entries = Utils.table_count(self.placeholder_db),
        base_path = self.base_library_path,
    }
end

return LibrarySyncManager
