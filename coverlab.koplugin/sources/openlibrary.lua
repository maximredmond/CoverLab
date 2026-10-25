return function(app)
    local json = require("json")
    local M = {}
    local function escape(value)
        return tostring(value or ""):gsub("([^%w%-_%.~])", function(c) return string.format("%%%02X", c:byte()) end)
    end
    local function get(url, missing_ok)
        local key = "api:" .. url
        local cached = app.cache.get(key)
        if cached then return cached end
        local body, err = app.network.text(url)
        if not body then
            if missing_ok and err and err:find("(404)",1,true) then return {} end
            return nil, err
        end
        local ok, value = pcall(json.decode, body)
        if not ok or type(value) ~= "table" then return nil, "Open Library returned invalid JSON." end
        app.cache.put(key, value)
        return value
    end
    local function list(value)
        if type(value) == "table" then return table.concat(value, ", ") end
        return type(value) == "string" and value or ""
    end
    local function append(out, edition, author, query)
        local exact = false
        local wanted = app.metadata.isbn13(query.isbn)
        if wanted then
            for _, values in ipairs{ edition.isbn_10 or {}, edition.isbn_13 or {} } do
                for _, isbn in ipairs(values) do
                    if app.metadata.isbn13(isbn) == wanted then exact = true end
                end
            end
        end
        for _, id in ipairs(edition.covers or {}) do
            if type(id) == "number" and id > 0 then
                out[#out + 1] = { id = tostring(id), source = "Open Library", title = edition.title or "",
                    author = author or "", edition = edition.key, publisher = list(edition.publishers),
                    year = edition.publish_date or "", exact = exact,
                    isbn = (edition.isbn_13 or edition.isbn_10 or {})[1],
                    url = "https://covers.openlibrary.org/b/id/" .. id .. "-L.jpg?default=false",
                    thumbnail_url = "https://covers.openlibrary.org/b/id/" .. id .. "-M.jpg?default=false" }
            end
        end
    end
    function M.search(query, page)
        local candidates, warnings = {}, {}
        if page == 1 and app.metadata.normalizeISBN(query.isbn) then
            local edition, err = get("https://openlibrary.org/isbn/" .. app.metadata.normalizeISBN(query.isbn) .. ".json", true)
            if not edition then return nil, err end
            append(candidates, edition, query.author, query)
        end
        if query.title == "" then
            return { candidates = candidates, more = false, warnings = warnings }
        end
        local url = "https://openlibrary.org/search.json?title=" .. escape(query.title)
            .. (query.author ~= "" and "&author=" .. escape(query.author) or "")
            .. "&fields=key,title,author_name&limit=3&page=" .. page
        local results, err = get(url)
        if not results then
            if #candidates == 0 then return nil, err end
            warnings[#warnings + 1] = err
            return {candidates=candidates,more=false,warnings=warnings}
        end
        for _, work in ipairs(results.docs or {}) do
            if type(work.key) == "string" and work.key:match("^/works/OL%d+W$") then
                local editions; editions, err = get("https://openlibrary.org" .. work.key .. "/editions.json?limit=6")
                if not editions then
                    warnings[#warnings + 1] = err
                    -- A rate limit or network outage stops this user-initiated batch.
                    break
                end
                for _, edition in ipairs(editions.entries or {}) do
                    append(candidates, edition, list(work.author_name), query)
                end
            end
        end
        local total = tonumber(results.numFound or results.num_found) or 0
        return { candidates=candidates, more=page*3 < total and #warnings == 0, warnings=warnings }
    end
    return M
end
