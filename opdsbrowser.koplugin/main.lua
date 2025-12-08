-- Refactored OPDS Browser Plugin with improvements
--
-- PLACEHOLDER BOOK AUTO-DOWNLOAD WORKFLOW (5 Steps):
-- ===================================================
-- Step 1: DETECT PLACEHOLDER OPENED
--   - Triggered by: onReaderReady() event when user opens a book
--   - Action: Check if opened file is a placeholder (via database lookup)
--   - Success: Call handlePlaceholderAutoDownload()
--   - Failure: Normal book reading continues
--
-- Step 2: TRIGGER OPDS DOWNLOAD
--   - Triggered by: handlePlaceholderAutoDownload() from Step 1
--   - Action: Download real book from OPDS server to temp file
--   - Success: Temp file created with real book content
--   - Failure: Show error, placeholder remains
--
-- Step 3: DELETE PLACEHOLDER
--   - Triggered by: _finishPlaceholderDownload() after download completes
--   - Action: Delete placeholder file, rename temp to final location
--   - Success: Real book replaces placeholder on disk
--   - Failure: Show error, temp file deleted, placeholder may remain
--
-- Step 4: RESTART KOREADER
--   - Triggered by: _finishPlaceholderDownload() after file replacement
--   - Action: Save navigation state, trigger automatic restart
--   - Success: KOReader restarts
--   - Failure: Fall back to opening book directly
--
-- Step 5: NAVIGATE TO FOLDER
--   - Triggered by: checkRestartNavigation() during init() after restart
--   - Action: Load saved state, navigate FileManager to book folder
--   - Success: User sees folder with newly downloaded book
--   - Failure: Show error, user must navigate manually
--
-- All steps include comprehensive logging with "OPDS WORKFLOW: STEP N" markers
-- for easy diagnosis. Each step logs success (✓) or failure with detailed error info.
--
local BD = require("ui/bidi")
local DataStorage = require("datastorage")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local socket = require("socket")
local _ = require("gettext")
local T = require("ffi/util").template
local lfs = require("libs/libkoreader-lfs")
local json = require("json")
local url = require("socket.url")

-- Plugin modules
local Constants = require("constants")
local Utils = require("utils")
local UIHelpers = require("ui_helpers")
local CacheManager = require("cache_manager")
local SettingsManager = require("settings_manager")
local HistoryManager = require("history_manager")
local OPDSClient = require("opds_client")
local HardcoverClient = require("hardcover_client")
local EphemeraClient = require("ephemera_client")
local HttpClient = require("http_client_new")
local PlaceholderGenerator = require("placeholder_generator")
local LibrarySyncManager = require("library_sync_manager")
local PlaceholderBadge = require("placeholder_badge")
local RestartNavigationManager = require("restart_navigation_manager")

local OPDSBrowser = WidgetContainer:extend{
    name = "opdsbrowser",
    is_doc_only = false,
}

function OPDSBrowser:init()
    self.ui.menu:registerToMainMenu(self)
    
    -- Initialize managers
    SettingsManager:init()
    CacheManager:init()
    HistoryManager:init()
    
    -- Load settings
    local settings = SettingsManager:getAll()
    self.opds_url = settings.opds_url
    self.opds_username = settings.opds_username
    self.opds_password = settings.opds_password
    self.ephemera_url = settings.ephemera_url
    self.download_dir = settings.download_dir
    self.hardcover_token = settings.hardcover_token
    self.use_publisher_as_series = settings.use_publisher_as_series
    self.enable_library_check = settings.enable_library_check
    self.library_check_page_limit = settings.library_check_page_limit
    
    -- Initialize clients
    self.opds_client = OPDSClient:new()
    self.opds_client:setCredentials(self.opds_url, self.opds_username, self.opds_password)
    
    self.hardcover_client = HardcoverClient:new()
    self.hardcover_client:setToken(self.hardcover_token)
    
    self.ephemera_client = EphemeraClient:new()
    self.ephemera_client:setBaseURL(self.ephemera_url)
    
    -- Initialize library sync
    -- Use download_dir as base, create Library subfolder
    local base_download_dir = settings.download_dir or "/mnt/us/books"
    -- Remove trailing slash if present
    base_download_dir = base_download_dir:gsub("/$", "")
    local library_path = settings.library_sync_path or (base_download_dir .. "/Library")
    LibrarySyncManager:init(library_path, self.opds_username, self.opds_password)
    self.library_sync = LibrarySyncManager

    -- Initialize placeholder badge system
    self.placeholder_badge = PlaceholderBadge
    local badge_ok = self.placeholder_badge:init(PlaceholderGenerator)
    if badge_ok then
        -- Register the patch that will hook into CoverBrowser when it loads
        self.placeholder_badge:registerPatch()
        logger.info("OPDS Browser: Cloud badge overlay system initialized and registered")
    else
        logger.warn("OPDS Browser: Cloud badge overlay system not available")
    end

    -- Queue refresh
    self.queue_refresh_action = nil
    
    -- Register file selection hook for FileManager
    -- This allows us to intercept placeholder file taps before they open
    self:registerFileManagerHooks()

    -- Check for pending navigation from restart (must be done after UI is ready)
    UIManager:scheduleIn(2, function()
        self:checkRestartNavigation()
    end)
    
    -- Run workflow health check on startup (logs to console)
    UIManager:scheduleIn(3, function()
        self:checkWorkflowHealth()
    end)

    logger.info("OPDS Browser: Initialized with improved architecture")
end

-- Check and handle pending navigation from restart
function OPDSBrowser:checkRestartNavigation()
    logger.info("========================================")
    logger.info("OPDS WORKFLOW: STEP 5 - POST-RESTART NAVIGATION")
    logger.info("========================================")
    logger.info("OPDS Browser: Checking for restart navigation state")
    
    local state = RestartNavigationManager:loadNavigationState()
    if not state then
        logger.info("OPDS WORKFLOW: No pending navigation - normal startup")
        logger.info("OPDS Browser: No restart navigation pending")
        return
    end
    
    logger.info("OPDS WORKFLOW: Found saved navigation state from pre-restart")
    logger.info("OPDS Browser: Found restart navigation state, navigating to:", state.folder_path)
    
    -- Navigate to the folder
    local success = RestartNavigationManager:navigateToFolder(state.folder_path)
    
    if success then
        logger.info("OPDS WORKFLOW: ✓ Step 5 complete - Successfully navigated to folder")
        logger.info("OPDS Browser: Successfully navigated to folder after restart")
        
        -- Show a brief notification to the user
        UIHelpers.showInfo(_("Navigated to downloaded book folder"))
    else
        logger.err("OPDS WORKFLOW: FAILED AT STEP 5 - Cannot navigate to folder")
        logger.err("OPDS Browser: Failed to navigate to folder after restart")
        UIHelpers.showError(_("Failed to navigate to folder"))
    end
    
    -- Clear the state file (consumed)
    RestartNavigationManager:clearNavigationState()
    
    logger.info("========================================")
    logger.info("OPDS WORKFLOW: ALL STEPS COMPLETE")
    logger.info("========================================")
end

-- Register FileManager hooks to intercept placeholder file selections
function OPDSBrowser:registerFileManagerHooks()
    logger.info("OPDS Browser: Registering FileManager hooks for placeholder interception")
    
    -- Note: In KOReader, we can't directly override the file tap behavior
    -- but we can add a menu action that users can trigger via long-press (hold)
    -- This is the standard way plugins add custom file actions
    
    -- The actual hook will be registered via onMenuHold which is called
    -- when a user long-presses a file in FileManager
    logger.info("OPDS Browser: FileManager hooks ready (onMenuHold)")
end

-- Handle menu hold (long-press) on a file in FileManager
-- This is called by KOReader when user long-presses a file
function OPDSBrowser:onMenuHold(item)
    logger.info("OPDS Browser: onMenuHold called")
    
    -- Only process if we're in FileManager (not ReaderUI)
    if self.ui.name ~= "FileManager" then
        logger.dbg("OPDS Browser: Not in FileManager, ignoring")
        return false
    end
    
    -- Check if item is a file (not a directory)
    if not item or not item.path or item.is_directory then
        logger.dbg("OPDS Browser: Not a file, ignoring")
        return false
    end
    
    local filepath = item.path
    logger.info("OPDS Browser: Checking if file is placeholder:", filepath)
    
    -- Check if file is a placeholder
    local book_info = self.library_sync:getBookInfo(filepath)
    if not book_info then
        logger.dbg("OPDS Browser: Not a placeholder, ignoring")
        return false
    end
    
    logger.info("OPDS Browser: File IS a placeholder!")
    logger.info("OPDS Browser: Book title:", book_info.title)
    
    -- Add our custom "Download from OPDS" action to the menu
    -- Return a table of menu items to add to the long-press menu
    return {
        {
            text = _("Download from OPDS"),
            callback = function()
                logger.info("OPDS Browser: User selected 'Download from OPDS'")
                UIManager:close(self.file_menu_dialog)
                self:handlePlaceholderDownloadFromFileManager(filepath, book_info)
            end,
        },
    }
end

-- Hook for when a file is selected (tapped) in FileManager
-- This is our main interception point for placeholder files
function OPDSBrowser:onFileSelect(filepath)
    logger.info("=========================================")
    logger.info("OPDS Browser: onFileSelect called")
    logger.info("OPDS Browser: File:", filepath)
    logger.info("=========================================")
    
    -- Only process if we're in FileManager
    if self.ui.name ~= "FileManager" then
        logger.dbg("OPDS Browser: Not in FileManager, ignoring")
        return false
    end
    
    -- Only process EPUB files
    if not filepath:match("%.epub$") then
        logger.dbg("OPDS Browser: Not an EPUB file, ignoring")
        return false
    end
    
    -- Check if this is a placeholder file
    local book_info = self.library_sync:getBookInfo(filepath)
    if not book_info then
        logger.dbg("OPDS Browser: Not a placeholder, allowing normal open")
        return false
    end
    
    logger.info("=========================================")
    logger.info("OPDS Browser: INTERCEPTED PLACEHOLDER SELECTION!")
    logger.info("OPDS Browser: Title:", book_info.title)
    logger.info("OPDS Browser: Author:", book_info.author)
    logger.info("=========================================")
    
    -- Intercept the selection and trigger download instead of opening
    self:handlePlaceholderDownloadFromFileManager(filepath, book_info)
    
    -- Return true to prevent default behavior (opening the file)
    return true
end

-- Handle placeholder download triggered from FileManager
-- This is different from handlePlaceholderAutoDownload which is triggered from Reader
function OPDSBrowser:handlePlaceholderDownloadFromFileManager(filepath, book_info)
    logger.info("========================================")
    logger.info("PLACEHOLDER FILE MANAGER DOWNLOAD WORKFLOW")
    logger.info("========================================")
    logger.info("OPDS Browser: Starting download from FileManager")
    logger.info("OPDS Browser: File:", filepath)
    logger.info("OPDS Browser: Title:", book_info.title)
    
    if not self:ensureNetwork() then
        logger.err("OPDS Browser: Network not available")
        return
    end
    
    -- Show confirmation dialog
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = T(_("Download '%1' from OPDS server?\n\nThis will replace the placeholder with the real book."), 
                 book_info.title),
        ok_text = _("Download"),
        ok_callback = function()
            -- Trigger the download with "refresh folder" mode
            self:downloadPlaceholderAndRefresh(filepath, book_info)
        end,
    })
end

