return function(app)
    local M = {}
    local function be(s, p, n)
        if p < 1 or p + n - 1 > #s then return end
        local value = 0
        for i = p, p+n-1 do value = value * 256 + s:byte(i) end
        return value
    end
    function M.header(s)
        if s:sub(1,8) == "\137PNG\r\n\26\n" and s:sub(13,16) == "IHDR" and be(s,9,4) == 13 then
            return be(s,17,4), be(s,21,4), "png"
        end
        if s:sub(1,2) == "\255\216" then
            local p = 3
            while p <= #s do
                if s:byte(p) ~= 255 then return end
                while s:byte(p) == 255 do p = p+1 end
                local marker = s:byte(p); p = p+1
                if not marker or marker == 218 or marker == 217 then return end
                if marker ~= 1 and not (marker >= 208 and marker <= 215) then
                    local length = be(s,p,2)
                    if not length or length < 2 or p+length-1 > #s then return end
                    if marker >= 192 and marker <= 207 and marker ~= 196 and marker ~= 200 and marker ~= 204 then
                        if length < 8 then return end
                        return be(s,p+5,2), be(s,p+3,2), "jpg"
                    end
                    p = p+length
                end
            end
        end
    end
    function M.bounds(w,h)
        return type(w) == "number" and type(h) == "number" and w > 0 and h > 0
            and w <= app.settings:get("max_dimension") and h <= app.settings:get("max_dimension")
            and w * h <= app.settings:get("max_pixels")
    end
    function M.validate(path)
        local data, err = app.fs.read(path, app.settings:get("max_download"))
        if not data then return nil, err or "Cannot read image." end
        local w,h,format = M.header(data)
        if not format then return nil, "Only valid JPEG and PNG images are supported." end
        if not M.bounds(w,h) then return nil, "Image dimensions exceed safe device memory limits." end
        if format == "jpg" then
            if not data:find("\255\217[^%S]*$") then return nil, "JPEG image is truncated." end
        else
            local p, idat, ended = 9, false, false
            while p + 11 <= #data do
                local n, kind = be(data,p,4), data:sub(p+4,p+7)
                if n > #data-p-11 then return nil, "PNG image is truncated." end
                if kind == "IDAT" then idat = true end
                if kind == "IEND" then ended = n == 0 and p+11 == #data; break end
                p = p+n+12
            end
            if not ended or not idat then return nil, "PNG image is incomplete." end
        end
        -- A dimension check alone is insufficient. Decode within the pixel cap.
        local ok, bb = pcall(function() return require("ui/renderimage"):renderImageFile(path, false) end)
        if not ok or not bb then return nil, "Image cannot be decoded." end
        local actual_w, actual_h = bb:getWidth(), bb:getHeight()
        bb:free()
        if actual_w ~= w or actual_h ~= h then return nil, "Decoded dimensions do not match image header." end
        return { width=w, height=h, format=format, size=#data, ratio=w/h, path=path }
    end
    function M.quality(w,h)
        if w >= 1200 and h >= 1800 then return "Very high" end
        if w >= 600 and h >= 900 then return "High" end
        if w >= 300 and h >= 450 then return "Standard" end
        return "Low"
    end
    function M.describe(image)
        return string.format("%d × %d px · %.3f · %s%s", image.width, image.height,
            image.ratio or image.width/image.height, M.quality(image.width,image.height),
            image.size and string.format(" · %.1f KB", image.size/1024) or "")
    end
    function M.fetch(url, path)
        local ok, err = app.network.download(url, path)
        if not ok then return nil, err end
        local image; image, err = M.validate(path)
        if not image then os.remove(path); return nil, err end
        local typed = path .. "." .. image.format
        local renamed; renamed, err = os.rename(path, typed)
        if not renamed then os.remove(path); return nil, err end
        image.path = typed
        return image
    end
    function M.thumbnail(candidate, index)
        local key = "thumb:" .. candidate.thumbnail_url
        local record = app.cache.get(key)
        local path = app.settings.cache_dir .. "/" .. app.cache.key(key)
        if record and record.path and app.fs.read(record.path, app.settings:get("max_download")) then
            candidate.thumbnail = record.path
        else
            local image, err = M.fetch(candidate.thumbnail_url, path .. ".part")
            if not image then candidate.image_error = err; return end
            candidate.thumbnail = image.path
            app.cache.put(key, { path = image.path })
        end
        local dimensions = app.cache.get("dimensions:" .. candidate.url)
        if not dimensions then
            local data = app.network.prefix(candidate.url)
            if data then
                local w,h = M.header(data)
                if M.bounds(w,h) then
                    dimensions = {width=w, height=h}
                    app.cache.put("dimensions:" .. candidate.url, dimensions)
                end
            end
        end
        if dimensions then candidate.width, candidate.height = dimensions.width, dimensions.height end
    end
    function M.cleanup()
        local lfs = require("libs/libkoreader-lfs")
        for file in lfs.dir(app.settings.temp_dir) do
            local path = app.settings.temp_dir .. "/" .. file
            if lfs.attributes(path, "mode") == "file" then os.remove(path) end
        end
        -- A cancelled thumbnail worker may leave a partial cache entry.
        for file in lfs.dir(app.settings.cache_dir) do
            if file:match("%.part$") then os.remove(app.settings.cache_dir .. "/" .. file) end
        end
    end
    return M
end
