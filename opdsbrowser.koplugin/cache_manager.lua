local logger = require("logger")
local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
local Constants = require("constants")

local CacheManager = {
    cache = {},
    timestamps = {},
    access_counts = {},
    persistent_cache_file = DataStorage:getSettingsDir() .. "/opdsbrowser_cache.lua",
}

function CacheManager:init()
    -- Load persistent cache
    self:loadPersistentCache()
    
    -- Clean up expired entries
    self:cleanup()
end

function CacheManager:loadPersistentCache()
    local settings = LuaSettings:open(self.persistent_cache_file)
    local cached_data = settings:readSetting("cache") or {}
    local cached_timestamps = settings:readSetting("timestamps") or {}
    
    -- Only load non-expired entries
    local current_time = os.time()
    for key, value in pairs(cached_data) do
        local timestamp = cached_timestamps[key] or 0
        if (current_time - timestamp) < Constants.CACHE_TTL then
            self.cache[key] = value
            self.timestamps[key] = timestamp
            self.access_counts[key] = 0
        end
    end
    
    logger.info("CacheManager: Loaded", self:count(), "entries from persistent cache")
end

function CacheManager:savePersistentCache()
    local settings = LuaSettings:open(self.persistent_cache_file)
    settings:saveSetting("cache", self.cache)
    settings:saveSetting("timestamps", self.timestamps)
    settings:flush()
    
    logger.info("CacheManager: Saved", self:count(), "entries to persistent cache")
end

function CacheManager:get(key)
    local current_time = os.time()
    local timestamp = self.timestamps[key]
    
    -- Check if key exists and is not expired
    if self.cache[key] and timestamp then
        local age = current_time - timestamp
        if age < Constants.CACHE_TTL then
            self.access_counts[key] = (self.access_counts[key] or 0) + 1
            logger.dbg("CacheManager: Cache hit for", key, "age:", age, "seconds")
            return self.cache[key], age
        else
            -- Expired, remove it
            logger.dbg("CacheManager: Cache expired for", key)
            self:remove(key)
        end
    end
    
    logger.dbg("CacheManager: Cache miss for", key)
    return nil, nil
end

function CacheManager:set(key, value)
    -- Check cache size limit
    if self:count() >= Constants.MAX_CACHE_SIZE then
        self:evictLRU()
    end
    
    local current_time = os.time()
    self.cache[key] = value
    self.timestamps[key] = current_time
    self.access_counts[key] = 0
    
    logger.dbg("CacheManager: Set cache for", key)
    
    -- Periodically save to disk (every 10 entries)
    if self:count() % 10 == 0 then
        self:savePersistentCache()
    end
end

function CacheManager:remove(key)
    self.cache[key] = nil
    self.timestamps[key] = nil
    self.access_counts[key] = nil
    logger.dbg("CacheManager: Removed cache for", key)
end

function CacheManager:clear()
    self.cache = {}
    self.timestamps = {}
    self.access_counts = {}
    self:savePersistentCache()
    logger.info("CacheManager: Cleared all cache")
end

function CacheManager:count()
    local count = 0
    for _ in pairs(self.cache) do
        count = count + 1
    end
    return count
end

function CacheManager:cleanup()
    local current_time = os.time()
    local removed = 0
    
    for key, timestamp in pairs(self.timestamps) do
        if (current_time - timestamp) >= Constants.CACHE_TTL then
            self:remove(key)
            removed = removed + 1
        end
    end
    
    if removed > 0 then
        logger.info("CacheManager: Cleaned up", removed, "expired entries")
        self:savePersistentCache()
    end
end

function CacheManager:evictLRU()
    -- Find least recently used entry
    local lru_key = nil
    local min_access = math.huge
    
    for key, count in pairs(self.access_counts) do
        if count < min_access then
            min_access = count
            lru_key = key
        end
    end
    
    if lru_key then
        logger.info("CacheManager: Evicting LRU entry:", lru_key)
        self:remove(lru_key)
    end
end

function CacheManager:getCacheStats()
    local current_time = os.time()
    local stats = {
        total_entries = self:count(),
        oldest_age = 0,
        newest_age = math.huge,
    }
    
    for key, timestamp in pairs(self.timestamps) do
        local age = current_time - timestamp
        if age > stats.oldest_age then
            stats.oldest_age = age
        end
        if age < stats.newest_age then
            stats.newest_age = age
        end
    end
    
    return stats
end

function CacheManager:invalidatePattern(pattern)
    local removed = 0
    local keys_to_remove = {}
    
    -- Collect keys matching pattern
    for key in pairs(self.cache) do
        if key:match(pattern) then
            table.insert(keys_to_remove, key)
        end
    end
    
    -- Remove them
    for _, key in ipairs(keys_to_remove) do
        self:remove(key)
        removed = removed + 1
    end
    
    if removed > 0 then
        logger.info("CacheManager: Invalidated", removed, "entries matching pattern:", pattern)
        self:savePersistentCache()
    end
    
    return removed
end

return CacheManager