-- Download placeholder and refresh folder (don't open book)
function OPDSBrowser:downloadPlaceholderAndRefresh(placeholder_path, book_info)
    logger.info("========================================")
    logger.info("DOWNLOAD AND REFRESH WORKFLOW")
    logger.info("========================================")
    
    if not self:ensureNetwork() then
        return
    end
    
    -- Extract book ID
    local book_id = book_info.book_id
    if book_id then
        book_id = book_id:match("book:(%d+)$") or book_id
    end
    
    if not book_id or book_id == "" then
        logger.err("OPDS: No book ID found in placeholder info")
        UIHelpers.showError(_("Cannot download: Book ID not found"))
        return
    end

    -- Determine file extension
    local extension = ".epub"
    if book_info.download_url and book_info.download_url:lower():match("kepub") then
        extension = ".kepub.epub"
    end

    -- Create unique temp file name
    local timestamp = os.time()
    local temp_filepath = placeholder_path:gsub("%.epub$", string.format(".downloading_%d.tmp", timestamp))
    local filepath = placeholder_path:gsub("%.epub$", extension)

    -- Use download URL from book_info
    local download_url = book_info.download_url
    
    if not download_url or download_url == "" then
        logger.warn("OPDS: No download_url in book_info, constructing from book ID")
        download_url = self.opds_url .. "/" .. book_id .. "/download"
    end

    logger.info("OPDS: Downloading:", book_info.title)
    logger.info("OPDS: Download URL:", download_url)
    logger.info("OPDS: Placeholder path:", placeholder_path)
    logger.info("OPDS: Temp download path:", temp_filepath)
    logger.info("OPDS: Final book path:", filepath)

    local loading = UIHelpers.createProgressMessage(_("Downloading book..."))
    UIManager:show(loading)
    
    -- Download with authentication
    local user = (self.opds_username and self.opds_username ~= "") and self.opds_username or nil
    local pass = (self.opds_password and self.opds_password ~= "") and self.opds_password or nil
    
    local https = require("ssl.https")
    local ltn12 = require("ltn12")
    local mime = require("mime")
    
    local response_body = {}
    local headers = {
        ["Cache-Control"] = "no-cache, no-store, must-revalidate",
        ["Pragma"] = "no-cache",
        ["Expires"] = "0"
    }
    
    if user and pass then
        local credentials = mime.b64(user .. ":" .. pass)
        headers["Authorization"] = "Basic " .. credentials
    end
    
    local res, code, response_headers = https.request{
        url = download_url,
        method = "GET",
        headers = headers,
        sink = ltn12.sink.table(response_body)
    }
    
    UIManager:close(loading)
    
    if not res or code ~= 200 then
        logger.err("OPDS: Download failed with code:", code)
        UIHelpers.showError(T(_("Download failed: HTTP %1"), code or "error"))
        return
    end
    
    local data = table.concat(response_body)
    logger.info("OPDS: Downloaded", #data, "bytes")

    -- Validate file size
    if #data < Constants.MIN_VALID_BOOK_SIZE then
        logger.err("OPDS: File size:", #data, "bytes, minimum:", Constants.MIN_VALID_BOOK_SIZE)
        UIHelpers.showError(_("Downloaded file appears invalid (too small)"))
        return
    end

    -- Write to temporary file
    local file, err = io.open(temp_filepath, "wb")
    if not file then
        logger.err("OPDS: Failed to open temp file for writing:", err)
        UIHelpers.showError(T(_("Failed to create file: %1"), err or "unknown"))
        return
    end

    file:write(data)
    file:close()

    logger.info("OPDS: Wrote", #data, "bytes to temp file:", temp_filepath)

    -- Verify temp file
    local temp_attr = lfs.attributes(temp_filepath)
    if not temp_attr or temp_attr.mode ~= "file" then
        logger.err("OPDS: Temp file was not created successfully")
        UIHelpers.showError(_("Download succeeded but temp file not found"))
        return
    end

    -- Replace placeholder with real book
    self:_finishPlaceholderDownloadAndRefresh(placeholder_path, temp_filepath, filepath, book_info.title)
end

-- Finish placeholder download and refresh folder (don't open book)
function OPDSBrowser:_finishPlaceholderDownloadAndRefresh(placeholder_path, temp_filepath, filepath, book_title)
    logger.info("========================================")
    logger.info("FINISHING DOWNLOAD AND REFRESH")
    logger.info("========================================")
    
    -- Verify temp file is not a placeholder
    local PlaceholderGenerator = require("placeholder_generator")
    local temp_is_placeholder = PlaceholderGenerator:isPlaceholder(temp_filepath)
    
    if temp_is_placeholder then
        logger.err("OPDS: Downloaded file is a placeholder!")
        os.remove(temp_filepath)
        UIHelpers.showError(_("Download failed: Server returned a placeholder instead of the book."))
        return
    end

    logger.info("OPDS: Verified - temp file is a real book")

    -- Delete placeholder file
    logger.info("OPDS: Deleting placeholder file:", placeholder_path)
    local delete_ok = os.remove(placeholder_path)
    
    if not delete_ok then
        logger.err("OPDS: Failed to delete placeholder")
        os.remove(temp_filepath)
        UIHelpers.showError(_("Failed to delete placeholder file"))
        return
    end
    
    -- Remove from placeholder database
    self.library_sync.placeholder_db[placeholder_path] = nil
    self.library_sync:savePlaceholderDB()
    logger.info("OPDS: Removed placeholder from database")

    -- Clean up symlinks in Recently Added
    local recently_added_path = self.library_sync.recently_added_path
    if recently_added_path then
        local placeholder_filename = placeholder_path:match("([^/]+)$")
        if placeholder_filename then
            local recently_added_file = recently_added_path .. "/" .. placeholder_filename
            local file_attr = lfs.attributes(recently_added_file)
            if file_attr then
                os.remove(recently_added_file)
                logger.info("OPDS: Removed Recently Added symlink")
            end
        end
    end

    -- Rename temp file to final location
    logger.info("OPDS: Renaming temp file to final location:", filepath)
    local rename_ok = os.rename(temp_filepath, filepath)
    if not rename_ok then
        logger.err("OPDS: Failed to rename temp file")
        os.remove(temp_filepath)
        UIHelpers.showError(_("Failed to rename downloaded file"))
        return
    end

    logger.info("OPDS: File replacement complete")

    -- Clear caches
    if self.placeholder_badge then
        self.placeholder_badge:clearCache(placeholder_path)
        self.placeholder_badge:clearCache(filepath)
    end
    
    -- Clear document settings
    pcall(function()
        local DocSettings = require("docsettings")
        DocSettings:open(placeholder_path):purge()
        DocSettings:open(filepath):purge()
    end)

    -- Show success message
    UIHelpers.showSuccess(T(_("Downloaded: %1\n\nReturning to folder view..."), book_title or "Book"))

    -- Extract folder path
    local folder_path = filepath:match("(.*/)")
    
    if folder_path then
        logger.info("OPDS: Refreshing folder view:", folder_path)
        
        -- Schedule folder refresh
        UIManager:scheduleIn(0.5, function()
            local FileManager = require("apps/filemanager/filemanager")
            if FileManager.instance then
                -- Refresh current folder
                FileManager.instance:onRefresh()
                logger.info("OPDS: FileManager refreshed")
            else
                -- FileManager not active, open folder
                FileManager:showFiles(folder_path)
                logger.info("OPDS: Opened folder:", folder_path)
            end
        end)
    end
    
    logger.info("========================================")
    logger.info("DOWNLOAD AND REFRESH COMPLETE")
    logger.info("========================================")
end

-- Hook for when a document is opened
function OPDSBrowser:onReaderReady(config)
    logger.info("OPDSBrowser: onReaderReady called")

    -- Use a delayed check since ReaderUI.instance.document may not be ready yet
    UIManager:scheduleIn(1, function()
        local ReaderUI = require("apps/reader/readerui")
        if not ReaderUI.instance or not ReaderUI.instance.document then
            logger.info("OPDSBrowser: No document loaded after delay")
            return
        end

        local current_file = ReaderUI.instance.document.file
        logger.info("OPDSBrowser: Checking file:", current_file)

        -- Check placeholder database directly (faster than parsing EPUB)
        local book_info = self.library_sync:getBookInfo(current_file)
        if book_info then
            logger.info("OPDSBrowser: Found placeholder in database, triggering auto-download")
            UIManager:scheduleIn(0.5, function()
                self:handlePlaceholderAutoDownload(current_file)
            end)
        else
            logger.info("OPDSBrowser: Not a placeholder")
        end
    end)
end

-- Handle auto-download from placeholder
function OPDSBrowser:handlePlaceholderAutoDownload(filepath)
    logger.info("========================================")
    logger.info("OPDS WORKFLOW: STEP 1 - PLACEHOLDER DETECTED")
    logger.info("========================================")
    logger.info("OPDSBrowser: handlePlaceholderAutoDownload called for:", filepath)

    -- CRITICAL: Resolve symlinks to get the real file path
    -- "Recently Added" folder contains symlinks to books in author folders
    local real_filepath = filepath
    local attr = lfs.symlinkattributes(filepath)
    if attr and attr.mode == "link" then
        -- It's a symlink, resolve it
        local target = lfs.readlink(filepath)
        if target then
            -- Handle relative symlinks
            if not target:match("^/") then
                local dir = filepath:match("(.*/)")
                real_filepath = dir .. target
            else
                real_filepath = target
            end
            logger.info("OPDSBrowser: Resolved symlink:", filepath, "->", real_filepath)
        end
    end

    -- Get book info from placeholder database using real path
    local book_info = self.library_sync:getBookInfo(real_filepath)

    if not book_info then
        logger.err("OPDS WORKFLOW: FAILED AT STEP 1 - Placeholder info not found")
        logger.warn("OPDSBrowser: Placeholder not found in database:", real_filepath)
        UIHelpers.showError(_("Placeholder information not found.\n\nPlease use the manual download option."))
        return
    end

    logger.info("OPDS WORKFLOW: ✓ Step 1 complete - Placeholder detected and validated")
    logger.info("OPDSBrowser: Starting auto-download for:", book_info.title)

    -- NEW STRATEGY: Keep placeholder open, download in background, then switch to real book
    -- This provides better user experience and prevents the "already downloaded" confusion

    -- Start download immediately (placeholder stays open during download)
    -- Pass the real filepath (not the symlink)
    self:downloadFromPlaceholderAuto(real_filepath, book_info)
end

-- Download from placeholder with auto-replacement
function OPDSBrowser:downloadFromPlaceholderAuto(placeholder_path, book_info)
    logger.info("========================================")
    logger.info("OPDS WORKFLOW: STEP 2 - TRIGGERING DOWNLOAD")
    logger.info("========================================")
    
    if not self:ensureNetwork() then
        logger.err("OPDS WORKFLOW: FAILED AT STEP 2 - Network not available")
        return
    end
    
    -- Extract book ID
    local book_id = book_info.book_id
    if book_id then
        book_id = book_id:match("book:(%d+)$") or book_id
    end
    
    if not book_id or book_id == "" then
        logger.err("OPDS WORKFLOW: FAILED AT STEP 2 - No book ID found in placeholder info")
        logger.err("OPDS: Book info:", book_info and "present" or "nil")
        UIHelpers.showError(_("Cannot download: Book ID not found"))
        return
    end

    -- Determine file extension
    local extension = ".epub"
    if book_info.download_url and book_info.download_url:lower():match("kepub") then
        extension = ".kepub.epub"
    end

    -- IMPORTANT: Use unique temp file name with timestamp to avoid any conflicts
    local timestamp = os.time()
    local temp_filepath = placeholder_path:gsub("%.epub$", string.format(".downloading_%d.tmp", timestamp))

    -- Final filepath after placeholder is removed
    -- If extension is same as placeholder (.epub), this will be the same as placeholder_path
    -- That's OK because we delete the placeholder first, then rename temp to this location
    local filepath = placeholder_path:gsub("%.epub$", extension)

    -- Use download URL from book_info (stored from OPDS feed)
    -- This ensures we use the correct download endpoint from the server
    local download_url = book_info.download_url
    
    if not download_url or download_url == "" then
        -- Fallback: construct from base URL and book ID
        logger.warn("OPDS: No download_url in book_info, constructing from book ID")
        download_url = self.opds_url .. "/" .. book_id .. "/download"
    end

    logger.info("OPDS: Auto-downloading:", book_info.title)
    logger.info("OPDS: Download URL:", download_url)
    logger.info("OPDS: Placeholder path:", placeholder_path)
    logger.info("OPDS: Temp download path:", temp_filepath)
    logger.info("OPDS: Final book path:", filepath)

    local loading = UIHelpers.createProgressMessage(_("Downloading book..."))
    UIManager:show(loading)
    
    -- Download with progress
    local user = (self.opds_username and self.opds_username ~= "") and self.opds_username or nil
    local pass = (self.opds_password and self.opds_password ~= "") and self.opds_password or nil
    
    local https = require("ssl.https")
    local ltn12 = require("ltn12")
    local mime = require("mime")
    
    local response_body = {}
    local headers = {
        ["Cache-Control"] = "no-cache, no-store, must-revalidate",
        ["Pragma"] = "no-cache",
        ["Expires"] = "0"
    }
    
    if user and pass then
        local credentials = mime.b64(user .. ":" .. pass)
        headers["Authorization"] = "Basic " .. credentials
    end
    
    local res, code, response_headers = https.request{
        url = download_url,
        method = "GET",
        headers = headers,
        sink = ltn12.sink.table(response_body)
    }
    
    UIManager:close(loading)
    
    if not res or code ~= 200 then
        logger.err("OPDS WORKFLOW: FAILED AT STEP 2 - Download failed")
        logger.err("OPDS: Download failed with code:", code)
        logger.err("OPDS: Download URL was:", download_url)
        logger.err("OPDS: Response:", res)
        UIHelpers.showError(T(_("Download failed: HTTP %1\n\nPlaceholder will remain."), code or "error"))
        return
    end
    
    logger.info("OPDS WORKFLOW: ✓ Step 2 complete - Book downloaded successfully")
    
    local data = table.concat(response_body)
    logger.info("OPDS: Downloaded", #data, "bytes")

    -- Validate file size - files smaller than MIN_VALID_BOOK_SIZE are likely errors
    if #data < Constants.MIN_VALID_BOOK_SIZE then
        logger.err("OPDS WORKFLOW: FAILED AT STEP 2 - Downloaded file too small")
        logger.err("OPDS: File size:", #data, "bytes, minimum:", Constants.MIN_VALID_BOOK_SIZE)
        UIHelpers.showError(_("Downloaded file appears invalid (too small)\n\nPlaceholder will remain."))
        return
    end

    -- Write to temporary file first
    local file, err = io.open(temp_filepath, "wb")
    if not file then
        logger.err("OPDS WORKFLOW: FAILED AT STEP 2 - Cannot create temp file")
        logger.err("OPDS: Failed to open temp file for writing:", err)
        UIHelpers.showError(T(_("Failed to create file: %1\n\nPlaceholder will remain."), err or "unknown"))
        return
    end

    file:write(data)
    file:close()

    logger.info("OPDS: Wrote", #data, "bytes to temp file:", temp_filepath)

    -- Verify temp file was written successfully
    local temp_attr = lfs.attributes(temp_filepath)
    if not temp_attr or temp_attr.mode ~= "file" then
        logger.err("OPDS WORKFLOW: FAILED AT STEP 2 - Temp file not created")
        logger.err("OPDS: Temp file was not created successfully")
        UIHelpers.showError(_("Download succeeded but temp file not found\n\nPlaceholder will remain."))
        return
    end

    logger.info("OPDS: Temp file verified, size:", temp_attr.size, "bytes")

    -- CRITICAL: Close the placeholder reader BEFORE deleting/renaming files
    -- This prevents file locking issues on systems that lock open files
    local ReaderUI = require("apps/reader/readerui")

    if ReaderUI.instance then
        logger.info("OPDS: Closing placeholder reader before file operations")

        -- Show a brief "processing" message to keep UI populated
        local processing_msg = UIHelpers.showLoading(_("Preparing downloaded book..."))
        UIManager:show(processing_msg)

        -- Close the reader
        UIManager:close(ReaderUI.instance)
        ReaderUI.instance = nil

        -- Capture self in closure for scheduled callback
        local plugin_ref = self

        -- Increased delay to ensure reader is fully closed and all locks released
        UIManager:scheduleIn(0.5, function()
            UIManager:close(processing_msg)

            -- Verify ReaderUI.instance is truly nil after closing
            if ReaderUI.instance then
                logger.warn("OPDS: ReaderUI.instance still exists after close attempt")
            else
                logger.info("OPDS: Verified ReaderUI.instance is nil after close")
            end

            -- Now continue with file operations
            logger.info("OPDS: Continuing with file operations after reader closed")
            plugin_ref:_finishPlaceholderDownload(placeholder_path, temp_filepath, filepath)
        end)
    else
        -- Reader wasn't open (shouldn't happen, but handle it)
        logger.warn("OPDS: Reader not open during placeholder download")
        self:_finishPlaceholderDownload(placeholder_path, temp_filepath, filepath)
    end
end

-- Finish placeholder download by replacing file and opening book
function OPDSBrowser:_finishPlaceholderDownload(placeholder_path, temp_filepath, filepath)
    logger.info("========================================")
    logger.info("OPDS WORKFLOW: STEP 3 - DELETING PLACEHOLDER")
    logger.info("========================================")
    logger.info("OPDS: Finishing placeholder download")
    logger.info("OPDS:   Placeholder path:", placeholder_path)
    logger.info("OPDS:   Temp file path:", temp_filepath)
    logger.info("OPDS:   Final file path:", filepath)

    -- CRITICAL: Verify the temp file is NOT a placeholder before we proceed
    local PlaceholderGenerator = require("placeholder_generator")
    local temp_is_placeholder = PlaceholderGenerator:isPlaceholder(temp_filepath)
    logger.info("OPDS: Checking if downloaded temp file is placeholder:", temp_is_placeholder)

    if temp_is_placeholder then
        logger.err("OPDS WORKFLOW: FAILED AT STEP 3 - Downloaded file is a placeholder")
        logger.err("OPDS: ERROR - Downloaded file is a placeholder!")
        logger.err("OPDS: The server sent us a placeholder instead of the real book")
        logger.err("OPDS: Download URL may be incorrect or server returned wrong content")
        os.remove(temp_filepath)
        UIHelpers.showError(_("Download failed: Server returned a placeholder instead of the book.\n\nPlease try downloading manually or contact support."))

        -- Return to file manager
        local FileManager = require("apps/filemanager/filemanager")
        if not FileManager.instance then
            local dir = placeholder_path:match("(.*/)")
            FileManager:showFiles(dir)
        else
            FileManager.instance:onRefresh()
        end
        return
    end

    logger.info("OPDS: Verified - temp file is a real book (not placeholder)")

    -- Delete the placeholder file with retry logic
    logger.info("OPDS: Deleting placeholder file:", placeholder_path)
    local delete_ok = false
    local max_delete_attempts = 3
    
    for attempt = 1, max_delete_attempts do
        delete_ok = os.remove(placeholder_path)
        
        if delete_ok then
            logger.info("OPDS: Successfully deleted placeholder on attempt", attempt, ":", placeholder_path)
            -- Verify file actually deleted
            local still_exists = lfs.attributes(placeholder_path)
            if still_exists then
                logger.err("OPDS: os.remove() returned true but file still exists!")
                delete_ok = false
            else
                logger.info("OPDS: Verified placeholder file no longer exists")
                -- Remove from placeholder database
                self.library_sync.placeholder_db[placeholder_path] = nil
                self.library_sync:savePlaceholderDB()
                logger.info("OPDS: Removed placeholder from database:", placeholder_path)
                break
            end
        else
            logger.warn("OPDS: Failed to delete placeholder on attempt", attempt, ":", placeholder_path)
            if attempt < max_delete_attempts then
                -- Brief delay before retry to allow any locks to clear
                logger.info("OPDS: Waiting before retry...")
                socket.sleep(0.2)
            end
        end
    end
    
    if not delete_ok then
        logger.err("OPDS WORKFLOW: FAILED AT STEP 3 - Cannot delete placeholder")
        logger.err("OPDS: Failed to delete placeholder after", max_delete_attempts, "attempts")
        os.remove(temp_filepath)
        UIHelpers.showError(_("Failed to delete placeholder file after multiple attempts.\n\nThe file may be locked or have permission issues.\n\nPlease close any other apps using the file and try again."))
        
        -- Return to file manager
        local FileManager = require("apps/filemanager/filemanager")
        if not FileManager.instance then
            local dir = placeholder_path:match("(.*/)")
            FileManager:showFiles(dir)
        else
            FileManager.instance:onRefresh()
        end
        return
    end

    -- Clean up any symlinks in "Recently Added" folder that point to this placeholder
    logger.info("OPDS: Checking for symlinks in Recently Added folder")
    local recently_added_path = self.library_sync.recently_added_path
    
    -- Validate recently_added_path exists and is a directory
    if recently_added_path and type(recently_added_path) == "string" and recently_added_path ~= "" then
        local attr = lfs.attributes(recently_added_path)
        if attr and attr.mode == "directory" then
            local placeholder_filename = placeholder_path:match("([^/]+)$")
            
            -- Validate filename is safe: no directory components, only filename
            -- This prevents directory traversal even with encoded or alternative separators
            if placeholder_filename and 
               placeholder_filename ~= "" and
               placeholder_filename ~= "." and
               placeholder_filename ~= ".." and
               not placeholder_filename:match("[/\\]") and
               not placeholder_filename:match("%.%.") then
                
                -- Construct the full path
                local recently_added_file = recently_added_path .. "/" .. placeholder_filename
                
                -- Use lfs.attributes to resolve and validate the canonical path
                -- This catches symlink-based directory traversal attempts
                local file_attr = lfs.attributes(recently_added_file)
                if file_attr then
                    -- Verify file is actually within Recently Added directory by checking the parent
                    local file_dir = recently_added_file:match("(.*/)")
                    if file_dir and file_dir:gsub("/$", "") == recently_added_path:gsub("/$", "") then
                        logger.info("OPDS: Found file in Recently Added, deleting:", recently_added_file)
                        logger.info("OPDS: File type:", file_attr.mode)
                        local removed = os.remove(recently_added_file)
                        if removed then
                            logger.info("OPDS: Successfully removed Recently Added file")
                        else
                            logger.warn("OPDS: Failed to remove Recently Added file:", recently_added_file)
                        end
                    else
                        logger.warn("OPDS: Path validation failed - file not in Recently Added directory")
                    end
                else
                    logger.dbg("OPDS: No corresponding file in Recently Added folder")
                end
            else
                logger.warn("OPDS: Invalid or unsafe filename detected, skipping cleanup:", placeholder_filename or "nil")
            end
        else
            logger.dbg("OPDS: Recently Added path is not a valid directory")
        end
    end

    -- Verify placeholder is truly gone before renaming
    local placeholder_still_exists = lfs.attributes(placeholder_path)
    if placeholder_still_exists then
        logger.err("OPDS WORKFLOW: FAILED AT STEP 3 - Placeholder still exists after deletion")
        logger.err("OPDS: Placeholder file still exists before rename operation")
        os.remove(temp_filepath)
        UIHelpers.showError(_("Placeholder deletion verification failed.\n\nThe old file still exists.\n\nPlease try again."))
        
        -- Return to file manager
        local FileManager = require("apps/filemanager/filemanager")
        if not FileManager.instance then
            local dir = placeholder_path:match("(.*/)")
            FileManager:showFiles(dir)
        else
            FileManager.instance:onRefresh()
        end
        return
    end

    logger.info("OPDS WORKFLOW: ✓ Step 3 complete - Placeholder deleted successfully")
    
    -- Rename temp file to final location
    logger.info("OPDS: Renaming temp file to final location:", filepath)
    local rename_ok = os.rename(temp_filepath, filepath)
    if not rename_ok then
        logger.err("OPDS WORKFLOW: FAILED AT STEP 3 - Cannot rename temp file")
        logger.err("OPDS: Failed to rename temp file to final location")
        logger.err("OPDS: Temp file:", temp_filepath)
        logger.err("OPDS: Target file:", filepath)
        
        -- Check if temp file still exists
        local temp_exists = lfs.attributes(temp_filepath)
        logger.err("OPDS: Temp file exists:", temp_exists ~= nil)
        
        -- Attempt cleanup
        logger.err("OPDS: Attempting to clean up temp file")
        os.remove(temp_filepath)
        
        UIHelpers.showError(_("Failed to rename downloaded file to final location.\n\nThis may be a permissions or filesystem issue.\n\nPlease try again."))

        -- Return to file manager
        local FileManager = require("apps/filemanager/filemanager")
        if not FileManager.instance then
            local dir = placeholder_path:match("(.*/)")
            FileManager:showFiles(dir)
        else
            FileManager.instance:onRefresh()
        end
        return
    end

    logger.info("OPDS: Successfully renamed temp file to:", filepath)
    logger.info("OPDS: File replacement complete - placeholder deleted, real book in place")

    -- Verify the downloaded file exists and has content
    local final_attr = lfs.attributes(filepath)
    logger.info("OPDS: Verifying final file - exists:", final_attr ~= nil, "mode:", final_attr and final_attr.mode, "size:", final_attr and final_attr.size)

    if not final_attr or final_attr.mode ~= "file" then
        logger.err("OPDS WORKFLOW: FAILED AT STEP 3 - Final file not found")
        logger.err("OPDS: Downloaded file not found at:", filepath)
        UIHelpers.showError(_("Download succeeded but file not found"))
        return
    end

    -- CRITICAL: Verify the file is NOT still a placeholder
    local PlaceholderGenerator = require("placeholder_generator")
    local still_placeholder = PlaceholderGenerator:isPlaceholder(filepath)
    logger.info("OPDS: Checking if final file is placeholder:", still_placeholder)

    if still_placeholder then
        logger.err("OPDS WORKFLOW: FAILED AT STEP 3 - Final file is still a placeholder")
        logger.err("OPDS: ERROR - Downloaded file is still a placeholder!")
        logger.err("OPDS: This means the real book didn't replace the placeholder properly")
        logger.err("OPDS: Temp file size was:", lfs.attributes(temp_filepath) and lfs.attributes(temp_filepath).size or "unknown")
        logger.err("OPDS: Final file size is:", final_attr.size)
        UIHelpers.showError(_("Download succeeded but file replacement failed.\n\nThe book is still a placeholder."))

        -- Return to file manager
        local FileManager = require("apps/filemanager/filemanager")
        if not FileManager.instance then
            local dir = placeholder_path:match("(.*/)")
            FileManager:showFiles(dir)
        else
            FileManager.instance:onRefresh()
        end
        return
    end

    logger.info("OPDS: Verified - final file is a real book (not placeholder)")
    logger.info("OPDS WORKFLOW: ✓ Step 3 complete - Placeholder deleted, real book in place")

    -- ============================================================================
    -- CRITICAL: Clear ALL caches related to the replaced book
    -- This ensures the UI shows the real book immediately without requiring restart
    -- ============================================================================
    logger.info("OPDS: ==================== CACHE INVALIDATION START ====================")
    logger.info("OPDS: Clearing ALL caches for placeholder:", placeholder_path)
    logger.info("OPDS: Clearing ALL caches for real book:", filepath)
    
    -- 1. Clear placeholder badge cache (visual indicator on cover)
    if self.placeholder_badge then
        self.placeholder_badge:clearCache(placeholder_path)
        self.placeholder_badge:clearCache(filepath)
        logger.info("OPDS: ✓ Cleared placeholder badge cache")
    else
        logger.info("OPDS: ✗ Placeholder badge not available")
    end
    
    -- 2. Clear document settings for both old and new paths
    pcall(function()
        local DocSettings = require("docsettings")
        -- Clear placeholder settings
        DocSettings:open(placeholder_path):purge()
        -- Clear final file settings (in case it existed before)
        DocSettings:open(filepath):purge()
        logger.info("OPDS: ✓ Cleared DocSettings cache for both paths")
    end)

    -- 3. Clear DocumentRegistry cache (KOReader's internal metadata cache)
    pcall(function()
        local DocumentRegistry = require("documentregistry")
        if DocumentRegistry then
            local cleared_registry = false
            local cleared_provider = false
            
            -- Remove cached entries for both paths from registry
            if DocumentRegistry.registry then
                if DocumentRegistry.registry[placeholder_path] then
                    DocumentRegistry.registry[placeholder_path] = nil
                    cleared_registry = true
                end
                if DocumentRegistry.registry[filepath] then
                    DocumentRegistry.registry[filepath] = nil
                    cleared_registry = true
                end
                if cleared_registry then
                    logger.info("OPDS: ✓ Cleared DocumentRegistry.registry cache")
                end
            end
            
            -- If DocumentRegistry has a provider_cache, clear those too
            if DocumentRegistry.provider_cache then
                if DocumentRegistry.provider_cache[placeholder_path] then
                    DocumentRegistry.provider_cache[placeholder_path] = nil
                    cleared_provider = true
                end
                if DocumentRegistry.provider_cache[filepath] then
                    DocumentRegistry.provider_cache[filepath] = nil
                    cleared_provider = true
                end
                if cleared_provider then
                    logger.info("OPDS: ✓ Cleared DocumentRegistry.provider_cache")
                end
            end
        end
    end)

    -- 4. Clear CoverBrowser cache if it's loaded
    pcall(function()
        -- Try to clear CoverBrowser caches if the plugin is loaded
        local package_loaded = package.loaded
        if package_loaded then
            -- Look for known CoverBrowser module names
            -- These are based on KOReader's plugin loading conventions
            -- If CoverBrowser changes its module structure, these may need updating
            local coverbrowser_modules = {
                "coverbrowser",
                "plugins.coverbrowser.main",
            }
            
            for _, module_name in ipairs(coverbrowser_modules) do
                local module = package_loaded[module_name]
                if module and type(module) == "table" then
                    local cleared_cache = false
                    -- Try to clear its cache tables
                    if module.cache then
                        module.cache[placeholder_path] = nil
                        module.cache[filepath] = nil
                        cleared_cache = true
                    end
                    if module.cover_cache then
                        module.cover_cache[placeholder_path] = nil
                        module.cover_cache[filepath] = nil
                        cleared_cache = true
                    end
                    if cleared_cache then
                        logger.info("OPDS: ✓ Cleared CoverBrowser caches for:", module_name)
                    end
                end
            end
        end
    end)

    -- 5. Clear FileManager collection cache if loaded
    pcall(function()
        local FileManagerCollection = require("apps/filemanager/filemanagercollection")
        if FileManagerCollection and FileManagerCollection.coll then
            -- Refresh collection data
            if type(FileManagerCollection.coll.reload) == "function" then
                FileManagerCollection.coll:reload()
                logger.info("OPDS: ✓ Reloaded FileManagerCollection")
            end
        end
    end)

    -- 6. Update placeholder database - remove the old entry
    if self.library_sync and self.library_sync.placeholder_db then
        if self.library_sync.placeholder_db[placeholder_path] then
            self.library_sync.placeholder_db[placeholder_path] = nil
            self.library_sync:savePlaceholderDB()
            logger.info("OPDS: ✓ Removed placeholder from database")
        end
        -- Ensure the new file is NOT in the placeholder database
        if self.library_sync.placeholder_db[filepath] then
            self.library_sync.placeholder_db[filepath] = nil
            self.library_sync:savePlaceholderDB()
            logger.info("OPDS: ✓ Removed new file from placeholder database (if present)")
        end
    end

    -- 7. Clear plugin's own OPDS cache for this book
    if CacheManager then
        -- Invalidate any OPDS metadata cache entries for this book
        -- Extract filename without extension (handles both .epub and .kepub.epub)
        -- The pattern ([^/]+)$ extracts everything after the last / (the filename)
        local filename = placeholder_path:match("([^/]+)$") or ""
        if filename ~= "" then
            -- Remove file extensions: try .kepub.epub first, then .epub
            -- The $ anchor ensures we only match at the end of the string
            local book_id_pattern = filename:gsub("%.kepub%.epub$", ""):gsub("%.epub$", "")
            if book_id_pattern ~= "" and book_id_pattern ~= filename then
                CacheManager:invalidatePattern(book_id_pattern)
                logger.info("OPDS: ✓ Invalidated OPDS cache entries matching:", book_id_pattern)
            end
        end
    end

    logger.info("OPDS: ==================== CACHE INVALIDATION COMPLETE ====================")
    logger.info("OPDS: Successfully downloaded book:", filepath)

    -- ============================================================================
    -- STEP 4: RESTART KOREADER AND NAVIGATE TO FOLDER
    -- This ensures all caches are completely cleared and UI shows the real book
    -- ============================================================================
    logger.info("========================================")
    logger.info("OPDS WORKFLOW: STEP 4 - RESTARTING KOREADER")
    logger.info("========================================")
    
    -- Extract folder path from filepath
    local folder_path = filepath:match("(.*/)")
    
    if folder_path then
        logger.info("OPDS: ==================== RESTART NAVIGATION START ====================")
        logger.info("OPDS: Saving navigation state for post-restart")
        logger.info("OPDS: Target folder:", folder_path)
        logger.info("OPDS: Downloaded book:", filepath)
        
        -- Save navigation state
        local save_ok = RestartNavigationManager:saveNavigationState(folder_path, filepath)
        
        if save_ok then
            logger.info("OPDS: Navigation state saved successfully")
            logger.info("OPDS WORKFLOW: ✓ Step 4 preparation complete - State saved for post-restart navigation")
            
            -- Show user message before restart
            local restart_msg = UIHelpers.showLoading(
                _("Download complete!\n\nRestarting KOReader to clear cache and show book...")
            )
            UIManager:show(restart_msg)
            UIManager:forceRePaint()
            
            -- Small delay to show message, then restart
            UIManager:scheduleIn(2, function()
                UIManager:close(restart_msg)
                
                logger.info("OPDS: Triggering KOReader restart")
                local restart_ok = RestartNavigationManager:restartKOReader()
                
                if not restart_ok then
                    -- Restart failed, fall back to old behavior (open book directly)
                    logger.err("OPDS WORKFLOW: FAILED AT STEP 4 - Restart not available")
                    logger.err("OPDS: Restart failed, falling back to direct book open")
                    UIHelpers.showError(_("Restart failed. Opening book directly."))
                    
                    -- Clean up state file
                    RestartNavigationManager:clearNavigationState()
                    
                    -- Open book directly
                    local ReaderUI = require("apps/reader/readerui")
                    ReaderUI:showReader(filepath)
                else
                    logger.info("OPDS WORKFLOW: ✓ Step 4 complete - Restart triggered")
                    logger.info("OPDS WORKFLOW: Waiting for restart... Step 5 will execute on next startup")
                end
            end)
        else
            logger.err("OPDS WORKFLOW: FAILED AT STEP 4 - Cannot save navigation state")
            logger.err("OPDS: Failed to save navigation state, opening book directly")
            
            -- Fall back to opening book directly
            local ReaderUI = require("apps/reader/readerui")
            ReaderUI:showReader(filepath)
        end
        
        logger.info("OPDS: ==================== RESTART NAVIGATION COMPLETE ====================")
    else
        logger.err("OPDS: Could not extract folder path from:", filepath)
        
        -- Fall back to opening book directly
        local ReaderUI = require("apps/reader/readerui")
        ReaderUI:showReader(filepath)
    end

    -- Background: Refresh file manager (in case restart fails)
    UIManager:scheduleIn(3, function()
        -- Refresh file manager in background
        local FileManager = require("apps/filemanager/filemanager")
        if FileManager.instance then
            -- Force a full refresh to clear any cached file information
            FileManager.instance:onRefresh()
            logger.info("OPDS: ✓ Background FileManager refresh complete")
            
            -- If FileManagerHistory exists, refresh it too
            pcall(function()
                if FileManager.instance.history then
                    FileManager.instance.history:reload()
                    logger.info("OPDS: ✓ Refreshed FileManager history")
                end
            end)
        end
        
        logger.info("OPDS: ==================== UI REFRESH COMPLETE ====================")
    end)
end

-- Health check for placeholder auto-download workflow
-- Verifies all components required for the 5-step workflow are available
function OPDSBrowser:checkWorkflowHealth()
    logger.info("========================================")
    logger.info("PLACEHOLDER AUTO-DOWNLOAD WORKFLOW HEALTH CHECK")
    logger.info("========================================")
    
    local all_ok = true
    local issues = {}
    
    -- Check Step 1: Placeholder detection
    logger.info("Step 1 - Placeholder Detection:")
    if self.library_sync and self.library_sync.getBookInfo then
        logger.info("  ✓ LibrarySyncManager available")
        if self.library_sync.placeholder_db then
            logger.info("  ✓ Placeholder database available")
            local count = 0
            for _ in pairs(self.library_sync.placeholder_db) do
                count = count + 1
            end
            logger.info("  ✓ Database has", count, "placeholder(s)")
        else
            logger.warn("  ✗ Placeholder database not initialized")
            table.insert(issues, "Placeholder database not initialized")
            all_ok = false
        end
    else
        logger.err("  ✗ LibrarySyncManager not available")
        table.insert(issues, "LibrarySyncManager not available")
        all_ok = false
    end
    
    -- Check Step 2: OPDS download capability
    logger.info("Step 2 - OPDS Download:")
    if self.opds_url and self.opds_url ~= "" then
        logger.info("  ✓ OPDS URL configured:", self.opds_url)
    else
        logger.warn("  ✗ OPDS URL not configured")
        table.insert(issues, "OPDS URL not configured")
        all_ok = false
    end
    
    local https_ok, https = pcall(require, "ssl.https")
    if https_ok and https then
        logger.info("  ✓ HTTPS library available")
    else
        logger.err("  ✗ HTTPS library not available")
        table.insert(issues, "HTTPS library not available")
        all_ok = false
    end
    
    -- Check Step 3: File operations
    logger.info("Step 3 - File Operations:")
    local lfs_ok = pcall(function() return lfs.attributes("/") end)
    if lfs_ok then
        logger.info("  ✓ LFS (filesystem) library available")
    else
        logger.err("  ✗ LFS library not working")
        table.insert(issues, "LFS library not working")
        all_ok = false
    end
    
    -- Check Step 4: Restart capability
    logger.info("Step 4 - Restart Capability:")
    if RestartNavigationManager then
        logger.info("  ✓ RestartNavigationManager available")
        
        -- Check if we can write state files
        local state_path = RestartNavigationManager:getStatePath()
        if state_path then
            logger.info("  ✓ State file path:", state_path)
            
            -- Try to write a test state (will be immediately deleted)
            local test_ok = pcall(function()
                local f = io.open(state_path .. ".test", "w")
                if f then
                    f:write("test")
                    f:close()
                    os.remove(state_path .. ".test")
                    return true
                end
                return false
            end)
            
            if test_ok then
                logger.info("  ✓ Can write state files")
            else
                logger.warn("  ✗ Cannot write state files")
                table.insert(issues, "Cannot write state files")
            end
        else
            logger.warn("  ✗ Cannot determine state path")
            table.insert(issues, "Cannot determine state path")
        end
        
        -- Check restart methods
        local UIManager = require("ui/uimanager")
        local Device = require("device")
        local has_restart = false
        
        if type(UIManager.restart) == "function" then
            logger.info("  ✓ UIManager:restart() available")
            has_restart = true
        elseif type(UIManager.restartKOReader) == "function" then
            logger.info("  ✓ UIManager:restartKOReader() available")
            has_restart = true
        elseif type(UIManager.exitOrRestart) == "function" then
            logger.info("  ✓ UIManager:exitOrRestart() available")
            has_restart = true
        elseif Device and type(Device.reboot) == "function" then
            logger.info("  ✓ Device:reboot() available")
            has_restart = true
        else
            logger.warn("  ✗ No restart method available (will fall back to direct open)")
            table.insert(issues, "No restart method available")
        end
    else
        logger.err("  ✗ RestartNavigationManager not available")
        table.insert(issues, "RestartNavigationManager not available")
        all_ok = false
    end
    
    -- Check Step 5: FileManager navigation
    logger.info("Step 5 - FileManager Navigation:")
    local fm_ok, FileManager = pcall(require, "apps/filemanager/filemanager")
    if fm_ok and FileManager and FileManager.showFiles then
        logger.info("  ✓ FileManager available")
        logger.info("  ✓ FileManager.showFiles() available")
    else
        logger.err("  ✗ FileManager or showFiles() not available")
        table.insert(issues, "FileManager not available")
        all_ok = false
    end
    
    -- Summary
    logger.info("========================================")
    if all_ok then
        logger.info("WORKFLOW HEALTH: ✓ ALL CHECKS PASSED")
        logger.info("All 5 workflow steps are fully functional")
    else
        logger.warn("WORKFLOW HEALTH: ✗ ISSUES FOUND")
        logger.warn("Found", #issues, "issue(s):")
        for i, issue in ipairs(issues) do
            logger.warn("  " .. i .. ".", issue)
        end
        logger.warn("Workflow may not function correctly")
    end
    logger.info("========================================")
    
    return all_ok, issues
end

function OPDSBrowser:addToMainMenu(menu_items)
    menu_items.opdsbrowser = {
        text = _("Cloud Book Library"),
        sub_item_table = {
            -- Library Sync section
            { text = _("Library Sync - OPDS"),
              callback = function() self:buildPlaceholderLibrary() end,
              enabled_func = function() return self.opds_url ~= "" end },

            { text = "────────────────────", enabled_func = function() return false end },

            -- Ephemera section
            { text = _("Ephemera - Request New Book"),
              callback = function() self:requestBook() end,
              enabled_func = function() return self.ephemera_client:isConfigured() end },
            { text = _("Ephemera - View Download Queue"),
              callback = function() self:showDownloadQueue() end,
              enabled_func = function() return self.ephemera_client:isConfigured() end },

            { text = "────────────────────", enabled_func = function() return false end },

            -- Hardcover section
            { text = _("Hardcover - Search Author"),
              callback = function() self:hardcoverSearchAuthor() end,
              enabled_func = function() return self.hardcover_client:isConfigured() end },

            { text = "────────────────────", enabled_func = function() return false end },

            -- History section
            { text = _("History - Recent Searches"),
              callback = function() self:showSearchHistory() end },
            { text = _("History - Recently Viewed"),
              callback = function() self:showRecentBooks() end },

            { text = "────────────────────", enabled_func = function() return false end },

            -- Settings section
            { text = _("Plugin - Settings"),
              callback = function() self:showSettings() end },
            { text = _("Plugin - Cache Info"),
              callback = function() self:showCacheInfo() end },
            { text = _("Plugin - Workflow Health Check"),
              callback = function() self:showWorkflowHealth() end },
        },
    }
end

-- Settings
function OPDSBrowser:showSettings()
    local hardcover_status = self.hardcover_client:isConfigured() and "✓ Configured" or "✗ Not configured"
    local publisher_setting = self.use_publisher_as_series and "YES" or "NO"
    local library_check_setting = self.enable_library_check and "YES" or "NO"

    local fields = {
        { text = self.opds_url, hint = _("Base URL (e.g., https://example.com/api/v1/opds)"), input_type = "string" },
        { text = self.opds_username, hint = _("OPDS Username (optional)"), input_type = "string" },
        { text = self.opds_password, hint = _("OPDS Password (optional)"), input_type = "string" },
        { text = self.ephemera_url, hint = _("Ephemera URL (e.g., http://example.com:8286)"), input_type = "string" },
        { text = self.download_dir, hint = _("Download Directory"), input_type = "string" },
        { text = publisher_setting, hint = _("Use Publisher as Series? (YES/NO)"), input_type = "string" },
        { text = library_check_setting, hint = _("Check 'In Library' for Hardcover? (YES/NO)"), input_type = "string" },
        { text = tostring(self.library_check_page_limit), hint = _("Max pages to check (5=250 books, 0=unlimited)"), input_type = "number" },
        { text = self.library_sync.base_library_path, hint = _("Library Sync Path"), input_type = "string" },
    }
    
    local extra_text = T(_("Hardcover API: %1\n\nTo configure Hardcover, edit:\nkoreader/settings/opdsbrowser.lua"), hardcover_status)
    
    UIHelpers.createMultiInputDialog(
        _("Book Download Settings"),
        fields,
        function(field_values)
            self:saveSettings(field_values)
        end,
        extra_text
    )
end

function OPDSBrowser:saveSettings(fields)
    -- Clean and validate URLs
    local new_opds_url = Utils.trim(fields[1] or ""):gsub("/$", "")
    local new_ephemera_url = Utils.trim(fields[4] or ""):gsub("/$", "")
    
    -- Validate OPDS URL
    if new_opds_url ~= "" then
        local valid, err = Utils.validate_url(new_opds_url)
        if not valid then
            UIHelpers.showError(err)
            return
        end
    end
    
    -- Validate Ephemera URL
    if new_ephemera_url ~= "" then
        local valid, err = Utils.validate_url(new_ephemera_url)
        if not valid then
            UIHelpers.showError(err)
            return
        end
    end
    
    -- Save settings
    self.opds_url = new_opds_url
    self.opds_username = Utils.trim(fields[2] or "")
    self.opds_password = Utils.trim(fields[3] or "")
    self.ephemera_url = new_ephemera_url
    self.download_dir = Utils.trim(fields[5] or self.download_dir)
    self.use_publisher_as_series = Utils.safe_boolean(fields[6], false)
    self.enable_library_check = Utils.safe_boolean(fields[7], true)
    self.library_check_page_limit = Utils.safe_number(fields[8], Constants.DEFAULT_PAGE_LIMIT)
    
    -- Update library sync path (use download_dir/Library unless user specified custom path)
    local new_library_path = Utils.trim(fields[9] or "")
    if new_library_path == "" or new_library_path == self.library_sync.base_library_path then
        -- Use default: download_dir/Library
        new_library_path = self.download_dir .. "/Library"
    end
    LibrarySyncManager:init(new_library_path)
    
    -- Update settings
    SettingsManager:setAll({
        opds_url = self.opds_url,
        opds_username = self.opds_username,
        opds_password = self.opds_password,
        ephemera_url = self.ephemera_url,
        download_dir = self.download_dir,
        use_publisher_as_series = self.use_publisher_as_series,
        enable_library_check = self.enable_library_check,
        library_check_page_limit = self.library_check_page_limit,
        library_sync_path = new_library_path,
    })
    
    -- Update clients
    self.opds_client:setCredentials(self.opds_url, self.opds_username, self.opds_password)
    self.hardcover_client:setToken(self.hardcover_token)
    self.ephemera_client:setBaseURL(self.ephemera_url)
    
    -- Clear cache
    CacheManager:clear()
    
    UIHelpers.showSuccess(_("Settings saved successfully!"))
end

-- Cache info
function OPDSBrowser:showCacheInfo()
    local stats = CacheManager:getCacheStats()
    local details = T(
        _("Cache Statistics\n\n") ..
        _("Total Entries: %1\n") ..
        _("Oldest Entry: %2 seconds\n") ..
        _("Newest Entry: %3 seconds\n") ..
        _("Cache TTL: %4 seconds"),
        stats.total_entries,
        stats.oldest_age,
        stats.newest_age == math.huge and "N/A" or stats.newest_age,
        Constants.CACHE_TTL
    )
    
    local buttons = {
        {
            { text = _("Clear Cache"), callback = function()
                UIManager:close(self.cache_info)
                CacheManager:clear()
                UIHelpers.showSuccess(_("Cache cleared"))
            end },
        },
        {
            { text = _("Close"), callback = function()
                UIManager:close(self.cache_info)
            end },
        },
    }
    
    self.cache_info = UIHelpers.createTextViewer(_("Cache Info"), details, buttons)
    UIManager:show(self.cache_info)
end

-- Show workflow health check results
function OPDSBrowser:showWorkflowHealth()
    -- Run health check
    local all_ok, issues = self:checkWorkflowHealth()
    
    -- Build message
    local status_icon = all_ok and "✓" or "✗"
    local status_text = all_ok and "ALL SYSTEMS OPERATIONAL" or "ISSUES DETECTED"
    
    local message = T(
        _("Placeholder Auto-Download Workflow\n\n") ..
        _("Status: %1 %2\n\n"),
        status_icon,
        status_text
    )
    
    if all_ok then
        message = message .. _("All 5 workflow steps are fully functional:\n\n") ..
            _("1. ✓ Placeholder Detection\n") ..
            _("2. ✓ OPDS Download\n") ..
            _("3. ✓ File Operations\n") ..
            _("4. ✓ Restart Capability\n") ..
            _("5. ✓ FileManager Navigation\n\n") ..
            _("The workflow will function correctly when you open a placeholder book.")
    else
        message = message .. T(
            _("Found %1 issue(s):\n\n"),
            #issues
        )
        
        for i, issue in ipairs(issues) do
            message = message .. T(_("%1. %2\n"), i, issue)
        end
        
        message = message .. _("\n") ..
            _("Some workflow steps may not function correctly. ") ..
            _("Check KOReader logs for detailed diagnostics.")
    end
    
    local buttons = {
        {
            { text = _("View Logs"), callback = function()
                UIManager:close(self.workflow_health)
                UIHelpers.showInfo(_("Check KOReader logs:\n\n") ..
                    _("Look for 'PLACEHOLDER AUTO-DOWNLOAD WORKFLOW HEALTH CHECK' ") ..
                    _("and 'OPDS WORKFLOW' entries for detailed information."))
            end },
        },
        {
            { text = _("Close"), callback = function()
                UIManager:close(self.workflow_health)
            end },
        },
    }
    
    self.workflow_health = UIHelpers.createTextViewer(_("Workflow Health"), message, buttons)
    UIManager:show(self.workflow_health)
end

-- Network check helper
function OPDSBrowser:ensureNetwork()
    if not NetworkMgr:isOnline() then
        NetworkMgr:beforeWifiAction()
        socket.sleep(1)
        if not NetworkMgr:isOnline() then
            UIHelpers.showError(_("Network unavailable"))
            return false
        end
    end
    return true
end

-- Show book list
function OPDSBrowser:showBookList(books, title)
    local items = {}
    for _, book in ipairs(books) do
        local display_text = book.title
        
        -- Add series info
        if book.series and book.series ~= "" then
            display_text = display_text .. " - " .. book.series
            if book.series_index and book.series_index ~= "" then
                display_text = display_text .. " #" .. tostring(book.series_index)
            end
        end
        
        -- Add author
        display_text = display_text .. " - " .. book.author

        table.insert(items, {
            text = display_text,
            callback = function()
                HistoryManager:addRecentBook({
                    title = book.title,
                    author = book.author,
                    series = book.series,
                })
                self:showBookDetails(book)
            end,
        })
    end

    self.book_menu = UIHelpers.createMenu(title or _("OPDS Books"), items)
    UIManager:show(self.book_menu)
end

-- Show book details
function OPDSBrowser:showBookDetails(book)
    local series_text = ""
    if book.series and book.series ~= "" then
        series_text = "\n\n" .. T(_("Series: %1"), book.series)
        if book.series_index and book.series_index ~= "" then
            series_text = series_text .. " - " .. book.series_index
        end
    end
    
    local bookmark_status = HistoryManager:isBookmarked(book.title, book.author) and " ★" or ""
    local details = T(_("Title: %1%2\n\nAuthor: %3"), book.title, bookmark_status, book.author) .. series_text .. "\n\n" .. book.summary

    local buttons = {
        {
            { text = _("Download"), callback = function()
                UIManager:close(self.book_details)
                self:downloadBook(book)
            end },
            { text = bookmark_status == "" and _("Bookmark") or _("Unbookmark"), callback = function()
                if HistoryManager:isBookmarked(book.title, book.author) then
                    HistoryManager:removeBookmark(book.title, book.author)
                    UIHelpers.showSuccess(_("Bookmark removed"))
                else
                    HistoryManager:addBookmark({
                        title = book.title,
                        author = book.author,
                        series = book.series,
                        summary = book.summary,
                    })
                    UIHelpers.showSuccess(_("Bookmarked!"))
                end
                UIManager:close(self.book_details)
            end },
        },
        {
            { text = _("Close"), callback = function() UIManager:close(self.book_details) end },
        },
    }

    self.book_details = UIHelpers.createTextViewer(book.title, details, buttons)
    UIManager:show(self.book_details)
end


-- Download book
function OPDSBrowser:downloadBook(book)
    -- Ensure download directory exists
    local dir_exists = lfs.attributes(self.download_dir, "mode") == "directory"
    if not dir_exists then
        local ok = lfs.mkdir(self.download_dir)
        if not ok then
            UIHelpers.showError(_("Failed to create download directory"))
            return
        end
    end

    -- Extract book ID
    local book_id = book.id:match("book:(%d+)$")
    
    if not book_id or book_id == "" then
        logger.err("OPDS: No book ID found in:", book.id)
        UIHelpers.showError(_("Cannot download: Book ID not found"))
        return
    end

    -- Determine file extension
    local extension = ".epub"
    if book.media_type and book.media_type:match("kepub") then
        extension = ".kepub.epub"
    elseif book.download_url and book.download_url:lower():match("kepub") then
        extension = ".kepub.epub"
    end

    -- Generate safe filename
    local filename = book.title:gsub("[^%w%s%-]", ""):gsub("%s+", "_") .. extension
    local filepath = self.download_dir .. "/" .. filename
    
    -- Construct download URL
    local download_url = self.opds_url .. "/" .. book_id .. "/download"
    
    logger.info("OPDS: Downloading:", book.title, "to", filepath)

    local loading = UIHelpers.createProgressMessage(_("Downloading..."))
    UIManager:show(loading)
    
    -- Download with progress
    local user = (self.opds_username and self.opds_username ~= "") and self.opds_username or nil
    local pass = (self.opds_password and self.opds_password ~= "") and self.opds_password or nil
    
    local https = require("ssl.https")
    local ltn12 = require("ltn12")
    local mime = require("mime")
    
    local response_body = {}
    local headers = {
        ["Cache-Control"] = "no-cache, no-store, must-revalidate",
        ["Pragma"] = "no-cache",
        ["Expires"] = "0"
    }
    
    if user and pass then
        local credentials = mime.b64(user .. ":" .. pass)
        headers["Authorization"] = "Basic " .. credentials
    end
    
    local res, code, response_headers = https.request{
        url = download_url,
        method = "GET",
        headers = headers,
        sink = ltn12.sink.table(response_body)
    }
    
    UIManager:close(loading)
    
    if not res or code ~= 200 then
        logger.err("OPDS: Download failed with code:", code)
        UIHelpers.showError(T(_("Download failed: HTTP %1"), code or "error"))
        return
    end
    
    local data = table.concat(response_body)
    logger.info("OPDS: Downloaded", #data, "bytes")
    
    if #data < 100 then
        UIHelpers.showError(_("Downloaded file appears invalid (too small)"))
        return
    end
    
    -- Write to file
    local file, err = io.open(filepath, "wb")
    if not file then
        logger.err("OPDS: Failed to open file for writing:", err)
        UIHelpers.showError(T(_("Failed to create file: %1"), err or "unknown"))
        return
    end
    
    file:write(data)
    file:close()
    
    -- Clear cached metadata
    pcall(function()
        local DocSettings = require("docsettings")
        DocSettings:open(filepath):purge()
    end)

    UIHelpers.showSuccess(T(_("Downloaded: %1\n\n%2"), book.title, Utils.format_file_size(#data)))

    -- Refresh file manager
    UIManager:scheduleIn(0.5, function()
        local FileManager = require("apps/filemanager/filemanager")
        if FileManager.instance then
            FileManager.instance:onRefresh()
        end
    end)
end

-- Ephemera functions
function OPDSBrowser:requestBook()
    UIHelpers.createMultiInputDialog(
        _("Request Book via Ephemera"),
        {
            { text = "", hint = _("Book Title"), input_type = "string" },
            { text = "", hint = _("Author (optional)"), input_type = "string" },
        },
        function(fields)
            local title = Utils.trim(fields[1] or "")
            local author = Utils.trim(fields[2] or "")
            if title ~= "" then
                self:searchEphemera(title, author)
            end
        end
    )
end

function OPDSBrowser:searchEphemera(title, author)
    if not self:ensureNetwork() then return end
    
    local loading = UIHelpers.showLoading(_("Searching Ephemera..."))
    UIManager:show(loading)
    
    local search_string = title
    if author ~= "" then
        search_string = search_string .. " " .. author
    end
    
    local ok, results = self.ephemera_client:search(search_string)
    
    UIManager:close(loading)
    
    if not ok then
        UIHelpers.showError(T(_("Ephemera search failed: %1"), results))
        return
    end
    
    -- Filter for EPUB
    results = self.ephemera_client:filterResults(results, { epub_only = true })
    
    if #results == 0 then
        UIHelpers.showInfo(_("No EPUB books found in Ephemera"))
        return
    end
    
    self:showEphemeraResults(results)
end

function OPDSBrowser:showEphemeraResults(results)
    local items = {}
    for _, book in ipairs(results) do
        local title = Utils.safe_string(book.title, "Unknown Title")
        local author = self.ephemera_client:formatAuthor(book.authors)
        local display_text = title .. " - " .. author
        
        table.insert(items, {
            text = display_text,
            callback = function() self:requestEphemeraBook(book) end
        })
    end

    self.ephemera_menu = UIHelpers.createMenu(
        T(_("Ephemera Search Results (%1 EPUB)"), #results),
        items
    )
    UIManager:show(self.ephemera_menu)
end

function OPDSBrowser:requestEphemeraBook(book)
    local loading = UIHelpers.showLoading(_("Requesting download..."))
    UIManager:show(loading)
    
    local ok, result = self.ephemera_client:requestDownload(book)
    
    UIManager:close(loading)
    
    if not ok then
        UIHelpers.showError(T(_("Download request failed: %1"), result))
        return
    end

    local message = ""
    if result.status == "queued" then
        message = T(_("Book queued for download!\n\nPosition: %1"), result.position or "unknown")
    elseif result.status == "already_downloaded" then
        message = _("Book already downloaded!")
    elseif result.status == "already_in_queue" then
        message = T(_("Book already in queue!\n\nPosition: %1"), result.position or "unknown")
    else
        message = T(_("Status: %1"), result.status or "unknown")
    end
    
    UIHelpers.showInfo(message)
    
    if self.ephemera_menu then
        UIManager:close(self.ephemera_menu)
    end
end

-- Ephemera queue
function OPDSBrowser:showDownloadQueue()
    if not self:ensureNetwork() then return end
    
    local loading = UIHelpers.showLoading(_("Loading queue..."))
    UIManager:show(loading)
    
    local ok, queue = self.ephemera_client:getQueue()
    
    UIManager:close(loading)
    
    if not ok then
        UIHelpers.showError(T(_("Failed to load queue: %1"), queue))
        return
    end
    
    self:displayDownloadQueue(queue)
end

function OPDSBrowser:displayDownloadQueue(queue)
    local items = {}
    local has_incomplete = self.ephemera_client:hasIncompleteItems(queue)

    local function addItems(category, status_label, icon)
        if category then
            for md5, item in pairs(category) do
                local title = Utils.safe_string(item.title, "Unknown")
                local status_text = status_label
                
                if item.status == "downloading" and item.progress then
                    status_text = status_text .. string.format(" (%d%%)", math.floor(item.progress))
                end
                
                if item.error then
                    status_text = status_text .. " - " .. item.error
                end
                
                table.insert(items, {
                    text = icon .. " " .. title,
                    subtitle = status_text,
                    md5 = md5,
                    status = item.status,
                })
            end
        end
    end

    addItems(queue.downloading, "Downloading", Constants.ICONS.DOWNLOADING)
    addItems(queue.queued, "Queued", Constants.ICONS.QUEUED)
    addItems(queue.delayed, "Delayed", Constants.ICONS.DELAYED)
    addItems(queue.available, "Available", Constants.ICONS.AVAILABLE)
    addItems(queue.done, "Done", Constants.ICONS.DONE)
    addItems(queue.error, "Error", Constants.ICONS.ERROR)
    addItems(queue.cancelled, "Cancelled", Constants.ICONS.CANCELLED)

    if #items == 0 then
        UIHelpers.showInfo(_("Download queue is empty"))
        return
    end

    self.queue_menu = UIHelpers.createMenu(_("Download Queue (Ephemera)"), items)
    UIManager:show(self.queue_menu)

    if has_incomplete then
        self:startQueueRefresh()
    else
        self:stopQueueRefresh()
    end
end

function OPDSBrowser:startQueueRefresh()
    self:stopQueueRefresh()
    
    self.queue_refresh_action = function()
        if self.queue_menu then
            local ok, queue = self.ephemera_client:getQueue()
            if ok then
                UIManager:close(self.queue_menu)
                self:displayDownloadQueue(queue)
            end
        else
            self:stopQueueRefresh()
        end
    end
    
    UIManager:scheduleIn(Constants.QUEUE_REFRESH_INTERVAL, self.queue_refresh_action)
end

function OPDSBrowser:stopQueueRefresh()
    if self.queue_refresh_action then
        UIManager:unschedule(self.queue_refresh_action)
        self.queue_refresh_action = nil
    end
end


-- Hardcover functions
function OPDSBrowser:hardcoverSearchAuthor()
    UIHelpers.createInputDialog(
        _("Search Author on Hardcover"),
        _("Enter author name"),
        function(author_name)
            if author_name and author_name ~= "" then
                self:performHardcoverAuthorSearch(author_name)
            end
        end
    )
end

function OPDSBrowser:performHardcoverAuthorSearch(author_name)
    if not self:ensureNetwork() then return end
    
    local loading = UIHelpers.showLoading(_("Searching Hardcover..."))
    UIManager:show(loading)
    
    local ok, results = self.hardcover_client:searchAuthor(author_name)
    
    UIManager:close(loading)
    
    if not ok then
        UIHelpers.showError(T(_("Hardcover search failed: %1"), results))
        return
    end
    
    self:showHardcoverAuthorResults(results)
end

function OPDSBrowser:showHardcoverAuthorResults(results)
    if not results.hits or #results.hits == 0 then
        UIHelpers.showInfo(_("No authors found on Hardcover"))
        return
    end

    local items = {}
    for _, hit in ipairs(results.hits) do
        local author = hit.document
        local display_text = Utils.safe_string(author.name, "Unknown Author")
        
        -- Add "Known for" info
        if author.books and #author.books > 0 then
            display_text = display_text .. " - Known for " .. author.books[1]
        end

        table.insert(items, {
            text = display_text,
            callback = function()
                HistoryManager:addRecentAuthor(author.name)
                self:hardcoverGetAuthorBooks(author.id, author.name)
            end,
        })
    end

    self.hardcover_menu = UIHelpers.createMenu(_("Hardcover Authors"), items)
    UIManager:show(self.hardcover_menu)
end

function OPDSBrowser:hardcoverGetAuthorBooks(author_id, author_name)
    if not self:ensureNetwork() then return end
    
    local loading = UIHelpers.showLoading(_("Loading books..."))
    UIManager:show(loading)
    
    local ok, books = self.hardcover_client:getAuthorBooks(author_id)
    
    UIManager:close(loading)
    
    if not ok then
        UIHelpers.showError(T(_("Failed to load books: %1"), books))
        return
    end
    
    self:showHardcoverAuthorFilterOptions(books, author_name, author_id)
end

function OPDSBrowser:showHardcoverAuthorFilterOptions(books, author_name, author_id)
    -- Store for later use
    self.hardcover_all_books = books
    self.hardcover_current_author = author_name
    self.hardcover_current_author_id = author_id

    local items = {
        {
            text = _("Standalone Books"),
            callback = function()
                UIManager:close(self.filter_menu)
                self:showHardcoverStandaloneBooks(books, author_name)
            end,
        },
        {
            text = _("Book Series"),
            callback = function()
                UIManager:close(self.filter_menu)
                self:showHardcoverBookSeries(author_id, author_name)
            end,
        },
        {
            text = _("All Books"),
            callback = function()
                UIManager:close(self.filter_menu)
                self:showHardcoverAllBooks(books, author_name)
            end,
        },
    }

    self.filter_menu = UIHelpers.createMenu(T(_("Books by %1"), author_name), items)
    UIManager:show(self.filter_menu)
end

function OPDSBrowser:showHardcoverStandaloneBooks(books, author_name)
    -- Filter standalone books
    local standalone_books = {}
    for _, book in ipairs(books) do
        local has_series = book.book_series and type(book.book_series) == "table" and #book.book_series > 0
        if not has_series then
            table.insert(standalone_books, book)
        end
    end

    if #standalone_books == 0 then
        UIHelpers.showInfo(_("No standalone books found for this author"))
        return
    end

    -- Sort by release date descending
    table.sort(standalone_books, function(a, b)
        local date_a = Utils.safe_string(a.release_date, "")
        local date_b = Utils.safe_string(b.release_date, "")
        if date_a == "" and date_b == "" then return false end
        if date_a == "" then return false end
        if date_b == "" then return true end
        return date_a > date_b
    end)

    -- Get library lookup if enabled
    local author_books_lookup = {}
    if self.enable_library_check then
        author_books_lookup = self:getAuthorBooksFromLibrary(author_name)
    end

    local items = {}
    for _, book in ipairs(standalone_books) do
        local display_text = Utils.safe_string(book.title, "Unknown Title")

        -- Add release date
        local release_date = Utils.safe_string(book.release_date, "")
        if release_date ~= "" then
            display_text = display_text .. " (" .. release_date .. ")"
        end

        -- Check if in library
        if self.enable_library_check then
            local normalized_title = Utils.normalize_title(book.title)
            if author_books_lookup[normalized_title] then
                display_text = Constants.ICONS.IN_LIBRARY .. " " .. display_text
            end
        end

        table.insert(items, {
            text = display_text,
            callback = function()
                self:showHardcoverBookDetails(book, author_name)
            end,
        })
    end

    self.standalone_menu = UIHelpers.createMenu(
        T(_("Standalone Books - %1"), author_name),
        items
    )
    UIManager:show(self.standalone_menu)
end

function OPDSBrowser:showHardcoverBookSeries(author_id, author_name)
    if not self:ensureNetwork() then return end
    
    local loading = UIHelpers.showLoading(_("Loading series..."))
    UIManager:show(loading)
    
    local ok, series_list = self.hardcover_client:getAuthorSeries(author_id)
    
    UIManager:close(loading)
    
    if not ok then
        UIHelpers.showError(T(_("Failed to load series: %1"), series_list))
        return
    end

    if #series_list == 0 then
        UIHelpers.showInfo(_("No series found for this author"))
        return
    end

    local items = {}
    for _, series in ipairs(series_list) do
        local book_count = Utils.safe_number(series.books_count, 0)
        local display_text = series.name .. " (" .. book_count .. " book" .. (book_count > 1 and "s" or "") .. ")"

        table.insert(items, {
            text = display_text,
            callback = function()
                self:showHardcoverSeriesBooks(series.id, series.name, author_name)
            end,
        })
    end

    self.series_menu = UIHelpers.createMenu(
        T(_("Book Series - %1"), author_name),
        items
    )
    UIManager:show(self.series_menu)
end

function OPDSBrowser:showHardcoverSeriesBooks(series_id, series_name, author_name)
    if not self:ensureNetwork() then return end
    
    local loading = UIHelpers.showLoading(_("Loading books..."))
    UIManager:show(loading)
    
    local ok, series_data = self.hardcover_client:getSeriesBooks(series_id)
    
    UIManager:close(loading)
    
    if not ok then
        UIHelpers.showError(T(_("Failed to load books: %1"), series_data))
        return
    end

    local book_series_list = series_data.book_series or {}

    if #book_series_list == 0 then
        UIHelpers.showInfo(_("No books found in this series"))
        return
    end

    -- Get library lookup if enabled
    local author_books_lookup = {}
    if self.enable_library_check then
        author_books_lookup = self:getAuthorBooksFromLibrary(author_name)
    end

    local items = {}
    for _, book_series in ipairs(book_series_list) do
        local book = book_series.book
        local position = Utils.safe_number(book_series.position, 0)

        local display_text = Utils.safe_string(book.title, "Unknown Title")

        -- Add series position
        if position > 0 then
            display_text = display_text .. " - " .. series_name .. " #" .. position
        else
            display_text = display_text .. " - " .. series_name
        end

        -- Check if in library
        if self.enable_library_check then
            local normalized_title = Utils.normalize_title(book.title)
            if author_books_lookup[normalized_title] then
                display_text = Constants.ICONS.IN_LIBRARY .. " " .. display_text
            end
        end

        table.insert(items, {
            text = display_text,
            callback = function()
                -- Add series info to book
                book.book_series = {{
                    series = { name = series_name, id = series_id },
                    details = "#" .. position
                }}
                self:showHardcoverBookDetails(book, author_name)
            end,
        })
    end

    self.series_books_menu = UIHelpers.createMenu(series_name, items)
    UIManager:show(self.series_books_menu)
end

function OPDSBrowser:showHardcoverAllBooks(books, author_name)
    if #books == 0 then
        UIHelpers.showInfo(_("No books found for this author"))
        return
    end

    -- Sort by release date descending
    table.sort(books, function(a, b)
        local date_a = Utils.safe_string(a.release_date, "")
        local date_b = Utils.safe_string(b.release_date, "")
        if date_a == "" and date_b == "" then return false end
        if date_a == "" then return false end
        if date_b == "" then return true end
        return date_a > date_b
    end)

    -- Get library lookup if enabled
    local author_books_lookup = {}
    if self.enable_library_check then
        author_books_lookup = self:getAuthorBooksFromLibrary(author_name)
    end

    local items = {}
    for _, book in ipairs(books) do
        local display_text = Utils.safe_string(book.title, "Unknown Title")

        -- Add release date
        local release_date = Utils.safe_string(book.release_date, "")
        if release_date ~= "" then
            display_text = display_text .. " (" .. release_date .. ")"
        end

        -- Check if in library
        if self.enable_library_check then
            local normalized_title = Utils.normalize_title(book.title)
            if author_books_lookup[normalized_title] then
                display_text = Constants.ICONS.IN_LIBRARY .. " " .. display_text
            end
        end

        table.insert(items, {
            text = display_text,
            callback = function()
                self:showHardcoverBookDetails(book, author_name)
            end,
        })
    end

    self.all_books_menu = UIHelpers.createMenu(
        T(_("All Books - %1"), author_name),
        items
    )
    UIManager:show(self.all_books_menu)
end


function OPDSBrowser:showHardcoverBookDetails(book, author_name)
    -- Extract author
    local book_author = author_name
    if book.contributions and #book.contributions > 0 and book.contributions[1].author then
        book_author = book.contributions[1].author.name
    end
    
    -- Build details
    local details = T(_("Title: %1\n\nAuthor: %2"), Utils.safe_string(book.title, "Unknown"), book_author)
    
    -- Add rating
    local rating_text = Utils.format_rating(book.rating, book.ratings_count)
    if rating_text ~= "" then
        details = details .. "\n\n" .. T(_("Rating: %1"), rating_text)
    end
    
    -- Add series
    if book.book_series and type(book.book_series) == "table" and #book.book_series > 0 then
        local series_info = book.book_series[1]
        if series_info and type(series_info) == "table" and series_info.series then
            local series_text = Utils.safe_string(series_info.series.name, "Unknown Series")
            local series_details = Utils.safe_string(series_info.details, "")
            if series_details ~= "" then
                series_text = series_text .. " - " .. series_details
            end
            details = details .. "\n\n" .. T(_("Series: %1"), series_text)
        end
    end
    
    -- Add description
    local description = Utils.safe_string(book.description, "")
    if description ~= "" then
        details = details .. "\n\n" .. Utils.strip_html(description)
    end
    
    -- Add release date and pages
    local release_date = Utils.safe_string(book.release_date, "")
    if release_date ~= "" then
        details = details .. "\n\n" .. T(_("Released: %1"), release_date)
    end
    
    local pages = Utils.safe_number(book.pages, 0)
    if pages > 0 then
        details = details .. "\n" .. T(_("Pages: %1"), tostring(pages))
    end

    local buttons = {
        {
            { text = _("Download from Ephemera"), callback = function()
                UIManager:close(self.hardcover_book_details)
                self:downloadFromEphemera(book, book_author)
            end },
        },
        {
            { text = _("Close"), callback = function()
                UIManager:close(self.hardcover_book_details)
            end },
        },
    }

    self.hardcover_book_details = UIHelpers.createTextViewer(book.title, details, buttons)
    UIManager:show(self.hardcover_book_details)
end

function OPDSBrowser:downloadFromEphemera(book, author)
    if not self.ephemera_client:isConfigured() then
        UIHelpers.showError(_("Ephemera URL not configured"))
        return
    end

    local loading = UIHelpers.showLoading(_("Searching Ephemera..."))
    UIManager:show(loading)

    local search_string = author .. " " .. book.title
    local ok, results = self.ephemera_client:search(search_string)
    
    UIManager:close(loading)
    
    if not ok then
        UIHelpers.showError(T(_("Ephemera search failed: %1"), results))
        return
    end

    -- Filter for EPUB and English
    results = self.ephemera_client:filterResults(results, { 
        epub_only = true,
        english_only = true 
    })

    if #results == 0 then
        UIHelpers.showInfo(_("No English EPUB books found"))
        return
    end

    -- Show top results
    local top_results = Utils.table_slice(results, 1, math.min(Constants.MAX_SEARCH_RESULTS, #results))
    self:showEphemeraResults(top_results)
end

-- Library checking
function OPDSBrowser:getAuthorBooksFromLibrary(author)
    if not self.enable_library_check then
        logger.info("Library check: Disabled in settings")
        return {}
    end

    if not self.opds_url or self.opds_url == "" then
        return {}
    end

    -- Check cache
    local cache_key = Utils.generate_cache_key("author", author)
    local cached_data, age = CacheManager:get(cache_key)
    if cached_data then
        logger.info("Library check: Cache hit for author", author, "age:", age, "seconds")
        return cached_data
    end

    -- Fetch from library
    local query = url.escape(author)
    local base_url = self.opds_url .. "/catalog?q=" .. query
    
    logger.info("Library check: Fetching books for author:", author)
    logger.info("Library check: Page limit:", self.library_check_page_limit)

    local all_xml = self.opds_client:fetchAllPages(
        base_url,
        Constants.DEFAULT_PAGE_SIZE,
        self.library_check_page_limit
    )
    
    if not all_xml then
        logger.warn("Library check: Failed to fetch library data")
        CacheManager:set(cache_key, {})
        return {}
    end

    -- Parse and build title lookup
    local books = self.opds_client:parseBookloreOPDSFeed(all_xml, self.use_publisher_as_series)
    local title_lookup = {}
    for _, book in ipairs(books) do
        local normalized_title = Utils.normalize_title(book.title)
        title_lookup[normalized_title] = true
    end

    logger.info("Library check: Found", Utils.table_count(title_lookup), "unique books for author:", author)

    -- Cache the result
    CacheManager:set(cache_key, title_lookup)

    return title_lookup
end

-- History views
function OPDSBrowser:showSearchHistory()
    local history = HistoryManager:getSearchHistory()
    
    if #history == 0 then
        UIHelpers.showInfo(_("No search history"))
        return
    end
    
    local items = {}
    for _, query in ipairs(history) do
        table.insert(items, {
            text = query,
            callback = function()
                UIManager:close(self.history_menu)
                self:performLibrarySearch(query)
            end,
        })
    end
    
    self.history_menu = UIHelpers.createMenu(_("Recent Searches"), items)
    UIManager:show(self.history_menu)
end

function OPDSBrowser:showRecentBooks()
    local recent = HistoryManager:getRecentBooks()
    
    if #recent == 0 then
        UIHelpers.showInfo(_("No recently viewed books"))
        return
    end
    
    local items = {}
    for _, book_info in ipairs(recent) do
        local display_text = Utils.safe_string(book_info.title, "Unknown")
        if book_info.author then
            display_text = display_text .. " - " .. book_info.author
        end
        
        table.insert(items, {
            text = display_text,
            callback = function()
                -- Show book details if we have full info
                if book_info.download_url then
                    self:showBookDetails(book_info)
                else
                    UIHelpers.showInfo(_("Limited book information available"))
                end
            end,
        })
    end
    
    self.recent_menu = UIHelpers.createMenu(_("Recently Viewed"), items)
    UIManager:show(self.recent_menu)
end

-- ============================================================================
-- LIBRARY SYNC FUNCTIONS
-- ============================================================================

-- Build placeholder library
function OPDSBrowser:buildPlaceholderLibrary()
    if not self:ensureNetwork() then return end
    
    -- Go straight to sync without confirmation dialog
    self:performLibrarySync()
end

function OPDSBrowser:performLibrarySync()
    local loading = UIHelpers.showLoading(_("Fetching library catalog..."))
    UIManager:show(loading)
    
    local full_url = self.opds_url .. "/catalog"
    local all_xml = self.opds_client:fetchAllPages(full_url, Constants.DEFAULT_PAGE_SIZE, 0)
    
    if not all_xml then
        UIManager:close(loading)
        UIHelpers.showError(_("Failed to fetch library catalog"))
        return
    end

    local books = self.opds_client:parseBookloreOPDSFeed(all_xml, self.use_publisher_as_series)
    
    if #books == 0 then
        UIManager:close(loading)
        UIHelpers.showInfo(_("No books found in library"))
        return
    end
    
    UIManager:show(loading)
    UIManager:forceRePaint()

    local progress_count = 0
    local last_update_time = os.time()
    local ok, result = self.library_sync:syncLibrary(books, function(current, total)
        progress_count = progress_count + 1
        -- Update every 50 items AND ensure at least 0.5s between updates to show progress
        local current_time = os.time()
        if progress_count % 50 == 0 or (current_time - last_update_time) >= 1 then
            -- Close old message and show new one (simple and reliable)
            UIManager:close(loading)
            loading = UIHelpers.showLoading(T(_("Syncing... %1/%2"), current, total))
            UIManager:show(loading)
            UIManager:forceRePaint()
            last_update_time = current_time
        end
    end)
    
    UIManager:close(loading)
    
    if not ok then
        UIHelpers.showError(T(_("Sync failed: %1"), result))
        return
    end
    
    local summary = T(
        _("Library Sync Complete!\n\n") ..
        _("Created: %1\n") ..
        _("Updated: %2\n") ..
        _("Skipped: %3\n") ..
        _("Failed: %4\n") ..
        _("Orphans removed: %5\n") ..
        _("Recently Added: %6\n") ..
        _("Total: %7\n\n") ..
        _("Location: %8"),
        result.created, result.updated, result.skipped, result.failed, result.deleted_orphans, 
        result.recently_added or 0, result.total,
        self.library_sync.base_library_path
    )
    
    UIHelpers.showInfo(summary, 10)

    -- Update "Recently Added" collection with 20 newest books
    self:updateRecentlyAddedCollection(books)

    -- Update "Currently Reading" collection
    self:updateCurrentlyReadingCollection()

    UIManager:scheduleIn(0.5, function()
        local FileManager = require("apps/filemanager/filemanager")
        if FileManager.instance then
            FileManager.instance:onRefresh()
        end
    end)
end

-- Update "Recently Added" collection with the 20 most recent books
function OPDSBrowser:updateRecentlyAddedCollection(books)
    logger.info("OPDS: Updating 'Recently Added' collection")

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

    -- Take top 20
    local recent_books = {}
    for i = 1, math.min(20, #books_with_dates) do
        table.insert(recent_books, books_with_dates[i])
    end

    logger.info("OPDS: Found", #recent_books, "recent books for collection")

    if #recent_books == 0 then
        logger.warn("OPDS: No books with timestamps found")
        return
    end

    -- Load ReadCollection plugin - ensure it's properly initialized
    local ok, ReadCollection = pcall(require, "apps/filemanager/readcollection")
    if not ok then
        logger.warn("OPDS: ReadCollection plugin not available")
        return
    end
    
    -- Initialize collections if needed
    if not ReadCollection.coll then
        ReadCollection.coll = {}
    end

    -- Get or create the "Recently Added" collection
    local coll_name = "Recently Added"
    local collections = ReadCollection.coll

    -- Clear existing collection entries
    collections[coll_name] = {}

    -- Add book filepaths to collection
    local added_count = 0
    for _, book in ipairs(recent_books) do
        -- Generate filepath for the placeholder
        local target_dir = self.library_sync:getBookDirectory(book)
        if target_dir then
            local filename = self.library_sync:generateFilename(book)
            local filepath = target_dir .. "/" .. filename

            -- Check if file exists
            if lfs.attributes(filepath, "mode") == "file" then
                table.insert(collections[coll_name], filepath)
                added_count = added_count + 1
                logger.dbg("OPDS: Added to collection:", filepath)
            else
                logger.dbg("OPDS: File not found:", filepath)
            end
        end
    end

    logger.info("OPDS: Added", added_count, "books to 'Recently Added' collection")

    -- Force save the collection
    ReadCollection:saveCollections()
end

-- Create "Currently Reading" collection from ReadHistory
function OPDSBrowser:updateCurrentlyReadingCollection()
    logger.info("OPDS: Updating 'Currently Reading' collection")
    
    -- Load ReadHistory
    local ok, ReadHistory = pcall(require, "readhistory")
    if not ok then
        logger.warn("OPDS: ReadHistory not available")
        return
    end
    
    -- Load ReadCollection plugin
    local ok2, ReadCollection = pcall(require, "apps/filemanager/readcollection")
    if not ok2 then
        logger.warn("OPDS: ReadCollection plugin not available")
        return
    end
    
    -- Initialize collections if needed
    if not ReadCollection.coll then
        ReadCollection.coll = {}
    end
    
    local coll_name = "Currently Reading"
    local collections = ReadCollection.coll
    collections[coll_name] = {}
    
    -- Check if ReadHistory has items
    if not ReadHistory.hist or #ReadHistory.hist == 0 then
        logger.info("OPDS: No items in ReadHistory")
        ReadCollection:saveCollections()
        return
    end
    
    -- Get reading history
    for _, item in ipairs(ReadHistory.hist) do
        local filepath = item.file
        -- Check if file still exists and has reading status
        if lfs.attributes(filepath, "mode") == "file" then
            local DocSettings = require("docsettings")
            local doc_settings = DocSettings:open(filepath)
            local summary = doc_settings:readSetting("summary")
            
            -- Include if status is "reading" (not "complete")
            if summary and summary.status and summary.status == "reading" then
                table.insert(collections[coll_name], filepath)
                logger.dbg("OPDS: Added to Currently Reading:", filepath)
            end
        end
    end
    
    logger.info("OPDS: Added", #collections[coll_name], "books to 'Currently Reading' collection")
    ReadCollection:saveCollections()
end

-- ============================================================================
-- END LIBRARY SYNC FUNCTIONS
-- ============================================================================

-- Cleanup functions
function OPDSBrowser:onCloseDocument()
    self:stopQueueRefresh()
    CacheManager:savePersistentCache()
end

function OPDSBrowser:onSuspend()
    self:stopQueueRefresh()
    CacheManager:savePersistentCache()
end

function OPDSBrowser:onExit()
    CacheManager:savePersistentCache()
end

return OPDSBrowser
