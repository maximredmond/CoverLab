return function(app)
    local DataStorage = require("datastorage")
    local LuaSettings = require("luasettings")
    local util = require("util")
    local dir = DataStorage:getSettingsDir() .. "/coverlab"
    util.makePath(dir)
    local config = LuaSettings:open(dir .. "/settings.lua")
    local M = { dir = dir, cache_dir = dir .. "/cache", temp_dir = dir .. "/tmp" }
    local defaults = {
        primary_source = "amazon", openlibrary_enabled = true,
        cache_enabled = true, cache_lifetime = 7 * 86400,
        max_download = 10 * 1024 * 1024, max_pixels = 12000000,
        max_dimension = 10000, contact = "", max_redirects = 3,
        connect_timeout = 10, total_timeout = 45,
    }
    function M:get(key) return config:readSetting(key, defaults[key]) end
    function M:set(key, value) config:saveSetting(key, value); config:flush() end
    util.makePath(M.cache_dir)
    util.makePath(M.temp_dir)
    return M
end
