local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
local logger = require("logger")

local HistoryManager = {
    history_file = DataStorage:getSettingsDir() .. "/opdsbrowser_history.lua",
    settings = nil,
    max_history = 50,
    max_bookmarks = 100,
}

function HistoryManager:init()
    self.settings = LuaSettings:open(self.history_file)
    logger.info("HistoryManager: Initialized")
end

-- Search history
function HistoryManager:getSearchHistory()
    return self.settings:readSetting("search_history") or {}
end

function HistoryManager:addSearchHistory(query)
    if not query or query == "" then return end
    
    local history = self:getSearchHistory()
    
    -- Remove duplicates
    for i = #history, 1, -1 do
        if history[i] == query then
            table.remove(history, i)
        end
    end
    
    -- Add to beginning
    table.insert(history, 1, query)
    
    -- Trim to max size
    while #history > self.max_history do
        table.remove(history)
    end
    
    self.settings:saveSetting("search_history", history)
    self.settings:flush()
    
    logger.dbg("HistoryManager: Added search query:", query)
end

function HistoryManager:clearSearchHistory()
    self.settings:saveSetting("search_history", {})
    self.settings:flush()
    logger.info("HistoryManager: Cleared search history")
end

-- Recently viewed books
function HistoryManager:getRecentBooks()
    return self.settings:readSetting("recent_books") or {}
end

function HistoryManager:addRecentBook(book_info)
    if not book_info or not book_info.title then return end
    
    local recent = self:getRecentBooks()
    
    -- Remove duplicates (by title)
    for i = #recent, 1, -1 do
        if recent[i].title == book_info.title then
            table.remove(recent, i)
        end
    end
    
    -- Add timestamp
    book_info.timestamp = os.time()
    
    -- Add to beginning
    table.insert(recent, 1, book_info)
    
    -- Trim to max size
    while #recent > self.max_history do
        table.remove(recent)
    end
    
    self.settings:saveSetting("recent_books", recent)
    self.settings:flush()
    
    logger.dbg("HistoryManager: Added recent book:", book_info.title)
end

function HistoryManager:clearRecentBooks()
    self.settings:saveSetting("recent_books", {})
    self.settings:flush()
    logger.info("HistoryManager: Cleared recent books")
end

-- Recently viewed authors
function HistoryManager:getRecentAuthors()
    return self.settings:readSetting("recent_authors") or {}
end

function HistoryManager:addRecentAuthor(author_name)
    if not author_name or author_name == "" then return end
    
    local recent = self:getRecentAuthors()
    
    -- Remove duplicates
    for i = #recent, 1, -1 do
        if recent[i] == author_name then
            table.remove(recent, i)
        end
    end
    
    -- Add to beginning
    table.insert(recent, 1, author_name)
    
    -- Trim to max size
    while #recent > self.max_history do
        table.remove(recent)
    end
    
    self.settings:saveSetting("recent_authors", recent)
    self.settings:flush()
    
    logger.dbg("HistoryManager: Added recent author:", author_name)
end

function HistoryManager:clearRecentAuthors()
    self.settings:saveSetting("recent_authors", {})
    self.settings:flush()
    logger.info("HistoryManager: Cleared recent authors")
end

-- Bookmarks/Favorites
function HistoryManager:getBookmarks()
    return self.settings:readSetting("bookmarks") or {}
end

function HistoryManager:addBookmark(book_info)
    if not book_info or not book_info.title then return end
    
    local bookmarks = self:getBookmarks()
    
    -- Check if already bookmarked
    for _, bookmark in ipairs(bookmarks) do
        if bookmark.title == book_info.title and bookmark.author == book_info.author then
            logger.dbg("HistoryManager: Book already bookmarked:", book_info.title)
            return false
        end
    end
    
    -- Check max size
    if #bookmarks >= self.max_bookmarks then
        logger.warn("HistoryManager: Bookmark limit reached")
        return false
    end
    
    -- Add timestamp
    book_info.timestamp = os.time()
    
    table.insert(bookmarks, book_info)
    self.settings:saveSetting("bookmarks", bookmarks)
    self.settings:flush()
    
    logger.info("HistoryManager: Added bookmark:", book_info.title)
    return true
end

function HistoryManager:removeBookmark(book_title, book_author)
    local bookmarks = self:getBookmarks()
    
    for i = #bookmarks, 1, -1 do
        if bookmarks[i].title == book_title and bookmarks[i].author == book_author then
            table.remove(bookmarks, i)
            self.settings:saveSetting("bookmarks", bookmarks)
            self.settings:flush()
            logger.info("HistoryManager: Removed bookmark:", book_title)
            return true
        end
    end
    
    return false
end

function HistoryManager:isBookmarked(book_title, book_author)
    local bookmarks = self:getBookmarks()
    
    for _, bookmark in ipairs(bookmarks) do
        if bookmark.title == book_title and bookmark.author == book_author then
            return true
        end
    end
    
    return false
end

function HistoryManager:clearBookmarks()
    self.settings:saveSetting("bookmarks", {})
    self.settings:flush()
    logger.info("HistoryManager: Cleared bookmarks")
end

-- Export all data
function HistoryManager:export()
    return {
        search_history = self:getSearchHistory(),
        recent_books = self:getRecentBooks(),
        recent_authors = self:getRecentAuthors(),
        bookmarks = self:getBookmarks(),
    }
end

-- Import data
function HistoryManager:import(data)
    if data.search_history then
        self.settings:saveSetting("search_history", data.search_history)
    end
    if data.recent_books then
        self.settings:saveSetting("recent_books", data.recent_books)
    end
    if data.recent_authors then
        self.settings:saveSetting("recent_authors", data.recent_authors)
    end
    if data.bookmarks then
        self.settings:saveSetting("bookmarks", data.bookmarks)
    end
    
    self.settings:flush()
    logger.info("HistoryManager: Imported data")
end

return HistoryManager
