-- opdsbrowser.koplugin/library_sync_manager.lua
-- Simplified LibrarySyncManager with Recently Added / Current Reads & symlink handling removed.
-- Provides:
--  - placeholder_db persistence (load/save)
--  - getBookInfo(filepath)
--  - populateCurrentReads() -> returns empty list (feature removed)
--  - updateCurrentReads() -> no-op (feature removed)
--  - clearPlaceholderDB()
--  - syncLibrary() -> simplified sync/stats (does not create special folders)

local logger = require("logger")
local json = require("json")
local lfs = require("libs/libkoreader-lfs")
local Utils = require("utils")

local LibrarySyncManager = {}
LibrarySyncManager.__index = LibrarySyncManager

-- Create a new manager; opts may include db_path
function LibrarySyncManager:new(opts)
    opts = opts or {}
    local o = {
        placeholder_db = {},
        db_path = opts.db_path or (Utils.get_user_data_path and Utils.get_user_data_path() .. "/opds_placeholder_db.json" or "opds_placeholder_db.json"),
    }
    setmetatable(o, self)
    o:loadPlaceholderDB()
    return o
end

-- Load placeholder DB from disk (JSON). If not present, create empty table.
function LibrarySyncManager:loadPlaceholderDB()
    local path = self.db_path
    local f, err = io.open(path, "rb")
    if not f then
        logger.info("LibrarySyncManager: Placeholder DB not found; starting with empty DB:", path)
        self.placeholder_db = {}
        return
    end

    local content = f:read("*a")
    f:close()

    local ok, decoded = pcall(json.decode, content)
    if ok and type(decoded) == "table" then
        self.placeholder_db = decoded
        logger.info("LibrarySyncManager: Loaded placeholder DB with entries:", Utils.table_length(self.placeholder_db) or 0)
    else
        logger.err("LibrarySyncManager: Failed to parse placeholder DB; starting fresh")
        self.placeholder_db = {}
    end
end

-- Save placeholder DB to disk (atomic write where possible)
function LibrarySyncManager:savePlaceholderDB()
    local path = self.db_path
    local tmp = path .. ".tmp"
    local ok, f, err = pcall(function() return io.open(tmp, "wb") end)
    if not ok or not f then
        logger.err("LibrarySyncManager: Failed to open tmp file for saving placeholder DB:", err or "unknown")
        return false, err
    end

    local content = json.encode(self.placeholder_db or {})
    f:write(content)
    f:close()

    local rename_ok, rename_err = os.remove(path)
    -- ignore remove failure — proceed to rename
    local r_ok, r_err = os.rename(tmp, path)
    if not r_ok then
        logger.err("LibrarySyncManager: Failed to rename placeholder DB tmp file:", r_err)
        return false, r_err
    end

    logger.info("LibrarySyncManager: Saved placeholder DB:", path)
    return true
end

-- Return book info from placeholder DB (or nil)
function LibrarySyncManager:getBookInfo(filepath)
    if not filepath then return nil end
    return self.placeholder_db[filepath]
end

-- Remove all placeholder entries and save DB
function LibrarySyncManager:clearPlaceholderDB()
    self.placeholder_db = {}
    local ok, err = self:savePlaceholderDB()
    if ok then
        logger.info("LibrarySyncManager: Cleared placeholder DB")
    else
        logger.err("LibrarySyncManager: Failed to clear placeholder DB:", err)
    end
end

-- populateCurrentReads is removed: return empty list for compatibility
function LibrarySyncManager:populateCurrentReads()
    logger.info("LibrarySyncManager: populateCurrentReads called, but Current Reads feature is removed")
    return {}, 0
end

-- updateCurrentReads is a no-op (kept for compatibility)
function LibrarySyncManager:updateCurrentReads()
    logger.dbg("LibrarySyncManager: updateCurrentReads called (no-op; feature removed)")
    return true
end

-- Simplified library sync function: scans provided paths if given, otherwise a no-op
-- Returns (ok, stats_table)
function LibrarySyncManager:syncLibrary(scan_paths)
    logger.info("LibrarySyncManager: Starting library sync (simplified)")

    -- This simplified sync does not create Recently Added/Current Reads or symlinks.
    -- It may be expanded to actually scan directories if you want that behavior.
    -- For now, keep placeholder_db untouched and return zeroed stats.
    local stats = {
        created = 0,
        updated = 0,
        skipped = 0,
        failed = 0,
        deleted_orphans = 0,
        total = 0,
    }

    -- If caller provided explicit placeholder entries to merge, merge them (backwards-compatible)
    if scan_paths and type(scan_paths) == "table" then
        -- optional: process scan_paths mapping of filepath->book_info
        for filepath, info in pairs(scan_paths) do
            if type(filepath) == "string" and type(info) == "table" then
                if not self.placeholder_db[filepath] then
                    self.placeholder_db[filepath] = info
                    stats.created = stats.created + 1
                else
                    self.placeholder_db[filepath] = info
                    stats.updated = stats.updated + 1
                end
                stats.total = stats.total + 1
            end
        end
        self:savePlaceholderDB()
    end

    logger.info("LibrarySyncManager: Sync complete - Created:", stats.created, "Updated:", stats.updated, "Total:", stats.total)
    return true, stats
end

-- Utility: safe table length (used for logging)
function Utils.table_length(t)
    if not t or type(t) ~= "table" then return 0 end
    local c = 0
    for _ in pairs(t) do c = c + 1 end
    return c
end

return LibrarySyncManager
