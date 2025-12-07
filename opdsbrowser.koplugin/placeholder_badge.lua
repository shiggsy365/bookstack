--[[
    PlaceholderBadge - Adds cloud icon badges to placeholder book covers

    This module hooks into KOReader's cover rendering to display a cloud icon
    badge on placeholder files, indicating they haven't been downloaded yet.
]]--

local logger = require("logger")
local ImageWidget = require("ui/widget/imagewidget")
local Size = require("ui/size")

local PlaceholderBadge = {}

-- Reference to the original paintTo method
local original_paintTo = nil

-- Cache for placeholder detection to improve performance
local placeholder_cache = {}
local cache_max_size = 100

function PlaceholderBadge:init(placeholder_generator)
    logger.info("PlaceholderBadge: Initializing cloud badge overlay system")

    self.placeholder_generator = placeholder_generator

    -- Hook into MosaicMenuItem if CoverBrowser is available
    local ok, MosaicMenu = pcall(require, "plugins/coverbrowser.koplugin/mosaicmenu")
    if not ok or not MosaicMenu then
        logger.warn("PlaceholderBadge: CoverBrowser not available, badges disabled")
        return false
    end

    local MosaicMenuItem = MosaicMenu.MosaicMenuItem
    if not MosaicMenuItem then
        logger.warn("PlaceholderBadge: MosaicMenuItem not found, badges disabled")
        return false
    end

    -- Store the original paintTo method
    original_paintTo = MosaicMenuItem.paintTo

    -- Override the paintTo method to add cloud badges
    MosaicMenuItem.paintTo = function(menu_item, bb, x, y)
        -- First, paint the original cover
        original_paintTo(menu_item, bb, x, y)

        -- Check if this item has a filepath and is a placeholder
        if menu_item.filepath and self:isPlaceholderCached(menu_item.filepath) then
            self:drawCloudBadge(bb, x, y, menu_item.width, menu_item.height)
        end
    end

    logger.info("PlaceholderBadge: Successfully hooked into MosaicMenuItem.paintTo")
    return true
end

-- Check if file is a placeholder with caching
function PlaceholderBadge:isPlaceholderCached(filepath)
    -- Check cache first
    if placeholder_cache[filepath] ~= nil then
        return placeholder_cache[filepath]
    end

    -- Not in cache, check with placeholder generator
    local is_placeholder = self.placeholder_generator:isPlaceholder(filepath)

    -- Add to cache
    placeholder_cache[filepath] = is_placeholder

    -- Simple cache size management - clear if too large
    local cache_size = 0
    for _ in pairs(placeholder_cache) do
        cache_size = cache_size + 1
    end

    if cache_size > cache_max_size then
        logger.info("PlaceholderBadge: Clearing cache (size:", cache_size, ")")
        placeholder_cache = {}
        placeholder_cache[filepath] = is_placeholder
    end

    return is_placeholder
end

-- Draw cloud badge at top-left corner of cover
function PlaceholderBadge:drawCloudBadge(bb, x, y, width, height)
    -- Badge size - scale based on cover size but keep reasonable bounds
    local badge_size = math.min(math.max(width * 0.25, Size.item.height_default * 0.3), Size.item.height_default * 0.5)

    -- Position: top-left corner with small inset
    local inset = Size.padding.small or 2
    local badge_x = x + inset
    local badge_y = y + inset

    -- Try to load and render the cloud SVG icon
    local ok, badge = pcall(function()
        return ImageWidget:new{
            file = "plugins/opdsbrowser.koplugin/cloud-badge.svg",
            width = badge_size,
            height = badge_size,
            alpha = true, -- Enable alpha channel for transparency
        }
    end)

    if ok and badge then
        -- Paint the badge onto the cover
        badge:paintTo(bb, badge_x, badge_y)
        badge:free() -- Free the image widget resources
    else
        logger.warn("PlaceholderBadge: Failed to load cloud badge icon")

        -- Fallback: Draw a simple colored circle as indicator
        local Screen = require("device").screen
        local radius = badge_size / 2
        local center_x = badge_x + radius
        local center_y = badge_y + radius

        -- Draw white circle background
        bb:paintCircle(center_x, center_y, radius, 0xFF, 0.9)
        -- Draw blue circle (cloud color)
        bb:paintCircle(center_x, center_y, radius * 0.8, 0x5A, 1.0)
    end
end

-- Clear the cache (useful when placeholders are downloaded)
function PlaceholderBadge:clearCache(filepath)
    if filepath then
        placeholder_cache[filepath] = nil
        logger.dbg("PlaceholderBadge: Cleared cache for:", filepath)
    else
        placeholder_cache = {}
        logger.info("PlaceholderBadge: Cleared entire cache")
    end
end

-- Restore original paintTo method (cleanup on plugin disable)
function PlaceholderBadge:cleanup()
    if original_paintTo then
        local ok, MosaicMenu = pcall(require, "plugins/coverbrowser.koplugin/mosaicmenu")
        if ok and MosaicMenu and MosaicMenu.MosaicMenuItem then
            MosaicMenu.MosaicMenuItem.paintTo = original_paintTo
            logger.info("PlaceholderBadge: Restored original paintTo method")
        end
    end

    placeholder_cache = {}
end

return PlaceholderBadge
