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
-- inside patchCoverBrowserForPlaceholders(plugin, placeholder_gen)
    -- Resolve placeholder generator: use provided placeholder_gen, or fall back to require()
    local resolved_placeholder_gen = placeholder_gen
    if not resolved_placeholder_gen then
        local ok, pg = pcall(require, "placeholder_generator")
        if ok and pg then
            resolved_placeholder_gen = pg
            logger.info("PlaceholderBadge: Resolved placeholder generator via require()")
        else
            logger.warn("PlaceholderBadge: placeholder_generator not provided and require() failed - placeholder detection disabled")
        end
    else
        logger.info("PlaceholderBadge: Using placeholder generator passed to patch")
    end

    -- Keep using resolved_placeholder_gen in the closure below.
    -- (later, inside the patched paintTo, replace any use of 'placeholder_gen' with 'resolved_placeholder_gen')



local function patchCoverBrowserForPlaceholders(plugin, placeholder_gen)
    logger.info("PlaceholderBadge: ==================== APPLYING COVERBROWSER PATCH ====================")
    logger.info("PlaceholderBadge: Patching CoverBrowser for placeholder badges")
    
    
    
    local resolved_placeholder_gen = placeholder_gen
        if not resolved_placeholder_gen then
            local ok, pg = pcall(require, "placeholder_generator")
            if ok and pg then
                resolved_placeholder_gen = pg
                logger.info("PlaceholderBadge: Resolved placeholder generator via require()")
            else
                logger.warn("PlaceholderBadge: placeholder_generator not provided and require() failed - placeholder detection disabled")
            end
        else
            logger.info("PlaceholderBadge: Using placeholder generator passed to patch")
        end

    
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
    local badge_render_failures = 0

    -- Override paintTo method to add cloud badges to placeholders
    function MosaicMenuItem:paintTo(bb, x, y)
        patch_call_count = patch_call_count + 1

        -- Log first few calls and every 25th call to confirm patch is working
        if patch_call_count <= 3 or patch_call_count % 25 == 0 then
            logger.info("PlaceholderBadge: *** paintTo called (call #" .. patch_call_count .. ") ***")
            logger.info("PlaceholderBadge: Patch statistics - calls:", patch_call_count,
                       "placeholders found:", placeholder_found_count,
                       "badges rendered:", badge_rendered_count,
                       "render failures:", badge_render_failures)
        end
        
        -- Call the original paintTo method to draw the cover normally
        orig_MosaicMenuItem_paint(self, bb, x, y)

        -- Only add badge to actual files (not directories)
        if self.is_directory or not self.filepath then
            if patch_call_count <= 3 or patch_call_count % 25 == 0 then
                logger.info("PlaceholderBadge: Skipping directory or no filepath")
            end
            return
        end

        -- Only check EPUB files
        if not self.filepath:match("%.epub$") then
            if patch_call_count <= 3 then
                logger.info("PlaceholderBadge: Skipping non-EPUB file:", self.filepath)
            end
            return
        end

        -- Log filepath for first few files to help debugging
        if patch_call_count <= 5 then
            logger.info("PlaceholderBadge: Processing EPUB file:", self.filepath)
        end

        -- Check if this is a placeholder (with caching)
        local is_placeholder = placeholder_cache[self.filepath]
        if is_placeholder == nil then
            -- Not in cache, check the file
            logger.dbg("PlaceholderBadge: Checking if placeholder (not in cache):", self.filepath)
            is_placeholder = placeholder_gen_resolved:isPlaceholder(self.filepath)
            placeholder_cache[self.filepath] = is_placeholder

            if is_placeholder then
                placeholder_found_count = placeholder_found_count + 1
                logger.info("PlaceholderBadge: ========================================")
                logger.info("PlaceholderBadge: *** PLACEHOLDER DETECTED (new) ***")
                logger.info("PlaceholderBadge: File:", self.filepath)
                logger.info("PlaceholderBadge: Total placeholders found:", placeholder_found_count)
                logger.info("PlaceholderBadge: Will attempt to render cloud badge")
                logger.info("PlaceholderBadge: ========================================")
            else
                logger.dbg("PlaceholderBadge: Not a placeholder (verified):", self.filepath)
            end

            -- Simple cache size management
            local cache_size = 0
            for _ in pairs(placeholder_cache) do
                cache_size = cache_size + 1
            end
            if cache_size > cache_max_size then
                logger.info("PlaceholderBadge: Cache size limit reached, clearing cache")
                logger.info("PlaceholderBadge: Old cache size:", cache_size)
                placeholder_cache = {}
                placeholder_cache[self.filepath] = is_placeholder
                logger.info("PlaceholderBadge: Cache cleared and reset")
            end
        else
            -- Already in cache
            if is_placeholder then
                logger.dbg("PlaceholderBadge: Placeholder (from cache):", self.filepath)
            end
        end

        if not is_placeholder then
            return
        end

        -- Get the cover image widget
        local target = self[1][1][1]
        if not target or not target.dimen then
            logger.warn("PlaceholderBadge: ========================================")
            logger.warn("PlaceholderBadge: *** BADGE RENDER FAILURE ***")
            logger.warn("PlaceholderBadge: Reason: No target widget or dimensions")
            logger.warn("PlaceholderBadge: File:", self.filepath)
            logger.warn("PlaceholderBadge: self[1]:", type(self[1]))
            if self[1] then
                logger.warn("PlaceholderBadge: self[1][1]:", type(self[1][1]))
                if self[1][1] then
                    logger.warn("PlaceholderBadge: self[1][1][1]:", type(self[1][1][1]))
                end
            end
            logger.warn("PlaceholderBadge: ========================================")
            badge_render_failures = badge_render_failures + 1
            return
        end

        logger.info("PlaceholderBadge: Starting badge render for:", self.filepath)
        logger.info("PlaceholderBadge: Target dimensions:", target.dimen.w, "x", target.dimen.h)

        -- Badge configuration (optimized for maximum visibility)
        local BADGE_W  = Screen:scaleBySize(80)  -- badge width - even larger for visibility
        local BADGE_H  = Screen:scaleBySize(40)  -- badge height - even larger
        local INSET_X  = Screen:scaleBySize(5)   -- push inward from the left edge
        local INSET_Y  = Screen:scaleBySize(5)   -- push down from the top
        local TEXT_PAD = Screen:scaleBySize(8)   -- breathing room inside the badge

        -- Use Unicode cloud character (☁ U+2601)
        -- This is the most compatible cloud character across devices
        -- Fallback options if needed in future:
        --   🌥 (U+1F325) - cloud with sun (may not render on all devices)
        --   ↓ (U+2193) - simple down arrow (universal fallback)
        local cloud_text = "☁"
        
        logger.info("PlaceholderBadge: Using cloud character:", cloud_text)

        local font_size = Screen:scaleBySize(28)  -- Larger font for better visibility
        local cloud_widget = TextWidget:new{
            text = cloud_text,
            font_size = font_size,
            face = Font:getFace("cfont", font_size),
            alignment = "center",
            fgcolor = Blitbuffer.COLOR_WHITE,  -- White text for contrast
            bold = true,
        }

        -- Calculate position (top-left corner of cover)
        local fx = x + math.floor((self.width  - target.dimen.w) / 2)
        local fy = y + math.floor((self.height - target.dimen.h) / 2)

        local bx = fx + INSET_X
        local by = fy + INSET_Y
        bx, by = math.floor(bx), math.floor(by)

        logger.info("PlaceholderBadge: Badge position:", bx, by)

        -- Create a semi-transparent blue background for the badge
        -- This ensures visibility on both light and dark book covers
        -- Use a solid color that contrasts well
        local badge_color = Blitbuffer.COLOR_DARK_GRAY
        local badge_color_name = "DARK_GRAY"
        
        -- Try to use a blue color if available (more visible and distinctive)
        -- Fallback to dark gray if blue is not available
        if Blitbuffer.COLOR_BLUE ~= nil then
            badge_color = Blitbuffer.COLOR_BLUE
            badge_color_name = "BLUE"
        elseif Blitbuffer.COLOR_DARK_BLUE ~= nil then
            badge_color = Blitbuffer.COLOR_DARK_BLUE
            badge_color_name = "DARK_BLUE"
        end
        
        logger.info("PlaceholderBadge: Using badge background color:", badge_color_name)
        
        local badge_bg = FrameContainer:new{
            background = badge_color,
            bordersize = Size.border.thick,  -- Thicker border for visibility
            border = Blitbuffer.COLOR_WHITE,  -- White border for contrast
            padding = TEXT_PAD,
            width = BADGE_W,
            height = BADGE_H,
            cloud_widget,
        }

        -- Paint the badge with error handling
        local paint_ok, paint_err = pcall(function()
            badge_bg:paintTo(bb, bx, by)
        end)
        
        if paint_ok then
            badge_rendered_count = badge_rendered_count + 1
            logger.info("PlaceholderBadge: ========================================")
            logger.info("PlaceholderBadge: *** BADGE PAINTED SUCCESSFULLY ***")
            logger.info("PlaceholderBadge: Position:", bx, by)
            logger.info("PlaceholderBadge: Size:", BADGE_W, "x", BADGE_H)
            logger.info("PlaceholderBadge: Total badges rendered:", badge_rendered_count)
            logger.info("PlaceholderBadge: File:", self.filepath)
            logger.info("PlaceholderBadge: ========================================")
        else
            badge_render_failures = badge_render_failures + 1
            logger.err("PlaceholderBadge: ========================================")
            logger.err("PlaceholderBadge: *** BADGE PAINT FAILED ***")
            logger.err("PlaceholderBadge: Error:", paint_err)
            logger.err("PlaceholderBadge: File:", self.filepath)
            logger.err("PlaceholderBadge: Total failures:", badge_render_failures)
            logger.err("PlaceholderBadge: ========================================")
        end
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
