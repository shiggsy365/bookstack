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

-- Try to load ImageWidget for potential SVG/image support
local has_imagewidget, ImageWidget = pcall(require, "ui/widget/imagewidget")

local PlaceholderBadge = {}

-- Cache for placeholder detection to improve performance
local placeholder_cache = {}
local cache_max_size = 100

function PlaceholderBadge:init(placeholder_generator)
    logger.info("PlaceholderBadge: Initializing cloud badge system")
    logger.info("PlaceholderBadge: ImageWidget available:", has_imagewidget)

    self.placeholder_generator = placeholder_generator

    -- Detect SVG icon availability
    local lfs = require("libs/libkoreader-lfs")
    local plugin_dir = (...):match("(.-)[^%.]+$")  -- Get directory path
    
    -- Try to find SVG files in plugin directory
    -- Note: In KOReader, plugin files are typically in koreader/plugins/pluginname.koplugin/
    self.cloud_svg_path = nil
    
    -- Try multiple potential paths for the cloud SVG
    local potential_paths = {
        "plugins/opdsbrowser.koplugin/cloud-badge.svg",
        "opdsbrowser.koplugin/cloud-badge.svg",
        "./cloud-badge.svg",
    }
    
    for _, path in ipairs(potential_paths) do
        local attr = lfs.attributes(path)
        if attr and attr.mode == "file" then
            self.cloud_svg_path = path
            logger.info("PlaceholderBadge: Found cloud SVG at:", path)
            break
        end
    end
    
    if not self.cloud_svg_path then
        logger.warn("PlaceholderBadge: Cloud SVG not found in standard locations")
        logger.warn("PlaceholderBadge: Will use Unicode cloud character fallback")
    end

    -- We'll be called as a plugin patch function
    return true
end

-- Patch function to be called by userpatch
local function patchCoverBrowserForPlaceholders(plugin, placeholder_gen)
    logger.info("PlaceholderBadge: ==================== APPLYING COVERBROWSER PATCH ====================")
    logger.info("PlaceholderBadge: Patching CoverBrowser for placeholder badges")

    -- Grab Cover Grid mode and the individual Cover Grid items
    local MosaicMenu = require("mosaicmenu")
    logger.info("PlaceholderBadge: ✓ Loaded MosaicMenu")
    
    local MosaicMenuItem = userpatch.getUpValue(MosaicMenu._updateItemsBuildUI, "MosaicMenuItem")

    if not MosaicMenuItem then
        logger.err("PlaceholderBadge: *** MosaicMenuItem not found - badges disabled ***")
        logger.err("PlaceholderBadge: This may indicate a KOReader version incompatibility")
        logger.err("PlaceholderBadge: MosaicMenu._updateItemsBuildUI:", type(MosaicMenu._updateItemsBuildUI))
        return
    end
    
    logger.info("PlaceholderBadge: ✓ Found MosaicMenuItem")
    logger.info("PlaceholderBadge: ✓ Preparing to patch MosaicMenuItem.paintTo")

    -- Store original MosaicMenuItem paintTo method
    local orig_MosaicMenuItem_paint = MosaicMenuItem.paintTo
    
    if not orig_MosaicMenuItem_paint then
        logger.err("PlaceholderBadge: *** MosaicMenuItem.paintTo not found ***")
        return
    end
    
    logger.info("PlaceholderBadge: ✓ Original paintTo method found")

    -- Track patch statistics
    local patch_call_count = 0
    local placeholder_found_count = 0
    local badge_rendered_count = 0

    -- Override paintTo method to add cloud badges to placeholders
    function MosaicMenuItem:paintTo(bb, x, y)
        patch_call_count = patch_call_count + 1
        
        -- Log every 50th call to avoid spam
        if patch_call_count % 50 == 0 then
            logger.info("PlaceholderBadge: Patch called", patch_call_count, "times,", placeholder_found_count, "placeholders found,", badge_rendered_count, "badges rendered")
        end
        
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
                placeholder_found_count = placeholder_found_count + 1
                logger.info("PlaceholderBadge: *** PLACEHOLDER DETECTED ***")
                logger.info("PlaceholderBadge: File:", self.filepath)
                logger.info("PlaceholderBadge: Will add cloud badge to cover")
            else
                logger.dbg("PlaceholderBadge: Not a placeholder:", self.filepath)
            end

            -- Simple cache size management
            local cache_size = 0
            for _ in pairs(placeholder_cache) do
                cache_size = cache_size + 1
            end
            if cache_size > cache_max_size then
                logger.dbg("PlaceholderBadge: Clearing cache (max size reached)")
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
            logger.warn("PlaceholderBadge: *** NO TARGET OR DIMEN FOR BADGE ***")
            logger.warn("PlaceholderBadge: File:", self.filepath)
            logger.warn("PlaceholderBadge: self[1]:", type(self[1]))
            if self[1] then
                logger.warn("PlaceholderBadge: self[1][1]:", type(self[1][1]))
                if self[1][1] then
                    logger.warn("PlaceholderBadge: self[1][1][1]:", type(self[1][1][1]))
                end
            end
            return
        end

        logger.info("PlaceholderBadge: Rendering badge for:", self.filepath)
        logger.info("PlaceholderBadge: Target dimensions:", target.dimen.w, "x", target.dimen.h)

        -- Badge configuration (more visible than before)
        local BADGE_W  = Screen:scaleBySize(70)  -- badge width - larger
        local BADGE_H  = Screen:scaleBySize(35)  -- badge height - larger
        local INSET_X  = Screen:scaleBySize(3)   -- push inward from the left edge
        local INSET_Y  = Screen:scaleBySize(3)   -- push down from the top
        local TEXT_PAD = Screen:scaleBySize(6)   -- breathing room inside the badge

        -- Try to use cloud icon (multiple Unicode options for better compatibility)
        -- ☁ (U+2601) - standard cloud
        -- 🌥 (U+1F325) - cloud with sun (may not render on all devices)
        -- ⬇ (U+2B07) - down arrow (current fallback)
        -- ↓ (U+2193) - simple down arrow
        local cloud_text = "☁"  -- Unicode cloud character
        
        logger.info("PlaceholderBadge: Using cloud character:", cloud_text)

        local font_size = Screen:scaleBySize(24)  -- Larger font for cloud
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

        logger.info("PlaceholderBadge: Badge position:", bx, by)

        -- Create a light blue/cyan background frame for the badge (more visible)
        -- Use COLOR_LIGHT_BLUE if available, otherwise LIGHT_GRAY
        local badge_color = Blitbuffer.COLOR_LIGHT_BLUE or Blitbuffer.COLOR_LIGHT_GRAY
        local badge_bg = FrameContainer:new{
            background = badge_color,
            bordersize = Size.border.thin,
            border = Blitbuffer.COLOR_DARK_GRAY,
            padding = TEXT_PAD,
            width = BADGE_W,
            height = BADGE_H,
            cloud_widget,
        }

        -- Paint the badge
        badge_bg:paintTo(bb, bx, by)
        badge_rendered_count = badge_rendered_count + 1
        logger.info("PlaceholderBadge: *** BADGE PAINTED SUCCESSFULLY ***")
        logger.info("PlaceholderBadge: Position:", bx, by)
        logger.info("PlaceholderBadge: Size:", BADGE_W, "x", BADGE_H)
        logger.info("PlaceholderBadge: File:", self.filepath)
    end

    logger.info("PlaceholderBadge: ✓ Successfully patched MosaicMenuItem.paintTo")
    logger.info("PlaceholderBadge: ✓ Placeholder badges will now appear on book covers")
    logger.info("PlaceholderBadge: ==================== COVERBROWSER PATCH COMPLETE ====================")
