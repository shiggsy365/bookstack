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
    authors_path = nil,
    placeholder_db = {}, -- Maps filepath -> book_info
    opds_username = nil,
    opds_password = nil,
}

function LibrarySyncManager:init(base_path, username, password)
    self.base_library_path = base_path or "/mnt/us/opdslibrary"
    -- Path Change: Books go directly into base path (e.g. /Library/Author/...)
    -- instead of /Library/authors/Author/...
    self.authors_path = self.base_library_path 
    self.opds_username = username
    self.opds_password = password
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

-- Sanitize a string for use as a directory/file name
function LibrarySyncManager:sanitizeFilename(str)
    return str:gsub('[/:*?"<>|\\]', '_'):gsub('%s+', '_')
end

-- Sanitize author name for directory (preserves spaces, removes illegal chars)
function LibrarySyncManager:sanitizeAuthorName(str)
    -- Remove illegal filesystem characters but keep spaces
    -- Replace only the illegal characters with nothing or dash
    str = str:gsub('[/:*?"<>|\\]', '-')
    -- Collapse multiple spaces to single space
    str = str:gsub('%s+', ' ')
    -- Trim leading/trailing spaces
    str = str:gsub('^%s+', ''):gsub('%s+$', '')
    return str
end

-- Create the folder structure
function LibrarySyncManager:createFolderStructure()
    -- Create base Library directory
    local ok, err = lfs.mkdir(self.base_library_path)
    if not ok and err ~= "File exists" then
        logger.err("LibrarySyncManager: Failed to create base directory:", self.base_library_path, err)
        return false
    end
    
    -- No longer creating 'authors', 'Recently Added', or 'Current Reads' subfolders
    
    logger.info("LibrarySyncManager: Created folder structure at:", self.base_library_path)
    return true
end

