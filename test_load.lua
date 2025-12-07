#!/usr/bin/env lua

-- Minimal test to check if main.lua can be loaded
-- This simulates what KOReader does when loading plugins

local function test_load()
    -- Try to load the module
    local ok, result = pcall(function()
        -- Set up minimal path
        package.path = "./opdsbrowser.koplugin/?.lua;" .. package.path

        -- Try to load main
        local main = require("main")
        return main
    end)

    if not ok then
        print("ERROR loading module:")
        print(result)
        return false
    else
        print("SUCCESS: Module loaded")
        print("Type:", type(result))
        if type(result) == "table" then
            print("Has name:", result.name)
        end
        return true
    end
end

test_load()
