# Cloud Badge Troubleshooting Guide

## Overview
Placeholder books should display a cloud icon (☁) badge on their cover when viewed in File Manager with CoverBrowser enabled. This guide helps diagnose and fix badge display issues.

## Requirements for Badge Display

### 1. CoverBrowser Plugin
**Status:** The CoverBrowser plugin MUST be enabled in KOReader

**Check:**
1. Open KOReader Settings
2. Go to Plugins
3. Look for "Cover Browser" or "CoverBrowser"
4. Ensure it's ENABLED

**Fix if disabled:**
1. Enable the plugin
2. Restart KOReader
3. Check File Manager view

### 2. Mosaic/Grid View
**Status:** File Manager must be in mosaic (grid) view mode

**Check:**
1. Open File Manager
2. Look at view mode (top menu)
3. Must be in "Mosaic" or "Grid" view

**Fix if wrong view:**
1. Open File Manager menu
2. Select "List mode" → "Mosaic view"
3. Badges should now appear

### 3. userpatch Support
**Status:** KOReader must have userpatch support (custom builds only)

**Check logs for:**
```
PlaceholderBadge: ✓ userpatch module available
PlaceholderBadge: ✓ Successfully registered CoverBrowser patch
```

**If you see:**
```
PlaceholderBadge: *** userpatch module not available - badges will not work ***
PlaceholderBadge: This is normal if you're not using a modified KOReader build
```

**Fix:**
- Standard KOReader builds don't include userpatch
- You need a custom KOReader build with userpatch support
- Badge feature requires modified KOReader
- Placeholder detection and download still work without badges

### 4. Actual Placeholder Books
**Status:** Books must be actual placeholders (not regular books)

**Check logs for:**
```
PlaceholderBadge: *** PLACEHOLDER DETECTED ***
PlaceholderBadge: File: /path/to/book.epub
```

**Verify placeholder:**
1. Open the book
2. Should show minimal content with "Auto-Download Placeholder" notice
3. Should trigger auto-download when opened

## Diagnostic Logs

### What to Look For

#### Badge System Initialization
```
PlaceholderBadge: Initializing cloud badge system
PlaceholderBadge: ImageWidget available: true/false
PlaceholderBadge: Cloud SVG at: /path/to/svg  (or: Cloud SVG not found)
OPDS Browser: Cloud badge overlay system initialized and registered
```

#### Registration Success
```
PlaceholderBadge: ==================== BADGE SYSTEM REGISTRATION ====================
PlaceholderBadge: ✓ userpatch module available
PlaceholderBadge: ✓ Successfully registered CoverBrowser patch
PlaceholderBadge: Badge will appear when:
PlaceholderBadge:   1. CoverBrowser plugin is enabled
PlaceholderBadge:   2. File Manager is in mosaic/grid view
PlaceholderBadge:   3. Viewing a folder with placeholder books
PlaceholderBadge: ==================== BADGE SYSTEM READY ====================
```

#### CoverBrowser Patch Applied
```
PlaceholderBadge: ==================== COVERBROWSER PATCH TRIGGERED ====================
PlaceholderBadge: CoverBrowser loaded, applying placeholder badge patch now
PlaceholderBadge: ==================== APPLYING COVERBROWSER PATCH ====================
PlaceholderBadge: ✓ Loaded MosaicMenu
PlaceholderBadge: ✓ Found MosaicMenuItem
PlaceholderBadge: ✓ Original paintTo method found
PlaceholderBadge: ✓ Successfully patched MosaicMenuItem.paintTo
PlaceholderBadge: ==================== COVERBROWSER PATCH COMPLETE ====================
```

#### Placeholder Detection
```
PlaceholderBadge: *** PLACEHOLDER DETECTED ***
PlaceholderBadge: File: /mnt/us/books/Library/Authors/Lee_Child/Killing_Floor.epub
PlaceholderBadge: Will add cloud badge to cover
```

#### Badge Rendering
```
PlaceholderBadge: Rendering badge for: /path/to/book.epub
PlaceholderBadge: Target dimensions: 120 x 180
PlaceholderBadge: Using cloud character: ☁
PlaceholderBadge: Badge position: 5, 5
PlaceholderBadge: *** BADGE PAINTED SUCCESSFULLY ***
PlaceholderBadge: Position: 5 5
PlaceholderBadge: Size: 70 x 35
```

#### Statistics (Every 50 Covers)
```
PlaceholderBadge: Patch called 50 times, 3 placeholders found, 3 badges rendered
PlaceholderBadge: Patch called 100 times, 5 placeholders found, 5 badges rendered
```

## Common Issues and Solutions

### Issue 1: "userpatch module not available"
**What it means:** KOReader build doesn't support badge patching

**Symptoms:**
- No badges appear
- Log shows: "userpatch module not available"

**Solutions:**
1. **Option A:** Use custom KOReader build with userpatch
2. **Option B:** Live without badges (download feature still works)
3. **Option C:** Wait for standard KOReader to add userpatch support

**Impact:** Low - placeholder detection and download work fine

### Issue 2: "MosaicMenuItem not found"
**What it means:** KOReader version incompatibility

**Symptoms:**
- Patch registered but not applied
- Log shows: "MosaicMenuItem not found - badges disabled"

**Solutions:**
1. Update to latest KOReader version
2. Check KOReader version compatibility
3. Report version number in GitHub issue

**Impact:** Medium - indicates version mismatch

### Issue 3: Badges Not Appearing in Grid View
**What it means:** Multiple possible causes

**Troubleshooting Steps:**

1. **Check CoverBrowser is enabled**
   - Settings → Plugins → CoverBrowser → Enabled
   
