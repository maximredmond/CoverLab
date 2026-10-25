-- Runs only in Trapper's disposable child process. DNS is resolved once and
-- the TCP connection is pinned to that validated address; TLS still sees the
-- original hostname. tls.lua verifies the chain and hostname explicitly.
return function(app)
    local M = {}
    function M.parse(url)
        if type(url) ~= "string" or #url > 4096 or url:find("[%c%s\\]") then
            return nil, "Enter an HTTPS image URL without spaces or control characters."
        end
        local authority, tail = url:match("^https://([^/?#]+)(.*)$")
        if not authority or authority:find("[@%%]") or authority:find("%[") then
            return nil, "Use an HTTPS URL with a public hostname and no credentials."
        end
        local host, port = authority:match("^([^:]+):(%d+)$")
        host = (host or authority):lower()
        if (port and port ~= "443") or not host:match("^[a-z0-9][a-z0-9%.%-]*$")
            or host:sub(-1) == "." or host:find("%.%.") then
            return nil, "Only HTTPS on port 443 with a valid public hostname is supported."
        end
        tail = tail:gsub("#.*$", "")
        return { host = host, url = "https://" .. host .. tail }
    end
    function M.publicIPv4(ip)
        local a,b,c,d = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
        -- libc may interpret leading zeroes as octal. Only connect to canonical
        -- dotted-decimal addresses, including addresses returned by a resolver.
        for _,part in ipairs{a,b,c,d} do if #part > 1 and part:sub(1,1) == "0" then return false end end
        a,b,c,d = tonumber(a),tonumber(b),tonumber(c),tonumber(d)
        if not a or a > 255 or b > 255 or c > 255 or d > 255 then return false end
        if a == 0 or a == 10 or a == 127 or a >= 224 then return false end
        if a == 100 and b >= 64 and b <= 127 then return false end
        if a == 169 and b == 254 or a == 172 and b >= 16 and b <= 31 then return false end
        if a == 192 and (b == 168 or b == 0 or b == 2) then return false end
        if a == 198 and (b == 18 or b == 19 or b == 51 and c == 100) then return false end
        if a == 203 and b == 0 and c == 113 then return false end
        return true
    end
    function M.resolve(host, dns)
        if host:match("^[%d%.]+$") then
            if M.publicIPv4(host) then return host end
            return nil, "Local, private, and reserved network addresses are blocked."
        end
        if not host:find("%.") or host:match("%.local$") or host:match("%.localhost$")
            or host:match("%.internal$") or host:match("%.home%.arpa$") then
            return nil, "Local network hostnames are blocked."
        end
        local records, err = dns.getaddrinfo(host)
        if not records then return nil, "Cannot resolve image host: " .. tostring(err) end
        local chosen
        for _, record in ipairs(records) do
            if record.family == "inet" then
                if not M.publicIPv4(record.addr) then return nil, "Host resolves to a private or reserved address." end
                chosen = chosen or record.addr
            end
        end
        -- IPv6-only destinations fail closed. Never ask the transport to resolve again.
        return chosen, chosen and nil or "This host has no supported public IPv4 address."
    end
    function M.request(url, sink, limit, range)
        local socket = require("socket")
        local http = require("socket.http")
        local socketutil = require("socketutil")
        local urlutil = require("socket.url")
        local settings = app.settings
        local started = socket.gettime()
        local original_proxy = http.PROXY
        http.PROXY = nil
        local last_path = settings.dir .. "/last-request"
        local function perform()
            for redirect = 0, settings:get("max_redirects") do
                local parsed, err = M.parse(url)
                if not parsed then return nil, err end
                -- A blocked Amazon request must not disable Open Library or
                -- an unrelated manual import. Recheck the destination on redirects.
                local retry_path=settings.dir .. "/retry-after-" .. app.cache.key(parsed.host)
                local cooldown=tonumber((app.fs.read(retry_path))) or 0
                if os.time() < cooldown then
                    return nil,parsed.host .. " rate-limited requests. Retry after " .. os.date("%H:%M:%S",cooldown) .. "."
                end
                local ip; ip, err = M.resolve(parsed.host, socket.dns)
                if not ip then return nil, err end
                local previous = tonumber((app.fs.read(last_path))) or 0
                local wait = 1.1 - (socket.gettime() - previous)
                if wait > 0 then socket.sleep(wait) end
                local recorded,record_err=app.fs.atomic(last_path, tostring(socket.gettime()))
                if not recorded then return nil,"Cannot save request limiter; check free storage: " .. tostring(record_err) end
                socketutil:set_timeout(settings:get("connect_timeout"), settings:get("total_timeout"))
                local count, sink_err = 0
                local contact = settings:get("contact"):gsub("[%c]", "")
                local _, code, headers = http.request{
                    url = parsed.url, method = "GET", redirect = false,
                    -- Explicitly disable KOReader's HTTP proxy: it would bypass address pinning.
                    proxy = false, create=function() return app.tls.create(parsed.host,ip) end,
                    headers = { ["User-Agent"] = "CoverLab/0.1 (KOReader" .. (contact ~= "" and "; contact=" .. contact or "") .. ")",
                        ["Accept-Encoding"] = "identity", ["Connection"] = "close",
                        ["Range"] = range and "bytes=0-65535" or nil },
                    sink = function(chunk, why)
                        if why then sink_err = why; return nil, why end
                        if not chunk then return 1 end
                        count = count + #chunk
                        if count > limit then sink_err = "Download exceeds the configured size limit."; return nil, sink_err end
                        if socket.gettime() - started > settings:get("total_timeout") then
                            sink_err = "Download timed out."; return nil, sink_err
                        end
                        return sink(chunk)
                    end,
                }
                code = tonumber(code) or code
                if code == 429 then
                    local retry = math.min(86400, math.max(60, tonumber((headers or {})["retry-after"]) or 60))
                    app.fs.atomic(retry_path, tostring(os.time() + retry))
                    return nil, "Provider rate limit reached. Retry in " .. retry .. " seconds."
                end
                if code == 301 or code == 302 or code == 303 or code == 307 or code == 308 then
                    if redirect == settings:get("max_redirects") or not headers or not headers.location then
                        return nil, "Too many redirects or missing redirect destination."
                    end
                    url = urlutil.absolute(parsed.url, headers.location)
                    -- Redirect bodies are discarded by the caller's reset hook.
                    local ok, why = sink(nil, true)
                    if not ok then return nil, why end
                elseif (code == 200 or range and code == 206) and not sink_err then
                    return true
                else
                    return nil, sink_err or ("Request failed (" .. tostring(code) .. "). Check Wi-Fi or use a local image.")
                end
            end
        end
        local ok, result, err = pcall(perform)
        http.PROXY = original_proxy
        socketutil:reset_timeout()
        if not ok then return nil, "Secure download failed: " .. tostring(result) end
        return result, err
    end
    function M.text(url, limit)
        local chunks = {}
        local ok, err = M.request(url, function(chunk, reset)
            if reset then chunks = {} else chunks[#chunks + 1] = chunk end
            return 1
        end, limit or 2 * 1024 * 1024)
        if not ok then return nil, err end
        local data=table.concat(chunks)
        if data:sub(1,2) == "\31\139" then return app.compression.gunzip(data,limit or 2*1024*1024) end
        return data
    end
    function M.prefix(url)
        local chunks, size = {}, 0
        local ok, err = M.request(url, function(chunk, reset)
            if reset then chunks, size = {}, 0; return 1 end
            local prefix = chunk:sub(1, 65536 - size)
            chunks[#chunks + 1], size = prefix, size + #prefix
            if size >= 65536 then return nil, "Image header read complete." end
            return 1
        end, app.settings:get("max_download"), true)
        local data = table.concat(chunks)
        if #data > 0 then return data end
        return nil, err or (not ok and "Cannot read image header.")
    end
    function M.download(url, path)
        local f, err = io.open(path, "wb")
        if not f then return nil, "Cannot create download: " .. tostring(err) end
        local ok; ok, err = M.request(url, function(chunk, reset)
            if reset then
                f:close(); f = io.open(path, "wb")
                if not f then return nil, "Cannot reset download file." end
            elseif not f:write(chunk) then return nil, "Cannot write image; check free storage." end
            return 1
        end, app.settings:get("max_download"))
        local closed = f and f:close()
        if not ok or not closed then os.remove(path); return nil, err or "Cannot finish image download." end
        return true
    end
    return M
end
