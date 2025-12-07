local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
local logger = require("logger")
local Constants = require("constants")

local SettingsManager = {
    settings = nil,
    settings_file = nil,
}

function SettingsManager:init()
    self.settings_file = DataStorage:getSettingsDir() .. "/" .. Constants.SETTINGS_FILE
    self.settings = LuaSettings:open(self.settings_file)
    logger.info("SettingsManager: Initialized with file:", self.settings_file)
end

function SettingsManager:get(key, default)
    local value = self.settings:readSetting(key)
    if value == nil then
        return default
    end
    return value
end

function SettingsManager:set(key, value)
    self.settings:saveSetting(key, value)
    logger.dbg("SettingsManager: Set", key, "=", tostring(value))
end

function SettingsManager:save()
    self.settings:flush()
    logger.info("SettingsManager: Settings saved")
end

function SettingsManager:delete(key)
    self.settings:delSetting(key)
    logger.dbg("SettingsManager: Deleted", key)
end

-- Get all settings as a table
function SettingsManager:getAll()
    return {
        opds_url = self:get("opds_url", ""),
        opds_username = self:get("opds_username", ""),
        opds_password = self:get("opds_password", ""),
        ephemera_url = self:get("ephemera_url", ""),
        download_dir = self:get("download_dir", DataStorage:getDataDir() .. "/mnt/us/books"),
        hardcover_token = self:get("hardcover_token", ""),
        use_publisher_as_series = self:get("use_publisher_as_series", false),
        enable_library_check = self:get("enable_library_check", true),
        library_check_page_limit = self:get("library_check_page_limit", Constants.DEFAULT_PAGE_LIMIT),
        cache_ttl = self:get("cache_ttl", Constants.CACHE_TTL),
        enable_persistent_cache = self:get("enable_persistent_cache", true),
    }
end

-- Set multiple settings at once
function SettingsManager:setAll(settings_table)
    for key, value in pairs(settings_table) do
        self:set(key, value)
    end
    self:save()
end

-- Validate settings
function SettingsManager:validate(settings_table)
    local errors = {}
    
    -- Validate OPDS URL
    if settings_table.opds_url and settings_table.opds_url ~= "" then
        if not settings_table.opds_url:match("^https?://") then
            table.insert(errors, "OPDS URL must start with http:// or https://")
        end
    end
    
    -- Validate Ephemera URL
    if settings_table.ephemera_url and settings_table.ephemera_url ~= "" then
        if not settings_table.ephemera_url:match("^https?://") then
            table.insert(errors, "Ephemera URL must start with http:// or https://")
        end
    end
    
    -- Validate page limit
    if settings_table.library_check_page_limit then
        local limit = tonumber(settings_table.library_check_page_limit)
        if not limit or limit < 0 then
            table.insert(errors, "Page limit must be a number >= 0")
        end
    end
    
    return #errors == 0, errors
end

-- Export settings to a table for backup
function SettingsManager:export()
    return self:getAll()
end

-- Import settings from a table
function SettingsManager:import(settings_table)
    local valid, errors = self:validate(settings_table)
    if not valid then
        return false, errors
    end
    
    self:setAll(settings_table)
    return true
end

-- Reset to defaults
function SettingsManager:reset()
    local defaults = {
        opds_url = "",
        opds_username = "",
        opds_password = "",
        ephemera_url = "",
        download_dir = DataStorage:getDataDir() .. "/mnt/us/books",
        hardcover_token = "",
        use_publisher_as_series = false,
        enable_library_check = true,
        library_check_page_limit = Constants.DEFAULT_PAGE_LIMIT,
        cache_ttl = Constants.CACHE_TTL,
        enable_persistent_cache = true,
    }
    
    self:setAll(defaults)
    logger.info("SettingsManager: Reset to defaults")
end

return SettingsManager
