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
    
    -- Create Authors directory
    local authors_path = self.base_library_path .. "/Authors"
    ok, err = lfs.mkdir(authors_path)
    if not ok and err ~= "File exists" then
        logger.err("LibrarySyncManager: Failed to create Authors directory:", authors_path, err)
        return false
    end
    
    logger.info("LibrarySyncManager: Created folder structure at:", self.base_library_path)
    return true
end

-- Sync library from book list
function LibrarySyncManager:syncLibrary(books, progress_callback)
    if not self:createFolderStructure() then
        return false, "Failed to create folder structure"
    end
    
    local library_path = self.base_library_path .. "/library"
    
    -- Clean up any leftover .tmp directories from previous failed runs
    logger.info("LibrarySyncManager: Cleaning up any leftover temp directories")
    os.execute('rm -rf "' .. library_path .. '"/*.tmp 2>/dev/null')
    
    local total_books = #books
    local created = 0
    local skipped = 0
    local failed = 0
    
    logger.info("LibrarySyncManager: Syncing", total_books, "books to", library_path)
    
    for i, book in ipairs(books) do
        if progress_callback then
            progress_callback(i, total_books)
        end
        
        -- Generate filename
        local filename = PlaceholderGenerator:generateFilename(book)
        local filepath = library_path .. "/" .. filename
        
        logger.dbg("LibrarySyncManager: Processing book", i, "of", total_books, ":", book.title)
        
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
    end
    
    -- Final save
    self:savePlaceholderDB()
    
    -- Create collections (symlinks)
    self:createAuthorCollections(books)
    self:createSeriesCollections(books)
    
    logger.info("LibrarySyncManager: Sync complete - Created:", created, "Skipped:", skipped, "Failed:", failed)
    
    return true, {
        created = created,
        skipped = skipped,
        failed = failed,
        total = total_books
    }
end

-- Create author collection symlinks
function LibrarySyncManager:createAuthorCollections(books)
    local authors_path = self.base_library_path .. "/Authors"
    local library_path = self.base_library_path .. "/library"
    
    -- Group books by author
    local author_books = {}
    for _, book in ipairs(books) do
        local author = Utils.safe_string(book.author, "Unknown")
        if not author_books[author] then
            author_books[author] = {}
        end
        table.insert(author_books[author], book)
    end
    
    logger.info("LibrarySyncManager: Creating author collections for", Utils.table_count(author_books), "authors")
    
    for author, books_list in pairs(author_books) do
        -- Create author directory
        local safe_author = author:gsub('[/:*?"<>|\\]', '_')
        local author_dir = authors_path .. "/" .. safe_author
        
        local ok, err = lfs.mkdir(author_dir)
        if not ok and err ~= "File exists" then
            logger.warn("LibrarySyncManager: Failed to create author directory:", author, err)
        else
            -- Copy files to author folder (symlinks don't work on FAT32)
            for _, book in ipairs(books_list) do
                local filename = PlaceholderGenerator:generateFilename(book)
                local source = library_path .. "/" .. filename
                local dest = author_dir .. "/" .. filename
                
                -- Copy file instead of symlinking
                local copy_cmd = string.format('cp "%s" "%s" 2>/dev/null', source, dest)
                os.execute(copy_cmd)
            end
        end
    end
end

-- Create series collection symlinks
function LibrarySyncManager:createSeriesCollections(books)
    local series_path = self.base_library_path .. "/Series"
    local library_path = self.base_library_path .. "/library"
    
    -- Group books by series
    local series_books = {}
    for _, book in ipairs(books) do
        local series = Utils.safe_string(book.series, "")
        if series ~= "" then
            if not series_books[series] then
                series_books[series] = {}
            end
            table.insert(series_books[series], book)
        end
    end
    
    logger.info("LibrarySyncManager: Creating series collections for", Utils.table_count(series_books), "series")
    
    for series, books_list in pairs(series_books) do
        -- Create series directory
        local safe_series = series:gsub('[/:*?"<>|\\]', '_')
        local series_dir = series_path .. "/" .. safe_series
        
        local ok, err = lfs.mkdir(series_dir)
        if not ok and err ~= "File exists" then
            logger.warn("LibrarySyncManager: Failed to create series directory:", series, err)
        else
            -- Sort books by series index
            table.sort(books_list, function(a, b)
                local a_idx = Utils.safe_number(a.series_index, 0)
                local b_idx = Utils.safe_number(b.series_index, 0)
                if a_idx ~= b_idx then
                    return a_idx < b_idx
                end
                return a.title < b.title
            end)
            
            -- Copy files to series folder
            for _, book in ipairs(books_list) do
                local filename = PlaceholderGenerator:generateFilename(book)
                local source = library_path .. "/" .. filename
                
                -- Prefix with series index for proper sorting
                local series_idx = Utils.safe_string(book.series_index, "")
                local dest_filename = filename
                if series_idx ~= "" then
                    local num = tonumber(series_idx) or 0
                    dest_filename = string.format("%03d_", num) .. filename
                end
                
                local dest = series_dir .. "/" .. dest_filename
                
                -- Copy file instead of symlinking
                local copy_cmd = string.format('cp "%s" "%s" 2>/dev/null', source, dest)
                os.execute(copy_cmd)
            end
        end
    end
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
    local library_path = self.base_library_path .. "/library"
    local count = 0
    
    if lfs.attributes(library_path, "mode") == "directory" then
        for file in lfs.dir(library_path) do
            if file ~= "." and file ~= ".." then
                count = count + 1
            end
        end
    end
    
    return {
        total_placeholders = count,
        db_entries = Utils.table_count(self.placeholder_db),
        base_path = self.base_library_path,
    }
end

return LibrarySyncManager
