--[[
    RestartNavigationManager - Manages navigation state across KOReader restarts
    
    After downloading a book to replace a placeholder, we store the folder path
    in a state file, restart KOReader, and navigate to that folder on startup.
]]--

local logger = require("logger")
local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")
local json = require("json")

local RestartNavigationManager = {}

-- State file path (in KOReader data directory)
local STATE_FILE = "opdsbrowser_restart_state.json"

function RestartNavigationManager:getStatePath()
    local data_dir = DataStorage:getDataDir()
    return data_dir .. "/" .. STATE_FILE
end

-- Save navigation state to file before restart
function RestartNavigationManager:saveNavigationState(folder_path, book_path)
    logger.info("RestartNavigation: Saving navigation state")
    logger.info("RestartNavigation:   Folder:", folder_path)
    logger.info("RestartNavigation:   Book:", book_path)
    
    local state = {
        folder_path = folder_path,
        book_path = book_path,
        timestamp = os.time(),
        version = 1
    }
    
    local state_path = self:getStatePath()
    local ok, err = pcall(function()
        local file = io.open(state_path, "w")
        if not file then
            logger.err("RestartNavigation: Failed to open state file for writing:", state_path)
            return
        end
        
        local json_str = json.encode(state)
        file:write(json_str)
        file:close()
        
        logger.info("RestartNavigation: State saved successfully to:", state_path)
    end)
    
    if not ok then
        logger.err("RestartNavigation: Error saving state:", err)
    end
    
    return ok
end

-- Load navigation state from file on startup
function RestartNavigationManager:loadNavigationState()
    local state_path = self:getStatePath()
    
    -- Check if state file exists
    local attr = lfs.attributes(state_path)
    if not attr or attr.mode ~= "file" then
        logger.info("RestartNavigation: No navigation state file found")
        return nil
    end
    
    logger.info("RestartNavigation: Loading navigation state from:", state_path)
    
    local ok, result = pcall(function()
        local file = io.open(state_path, "r")
        if not file then
            logger.warn("RestartNavigation: Failed to open state file for reading")
            return nil
        end
        
        local json_str = file:read("*all")
        file:close()
        
        local state = json.decode(json_str)
        
        -- Validate state
        if not state or type(state) ~= "table" then
            logger.warn("RestartNavigation: Invalid state data")
            return nil
        end
        
        if not state.folder_path or state.folder_path == "" then
            logger.warn("RestartNavigation: No folder path in state")
            return nil
        end
        
        -- Check if state is recent (within last 60 seconds to avoid stale restarts)
        local age = os.time() - (state.timestamp or 0)
        if age > 60 then
            logger.info("RestartNavigation: State too old (", age, "seconds), ignoring")
            return nil
        end
        
        logger.info("RestartNavigation: Loaded state - folder:", state.folder_path, "book:", state.book_path or "none")
        return state
    end)
    
    if not ok then
        logger.err("RestartNavigation: Error loading state:", result)
        return nil
    end
    
    return result
end

-- Clear navigation state (called after successful navigation or on error)
function RestartNavigationManager:clearNavigationState()
    local state_path = self:getStatePath()
    
    local attr = lfs.attributes(state_path)
    if not attr then
        logger.dbg("RestartNavigation: No state file to clear")
        return
    end
    
    logger.info("RestartNavigation: Clearing navigation state")
    local ok = os.remove(state_path)
    
    if ok then
        logger.info("RestartNavigation: State file removed successfully")
    else
        logger.warn("RestartNavigation: Failed to remove state file")
    end
end

-- Navigate to folder (call this on startup if state exists)
function RestartNavigationManager:navigateToFolder(folder_path)
    logger.info("RestartNavigation: Navigating to folder:", folder_path)
    
    -- Validate folder exists
    local attr = lfs.attributes(folder_path)
    if not attr or attr.mode ~= "directory" then
        logger.err("RestartNavigation: Folder does not exist:", folder_path)
        return false
    end
    
    -- Get FileManager
    local FileManager = require("apps/filemanager/filemanager")
    
    -- Close any existing FileManager instance first
    if FileManager.instance then
        logger.info("RestartNavigation: Closing existing FileManager instance")
        local UIManager = require("ui/uimanager")
        UIManager:close(FileManager.instance)
        FileManager.instance = nil
    end
    
    -- Show FileManager at the specified folder
    logger.info("RestartNavigation: Opening FileManager at:", folder_path)
    FileManager:showFiles(folder_path)
    
    -- Force refresh to ensure UI is updated
    if FileManager.instance then
        logger.info("RestartNavigation: Refreshing FileManager")
        FileManager.instance:onRefresh()
        return true
    else
        logger.err("RestartNavigation: Failed to create FileManager instance")
        return false
    end
end

-- Trigger KOReader restart
function RestartNavigationManager:restartKOReader()
    logger.info("RestartNavigation: Triggering KOReader restart")
    
    -- Try multiple restart methods in order of preference
    local UIManager = require("ui/uimanager")
    local Device = require("device")
    
    -- Method 1: UIManager.restart (most common in modern KOReader)
    if type(UIManager.restart) == "function" then
        logger.info("RestartNavigation: Using UIManager:restart()")
        UIManager:restart()
        return true
    end
    
    -- Method 2: UIManager.restartKOReader (older versions)
    if type(UIManager.restartKOReader) == "function" then
        logger.info("RestartNavigation: Using UIManager:restartKOReader()")
        UIManager:restartKOReader()
        return true
    end
    
    -- Method 3: UIManager.exitOrRestart with restart flag (alternative approach)
    if type(UIManager.exitOrRestart) == "function" then
        logger.info("RestartNavigation: Using UIManager:exitOrRestart() with restart=true")
        UIManager:exitOrRestart(nil, true)
        return true
    end
    
    -- Method 4: Device reboot (last resort, device-specific)
    if Device and type(Device.reboot) == "function" then
        logger.info("RestartNavigation: Using Device:reboot() as fallback")
        Device:reboot()
        return true
    end
    
    -- If none of the above work, log error
    logger.err("RestartNavigation: No restart method available!")
    logger.err("RestartNavigation: UIManager.restart:", type(UIManager.restart))
    logger.err("RestartNavigation: UIManager.restartKOReader:", type(UIManager.restartKOReader))
    logger.err("RestartNavigation: UIManager.exitOrRestart:", type(UIManager.exitOrRestart))
    logger.err("RestartNavigation: Device.reboot:", type(Device and Device.reboot or nil))
    
    return false
end

return RestartNavigationManager
