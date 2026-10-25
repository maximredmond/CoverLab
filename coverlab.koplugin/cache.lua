return function(app)
    local json = require("json")
    local M = {}
    -- Verify the stored key as well as its filename; collisions cannot return
    -- another query's data. Avoid a dependency on a platform hash library.
    function M.key(s)
        local a,b = 5381, 52711
        for i = 1, #s do a = (a * 33 + s:byte(i)) % 4294967291; b = (b * 31 + s:byte(i)) % 4294967291 end
        return string.format("%08x%08x", a,b)
    end
    function M.get(key)
        if not app.settings:get("cache_enabled") then return end
        local data = app.fs.read(app.settings.cache_dir .. "/" .. M.key(key) .. ".json", 4 * 1024 * 1024)
        if not data then return end
        local ok, item = pcall(json.decode, data)
        if ok and type(item) == "table" and item.key == key and type(item.time) == "number"
            and os.time() - item.time < app.settings:get("cache_lifetime") then return item.value end
    end
    function M.put(key, value)
        if not app.settings:get("cache_enabled") then return end
        return app.fs.atomic(app.settings.cache_dir .. "/" .. M.key(key) .. ".json",
            json.encode{ key = key, time = os.time(), value = value })
    end
    function M.prune()
        local lfs = require("libs/libkoreader-lfs")
        local files, total = {}, 0
        for file in lfs.dir(app.settings.cache_dir) do
            local path = app.settings.cache_dir .. "/" .. file
            local a = lfs.attributes(path)
            if a and a.mode == "file" then
                files[#files + 1] = { path = path, time = a.modification, size = a.size }
                total = total + a.size
            end
        end
        table.sort(files, function(a,b) return a.time < b.time end)
        for _, f in ipairs(files) do
            if os.time() - f.time > app.settings:get("cache_lifetime") or total > 40 * 1024 * 1024 then
                if os.remove(f.path) then total = total - f.size end
            end
        end
    end
    return M
end
