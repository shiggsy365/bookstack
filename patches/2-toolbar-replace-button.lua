--[[
    User Patch for Project: Title + OPDS Browser
    
    This replaces the favourites toolbar button with shortcuts to:
    - Tap: Open OPDS Browser Menu
    - Hold: Sync OPDS Library
    
    NOTE: Requires the OPDS Browser plugin to be installed.
--]]
local userpatch = require("userpatch")
-- Removed: local Dispatcher = require("dispatcher") -- Not needed
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")

-- =========================== CONFIGURATION =========================== -
local button_to_replace = "left2"       -- Favorites (heart)
local new_icon = "appbar.search"
-- ===================================================================== -

local function ensurePluginLoaded()
    if not _G.opds_plugin_instance then
        UIManager:show(InfoMessage:new{
            text = "OPDS Browser plugin is not loaded yet.",
            timeout = 3
        })
        return false
    end
    return true
end

-- Tap Callback: Open Menu
local new_tap_callback = function()
    if ensurePluginLoaded() then
        -- Call function directly on the global instance
        _G.opds_plugin_instance:showMainMenu()
    end
end

-- Hold Callback: Sync Library
local new_hold_callback = function()
    if ensurePluginLoaded() then
        -- Call function directly on the global instance
        _G.opds_plugin_instance:buildPlaceholderLibrary()
    end
end

-- Patch Logic
local function patchCoverBrowser(plugin)
    local TitleBar = require("titlebar")
    local orig_TitleBar_init = TitleBar.init
    TitleBar.init = function(self)
        self[button_to_replace .. "_icon"] = new_icon or self[button_to_replace .. "_icon"]
        self[button_to_replace .. "_icon_tap_callback"] = new_tap_callback or self[button_to_replace .. "_icon_tap_callback"]
        self[button_to_replace .. "_icon_hold_callback"] = new_hold_callback or self[button_to_replace .. "_icon_hold_callback"]
        orig_TitleBar_init(self)
    end
end
userpatch.registerPatchPluginFunc("coverbrowser", patchCoverBrowser)
