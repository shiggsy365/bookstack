--[[
    PlaceholderBadge - Adds cloud icon badges to placeholder book covers

    This module hooks into KOReader's CoverBrowser to display a badge
    on placeholder files, indicating they haven't been downloaded yet.

    Uses the same pattern as successful user patches (paintTo override)
]]--

local logger = require("logger")
local userpatch = require("userpatch")
local TextWidget = require("ui/widget/textwidget")
local FrameContainer = require("ui/widget/container/framecontainer")
local Font = require("ui/font")
local Screen = require("device").screen
local Size = require("ui/size")
local Blitbuffer = require("ffi/blitbuffer")

local PlaceholderBadge = {}

-- Cache for placeholder detection to improve performance
local placeholder_cache = {}
local cache_max_size = 100

function PlaceholderBadge:init(placeholder_generator)
    logger.info("PlaceholderBadge: Initializing cloud badge system")

    self.placeholder_generator = placeholder_generator

    -- We'll be called as a plugin patch function
    return true
end

-- Patch function to be called by userpatch
local function patchCoverBrowserForPlaceholders(plugin, placeholder_gen)
    logger.info("PlaceholderBadge: Patching CoverBrowser for placeholder badges")

    -- Grab Cover Grid mode and the individual Cover Grid items
    local MosaicMenu = require("mosaicmenu")
    local MosaicMenuItem = userpatch.getUpValue(MosaicMenu._updateItemsBuildUI, "MosaicMenuItem")

    if not MosaicMenuItem then
        logger.warn("PlaceholderBadge: MosaicMenuItem not found, badges disabled")
        return
    end

    -- Store original MosaicMenuItem paintTo method
    local orig_MosaicMenuItem_paint = MosaicMenuItem.paintTo

    -- Override paintTo method to add cloud badges to placeholders
    function MosaicMenuItem:paintTo(bb, x, y)
        -- Call the original paintTo method to draw the cover normally
        orig_MosaicMenuItem_paint(self, bb, x, y)

        -- Only add badge to actual files (not directories)
        if self.is_directory or not self.filepath then
            return
        end

        -- Only check EPUB files
        if not self.filepath:match("%.epub$") then
            return
        end

        -- Check if this is a placeholder (with caching)
        local is_placeholder = placeholder_cache[self.filepath]
        if is_placeholder == nil then
            is_placeholder = placeholder_gen:isPlaceholder(self.filepath)
            placeholder_cache[self.filepath] = is_placeholder

            if is_placeholder then
                logger.dbg("PlaceholderBadge: Found placeholder, adding badge:", self.filepath)
            end

            -- Simple cache size management
            local cache_size = 0
            for _ in pairs(placeholder_cache) do
                cache_size = cache_size + 1
            end
            if cache_size > cache_max_size then
                logger.dbg("PlaceholderBadge: Clearing cache")
                placeholder_cache = {}
                placeholder_cache[self.filepath] = is_placeholder
            end
        end

        if not is_placeholder then
            return
        end

        -- Get the cover image widget
        local target = self[1][1][1]
        if not target or not target.dimen then
            logger.dbg("PlaceholderBadge: No target or dimen for badge")
            return
        end

        -- Badge configuration (more visible than before)
        local BADGE_W  = Screen:scaleBySize(70)  -- badge width - larger
        local BADGE_H  = Screen:scaleBySize(35)  -- badge height - larger
        local INSET_X  = Screen:scaleBySize(3)   -- push inward from the left edge
        local INSET_Y  = Screen:scaleBySize(3)   -- push down from the top
        local TEXT_PAD = Screen:scaleBySize(6)   -- breathing room inside the badge

        -- Use a down arrow character (more visible than cloud)
        local cloud_text = "⬇"  -- Down arrow

        local font_size = Screen:scaleBySize(22)  -- Larger font
        local cloud_widget = TextWidget:new{
            text = cloud_text,
            font_size = font_size,
            face = Font:getFace("cfont", font_size),
            alignment = "center",
            fgcolor = Blitbuffer.COLOR_BLACK,  -- Black for better contrast
            bold = true,
        }

        -- Calculate position (top-left corner of cover)
        local fx = x + math.floor((self.width  - target.dimen.w) / 2)
        local fy = y + math.floor((self.height - target.dimen.h) / 2)

        local bx = fx + INSET_X
        local by = fy + INSET_Y
        bx, by = math.floor(bx), math.floor(by)

        -- Create a light blue/cyan background frame for the badge (more visible)
        local badge_bg = FrameContainer:new{
            background = Blitbuffer.COLOR_LIGHT_GRAY,
            bordersize = Size.border.thin,
            border = Blitbuffer.COLOR_DARK_GRAY,
            padding = TEXT_PAD,
            width = BADGE_W,
            height = BADGE_H,
            cloud_widget,
        }

        -- Paint the badge
        badge_bg:paintTo(bb, bx, by)
        logger.dbg("PlaceholderBadge: Painted badge at", bx, by, "for", self.filepath)
    end

    logger.info("PlaceholderBadge: Successfully patched CoverBrowser")
end

-- Register the patch with the placeholder generator reference
function PlaceholderBadge:registerPatch()
    local placeholder_gen = self.placeholder_generator

    -- Register patch function that will be called when CoverBrowser loads
    userpatch.registerPatchPluginFunc("coverbrowser", function(plugin)
        patchCoverBrowserForPlaceholders(plugin, placeholder_gen)
    end)

    logger.info("PlaceholderBadge: Registered CoverBrowser patch")
end

-- Check if file is a placeholder (for external use)
function PlaceholderBadge:isPlaceholderCached(filepath)
    local cached = placeholder_cache[filepath]
    if cached ~= nil then
        return cached
    end

    local is_placeholder = self.placeholder_generator:isPlaceholder(filepath)
    placeholder_cache[filepath] = is_placeholder
    return is_placeholder
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

-- No cleanup needed for userpatch-based approach
function PlaceholderBadge:cleanup()
    placeholder_cache = {}
end

return PlaceholderBadge
