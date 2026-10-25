return function(app)
    local M = {}
    function M.normalizeASIN(value)
        local s=tostring(value or ""):upper():match("^%s*(.-)%s*$")
        if #s == 10 and s:match("^B[A-Z0-9]+$") then return s end
    end
    function M.extractASIN(value)
        if type(value) == "table" then
            for _,v in pairs(value) do local asin=M.extractASIN(v);if asin then return asin end end
        elseif type(value) == "string" then
            for word in value:upper():gmatch("[A-Z0-9]+") do local asin=M.normalizeASIN(word);if asin then return asin end end
        end
    end
    function M.normalizeISBN(value)
        local s = tostring(value or ""):gsub("[ %-]", ""):upper()
        if #s == 10 and s:match("^%d%d%d%d%d%d%d%d%d[%dX]$") then
            local sum = 0
            for i = 1, 10 do sum = sum + (s:sub(i,i) == "X" and 10 or tonumber(s:sub(i,i))) * (11-i) end
            if sum % 11 == 0 then return s end
        elseif #s == 13 and s:match("^%d+$") and (s:sub(1,3) == "978" or s:sub(1,3) == "979") then
            local sum = 0
            for i = 1, 13 do sum = sum + tonumber(s:sub(i,i)) * (i % 2 == 0 and 3 or 1) end
            if sum % 10 == 0 then return s end
        end
    end
    function M.isbn13(isbn)
        isbn = M.normalizeISBN(isbn)
        if not isbn or #isbn == 13 then return isbn end
        local base, sum = "978" .. isbn:sub(1,9), 0
        for i = 1, 12 do sum = sum + tonumber(base:sub(i,i)) * (i % 2 == 0 and 3 or 1) end
        return base .. ((10 - sum % 10) % 10)
    end
    function M.extractISBN(value)
        if type(value) == "table" then
            for _, v in pairs(value) do local n = M.extractISBN(v); if n then return n end end
        elseif type(value) == "string" or type(value) == "number" then
            local text = tostring(value)
            local n = M.normalizeISBN(text)
            if n then return n end
            for run in text:gmatch("[%d][%dXx %-]+[%dXx]") do
                n = M.normalizeISBN(run)
                if n then return n end
            end
        end
    end
    function M.read(file)
        local BookInfo = require("apps/filemanager/filemanagerbookinfo")
        local info = BookInfo:new{ ui = app.host.ui }
        local props = info:getDocProps(file) or {}
        -- BookInfo filters out identifiers when creating its display table.
        -- Read those through the document provider, including for cached books.
        local raw={}
        local document=app.host.ui.document
        local owned=not document or document.file ~= file
        if owned then document=require("document/documentregistry"):openDocument(file) end
        if document then
            local ok,value=pcall(function()
                if owned and document.loadDocument and not document:loadDocument(false) then return {} end
                return document:getDocumentProps() or {}
            end)
            if owned then document:close() end
            if ok then raw=value end
        end
        -- Work on a new table: never change document properties or reading settings.
        return { file = file, title = props.title or "", author = props.authors or "",
            isbn = M.extractISBN(raw.isbn or raw.identifiers or props.isbn or props.identifiers) or "",
            asin = M.extractASIN(raw.asin or raw.identifiers or props.asin or props.identifiers) or "",
            publisher = raw.publisher or props.publisher, year = raw.publication_year or raw.year or props.publication_year or props.year,
        }
    end
    return M
end