end

-- Register the patch with the placeholder generator reference
function PlaceholderBadge:registerPatch()
    local placeholder_gen = self.placeholder_generator

    logger.info("PlaceholderBadge: ==================== BADGE SYSTEM REGISTRATION ====================")
    
    -- Check if userpatch is available
    local has_userpatch, userpatch_module = pcall(require, "userpatch")
    if not has_userpatch then
        logger.warn("PlaceholderBadge: *** userpatch module not available - badges will not work ***")
        logger.warn("PlaceholderBadge: This is normal if you're not using a modified KOReader build")
        logger.warn("PlaceholderBadge: To enable badges, you need KOReader with userpatch support")
        return false
    end
    
    logger.info("PlaceholderBadge: ✓ userpatch module available")

    -- Register patch function that will be called when CoverBrowser loads
    local ok, err = pcall(function()
        userpatch_module.registerPatchPluginFunc("coverbrowser", function(plugin)
            logger.info("PlaceholderBadge: ==================== COVERBROWSER PATCH TRIGGERED ====================")
            logger.info("PlaceholderBadge: CoverBrowser loaded, applying placeholder badge patch now")
            patchCoverBrowserForPlaceholders(plugin, placeholder_gen)
        end)
    end)

    if ok then
        logger.info("PlaceholderBadge: ✓ Successfully registered CoverBrowser patch")
        logger.info("PlaceholderBadge: Badge will appear when:")
        logger.info("PlaceholderBadge:   1. CoverBrowser plugin is enabled")
        logger.info("PlaceholderBadge:   2. File Manager is in mosaic/grid view")
        logger.info("PlaceholderBadge:   3. Viewing a folder with placeholder books")
        logger.info("PlaceholderBadge: ==================== BADGE SYSTEM READY ====================")
        return true
    else
        logger.err("PlaceholderBadge: *** Failed to register patch with userpatch ***")
        logger.err("PlaceholderBadge: Error:", err)
        return false
    end
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