2. **Check view mode**
   - File Manager → Menu → View mode → Mosaic
   
3. **Check placeholders exist**
   - Look for log: "PLACEHOLDER DETECTED"
   - Try opening book to verify it's a placeholder
   
4. **Check cache**
   - Badge cache might be stale
   - Refresh File Manager (swipe down or menu → Refresh)
   
5. **Check patch application**
   - Look for "COVERBROWSER PATCH COMPLETE" in logs
   - If missing, CoverBrowser never loaded

### Issue 4: Badges Stuck After Download
**What it means:** Badge cache not cleared

**Symptoms:**
- Downloaded book still shows cloud badge
- Book opens normally (real content)

**Check logs for:**
```
OPDS: ✓ Cleared placeholder badge cache
```

**Solutions:**
1. Refresh File Manager (swipe down)
2. Close and reopen File Manager
3. Restart KOReader
4. Check cache clearing logs

**Expected behavior:**
- Badge should disappear after download
- If restart navigation worked, should be gone after restart

### Issue 5: No Target or Dimen for Badge
**What it means:** Cover widget structure unexpected

**Symptoms:**
- Log shows: "NO TARGET OR DIMEN FOR BADGE"
- Detailed widget structure logged

**Causes:**
- Cover not loaded yet
- Different CoverBrowser version
- Widget structure changed

**Solutions:**
1. Wait for covers to load
2. Refresh File Manager
3. Check CoverBrowser version
4. Report issue with logs

## Testing Badge Display

### Test Procedure

1. **Create test placeholders:**
   ```
   Cloud Book Library → Library Sync - OPDS
   ```

2. **Enable CoverBrowser:**
   ```
   Settings → Plugins → Cover Browser → Enable
   ```

3. **Set Mosaic view:**
   ```
   File Manager → Menu → View mode → Mosaic
   ```

4. **Navigate to Library folder:**
   ```
   File Manager → Library → Authors → [Author Name]
   ```

5. **Check for badges:**
   - Placeholder books should have cloud (☁) icon
   - Icon should be in top-left corner of cover
   - Icon should have light blue/gray background

6. **Test download:**
   - Open a placeholder book
   - Let it auto-download
   - After restart, badge should be gone

### Expected Visual

```
┌─────────────────┐
│ ☁              │  ← Cloud badge (top-left)
│                 │
│   Book Cover    │
│     Image       │
│                 │
│  Killing Floor  │
│   Lee Child     │
└─────────────────┘
```

## Badge Visual Properties

- **Icon:** ☁ (Unicode cloud character, U+2601)
- **Size:** 70x35 pixels (scaled by device)
- **Position:** Top-left corner, 3px inset
- **Background:** Light blue or light gray
- **Border:** Thin dark gray border
- **Text color:** Black
- **Font size:** 24pt (scaled by device)

## Alternative Badge Characters

If cloud (☁) doesn't render on your device, the code could be modified to use:
- ⬇ (U+2B07) - Down arrow
- ↓ (U+2193) - Simple arrow
- 🌥 (U+1F325) - Cloud with sun (may not render on e-ink)

## Performance Considerations

### Badge Rendering Cost
- Very low: < 1ms per badge
- Cached after first check
- Only checks .epub files
- Skips directories automatically

### Cache Management
- Automatic cache pruning at 100 entries
- Cache cleared when book downloaded
- No manual cache management needed

## Accessing Logs

### Log File Locations
- Kindle: `/mnt/us/.adds/koreader/crash.log`
- Kobo: `/mnt/onboard/.adds/koreader/crash.log`
- Android: `/sdcard/koreader/crash.log`

### Grep for Badge Messages
```bash
grep "PlaceholderBadge" /path/to/crash.log
grep "PLACEHOLDER DETECTED" /path/to/crash.log
grep "BADGE PAINTED" /path/to/crash.log
```

### Real-time Monitoring (if SSH available)
```bash
tail -f /path/to/crash.log | grep -i badge
```

## Reporting Issues

When reporting badge display issues, please include:

1. **KOReader version**
2. **Device model**
3. **CoverBrowser status** (enabled/disabled)
4. **userpatch availability** (from logs)
5. **Relevant log sections:**
   - Badge system initialization
   - Patch registration
   - Patch application
   - Placeholder detection (if any)
   - Badge rendering (if any)

## Feature Limitations

### Known Limitations
1. Requires userpatch support (custom KOReader builds)
2. Only works in CoverBrowser mosaic view
3. Only shows on .epub files
4. Badge is text-based (no actual SVG rendering in standard KOReader)
5. Cloud character (☁) may not render on all devices/fonts

### Won't Fix
- Badge in list view (CoverBrowser limitation)
- SVG rendering without ImageWidget support
- Badge customization without plugin settings
- Badge on non-epub files

## Success Criteria

Badge system is working correctly if:
1. ✅ Logs show "BADGE SYSTEM READY"
2. ✅ Logs show "COVERBROWSER PATCH COMPLETE"
3. ✅ Logs show "PLACEHOLDER DETECTED" for placeholder books
4. ✅ Logs show "BADGE PAINTED SUCCESSFULLY" when viewing placeholders
5. ✅ Cloud icon visible on placeholder covers in mosaic view
6. ✅ Badge disappears after book download

## Summary

The cloud badge feature requires:
- ✅ CoverBrowser plugin enabled
- ✅ Mosaic/grid view mode
- ✅ userpatch support (custom KOReader build)
- ✅ Actual placeholder books

If any requirement is missing, badges won't appear, but download functionality is unaffected.
