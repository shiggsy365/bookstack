-- opdsbrowser.koplugin/placeholder_badge.lua
-- NO-OP placeholder badge module: disables cloud-badge display while keeping API compatibility.
-- This file intentionally does nothing so the rest of the plugin code that calls it
-- won't error, and no cloud icons are rendered.

local logger = require("logger")

local PlaceholderBadge = {}

-- Keep init, registerPatch, isPlaceholderCached, clearCache, cleanup functions
-- so any calls from main.lua / other modules are safe.

function PlaceholderBadge:init(placeholder_generator)
    logger.info("PlaceholderBadge: NO-OP initialized (cloud badge disabled)")
    -- store generator reference for compatibility if needed
    self.placeholder_generator = placeholder_generator
    return true
end

function PlaceholderBadge:registerPatch()
    logger.info("PlaceholderBadge: NO-OP registerPatch called (cloud badge disabled)")
    return true
end

function PlaceholderBadge:isPlaceholderCached(filepath)
    -- Always return false to avoid any badge-dependent logic elsewhere
    return false
end

function PlaceholderBadge:clearCache(filepath)
    -- no-op
    logger.dbg("PlaceholderBadge: NO-OP clearCache called for", filepath)
end

function PlaceholderBadge:cleanup()
    logger.info("PlaceholderBadge: NO-OP cleanup")
end

return PlaceholderBadge
