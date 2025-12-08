# KOReader Restart and Navigation Feature

## Overview
After downloading a book to replace a placeholder, KOReader will automatically restart and navigate to the folder containing the newly downloaded book. This ensures all caches are completely cleared and the UI displays the real book immediately.

## How It Works

### 1. Download Completion
When a placeholder book is successfully downloaded:
1. The plugin clears all caches (DocSettings, DocumentRegistry, CoverBrowser, etc.)
2. Saves the navigation state to a JSON file in the KOReader data directory
3. Shows a message: "Download complete! Restarting KOReader to clear cache and show book..."
4. Triggers a KOReader restart after 2 seconds

### 2. Restart Process
The restart system tries multiple methods for compatibility:
1. `UIManager:restart()` - Modern KOReader versions
2. `UIManager:restartKOReader()` - Older versions
3. `UIManager:exitOrRestart(nil, true)` - Alternative method
4. `Device:reboot()` - Last resort (device-specific)

If restart fails, the book is opened directly as a fallback.

### 3. Post-Restart Navigation
On KOReader startup (2 seconds after init):
1. Plugin checks for navigation state file
2. If found and recent (< 60 seconds old):
   - Navigates to the saved folder path
   - Shows notification: "Navigated to downloaded book folder"
   - Clears the state file
3. If state is stale or missing, no action is taken

## State File Format

Location: `<KOReader data dir>/opdsbrowser_restart_state.json`

Example content:
```json
{
  "folder_path": "/mnt/us/books/Library/Authors/Lee Child",
  "book_path": "/mnt/us/books/Library/Authors/Lee Child/Killing_Floor.epub",
  "timestamp": 1670454321,
  "version": 1
}
```

## Configuration

No configuration needed - the feature is automatic.

## Compatibility

### Supported KOReader Versions
- Modern versions with `UIManager.restart` support
- Older versions with `UIManager.restartKOReader` support
- Versions with `UIManager.exitOrRestart` support
- Device-specific versions with `Device.reboot` support

### Fallback Behavior
If restart is not available:
- Book opens directly without restart
- All caches are still cleared
- User sees error: "Restart failed. Opening book directly."

## Troubleshooting

### Restart Not Working
**Symptoms:** Book opens but no restart occurs

**Check:**
1. Look for log message: "RestartNavigation: No restart method available!"
2. Check which methods are available in logs

**Solution:**
- Update to latest KOReader version
- Restart feature may not be available on your device
- Fallback (direct open) still works correctly

### Navigation Not Working After Restart
**Symptoms:** KOReader restarts but doesn't navigate to folder

**Check:**
1. Look for: "RestartNavigation: No navigation state file found"
2. Check: "RestartNavigation: State too old (X seconds), ignoring"

**Possible Causes:**
- Restart took > 60 seconds
- State file was deleted
- State file corrupted

**Solution:**
- Navigate to the folder manually (default: `/Library/Authors/<Author Name>/`)
- Check KOReader data directory for state file
- State expiry is intentional to prevent stale navigation

### Folder Doesn't Exist
**Symptoms:** Error message "Folder does not exist"

**Check logs:**
```
RestartNavigation: Folder does not exist: /path/to/folder
```

**Possible Causes:**
- Book was moved or deleted during restart
- Folder path changed
- SD card unmounted/remounted

**Solution:**
- Find book manually
- Trigger download again
- Check filesystem for book location

## Log Messages

### Successful Flow
```
OPDS: ==================== CACHE INVALIDATION COMPLETE ====================
RestartNavigation: Saving navigation state
RestartNavigation:   Folder: /mnt/us/books/Library/Authors/Lee Child
RestartNavigation:   Book: /mnt/us/books/Library/Authors/Lee Child/Killing_Floor.epub
RestartNavigation: State saved successfully to: /mnt/us/.adds/koreader/opdsbrowser_restart_state.json
RestartNavigation: Triggering KOReader restart
RestartNavigation: Using UIManager:restart()

[KOReader restarts]

OPDS Browser: Checking for restart navigation state
RestartNavigation: Loading navigation state from: /mnt/us/.adds/koreader/opdsbrowser_restart_state.json
RestartNavigation: Loaded state - folder: /mnt/us/books/Library/Authors/Lee Child book: Killing_Floor.epub
OPDS Browser: Found restart navigation state, navigating to: /mnt/us/books/Library/Authors/Lee Child
RestartNavigation: Navigating to folder: /mnt/us/books/Library/Authors/Lee Child
RestartNavigation: Opening FileManager at: /mnt/us/books/Library/Authors/Lee Child
RestartNavigation: Refreshing FileManager
OPDS Browser: Successfully navigated to folder after restart
RestartNavigation: Clearing navigation state
RestartNavigation: State file removed successfully
```

### Restart Failed (Fallback)
```
OPDS: ==================== CACHE INVALIDATION COMPLETE ====================
RestartNavigation: Triggering KOReader restart
RestartNavigation: No restart method available!
RestartNavigation: UIManager.restart: nil
RestartNavigation: UIManager.restartKOReader: nil
RestartNavigation: UIManager.exitOrRestart: nil
RestartNavigation: Device.reboot: nil
OPDS: Restart failed, falling back to direct book open
[Book opens directly]
```

## Security Considerations

### State File Security
- State file is plain JSON (no sensitive data)
- Contains only folder paths and timestamps
- Auto-expires after 60 seconds
- Cleared after use

### Path Validation
- Folder existence checked before navigation
- No directory traversal risk
- Paths are validated against filesystem

## Performance Impact

- State save: < 10ms
- State load: < 10ms
- Restart time: depends on device (typically 5-20 seconds)
- Total added time: restart duration only

## Future Enhancements

Potential improvements:
1. Configurable state expiry time
2. Option to disable restart (use direct open)
3. Navigate directly to book instead of folder
4. Support for opening book after navigation
5. Batch download with single restart
6. Smart restart (only if cache issues detected)
