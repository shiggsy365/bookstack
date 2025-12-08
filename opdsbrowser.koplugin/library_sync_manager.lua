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
    recently_added_path = nil,
    current_reads_path = nil,
    placeholder_db = {}, -- Maps filepath -> book_info
    opds_username = nil,
    opds_password = nil,
}

function LibrarySyncManager:init(base_path, username, password)
    self.base_library_path = base_path or "/mnt/us/opdslibrary"
    self.authors_path = self.base_library_path .. "/authors"
    self.recently_added_path = self.base_library_path .. "/Recently Added"
    self.current_reads_path = self.base_library_path .. "/Current Reads"
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
    
    -- Create authors directory (new structure - all books go under authors)
    ok, err = lfs.mkdir(self.authors_path)
    if not ok and err ~= "File exists" then
        logger.err("LibrarySyncManager: Failed to create authors directory:", self.authors_path, err)
        return false
    end
    
    -- Create Recently Added directory
    ok, err = lfs.mkdir(self.recently_added_path)
    if not ok and err ~= "File exists" then
        logger.err("LibrarySyncManager: Failed to create Recently Added directory:", self.recently_added_path, err)
        return false
    end

    -- Create Current Reads directory
    ok, err = lfs.mkdir(self.current_reads_path)
    if not ok and err ~= "File exists" then
        logger.err("LibrarySyncManager: Failed to create Current Reads directory:", self.current_reads_path, err)
        return false
    end

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
    
    logger.info("LibrarySyncManager: Syncing", total_books, "books with new authors folder structure")
    
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
    
    -- Populate Recently Added folder
    logger.info("LibrarySyncManager: Populating Recently Added folder")
    local recently_added, recently_failed = self:populateRecentlyAdded(books)

    -- Populate Current Reads folder from reading history
    logger.info("LibrarySyncManager: Populating Current Reads folder")
    local current_reads, current_reads_failed = self:populateCurrentReads()

    -- Save database again after populating special folders (includes symlink/copy paths)
    self:savePlaceholderDB()
    logger.info("LibrarySyncManager: Saved database with Recently Added and Current Reads entries")

    logger.info("LibrarySyncManager: Sync complete - Created:", created, "Updated:", updated, "Skipped:", skipped, "Failed:", failed, "Orphans removed:", deleted_orphans, "Recently Added:", recently_added, "Current Reads:", current_reads)
    
    return true, {
        created = created,
        updated = updated,
        skipped = skipped,
        failed = failed,
        deleted_orphans = deleted_orphans,
        recently_added = recently_added,
        current_reads = current_reads,
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

-- Populate Recently Added folder with symlinks to recently added books
function LibrarySyncManager:populateRecentlyAdded(books)
    logger.info("LibrarySyncManager: Populating Recently Added folder")
    
    -- Clear existing Recently Added folder
    local function clear_directory(dir)
        if lfs.attributes(dir, "mode") ~= "directory" then
            return
        end

        for file in lfs.dir(dir) do
            if file ~= "." and file ~= ".." then
                local path = dir .. "/" .. file
                local attr = lfs.attributes(path)
                if attr and attr.mode == "file" then
                    -- Remove from database before deleting file
                    if self.placeholder_db[path] then
                        self.placeholder_db[path] = nil
                        logger.dbg("LibrarySyncManager: Removed from database:", path)
                    end
                    os.remove(path)
                    logger.dbg("LibrarySyncManager: Removed old file:", path)
                end
            end
        end
    end

    clear_directory(self.recently_added_path)
    
    -- Sort books by updated timestamp (most recent first)
    local books_with_dates = {}
    for _, book in ipairs(books) do
        if book.updated and book.updated ~= "" then
            table.insert(books_with_dates, book)
        end
    end
    
    table.sort(books_with_dates, function(a, b)
        return a.updated > b.updated
    end)
    
    -- Take top 50 most recent books
    local recent_count = math.min(50, #books_with_dates)
    logger.info("LibrarySyncManager: Found", recent_count, "recent books")
    
    local added = 0
    local failed = 0
    
    for i = 1, recent_count do
        local book = books_with_dates[i]
        
        -- Find the original placeholder file
        local target_dir = self:getBookDirectory(book)
        if target_dir then
            local filename = self:generateFilename(book)
            local original_path = target_dir .. "/" .. filename
            
            -- Check if original file exists
            if lfs.attributes(original_path, "mode") == "file" then
                -- Create symlink in Recently Added folder
                local symlink_path = self.recently_added_path .. "/" .. filename
                
                -- Try to create symlink using lfs.link if available
                local link_ok = false
                
                -- First try using lfs.link (safer, no shell injection risk)
                -- lfs.link(old, new, symlink=true) creates a symbolic link
                if lfs.link then
                    local ok, result = pcall(lfs.link, original_path, symlink_path, true)
                    -- Check both pcall success and lfs.link return value
                    if ok and result == true then
                        link_ok = true
                        logger.dbg("LibrarySyncManager: Created symlink with lfs.link:", symlink_path)
                    elseif ok and result ~= true then
                        logger.dbg("LibrarySyncManager: lfs.link (symlink) returned:", result)
                    end
                end
                
                if link_ok then
                    added = added + 1
                    -- Store the symlink path in database too for quick lookups
                    self.placeholder_db[symlink_path] = self.placeholder_db[original_path]
                    logger.dbg("LibrarySyncManager: Added symlink to database:", symlink_path)
                else
                    -- If symlink fails, try creating a hard link or copy instead
                    local copy_ok = false
                    
                    -- Try hard link first (no space cost)
                    -- lfs.link(old, new) without third parameter creates a hard link
                    if lfs.link then
                        local ok, result = pcall(lfs.link, original_path, symlink_path)
                        -- Check both pcall success and lfs.link return value
                        if ok and result == true then
                            copy_ok = true
                            logger.dbg("LibrarySyncManager: Created hard link with lfs.link:", symlink_path)
                        elseif ok and result ~= true then
                            logger.dbg("LibrarySyncManager: lfs.link (hard) returned:", result)
                        end
                    end
                    
                    -- Fallback to file copy using pure Lua I/O (completely safe)
                    if not copy_ok then
                        local ok, err = pcall(function()
                            local source_file = io.open(original_path, "rb")
                            if not source_file then
                                return false, "Cannot open source"
                            end
                            
                            local content = source_file:read("*all")
                            source_file:close()
                            
                            local dest_file = io.open(symlink_path, "wb")
                            if not dest_file then
                                return false, "Cannot open destination"
                            end
                            
                            dest_file:write(content)
                            dest_file:close()
                            
                            return true
                        end)
                        
                        if ok and err == true then
                            copy_ok = true
                            logger.dbg("LibrarySyncManager: Created copy with Lua I/O:", symlink_path)
                        elseif ok and err ~= true then
                            logger.dbg("LibrarySyncManager: File copy failed:", err)
                        end
                    end
                    
                    if copy_ok then
                        added = added + 1
                        -- Store the copy/link path in database too for quick lookups
                        self.placeholder_db[symlink_path] = self.placeholder_db[original_path]
                        logger.dbg("LibrarySyncManager: Added copy/hard link to database:", symlink_path)
                    else
                        failed = failed + 1
                        logger.warn("LibrarySyncManager: Failed to create link/copy for:", filename)
                    end
                end
            else
                logger.dbg("LibrarySyncManager: Original file not found:", original_path)
                failed = failed + 1
            end
        else
            failed = failed + 1
        end
    end
    
    logger.info("LibrarySyncManager: Recently Added populated - Added:", added, "Failed:", failed)
    return added, failed
end

-- Populate Current Reads folder with symlinks to recently read books from history
function LibrarySyncManager:populateCurrentReads()
    logger.info("LibrarySyncManager: Populating Current Reads folder")

    -- Clear existing Current Reads folder
    local function clear_directory(dir)
        if lfs.attributes(dir, "mode") ~= "directory" then
            return
        end

        for file in lfs.dir(dir) do
            if file ~= "." and file ~= ".." then
                local path = dir .. "/" .. file
                local attr = lfs.attributes(path)
                if attr and attr.mode == "file" then
                    -- Remove from database before deleting file
                    if self.placeholder_db[path] then
                        self.placeholder_db[path] = nil
                        logger.dbg("LibrarySyncManager: Removed from database:", path)
                    end
                    os.remove(path)
                    logger.dbg("LibrarySyncManager: Removed old file:", path)
                end
            end
        end
    end

    clear_directory(self.current_reads_path)

    -- Access KOReader's reading history
    local ReadHistory = require("readhistory")
    local history = ReadHistory:getFileList()

    if not history or #history == 0 then
        logger.info("LibrarySyncManager: No reading history found")
        return 0, 0
    end

    logger.info("LibrarySyncManager: Found", #history, "items in reading history")

    -- Filter history for books in our library (placeholders or downloaded books in library)
    local library_books = {}
    for _, item in ipairs(history) do
        local filepath = item.file
        -- Check if this file is in our library path or is in our placeholder database
        if filepath and (filepath:match("^" .. self.base_library_path) or self.placeholder_db[filepath]) then
            table.insert(library_books, {
                filepath = filepath,
                time = item.time or 0
            })
        end
    end

    -- Sort by most recent first (already sorted by ReadHistory, but ensure it)
    table.sort(library_books, function(a, b)
        return a.time > b.time
    end)

    -- Take top 25 most recently read books
    local current_count = math.min(25, #library_books)
    logger.info("LibrarySyncManager: Found", current_count, "library books in reading history")

    local added = 0
    local failed = 0

    for i = 1, current_count do
        local item = library_books[i]
        local original_path = item.filepath

        -- Check if original file exists
        if lfs.attributes(original_path, "mode") == "file" then
            -- Extract filename from path
            local filename = original_path:match("([^/]+)$")
            -- Create symlink in Current Reads folder
            local symlink_path = self.current_reads_path .. "/" .. filename

            -- Try to create symlink using lfs.link if available
            local link_ok = false

            -- First try using lfs.link (safer, no shell injection risk)
            if lfs.link then
                local ok, result = pcall(lfs.link, original_path, symlink_path, true)
                if ok and result == true then
                    link_ok = true
                    logger.dbg("LibrarySyncManager: Created symlink with lfs.link:", symlink_path)
                elseif ok and result ~= true then
                    logger.dbg("LibrarySyncManager: lfs.link (symlink) returned:", result)
                end
            end

            if link_ok then
                added = added + 1
                -- Store the symlink path in database too for quick lookups (if original is in DB)
                if self.placeholder_db[original_path] then
                    self.placeholder_db[symlink_path] = self.placeholder_db[original_path]
                    logger.dbg("LibrarySyncManager: Added symlink to database:", symlink_path)
                end
            else
                -- If symlink fails, try creating a hard link or copy instead
                local copy_ok = false

                -- Try hard link first (no space cost)
                if lfs.link then
                    local ok, result = pcall(lfs.link, original_path, symlink_path)
                    if ok and result == true then
                        copy_ok = true
                        logger.dbg("LibrarySyncManager: Created hard link with lfs.link:", symlink_path)
                    elseif ok and result ~= true then
                        logger.dbg("LibrarySyncManager: lfs.link (hard) returned:", result)
                    end
                end

                -- Fallback to file copy using pure Lua I/O (completely safe)
                if not copy_ok then
                    local ok, err = pcall(function()
                        local source_file = io.open(original_path, "rb")
                        if not source_file then
                            return false, "Cannot open source"
                        end

                        local content = source_file:read("*all")
                        source_file:close()

                        local dest_file = io.open(symlink_path, "wb")
                        if not dest_file then
                            return false, "Cannot open destination"
                        end

                        dest_file:write(content)
                        dest_file:close()

                        return true
                    end)

                    if ok and err == true then
                        copy_ok = true
                        logger.dbg("LibrarySyncManager: Created copy with Lua I/O:", symlink_path)
                    elseif ok and err ~= true then
                        logger.dbg("LibrarySyncManager: File copy failed:", err)
                    end
                end

                if copy_ok then
                    added = added + 1
                    -- Store the copy/link path in database too for quick lookups (if original is in DB)
                    if self.placeholder_db[original_path] then
                        self.placeholder_db[symlink_path] = self.placeholder_db[original_path]
                        logger.dbg("LibrarySyncManager: Added copy/hard link to database:", symlink_path)
                    end
                else
                    failed = failed + 1
                    logger.warn("LibrarySyncManager: Failed to create link/copy for:", filename)
                end
            end
        else
            logger.dbg("LibrarySyncManager: Original file not found:", original_path)
            failed = failed + 1
        end
    end

    logger.info("LibrarySyncManager: Current Reads populated - Added:", added, "Failed:", failed)
    return added, failed
end

-- Update Current Reads folder (to be called when a book is opened)
function LibrarySyncManager:updateCurrentReads()
    logger.dbg("LibrarySyncManager: Updating Current Reads folder")
    local added, failed = self:populateCurrentReads()
    if added > 0 or failed > 0 then
        self:savePlaceholderDB()
        logger.dbg("LibrarySyncManager: Current Reads updated - Added:", added, "Failed:", failed)
    end
    return added, failed
end

return LibrarySyncManager
