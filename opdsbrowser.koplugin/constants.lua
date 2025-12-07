-- Constants for OPDS Browser Plugin
local Constants = {
    -- Network timeouts
    BLOCK_TIMEOUT = 5,
    TOTAL_TIMEOUT = 30,
    API_TIMEOUT = 5, -- Timeout for external API calls
    
    -- Cache settings
    CACHE_TTL = 3600, -- 1 hour in seconds
    MAX_CACHE_SIZE = 100, -- Maximum number of cached entries
    
    -- Pagination
    DEFAULT_PAGE_SIZE = 50,
    DEFAULT_PAGE_LIMIT = 5,
    MAX_SEARCH_RESULTS = 5,
    ITEMS_PER_MENU_PAGE = 10,
    
    -- User agent
    USER_AGENT = "KOReader-OPDS-Browser",
    
    -- Retry settings
    MAX_RETRIES = 3,
    RETRY_DELAY = 1, -- seconds
    BACKOFF_MULTIPLIER = 2,
    
    -- UI refresh intervals
    QUEUE_REFRESH_INTERVAL = 5, -- seconds
    LIBRARY_CHECK_DELAY = 0.01, -- seconds between async checks
    
    -- File paths
    SETTINGS_FILE = "opdsbrowser.lua",
    
    -- API endpoints
    HARDCOVER_API_URL = "https://api.hardcover.app/v1/graphql",
    
    -- UI icons
    ICONS = {
        DOWNLOADING = "⬇",
        QUEUED = "⏳",
        DELAYED = "⏸",
        AVAILABLE = "✓",
        DONE = "✓",
        ERROR = "✗",
        CANCELLED = "⊘",
        IN_LIBRARY = "✓",
    },
    
    -- Series extraction patterns
    SERIES_PATTERNS = {
        TITLE_WITH_SERIES = "^(.-)%s*|([^|]+)|%s*$",
        SERIES_WITH_NUMBER = "^(.-)%s*#(%d+)$",
        SUMMARY_SERIES = "|([^|]+)|",
        PUBLISHER_WITH_NUMBER = "^(.-)%s+(%d+)$",
    },
    
    -- Language codes
    ENGLISH_LANGUAGE_CODES = {
        ["english"] = true,
        ["en"] = true,
        ["eng"] = true,
    },
}

return Constants
