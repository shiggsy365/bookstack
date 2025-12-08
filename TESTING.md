# Testing Guide for Placeholder Replacement Fix

## Overview
This fix ensures that after downloading a real book to replace a placeholder via OPDS, the UI immediately reflects the change without requiring an app restart.

## Test Prerequisites
1. KOReader installed on your e-reader device
2. Bookstack OPDS server configured and running
3. The opdsbrowser.koplugin installed in KOReader
4. At least one placeholder book in your library

## Test Procedure

### Test 1: Placeholder Replacement from Reader
1. **Setup**: Create a placeholder book in your library
   - Open KOReader
   - Go to Cloud Book Library → Library Sync - OPDS
   - Sync your library to create placeholders
   
2. **Open Placeholder**: 
   - Navigate to the Library folder in File Manager
   - Open a placeholder book (you should see a cloud/download badge on the cover)
   - The placeholder should open showing minimal content
   
3. **Trigger Download**:
   - The plugin should detect it's a placeholder and auto-download
   - You'll see "Downloading book..." progress message
   - Then "Preparing downloaded book..."
   
4. **Verify Replacement**:
   - The real book should open immediately after download
   - Check the logs (see below) to verify cache invalidation
   - **CRITICAL**: The book should show real content, not placeholder content
   - Close and reopen the book - it should still be the real book

5. **Verify UI Update**:
   - Return to File Manager
   - The cloud badge should be GONE from the book cover
   - The file size should be larger (real book vs placeholder)
   - Re-opening the book should show real content

### Test 2: Placeholder Badge Persistence
1. **Setup**: Same as Test 1
2. Open File Manager to the Library folder (with CoverBrowser enabled)
3. Note which books have cloud badges (placeholders)
4. Open a placeholder book - it will auto-download
5. After replacement, return to File Manager
6. **Verify**: The cloud badge should be removed from the book cover immediately
7. **Verify**: Refreshing the view should not bring back the badge

## Verification Checklist
After running the tests above, verify:
- [ ] Placeholder book is deleted from disk
- [ ] Real book exists at the correct location
- [ ] Real book opens immediately without app restart
- [ ] Cloud badge is removed from cover
- [ ] File Manager shows updated file size
- [ ] Reopening the book shows real content
- [ ] Logs show successful cache invalidation (see below)

## Log Verification

To verify the fix is working, check KOReader logs for these messages:

```
OPDS: ==================== CACHE INVALIDATION START ====================
OPDS: Clearing ALL caches for placeholder: /path/to/placeholder.epub
OPDS: Clearing ALL caches for real book: /path/to/book.epub
OPDS: ✓ Cleared placeholder badge cache
OPDS: ✓ Cleared DocSettings cache for both paths
OPDS: ✓ Cleared DocumentRegistry cache for placeholder
OPDS: ✓ Cleared DocumentRegistry cache for real book
OPDS: ✓ Cleared DocumentRegistry provider cache
OPDS: ✓ Cleared CoverBrowser cache for: [module_name]
OPDS: ✓ Cleared CoverBrowser cover_cache for: [module_name]
OPDS: ✓ Reloaded FileManagerCollection
OPDS: ✓ Removed placeholder from database
OPDS: ✓ Invalidated OPDS cache entries matching: [pattern]
OPDS: ==================== CACHE INVALIDATION COMPLETE ====================
OPDS: Successfully downloaded and cached book, opening: /path/to/book.epub
OPDS: ✓ Background FileManager refresh complete
OPDS: ✓ Refreshed FileManager history
OPDS: ==================== UI REFRESH COMPLETE ====================
```

Each ✓ indicates a cache was successfully cleared. If you see ✗, it means that cache wasn't available (which may be normal).

## Accessing Logs

### On Device
1. Connect device via USB
2. Navigate to `.adds/koreader/` (or equivalent KOReader data directory)
3. Look for `crash.log` or `debug.log`
4. Search for "CACHE INVALIDATION" to find relevant entries

