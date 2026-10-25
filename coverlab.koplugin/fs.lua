-- All writes are limited to plugin storage and KOReader-managed cover sidecars.
local M = {}
function M.read(path, limit)
    local f, err = io.open(path, "rb")
    if not f then return nil, err end
    local s = f:read(limit and limit + 1 or "*a")
    f:close()
    if limit and s and #s > limit then return nil, "File exceeds size limit." end
    return s
end
function M.write(path, data)
    local f, err = io.open(path, "wb")
    if not f then return nil, err end
    local ok, why = f:write(data)
    local closed, cerr = f:close()
    if not ok or not closed then os.remove(path); return nil, why or cerr end
    return true
end
function M.atomic(path, data)
    local ok, err = M.write(path .. ".part", data)
    if not ok then return nil, err end
    ok, err = os.rename(path .. ".part", path)
    if not ok then os.remove(path .. ".part") end
    return ok, err
end
function M.copy(src, dst)
    local data, err = M.read(src)
    if not data then return nil, err end
    local ok; ok, err = M.atomic(dst, data)
    if not ok then return nil, err end
    if M.read(dst) ~= data then return nil, "Cover copy verification failed." end
    return true
end
function M.dirname(path) return path:match("^(.*)/[^/]*$") or "." end
return M
