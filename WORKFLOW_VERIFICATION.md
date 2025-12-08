# Placeholder Auto-Download Workflow Verification Guide

## Overview

This guide explains how to verify that all 5 steps of the placeholder auto-download workflow execute correctly and reliably.

## The 5-Step Workflow

### Step 1: Detect Placeholder Opened
**What happens:** When a user opens a book, the plugin checks if it's a placeholder  
**How it works:** `onReaderReady()` event triggers, checks placeholder database  
**Success criteria:** Placeholder detected and Step 2 triggered  
**Failure:** Normal book opens (not a placeholder)

### Step 2: Trigger OPDS Download
**What happens:** Plugin downloads the real book from OPDS server  
**How it works:** HTTP download to temporary file  
**Success criteria:** Real book downloaded successfully to temp file  
**Failure:** Error shown, placeholder remains, download aborted

### Step 3: Delete Placeholder
**What happens:** Placeholder file deleted, real book moved into place  
**How it works:** File deletion with retry logic, rename temp to final path  
**Success criteria:** Placeholder gone, real book exists at correct location  
**Failure:** Error shown, temp file cleaned up, may need manual intervention

### Step 4: Restart KOReader
**What happens:** KOReader automatically restarts to clear all caches  
**How it works:** Save navigation state, trigger restart via UIManager  
**Success criteria:** KOReader restarts successfully  
**Failure:** Falls back to opening book directly (without restart)

### Step 5: Navigate to Folder
**What happens:** After restart, automatically navigate to book's folder  
**How it works:** Load saved state, open FileManager at folder path  
**Success criteria:** FileManager opens showing the downloaded book  
**Failure:** Error shown, user navigates manually

## Verification Methods

### Method 1: Workflow Health Check (Recommended)

The plugin includes a built-in health check that verifies all workflow components.

**To run:**
1. Open KOReader
2. Go to: Menu → Cloud Book Library → Plugin - Workflow Health Check
3. Review the status report

**What it checks:**
- ✓ Placeholder database availability
- ✓ OPDS configuration
- ✓ Network libraries (HTTPS)
- ✓ File system access (LFS)
- ✓ Restart capability
- ✓ FileManager availability

**Expected result:** "✓ ALL SYSTEMS OPERATIONAL"

If issues are found, the report will list specific problems to fix.

### Method 2: Log Analysis

The workflow produces detailed logs with clear markers for each step.

**Log file locations:**
- Kindle: `/mnt/us/.adds/koreader/crash.log`
- Kobo: `/mnt/onboard/.adds/koreader/crash.log`
- Android: `/sdcard/koreader/crash.log`

**Key log markers to look for:**

```
========================================
OPDS WORKFLOW: STEP 1 - PLACEHOLDER DETECTED
========================================
...
OPDS WORKFLOW: ✓ Step 1 complete - Placeholder detected and validated
```

```
========================================
OPDS WORKFLOW: STEP 2 - TRIGGERING DOWNLOAD
========================================
...
OPDS WORKFLOW: ✓ Step 2 complete - Book downloaded successfully
```

```
========================================
OPDS WORKFLOW: STEP 3 - DELETING PLACEHOLDER
========================================
...
OPDS WORKFLOW: ✓ Step 3 complete - Placeholder deleted, real book in place
```

```
========================================
OPDS WORKFLOW: STEP 4 - RESTARTING KOREADER
========================================
...
OPDS WORKFLOW: ✓ Step 4 complete - Restart triggered
```

```
========================================
OPDS WORKFLOW: STEP 5 - POST-RESTART NAVIGATION
========================================
...
OPDS WORKFLOW: ✓ Step 5 complete - Successfully navigated to folder
========================================
OPDS WORKFLOW: ALL STEPS COMPLETE
========================================
```