### Via SSH (if available)
**Security Warning:** Only use SSH if you have properly secured your device with strong credentials. Avoid using root access when possible.

```bash
# Example with regular user (recommended):
ssh user@your-device-ip
tail -f /path/to/koreader/crash.log | grep -A 20 "CACHE INVALIDATION"

# Example with root (if necessary, ensure device is secured):
ssh root@your-device-ip
tail -f /path/to/koreader/crash.log | grep -A 20 "CACHE INVALIDATION"

# Common KOReader log paths by device:
# - Kindle: /mnt/us/.adds/koreader/crash.log
# - Kobo: /mnt/onboard/.adds/koreader/crash.log
# - Android: /sdcard/koreader/crash.log
```

## Known Issues and Edge Cases

### Edge Case 1: File Locked by System
If the OS has locked the placeholder file:
- The plugin will retry deletion up to 3 times
- Logs will show retry attempts
- User will see error message if all retries fail

### Edge Case 2: CoverBrowser Not Loaded
- If CoverBrowser plugin is not active, its cache clearing will be skipped
- This is normal and won't affect functionality
- Logs will show which caches were skipped

### Edge Case 3: Network Issues During Download
- If download fails, placeholder remains intact
- No cache invalidation occurs
- User sees appropriate error message

## Troubleshooting

### Problem: Book still shows as placeholder after download
**Check:**
1. Verify logs show "CACHE INVALIDATION COMPLETE"
2. Check if DocumentRegistry cache was cleared (look for ✓ in logs)
3. Verify placeholder file was actually deleted
4. Check file system for both old and new paths

**Solution:**
- If logs don't show cache clearing, there may be a Lua error
- Check crash.log for any error messages
- Verify KOReader version is compatible

### Problem: Cloud badge still appears after replacement
**Check:**
1. Logs should show "✓ Cleared placeholder badge cache"
2. Verify FileManager was refreshed
3. Check if CoverBrowser was reloaded

**Solution:**
- Try manually refreshing File Manager (swipe down or menu → Refresh)
- Restart KOReader as last resort (should not be needed)

### Problem: Download succeeds but file not opened
**Check:**
1. Verify "Opening: /path/to/book.epub" appears in logs
2. Check if ReaderUI.showReader was called
3. Look for any errors after "CACHE INVALIDATION COMPLETE"

**Solution:**
- Check file permissions on downloaded book
- Verify EPUB file is valid (not corrupted)
- Check available storage space

## Success Criteria

The fix is working correctly if:
1. ✅ Real book opens immediately after download (no restart needed)
2. ✅ Cloud badge disappears from cover
3. ✅ Reopening book shows real content
4. ✅ File Manager shows updated file size
5. ✅ All cache invalidation logs show ✓
6. ✅ No error messages during replacement
7. ✅ Placeholder database updated correctly

## Regression Testing

To ensure no existing functionality was broken:

### Test: Regular (Non-Placeholder) Downloads
1. Download a book from OPDS that's not a placeholder
2. Verify it downloads and opens correctly
3. Check File Manager shows the new book
4. Logs should show DocSettings purge but not full cache invalidation

### Test: Library Sync
1. Trigger a full library sync
2. Verify placeholders are created correctly
3. Cloud badges should appear on new placeholders
4. Placeholder database should be populated

### Test: Multiple Sequential Replacements
1. Download and replace 3-5 placeholders in a row
2. Each should open correctly
3. No memory leaks or performance degradation
4. All badges should disappear

## Performance Considerations

The cache invalidation adds minimal overhead:
- All operations use pcall for safety
- Cache clearing is O(1) for direct lookups
- Pattern matching is limited to OPDS cache
- Background refresh doesn't block UI
- Total added latency: < 100ms

## Future Enhancements

Potential improvements for future versions:
1. Add metrics tracking for cache hit/miss rates
2. Implement cache warming after replacement
3. Add option to batch-download multiple placeholders
4. Implement progressive cache invalidation
5. Add cache statistics to UI
