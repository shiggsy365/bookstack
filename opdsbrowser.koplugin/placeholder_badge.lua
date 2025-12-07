--[[
    PlaceholderBadge - Adds cloud icon badges to placeholder book covers

    This module hooks into KOReader's FileChooser to display a cloud icon
    badge on placeholder files, indicating they haven't been downloaded yet.

    Uses FileChooser.getListItem patching (works in all file browser views)
]]--

local logger = require("logger")
local ImageWidget = require("ui/widget/imagewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local TopContainer = require("ui/widget/container/topcontainer")
local Size = require("ui/size")
local Blitbuffer = require("ffi/blitbuffer")

local PlaceholderBadge = {}

-- Reference to the original getListItem function
local original_getListItem = nil

-- Cache for placeholder detection to improve performance
local placeholder_cache = {}
local cache_max_size = 100

function PlaceholderBadge:init(placeholder_generator)
    logger.info("PlaceholderBadge: Initializing cloud badge overlay system (FileChooser method)")

    self.placeholder_generator = placeholder_generator

    -- Hook into FileChooser.getListItem
    local ok, FileChooser = pcall(require, "ui/widget/filechooser")
    if not ok or not FileChooser then
        logger.warn("PlaceholderBadge: FileChooser not available, badges disabled")
        return false
    end

    -- Store the original getListItem function
    original_getListItem = FileChooser.getListItem

    -- Create a reference to self for use in the hook
    local badge_module = self

    -- Override getListItem to add cloud badges to placeholders
    FileChooser.getListItem = function(self, dirpath, f, fullpath, attributes, collate)
        -- Call the original function to get the list item
        local item = original_getListItem(self, dirpath, f, fullpath, attributes, collate)

        -- Only add badge to EPUB files (placeholders)
        if item and fullpath and fullpath:match("%.epub$") then
            -- Check if this is a placeholder
            if badge_module:isPlaceholderCached(fullpath) then
                badge_module:addCloudBadgeToItem(item)
            end
        end

        return item
    end

    logger.info("PlaceholderBadge: Successfully hooked into FileChooser.getListItem")
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
        logger.dbg("PlaceholderBadge: Clearing cache (size:", cache_size, ")")
        placeholder_cache = {}
        placeholder_cache[filepath] = is_placeholder
    end

    return is_placeholder
end

-- Add cloud badge overlay to a file list item
function PlaceholderBadge:addCloudBadgeToItem(item)
    -- Only add badge if item doesn't already have one
    if item._placeholder_badge_added then
        return
    end

    -- Mark that we've added the badge
    item._placeholder_badge_added = true

    -- Create cloud icon widget
    local badge_size = Size.item.height_default * 0.35
    local cloud_icon = self:createCloudIcon(badge_size)

    if not cloud_icon then
        return -- Failed to create icon
    end

    -- Position cloud icon in top-left corner
    local icon_container = TopContainer:new{
        dimen = item[1]:getSize(),
        ImageWidget:new{
            image = cloud_icon,
            width = badge_size,
            height = badge_size,
            alpha = true,
        },
        overlap_offset = { Size.padding.small, Size.padding.small },
    }

    -- Wrap the original item content with an OverlapGroup to add the cloud badge
    local original_widget = item[1]
    item[1] = OverlapGroup:new{
        dimen = original_widget:getSize(),
        original_widget,
        icon_container,
    }
end

-- Create cloud icon (load SVG or create fallback)
function PlaceholderBadge:createCloudIcon(size)
    -- Try to load the SVG cloud icon
    local ok, image = pcall(function()
        local img_widget = ImageWidget:new{
            file = "plugins/opdsbrowser.koplugin/cloud-badge.svg",
            width = size,
            height = size,
            alpha = true,
        }
        img_widget:_render()
        return img_widget:getImage()
    end)

    if ok and image then
        return image
    end

    -- Fallback: Create a simple blue circle
    logger.dbg("PlaceholderBadge: SVG load failed, using fallback circle")
    local bb = Blitbuffer.new(size, size, Blitbuffer.TYPE_BBRGB32)
    bb:fill(Blitbuffer.COLOR_WHITE)

    local radius = size / 2
    local center = radius

    -- Draw blue circle (cloud color #5AB8FF)
    bb:paintCircle(center, center, radius * 0.9, Blitbuffer.COLOR_LIGHT_GRAY, 1.0)

    return bb
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

-- Restore original getListItem (cleanup on plugin disable)
function PlaceholderBadge:cleanup()
    if original_getListItem then
        local ok, FileChooser = pcall(require, "ui/widget/filechooser")
        if ok and FileChooser then
            FileChooser.getListItem = original_getListItem
            logger.info("PlaceholderBadge: Restored original getListItem function")
        end
    end

    placeholder_cache = {}
end

return PlaceholderBadge