**Complete successful workflow log:**
```
OPDS WORKFLOW: STEP 1 - PLACEHOLDER DETECTED
OPDS WORKFLOW: ✓ Step 1 complete - Placeholder detected and validated
OPDS WORKFLOW: STEP 2 - TRIGGERING DOWNLOAD
OPDS WORKFLOW: ✓ Step 2 complete - Book downloaded successfully
OPDS WORKFLOW: STEP 3 - DELETING PLACEHOLDER
OPDS WORKFLOW: ✓ Step 3 complete - Placeholder deleted, real book in place
OPDS: ==================== CACHE INVALIDATION COMPLETE ====================
OPDS WORKFLOW: STEP 4 - RESTARTING KOREADER
OPDS WORKFLOW: ✓ Step 4 complete - Restart triggered
OPDS WORKFLOW: Waiting for restart... Step 5 will execute on next startup

[KOReader restarts]

OPDS WORKFLOW: STEP 5 - POST-RESTART NAVIGATION
OPDS WORKFLOW: ✓ Step 5 complete - Successfully navigated to folder
OPDS WORKFLOW: ALL STEPS COMPLETE
```

### Method 3: End-to-End Testing

**Prerequisites:**
1. Working OPDS server with books
2. At least one placeholder book created via Library Sync
3. Network connectivity

**Test procedure:**

1. **Initial State:**
   - Note: Which book is the placeholder
   - Verify: Cloud badge (☁) shows on placeholder cover (if CoverBrowser enabled)
   - Record: File size of placeholder (should be small, < 200KB typically)

2. **Open Placeholder:**
   - Navigate to placeholder book in File Manager
   - Open the placeholder book
   - Expected: "Downloading book..." message appears immediately

3. **During Download:**
   - Expected: Progress message visible
   - Wait: Download completes
   - Expected: "Preparing downloaded book..." message
   - Expected: Reader closes

4. **After Download:**
   - Expected: "Download complete! Restarting KOReader..." message
   - Wait: 2 seconds
   - Expected: KOReader restarts automatically

5. **After Restart:**
   - Expected: KOReader opens to FileManager
   - Expected: FileManager shows the folder containing the downloaded book
   - Expected: Notification: "Navigated to downloaded book folder"
   - Verify: The book is no longer a placeholder (larger file size)
   - Verify: Cloud badge (☁) is gone from cover
   - Verify: Opening the book shows real content, not placeholder

6. **Final Verification:**
   - Close and reopen the book
   - Expected: Real book content every time
   - Check logs for complete workflow markers (see Method 2)

## Troubleshooting Failed Steps

### Step 1 Failures

**Symptom:** Placeholder opens normally, no auto-download  
**Log marker:** Missing "STEP 1 - PLACEHOLDER DETECTED"  
**Possible causes:**
- File not in placeholder database
- `onReaderReady` event not firing
- LibrarySyncManager not initialized

**Solutions:**
1. Re-sync library to recreate placeholders
2. Check that placeholder was created via Library Sync
3. Run workflow health check

### Step 2 Failures

**Symptom:** "Download failed" error  
**Log marker:** "OPDS WORKFLOW: FAILED AT STEP 2"  
**Possible causes:**
- Network connectivity issues
- OPDS server down or misconfigured
- Authentication failure
- Book ID invalid

**Solutions:**
1. Check network connection
2. Verify OPDS URL in settings
3. Test OPDS credentials
4. Check server logs for errors

### Step 3 Failures

**Symptom:** Download succeeds but file replacement fails  
**Log marker:** "OPDS WORKFLOW: FAILED AT STEP 3"  
**Possible causes:**
- File system permissions
- Disk full
- File locked by another process
- Placeholder file cannot be deleted

**Solutions:**
1. Check available disk space
2. Ensure no other apps have the file open
3. Restart KOReader and try again
4. Check file system permissions

### Step 4 Failures

**Symptom:** Restart doesn't happen, book opens directly  
**Log marker:** "OPDS WORKFLOW: FAILED AT STEP 4"  
**Possible causes:**
- No restart method available on device
- Cannot write state file
- Restart triggered but failed

**Solutions:**
1. This is expected on some devices/KOReader versions
2. Book will open directly as fallback
3. Workflow still succeeds (without restart)
4. Check health report for restart capability

### Step 5 Failures

**Symptom:** After restart, doesn't navigate to folder  
**Log marker:** "OPDS WORKFLOW: FAILED AT STEP 5"  
**Possible causes:**
- State file missing or expired (>60 seconds)
- Folder path invalid
- FileManager not available

**Solutions:**
1. Check if restart took longer than 60 seconds
2. Navigate to book folder manually
3. State file automatically cleaned up
4. Next download will retry navigation

