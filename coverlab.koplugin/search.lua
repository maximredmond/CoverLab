return function(app)
    local M = {}
    local function tokens(value)
        local t = {}
        for word in tostring(value or ""):lower():gmatch("[%w\128-\255]+") do t[word] = true end
        return t
    end
    local function similarity(a,b)
        local x,y,count,total = tokens(a),tokens(b),0,0
        for word in pairs(x) do total=total+1; if y[word] then count=count+1 end end
        for word in pairs(y) do if not x[word] then total=total+1 end end
        return total > 0 and count/total or 0
    end
    function M.rank(candidates, query)
        for _, c in ipairs(candidates) do
            local title = similarity(c.title, query.title)
            local author = query.author ~= "" and similarity(c.author,query.author) or title
            c.confidence = 0.7*title + 0.3*author
            c.area = (c.width or 0) * (c.height or 0)
            local ratio = c.width and c.height and c.width/c.height or 0
            c.aspect_score = ratio >= 0.5 and ratio <= 0.85 and 1 or 0
        end
        table.sort(candidates, function(a,b)
            if a.exact ~= b.exact then return a.exact == true end
            if a.confidence ~= b.confidence then return a.confidence > b.confidence end
            if (a.source_priority or 2) ~= (b.source_priority or 2) then return (a.source_priority or 2) < (b.source_priority or 2) end
            if a.area ~= b.area then return a.area > b.area end
            if a.aspect_score ~= b.aspect_score then return a.aspect_score > b.aspect_score end
            return a.id < b.id
        end)
        return candidates
    end
    function M.deduplicate(candidates)
        local result, urls, bytes = {}, {}, {}
        for _, c in ipairs(candidates) do
            local duplicate = urls[c.url]
            local data = c.thumbnail and app.fs.read(c.thumbnail, app.settings:get("max_download"))
            if data then
                local hash = app.cache.key(data)
                for _, previous in ipairs(bytes[hash] or {}) do
                    if data == app.fs.read(previous, app.settings:get("max_download")) then duplicate = true; break end
                end
                bytes[hash] = bytes[hash] or {}
                bytes[hash][#bytes[hash]+1] = c.thumbnail
            end
            if not duplicate then urls[c.url] = true; result[#result+1] = c end
        end
        return result
    end
    function M.append(existing, incoming, query)
        -- Once browsed, candidate positions are stable. Rank only the newly
        -- fetched batch, then append unseen URLs instead of moving the cursor's
        -- previously displayed results around.
        local result,seen={},{}
        for _,c in ipairs(existing) do result[#result+1]=c;seen[c.url]=true end
        for _,c in ipairs(M.deduplicate(M.rank(incoming,query))) do
            if not seen[c.url] then result[#result+1]=c;seen[c.url]=true end
        end
        return result
    end
    function M.page(query, page, provider)
        if provider == "openlibrary" then
            if not app.settings:get("openlibrary_enabled") then return nil,"Open Library is disabled in CoverLab settings." end
            local result,err=app.sources.openlibrary.search(query,page)
            if not result then return nil,err end
            result.active_source="Open Library";result.provider="openlibrary"
            result.candidates=M.deduplicate(M.rank(result.candidates,query))
            return result
        end
        local result, err = app.sources.amazon.search(query,page)
        if not result then result={candidates={},more=false,warnings={err}} end
        result.active_source="Amazon Kindle"
        result.provider="amazon"
        -- Only use the secondary provider when Amazon could not return covers.
        -- The switch is checked before calling any Open Library code or cache.
        if #result.candidates == 0 and app.settings:get("openlibrary_enabled") then
            local secondary,why=app.sources.openlibrary.search(query,page)
            if secondary then
                for _,warning in ipairs(result.warnings or {}) do secondary.warnings[#secondary.warnings+1]=warning end
                result=secondary;result.active_source="Open Library (fallback)";result.provider="openlibrary"
            elseif why then result.warnings[#result.warnings+1]=why end
        end
        if #result.candidates == 0 and #(result.warnings or {}) > 0 then return nil,table.concat(result.warnings,"\n") end
        result.candidates = M.deduplicate(M.rank(result.candidates,query))
        return result
    end
    function M.thumbnails(candidates)
        for i,c in ipairs(candidates) do app.images.thumbnail(c,i) end
        return candidates
    end
    return M
end
