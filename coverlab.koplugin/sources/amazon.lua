-- User-initiated, bounded reads of public Kindle search/product pages.
-- No login, browser emulation, CAPTCHA solving, cookies, or block evasion.
return function(app)
    local M={name="Amazon Kindle"}
    local util=require("util")
    local function plain(s) return util.htmlToPlainText(s or ""):gsub("%s+"," "):match("^%s*(.-)%s*$") end
    local function attr(tag,name)
        local escaped=name:gsub("(%W)","%%%1")
        return tag:match("%s" .. escaped .. '%s*=%s*"([^"]*)"') or tag:match("%s" .. escaped .. "%s*=%s*'([^']*)'")
    end
    local function escape(s) return tostring(s or ""):gsub("([^%w%-_%.~])",function(c)return string.format("%%%02X",c:byte())end) end
    function M.imageURL(url)
        if not url then return end
        url=util.htmlEntitiesToUtf8(url)
        local parsed=app.network.parse(url)
        if not parsed then return end
        local allowed={ ["m.media-amazon.com"]=true,["images-na.ssl-images-amazon.com"]=true,
            ["images-eu.ssl-images-amazon.com"]=true,["images-fe.ssl-images-amazon.com"]=true }
        if not allowed[parsed.host] then return end
        -- Remove Amazon's thumbnail transform to request the stored image.
        local stem=url:match("^(https://[^/]+/images/I/[%w%+%-]+)%.%_[^/]+_%.[Jj][Pp][Ee]?[Gg]$")
        if stem then return stem .. ".jpg" end
        if url:match("/images/I/[%w%+%-]+%.[Jj][Pp][Ee]?[Gg]$") then return url end
    end
    local function candidate(asin,title,author,image,query)
        local full=M.imageURL(image)
        if not full then return end
        local exact=app.metadata.normalizeASIN(query.asin) == asin
        return {id="amazon:" .. asin,asin=asin,source="Amazon Kindle",source_priority=1,
            title=plain(title),author=plain(author),edition="Kindle ASIN " .. asin,
            exact=exact,match_label=exact and "Exact Kindle ASIN" or "Kindle edition · verify match",
            publisher="",year="",url=full,thumbnail_url=full:gsub("%.jpg$","._SL160_.jpg")}
    end
    function M.parseSearch(html,query)
        local lower=html:lower()
        if lower:find("validatecaptcha",1,true) or lower:find("enter the characters you see below",1,true)
            or lower:find("automated access to amazon data",1,true) or lower:find("robot check",1,true) then
            return nil,"Amazon blocked this lookup or requested a CAPTCHA. Try later, import an image, or enable Open Library."
        end
        local starts,position={},1
        while true do
            local s,e=html:find('<div[^>]-data%-component%-type%s*=%s*["\']s%-search%-result["\'][^>]*>',position)
            if not s then break end
            starts[#starts+1]={s=s,e=e};position=e+1
        end
        local out,seen={},{}
        for i,span in ipairs(starts) do
            if #out >= 16 then break end
            local tag=html:sub(span.s,span.e)
            local asin=app.metadata.normalizeASIN(attr(tag,"data-asin"))
            local block=html:sub(span.e+1,starts[i+1] and starts[i+1].s-1 or #html)
            -- Kindle search can include print and sponsored products. Require a
            -- Kindle format label and a Kindle ASIN before admitting a result.
            if asin and not seen[asin] and block:find("Kindle",1,true) then
                local title,image,author
                for h2 in block:gmatch("<h2[^>]*>.-</h2>") do title=attr(h2,"aria-label") or plain(h2);break end
                for img in block:gmatch("<img%s[^>]*>") do
                    if (attr(img,"class") or ""):find("s-image",1,true) then
                        image=attr(img,"src");title=title or attr(img,"alt");break
                    end
                end
                author=block:match('by%s*</span>%s*<a[^>]*>(.-)</a>') or block:match('by%s+<a[^>]*>(.-)</a>')
                if not author then author=block:match('by%s*</span>%s*<span[^>]*>(.-)</span>') end
                if title and image then
                    local c=candidate(asin,title,author,image,query)
                    if c then out[#out+1]=c;seen[asin]=true end
                end
            end
        end
        local more=false
        for tag in html:gmatch("<a%s[^>]*>") do
            local class=attr(tag,"class") or ""
            if class:find("s-pagination-next",1,true) and not class:find("disabled",1,true) then more=true end
        end
        if #starts == 0 and not lower:find("no results",1,true) and not lower:find("did not match any products",1,true) then
            return nil,"Amazon returned an unsupported page. Search markup may have changed; try manual import or Open Library."
        end
        return {candidates=out,more=more,warnings={}}
    end
    function M.parseProduct(html,query)
        local wanted=app.metadata.normalizeASIN(query.asin)
        local identified
        for tag in html:gmatch("<input%s[^>]*>") do
            if attr(tag,"id") == "ASIN" or attr(tag,"name") == "ASIN" then
                identified=app.metadata.normalizeASIN(attr(tag,"value"));break
            end
        end
        -- A redirect or recommendation must not become an exact match merely
        -- because the requested URL contained the expected ASIN.
        if not identified or identified ~= wanted then return end
        local image,title
        for tag in html:gmatch("<img%s[^>]*>") do
            local id=attr(tag,"id")
            if id == "ebooksImgBlkFront" or id == "landingImage" then
                image=attr(tag,"data-old-hires")
                if not image or image == "" then image=attr(tag,"src") end
                title=attr(tag,"alt");break
            end
        end
        local page_title=html:match('<span[^>]-id%s*=%s*["\']productTitle["\'][^>]*>(.-)</span>')
        if page_title then title=page_title end
        return candidate(app.metadata.normalizeASIN(query.asin),title or query.title,"",image,query)
    end
    local function page(url)
        local html,err=app.network.text(url,2*1024*1024)
        if not html then return nil,"Amazon lookup failed: " .. tostring(err) end
        -- Cache parsed results below, rather than Amazon page content.
        return html
    end
    function M.search(query,number)
        -- Length prefixes avoid ambiguity when user-entered fields contain ':'.
        -- Version the key so old entries that omitted ISBN cannot be reused.
        local parts={"amazon-results:v2:"}
        for _,value in ipairs{query.asin or "",query.title or "",query.author or "",query.isbn or "",tostring(number)} do
            parts[#parts+1]=#value .. ":" .. value
        end
        local cachekey=table.concat(parts)
        local cached=app.cache.get(cachekey)
        if cached then return cached end
        local out,warnings={},{}
        local asin=app.metadata.normalizeASIN(query.asin)
        if asin and number == 1 then
            local html,err=page("https://www.amazon.com/dp/" .. asin)
            if html then
                local c=M.parseProduct(html,query)
                if c then out[#out+1]=c end
            elseif err then return nil,err end
        end
        local terms=query.title ~= "" and (query.title .. (query.author ~= "" and " " .. query.author or "")) or query.isbn or ""
        if terms ~= "" then
            local html,err=page("https://www.amazon.com/s?i=digital-text&k=" .. escape(terms) .. "&page=" .. number)
            if not html then
                if #out == 0 then return nil,err end
                warnings[#warnings+1]=err
            else
                local result;result,err=M.parseSearch(html,query)
                if not result then
                    if #out == 0 then return nil,err end
                    warnings[#warnings+1]=err
                else
                    for _,c in ipairs(result.candidates) do out[#out+1]=c end
                    local value={candidates=out,more=result.more,warnings=warnings}
                    app.cache.put(cachekey,value);return value
                end
            end
        end
        local value={candidates=out,more=false,warnings=warnings}
        app.cache.put(cachekey,value);return value
    end
    return M
end