## Common Issues

### "No placeholder in database" but file is a placeholder

**Cause:** Database out of sync with filesystem  
**Solution:** 
1. Go to: Cloud Book Library → Library Sync - OPDS
2. Re-sync library
3. Database will be regenerated

### Workflow works but logs show failures

**Cause:** Optional components missing (e.g., restart capability)  
**Solution:** 
- This is normal on some systems
- Workflow has fallbacks for missing components
- Check health report to see what's missing

### All steps complete but book still shows as placeholder

**Cause:** Cache not fully cleared (rare)  
**Solution:**
1. Manually restart KOReader
2. Check file size - if large, it's the real book
3. Report as a bug if issue persists

## Testing Checklist

Use this checklist to verify the workflow is working correctly:

- [ ] Health check shows "ALL SYSTEMS OPERATIONAL"
- [ ] Opening a placeholder triggers immediate download
- [ ] Download progress messages appear
- [ ] Download completes successfully
- [ ] Placeholder file is deleted
- [ ] Real book file exists at correct location
- [ ] KOReader restarts automatically (or book opens directly)
- [ ] After restart, navigates to book folder
- [ ] Book shows real content when opened
- [ ] Cloud badge disappears from cover
- [ ] Logs show all 5 steps completing successfully
- [ ] Re-opening book shows real content consistently

If all items are checked, the workflow is functioning correctly!

## Reporting Issues

If the workflow is not working correctly, gather this information:

1. **Device information:**
   - Device model (Kindle, Kobo, etc.)
   - KOReader version

2. **Log excerpt:**
   - Run workflow health check
   - Open a placeholder book
   - Extract logs showing "OPDS WORKFLOW" entries
   - Include any error messages

3. **Configuration:**
   - OPDS server URL
   - Whether using authentication
   - Download directory path

4. **What failed:**
   - Which step failed (1-5)?
   - What error message appeared?
   - What was expected vs actual behavior?

Include this information when reporting issues on GitHub.

## Advanced Diagnostics

### Manual Health Check via Logs

On startup, the plugin automatically runs a health check. Look for:

```
========================================
PLACEHOLDER AUTO-DOWNLOAD WORKFLOW HEALTH CHECK
========================================
Step 1 - Placeholder Detection:
  ✓ LibrarySyncManager available
  ✓ Placeholder database available
  ✓ Database has X placeholder(s)
Step 2 - OPDS Download:
  ✓ OPDS URL configured: ...
  ✓ HTTPS library available
Step 3 - File Operations:
  ✓ LFS (filesystem) library available
Step 4 - Restart Capability:
  ✓ RestartNavigationManager available
  ✓ State file path: ...
  ✓ Can write state files
  ✓ UIManager:restart() available
Step 5 - FileManager Navigation:
  ✓ FileManager available
  ✓ FileManager.showFiles() available
========================================
WORKFLOW HEALTH: ✓ ALL CHECKS PASSED
All 5 workflow steps are fully functional
========================================
```

If any checks show ✗, investigate that component.

### Testing Individual Steps

You can test components in isolation:

**Test Step 1 (Detection):**
```lua
-- In KOReader console
local pg = require("placeholder_generator")
print(pg:isPlaceholder("/path/to/file.epub"))
```

**Test Step 4 (Restart):**
- Use: Cloud Book Library → Plugin - Workflow Health Check
- Check: "Restart Capability" section

## Performance Expectations

**Normal workflow timing:**
- Step 1 (Detection): < 1 second
- Step 2 (Download): Depends on book size and network speed
- Step 3 (File operations): < 5 seconds
- Step 4 (Restart trigger): < 2 seconds
- Step 5 (Navigation): < 2 seconds after restart

**Total time:** Download time + ~10 seconds + restart time

**KOReader restart typically takes:** 5-30 seconds depending on device

## Summary

The 5-step workflow is designed to be:
- **Reliable:** Each step validates before proceeding
- **Transparent:** Comprehensive logging at every step
- **Resilient:** Fallbacks for missing components
- **Verifiable:** Multiple ways to confirm it's working

Use the built-in health check and log analysis to verify the workflow is functioning correctly. All placeholder books should follow this flow exactly when opened.