-- Get the target directory for a book based on author/series
function LibrarySyncManager:getBookDirectory(book)
    -- Sanitize author name (preserving spaces for readability)
    local author = Utils.safe_string(book.author, "Unknown Author")
    local safe_author = self:sanitizeAuthorName(author)
    
    local author_dir = self.authors_path .. "/" .. safe_author
    
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
        local safe_series = self:sanitizeFilename(series)
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
    local updated = 0
    local deleted_orphans = 0
    
    logger.info("LibrarySyncManager: Syncing", total_books, "books")
    
    -- Create a lookup map of book IDs from remote library
    local remote_book_ids = {}
    for _, book in ipairs(books) do
        if book.id then
            remote_book_ids[book.id] = true
        end
    end
    
    -- First pass: Identify and remove orphaned placeholders
    logger.info("LibrarySyncManager: Checking for orphaned placeholders")
    local orphaned_paths = {}
    for filepath, book_info in pairs(self.placeholder_db) do
        local book_id = book_info.book_id
        if book_id and not remote_book_ids[book_id] then
            -- This placeholder's book no longer exists in remote library
            table.insert(orphaned_paths, filepath)
        end
    end
    
    -- Delete orphaned placeholders
    for _, filepath in ipairs(orphaned_paths) do
        logger.info("LibrarySyncManager: Removing orphaned placeholder:", filepath)
        local ok = os.remove(filepath)
        if ok then
            self.placeholder_db[filepath] = nil
            deleted_orphans = deleted_orphans + 1
        else
            logger.warn("LibrarySyncManager: Failed to remove orphaned placeholder:", filepath)
        end
    end
    
    if deleted_orphans > 0 then
        logger.info("LibrarySyncManager: Removed", deleted_orphans, "orphaned placeholders")
        self:savePlaceholderDB()
    end
    
    -- Second pass: Create/update placeholders for books in remote library
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
        
        -- CRITICAL FIX: Check if file actually exists on disk first
        -- The database might have stale entries if the library folder was deleted
        local file_exists_on_disk = lfs.attributes(filepath, "mode") == "file"
        local existing_info = self.placeholder_db[filepath]
        
        -- Only consider the DB entry valid if the file actually exists
        if existing_info and file_exists_on_disk then
            -- Check if metadata has changed
            local metadata_changed = false
            if existing_info.title ~= book.title then
                logger.info("LibrarySyncManager: Title changed:", existing_info.title, "->", book.title)
                metadata_changed = true
            end
            if existing_info.author ~= book.author then
                logger.info("LibrarySyncManager: Author changed:", existing_info.author, "->", book.author)
                metadata_changed = true
            end
            if existing_info.series ~= book.series then
                logger.info("LibrarySyncManager: Series changed:", existing_info.series or "none", "->", book.series or "none")
                metadata_changed = true
            end
            if existing_info.series_index ~= book.series_index then
                logger.info("LibrarySyncManager: Series index changed:", existing_info.series_index or "none", "->", book.series_index or "none")
                metadata_changed = true
            end
            
            if metadata_changed then
                -- Metadata changed - need to regenerate placeholder
                logger.info("LibrarySyncManager: Metadata changed, regenerating placeholder:", book.title)
                
                -- Delete old placeholder
                local delete_ok = os.remove(filepath)
                if not delete_ok then
                    logger.warn("LibrarySyncManager: Failed to delete old placeholder for update:", filepath)
                    failed = failed + 1
                    goto continue
                end
                
                -- Remove old entry from database
                self.placeholder_db[filepath] = nil
                
                -- Regenerate with new metadata
                -- Note: filename might be different if series changed, so recalculate
                target_dir = self:getBookDirectory(book)
                if not target_dir then
                    failed = failed + 1
                    logger.err("LibrarySyncManager: Failed to determine new directory for:", book.title)
                    goto continue
                end
                
                filename = self:generateFilename(book)
                local new_filepath = target_dir .. "/" .. filename
                
                logger.dbg("LibrarySyncManager: Creating updated placeholder at:", new_filepath)
                local ok = PlaceholderGenerator:createMinimalEPUB(book, new_filepath, self.opds_username, self.opds_password)
                if ok then
                    updated = updated + 1
                    logger.dbg("LibrarySyncManager: Successfully updated:", filename)
                    
                    -- Store new mapping
                    self.placeholder_db[new_filepath] = {
                        book_id = book.id,
                        title = book.title,
                        author = book.author,
                        series = book.series,
                        series_index = book.series_index,
                        download_url = book.download_url,
                        cover_url = book.cover_url,
                        summary = book.summary,
                    }
                    
                    -- Save periodically
                    if (updated + created) % 50 == 0 then
                        logger.info("LibrarySyncManager: Progress - processed", updated + created, "items so far")
                        self:savePlaceholderDB()
                    end
                else
                    failed = failed + 1
                    logger.err("LibrarySyncManager: Failed to update placeholder for:", book.title)
                end
            else
                -- No metadata changes, skip
                skipped = skipped + 1
                logger.dbg("LibrarySyncManager: Skipping unchanged:", filename)
            end
        elseif existing_info and not file_exists_on_disk then
            -- File was in DB but doesn't exist on disk (folder was deleted)
            -- Recreate the placeholder
            logger.info("LibrarySyncManager: File in DB but missing on disk, recreating:", filepath)
            
            -- Create the placeholder
            logger.dbg("LibrarySyncManager: Creating placeholder at:", filepath)
            local ok = PlaceholderGenerator:createMinimalEPUB(book, filepath, self.opds_username, self.opds_password)
            if ok then
                created = created + 1
                logger.info("LibrarySyncManager: Successfully recreated placeholder:", filename)
                
                -- Update the mapping with current metadata
                self.placeholder_db[filepath] = {
                    book_id = book.id,
                    title = book.title,
                    author = book.author,
                    series = book.series,
                    series_index = book.series_index,
                    download_url = book.download_url,
                    cover_url = book.cover_url,
                    summary = book.summary,
                }
                
                -- Save periodically
                if created % 50 == 0 then
                    logger.info("LibrarySyncManager: Progress - created", created, "placeholders so far")
                    self:savePlaceholderDB()
                end
            else
                failed = failed + 1
                logger.err("LibrarySyncManager: Failed to recreate placeholder for:", book.title)
                logger.err("LibrarySyncManager: Failed filepath was:", filepath)
            end
        elseif file_exists_on_disk then
            -- File exists but not in database - this might be a downloaded book
            -- Check if it's a placeholder
            if PlaceholderGenerator:isPlaceholder(filepath) then
                -- It's a placeholder but not in DB - add to DB
                logger.info("LibrarySyncManager: Found placeholder not in DB, adding:", filepath)
                self.placeholder_db[filepath] = {
                    book_id = book.id,
                    title = book.title,
                    author = book.author,
                    series = book.series,
                    series_index = book.series_index,
                    download_url = book.download_url,
                    cover_url = book.cover_url,
                    summary = book.summary,
                }
                skipped = skipped + 1
            else
                -- It's a real book (downloaded), don't touch it
                logger.dbg("LibrarySyncManager: Skipping downloaded book:", filename)
                skipped = skipped + 1
            end
        else
            -- Create new placeholder
            logger.dbg("LibrarySyncManager: Creating new placeholder at:", filepath)
            local ok = PlaceholderGenerator:createMinimalEPUB(book, filepath, self.opds_username, self.opds_password)
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
                    summary = book.summary,
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
    
    logger.info("LibrarySyncManager: Sync complete - Created:", created, "Updated:", updated, "Skipped:", skipped, "Failed:", failed, "Orphans removed:", deleted_orphans)
    
    return true, {
        created = created,
        updated = updated,
        skipped = skipped,
        failed = failed,
        deleted_orphans = deleted_orphans,
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
                    elseif attr.mode == "file" and file:match("%.epub$") then
                        count = count + 1
                    end
                end
            end
        end
    end
    
    if lfs.attributes(self.authors_path, "mode") == "directory" then
        count_files(self.authors_path)
    end
    
    return {
        total_placeholders = count,
        db_entries = Utils.table_count(self.placeholder_db),
        base_path = self.base_library_path,
    }
end

return LibrarySyncManager
