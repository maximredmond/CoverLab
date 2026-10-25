-- Standalone contract tests: luajit tests/run.lua
-- KOReader UI, TLS, decoder and sidecar APIs are simulated here. Hardware and
-- native decoder integration are covered by tests/native.lua, not this suite.
local root = "coverlab.koplugin/"
local count, failed = 0, 0
local function eq(a,b) assert(a==b, tostring(a) .. " ~= " .. tostring(b)) end
local function test(name, fn)
    count=count+1
    local ok,err=pcall(fn)
    if ok then print("ok " .. count .. " - " .. name) else failed=failed+1; print("not ok " .. count .. " - " .. name .. ": " .. tostring(err)) end
end
local function clone(t)
    if type(t) ~= "table" then return t end
    local out={}; for k,v in pairs(t) do out[k]=clone(v) end; return out
end
local function settings()
    local values={max_download=1024*1024,max_dimension=10000,max_pixels=12000000,
        cache_enabled=true,cache_lifetime=604800,connect_timeout=10,total_timeout=45,max_redirects=3,contact="test@example.com"}
    return {dir="/settings",cache_dir="/cache",temp_dir="/tmp",get=function(_,k) return values[k] end,
        set=function(_,k,v) values[k]=v end}
end
local encoded, seq = {}, 0
package.preload.json=function() return {
    encode=function(value) seq=seq+1; local s="encoded:" .. seq; encoded[s]=clone(value); return s end,
    decode=function(s) assert(encoded[s],"Invalid JSON fixture"); return clone(encoded[s]) end,
} end
local app={settings=settings()}
app.metadata=dofile(root .. "metadata.lua")(app)
test("ISBN checksums and ISBN-10/13 equivalence",function()
    eq(app.metadata.normalizeISBN("0-14-044926-4"),"0140449264")
    eq(app.metadata.isbn13("0140449264"),"9780140449266")
    eq(app.metadata.normalizeISBN("9780140449260"),nil)
    eq(app.metadata.normalizeISBN("123456789X"),"123456789X")
end)
test("identifiers are extracted without consulting filenames",function()
    eq(app.metadata.extractISBN("uuid:abc; ISBN: 978-0-14-044926-6; other:42"),"9780140449266")
    eq(app.metadata.extractISBN({uuid="123",isbn="0140449264"}),"0140449264")
    eq(app.metadata.extractISBN("download-site.example - a book.epub"),nil)
end)
test("Kindle ASIN extraction is separate from ISBN identification",function()
    eq(app.metadata.extractASIN("uuid:123; ASIN:B0CFWHPJTN"),"B0CFWHPJTN")
    eq(app.metadata.normalizeASIN(" b0cfwhpjtn "),"B0CFWHPJTN")
    eq(app.metadata.normalizeASIN("9780140449"),nil)
end)
app.network=dofile(root .. "network.lua")(app)
test("URLs reject downgrade, credentials, control characters and non-HTTPS ports",function()
    for _,url in ipairs{"http://example.com/x","file:///tmp/x","https://user:pass@example.com/a","https://example.com:80/a","https://example.com/\nx","https://[::1]/x","https://example.com\\@localhost/x"} do
        eq(app.network.parse(url),nil)
    end
    eq(app.network.parse("https://EXAMPLE.com:443/a?b=c#d").url,"https://example.com/a?b=c")
end)
test("private, loopback, metadata, reserved and ambiguous numeric addresses fail closed",function()
    for _,ip in ipairs{"0.0.0.0","10.0.0.1","127.0.0.1","169.254.169.254","172.16.0.1","172.31.255.254","192.168.1.1","100.64.0.1","192.0.0.1","198.18.1.1","198.51.100.1","203.0.113.1","224.0.0.1","999.1.1.1","2130706433","127.1","0177.0.0.1"} do
        eq(app.network.publicIPv4(ip),false)
    end
    eq(app.network.publicIPv4("8.8.8.8"),true)
end)
local tls=dofile(root .. "tls.lua")(app)
test("TLS verifies SAN names, restricts wildcards, and gives SAN priority over CN",function()
    local cert={extensions=function()return {["2.5.29.17"]={dNSName={"*.example.com"}}}end,
        subject=function()return {{name="commonName",value="other.com"}}end}
    eq(tls.matches(cert,"images.example.com"),true)
    eq(tls.matches(cert,"a.b.example.com"),false)
    eq(tls.matches(cert,"example.com"),false)
    eq(tls.matches(cert,"other.com"),false)
    eq(tls.matches(cert,"8.8.8.8"),false)
end)
test("mixed public/private DNS results are rejected; IPv6-only fails closed",function()
    eq(app.network.resolve("example.com",{getaddrinfo=function()return {{family="inet",addr="8.8.8.8"},{family="inet",addr="127.0.0.1"}}end}),nil)
    eq(app.network.resolve("example.com",{getaddrinfo=function()return {{family="inet6",addr="::1"}}end}),nil)
    eq(app.network.resolve("printer.local",{}),nil)
end)
local function virtual()
    local files,dirs, faults = {},{},{}
    local fs={}
    function fs.read(path,limit)
        if not files[path] then return nil,"missing" end
        if limit and #files[path]>limit then return nil,"File exceeds size limit." end
        return files[path]
    end
    function fs.write(path,data)
        if faults.write and faults.write(path) then return nil,"disk full" end
        files[path]=data; return true
    end
    fs.atomic=fs.write
    function fs.copy(src,dst)
        if not files[src] then return nil,"missing source" end
        if faults.copy and faults.copy(src,dst) then return nil,"injected copy failure" end
        return fs.write(dst,files[src])
    end
    fs.dirname=function(path) return path:match("^(.*)/[^/]*$") end
    local lfs={}
    function lfs.attributes(path,key)
        local a=files[path] and {mode="file",size=#files[path],modification=os.time()} or dirs[path] and {mode="directory"}
        return a and (key and a[key] or a)
    end
    function lfs.dir(path)
        local names={}
        for p in pairs(files) do local name=p:match("^" .. path:gsub("(%W)","%%%1") .. "/([^/]+)$"); if name then names[#names+1]=name end end
        table.sort(names)
        local i=0; return function()i=i+1;return names[i]end
    end
    return fs,files,dirs,faults,lfs
end
app.fs,app.files=virtual()
app.cache=dofile(root .. "cache.lua")(app)
app.search=dofile(root .. "search.lua")(app)
test("edition confidence outranks both resolution and aspect ratio",function()
    local ranked=app.search.rank({
        {id="3",title="Another book",author="Wrong author",width=3000,height=4500,exact=false},
        {id="2",title="The Book",author="The Author",width=1600,height=2400,exact=false},
        {id="1",title="The Book",author="The Author",width=200,height=300,exact=true},
    },{title="The Book",author="The Author"})
    eq(ranked[1].id,"1");eq(ranked[2].id,"2")
end)
test("byte-identical images and repeated provider covers are deduplicated",function()
    app.files["/a"]="same";app.files["/b"]="same"
    local c=app.search.deduplicate({{url="a",thumbnail="/a"},{url="b",thumbnail="/b"},{url="a"},{url="c"}})
    eq(#c,2);eq(c[2].url,"c")
end)
test("cache expires, verifies keys and honours disabled setting",function()
    app.cache.put("query",{title="book"});eq(app.cache.get("query").title,"book")
    app.settings:set("cache_lifetime",-1);eq(app.cache.get("query"),nil)
    app.settings:set("cache_lifetime",604800);app.settings:set("cache_enabled",false);eq(app.cache.get("query"),nil)
    app.settings:set("cache_enabled",true)
end)
test("pagination appends better new matches without moving existing candidates",function()
    local q={title="A Book",author="An Author"}
    local existing={}
    for i=1,3 do existing[i]={id=tostring(i),url=tostring(i),title="A Book Other Edition",author="An Author",exact=false} end
    local incoming={
        {id="new-low",url="low",title="Different",author="Different",exact=false},
        {id="new-best",url="best",title=q.title,author=q.author,exact=true},
        clone(existing[2]),
    }
    local merged=app.search.append(existing,incoming,q)
    eq(#merged,5)
    for i=1,3 do eq(merged[i],existing[i]) end
    eq(merged[4].id,"new-best");eq(merged[5].id,"new-low")
    eq(#app.search.append(merged,{clone(existing[1])},q),5)
end)
local be=function(n,bytes)
    local s="";for _=1,bytes do s=string.char(n%256) .. s;n=math.floor(n/256) end;return s
end
local function png(w,h)
    local function chunk(kind,data) return be(#data,4) .. kind .. data .. "CRC!" end
    return "\137PNG\r\n\26\n" .. chunk("IHDR",be(w,4) .. be(h,4) .. "\8\2\0\0\0") .. chunk("IDAT","pixels") .. chunk("IEND","")
end
package.preload["ui/renderimage"]=function()return {renderImageFile=function(_,path)
    local data=app.fs.read(path)
    if data:find("BAD",1,true) then return end
    local w,h=app.images.header(data)
    return {getWidth=function()return w end,getHeight=function()return h end,free=function()end}
end}end
app.images=dofile(root .. "images.lua")(app)
test("actual image header dimensions, pixel cap and quality labels",function()
    app.files["/good"]=png(600,900)
    local image=assert(app.images.validate("/good"));eq(image.width,600);eq(image.height,900);eq(image.format,"png")
    eq(app.images.quality(600,900),"High");eq(app.images.quality(1200,1800),"Very high")
    app.files["/huge"]=png(10000,10000);eq(app.images.validate("/huge"),nil)
end)
test("truncated PNG, unsupported content and decoder failures are rejected",function()
    app.files["/bad"]=png(600,900):sub(1,-5);eq(app.images.validate("/bad"),nil)
    app.files["/html"]="<html>not an image</html>";eq(app.images.validate("/html"),nil)
    app.files["/decode"]=png(1,1):gsub("pixels","BAD");eq(app.images.validate("/decode"),nil)
end)
test("JPEG dimensions require complete, bounded segment headers",function()
    local jpeg="\255\216\255\192" .. be(17,2) .. "\8" .. be(900,2) .. be(600,2) .. "\3" .. string.rep("\0",9) .. "\255\217"
    local w,h,f=app.images.header(jpeg);eq(w,600);eq(h,900);eq(f,"jpg")
    eq(app.images.header(jpeg:sub(1,10)),nil)
end)
package.loaded.util={
    htmlEntitiesToUtf8=function(s)return s:gsub("&amp;","&"):gsub("&quot;",'"')end,
    htmlToPlainText=function(s)return s:gsub("<[^>]*>",""):gsub("&amp;","&")end,
}
local amazon=dofile(root .. "sources/amazon.lua")(app)
local query={title="A Book",author="An Author",isbn="",asin=""}
test("Amazon uses Kindle search result images at original resolution",function()
    local html=[[<div data-asin="B0CFWHPJTN" data-component-type="s-search-result">
        <img class="s-image" src="https://m.media-amazon.com/images/I/71test._AC_UY218_.jpg" alt="A Book"/>
        <h2 aria-label="A Book &amp; More"><span>A Book</span></h2>
        <span>by </span><a href="/author">An Author</a><a>Kindle Edition</a></div>
        <a class="s-pagination-next" href="/s?page=2">Next</a>]]
    local result=assert(amazon.parseSearch(html,query));eq(#result.candidates,1)
    local c=result.candidates[1];eq(c.url,"https://m.media-amazon.com/images/I/71test.jpg")
    eq(c.author,"An Author");eq(c.title,"A Book & More");eq(c.exact,false);eq(result.more,true)
end)
test("Amazon skips print items, duplicate ASINs and untrusted image hosts",function()
    local html=[[<div data-asin="0140449264" data-component-type="s-search-result"><h2>Print book</h2>Paperback</div>
        <div data-asin="B0CFWHPJTN" data-component-type="s-search-result"><h2>Wrong host</h2>Kindle Edition<img class="s-image" src="https://evil.example/images/I/test.jpg"/></div>]]
    eq(#assert(amazon.parseSearch(html,query)).candidates,0)
    eq(amazon.imageURL("http://m.media-amazon.com/images/I/test.jpg"),nil)
end)
test("Amazon CAPTCHA and unknown markup stop rather than bypassing blocks",function()
    eq(amazon.parseSearch('<form action="/errors/validateCaptcha">Robot Check</form>',query),nil)
    eq(amazon.parseSearch('<html>Unknown new layout</html>',query),nil)
    eq(#assert(amazon.parseSearch('<html>No results</html>',query)).candidates,0)
end)
test("ASIN product cover lookup preserves exact match without inventing an author",function()
    local q=clone(query);q.asin="B0CFWHPJTN"
    local c=assert(amazon.parseProduct([[<input id="ASIN" value="B0CFWHPJTN"/><img id="ebooksImgBlkFront" src="https://m.media-amazon.com/images/I/71test._SY400_.jpg" alt="A Book"/>]],q))
    eq(c.exact,true);eq(c.asin,q.asin);eq(c.author,"")
    eq(amazon.parseProduct([[<input id="ASIN" value="B000000000"/><img id="ebooksImgBlkFront" src="https://m.media-amazon.com/images/I/71test.jpg"/>]],q),nil)
end)
test("ISBN-only Amazon searches have distinct cache entries and unchanged queries reuse them",function()
    local records,requests={},{}
    local a={metadata=app.metadata,network={parse=app.network.parse},cache={
        get=function(key)return records[key]end,put=function(key,value)records[key]=clone(value)end,
    }}
    function a.network.text(url)
        requests[#requests+1]=url
        local asin=#requests == 1 and "B000000001" or "B000000002"
        return '<div data-asin="' .. asin .. '" data-component-type="s-search-result"><h2>A Book</h2>'
            .. '<img class="s-image" src="https://m.media-amazon.com/images/I/test.jpg"/>Kindle Edition</div>'
    end
    local source=dofile(root .. "sources/amazon.lua")(a)
    local first={title="",author="",asin="",isbn="9780140449266"}
    local second={title="",author="",asin="",isbn="9780141439600"}
    local r1=assert(source.search(first,1));local r2=assert(source.search(second,1))
    eq(#requests,2);assert(requests[1]:find(first.isbn,1,true));assert(requests[2]:find(second.isbn,1,true))
    eq(r1.candidates[1].asin,"B000000001");eq(r2.candidates[1].asin,"B000000002")
    eq(assert(source.search(first,1)).candidates[1].asin,"B000000001");eq(#requests,2)
end)
test("Amazon is primary and disabling Open Library prevents all secondary lookups",function()
    local calls=0
    app.sources={amazon={search=function()return {candidates={{id="a",url="a",title=query.title,author=query.author,exact=false}},warnings={},more=false}end},
        openlibrary={search=function()calls=calls+1;return {candidates={{id="ol",url="ol",title=query.title,author=query.author,exact=false}},warnings={},more=false}end}}
    app.settings:set("openlibrary_enabled",false)
    eq(assert(app.search.page(query,1)).provider,"amazon");eq(calls,0)
    eq(app.search.page(query,1,"openlibrary"),nil);eq(calls,0)
    app.sources.amazon.search=function()return nil,"Amazon unavailable"end
    eq(app.search.page(query,1),nil);eq(calls,0)
    app.settings:set("openlibrary_enabled",true)
    eq(assert(app.search.page(query,1)).provider,"openlibrary");eq(calls,1)
end)
local real_remove, real_rename=os.remove,os.rename
local function coverEnv()
    local fs,files,dirs,faults,lfs=virtual()
    local doc={}
    function doc:getSidecarDir(file,where) return "/" .. where .. "/book.sdr" end
    function doc:getCustomLocationCandidates() return {"/hash/book.sdr"} end
    function doc:findCustomCoverFile()
        for _,where in ipairs{"hash","doc","dir"} do
            for name in lfs.dir("/" .. where .. "/book.sdr") do if name:match("^cover%.") then return "/" .. where .. "/book.sdr/" .. name end end
        end
    end
    package.loaded["docsettings"]=doc
    package.loaded["libs/libkoreader-lfs"]=lfs
    package.loaded.util={makePath=function(path) dirs[path]=true end}
    local events={}
    package.loaded["ui/uimanager"]={broadcastEvent=function(_,event)events[#events+1]=event end,setDirty=function()end}
    package.loaded["ui/event"]={new=function(_,name,file)return {name=name,file=file}end}
    os.remove=function(path)
        if faults.remove and faults.remove(path) then return nil,"read only" end
        if not files[path] then return nil,"missing" end
        files[path]=nil;return true
    end
    os.rename=function(src,dst)
        if faults.rename and faults.rename(src,dst) then return nil,"injected rename failure" end
        if not files[src] then return nil,"missing" end
        files[dst]=files[src];files[src]=nil;return true
    end
    local a={fs=fs,settings=settings(),host={ui={}},images={validate=function(path)
        if files[path] == "INVALID" then return nil,"Invalid image" end
        return {format=files[path] == "PNG" and "png" or "jpg"}
    end}}
    a.covers=dofile(root .. "covers.lua")(a)
    files["/library/book.epub"]="EPUB BYTES UNCHANGED"
    files["/new.jpg"]="NEW COVER"
    return a,files,faults,doc,events
end
local book="/library/book.epub"
test("apply to hashed sidecar, preserve and restore previous cover; EPUB remains unchanged",function()
    local a,files,_,doc,events=coverEnv()
    files["/hash/book.sdr/cover.png"]="OLD COVER"
    assert(a.covers.apply(book,"/new.jpg"));eq(files[doc:findCustomCoverFile(book)],"NEW COVER")
    eq(files[a.covers.previous(book).path],"OLD COVER")
    assert(a.covers.restorePrevious(book));eq(files[doc:findCustomCoverFile(book)],"OLD COVER")
    eq(files[book],"EPUB BYTES UNCHANGED");eq(events[1].name,"InvalidateMetadataCache")
end)
test("using embedded cover clears all shadow overrides and preserves active previous cover",function()
    local a,files,_,doc=coverEnv()
    files["/hash/book.sdr/cover.png"]="ACTIVE"
    files["/doc/book.sdr/cover.jpg"]="SHADOW"
    assert(a.covers.original(book));eq(doc:findCustomCoverFile(book),nil)
    eq(files[a.covers.previous(book).path],"ACTIVE")
    assert(a.covers.restorePrevious(book));eq(files[doc:findCustomCoverFile(book)],"ACTIVE")
end)
test("backup failure aborts before removing existing covers",function()
    local a,files,faults=coverEnv();files["/hash/book.sdr/cover.jpg"]="OLD"
    faults.copy=function(src) return src:match("cover%.jpg$") end
    eq(a.covers.apply(book,"/new.jpg"),nil);eq(files["/hash/book.sdr/cover.jpg"],"OLD")
end)
test("disk full while staging leaves current cover and reading data untouched",function()
    local a,files,faults=coverEnv();files["/hash/book.sdr/cover.png"]="OLD"
    files["/hash/book.sdr/metadata.epub.lua"]="PROGRESS, HIGHLIGHTS, BOOKMARKS"
    faults.copy=function(_,dst) return dst:match("incoming%.part$") end
    eq(a.covers.apply(book,"/new.jpg"),nil);eq(files["/hash/book.sdr/cover.png"],"OLD")
    eq(files["/hash/book.sdr/metadata.epub.lua"],"PROGRESS, HIGHLIGHTS, BOOKMARKS")
end)
test("installation rename failure rolls back all custom covers",function()
    local a,files,faults=coverEnv();files["/hash/book.sdr/cover.png"]="OLD";files["/doc/book.sdr/cover.jpg"]="SHADOW"
    faults.rename=function(src) return src:match("incoming%.part$") end
    eq(a.covers.apply(book,"/new.jpg"),nil)
    eq(files["/hash/book.sdr/cover.png"],"OLD");eq(files["/doc/book.sdr/cover.jpg"],"SHADOW")
    eq(files["/hash/book.sdr/cover.jpg"],nil)
end)
test("invalid image is rejected before any custom cover mutation",function()
    local a,files=coverEnv();files["/hash/book.sdr/cover.png"]="OLD";files["/new.jpg"]="INVALID"
    eq(a.covers.apply(book,"/new.jpg"),nil);eq(files["/hash/book.sdr/cover.png"],"OLD")
end)
test("interrupted transaction recovers at next open",function()
    local a,files=coverEnv()
    files["/hash/book.sdr/cover.jpg"]="PARTIAL NEW"
    files["/hash/book.sdr/coverlab/backup.png"]="OLD"
    files["/hash/book.sdr/coverlab/transaction.json"]=require("json").encode{
        file=book,target="/hash/book.sdr/cover.jpg",originals={{path="/hash/book.sdr/cover.png",backup="/hash/book.sdr/coverlab/backup.png"}}}
    assert(a.covers.recover(book));eq(files["/hash/book.sdr/cover.png"],"OLD");eq(files["/hash/book.sdr/cover.jpg"],nil)
end)
test("missing recovery backup never deletes the available cover",function()
    local a,files=coverEnv();files["/hash/book.sdr/cover.jpg"]="AVAILABLE"
    files["/hash/book.sdr/coverlab/transaction.json"]=require("json").encode{
        file=book,target="/hash/book.sdr/cover.jpg",originals={{path="/hash/book.sdr/cover.png",backup="/missing"}}}
    eq(a.covers.recover(book),nil);eq(files["/hash/book.sdr/cover.jpg"],"AVAILABLE")
end)
test("post-install storage exhaustion restores cover and previous record without allocating files",function()
    local a,files,faults=coverEnv()
    local current="/hash/book.sdr/cover.jpg"
    local previous="/hash/book.sdr/coverlab/previous.json"
    files[current]="OLD"
    files["/saved-previous.png"]="PREVIOUS"
    local old_record=require("json").encode{file=book,path="/saved-previous.png",time=1}
    files[previous]=old_record
    local full=false
    faults.rename=function(src,dst)
        if src:find("/previous-next-",1,true) and dst == previous then full=true;return true end
    end
    faults.write=function()return full end
    faults.copy=function()return full end
    local ok= a.covers.apply(book,"/new.jpg")
    eq(ok,nil);eq(full,true)
    eq(files[current],"OLD");eq(files[previous],old_record);eq(files["/saved-previous.png"],"PREVIOUS")
    eq(files["/hash/book.sdr/coverlab/transaction.json"],nil)
    assert(a.covers.recover(book));eq(files[book],"EPUB BYTES UNCHANGED")
end)
test("rollback retains its backups until a persistently failing journal deletion succeeds",function()
    local a,files,faults=coverEnv();files["/hash/book.sdr/cover.jpg"]="OLD"
    local journal_path="/hash/book.sdr/coverlab/transaction.json"
    local previous_path="/hash/book.sdr/coverlab/previous.json"
    files["/saved-previous.png"]="PREVIOUS"
    local previous_raw=require("json").encode{file=book,path="/saved-previous.png",time=1}
    files[previous_path]=previous_raw
    faults.remove=function(path)return path == journal_path end
    eq(a.covers.apply(book,"/new.jpg"),nil)
    eq(files["/hash/book.sdr/cover.jpg"],"OLD")
    local journal=require("json").decode(assert(files[journal_path]))
    for _,old in ipairs(journal.originals) do eq(files[old.backup],"OLD") end
    eq(a.covers.recover(book),nil)
    for _,old in ipairs(journal.originals) do eq(files[old.backup],"OLD") end
    eq(files[previous_path],previous_raw)
    faults.remove=nil
    assert(a.covers.recover(book));eq(files[journal_path],nil)
    eq(files["/hash/book.sdr/cover.jpg"],"OLD")
    eq(files[previous_path],previous_raw);eq(files["/saved-previous.png"],"PREVIOUS")
    for _,old in ipairs(journal.originals) do eq(files[old.backup],nil) end
end)
test("interrupted rollback retries already-restored originals and previous metadata safely",function()
    local a,files,faults=coverEnv()
    files["/hash/book.sdr/cover.png"]="ACTIVE";files["/doc/book.sdr/cover.jpg"]="SHADOW"
    faults.rename=function(src,dst)
        return src:match("incoming%.part$") or src:find("/.coverlab-restore-",1,true) and dst == "/hash/book.sdr/cover.png"
    end
    eq(a.covers.apply(book,"/new.jpg"),nil)
    -- The first original was restored; the second still has its saved sibling.
    eq(files["/doc/book.sdr/cover.jpg"],"SHADOW")
    assert(files["/hash/book.sdr/coverlab/transaction.json"])
    faults.rename=nil;faults.copy=function()return true end;faults.write=function()return true end
    assert(a.covers.recover(book))
    eq(files["/hash/book.sdr/cover.png"],"ACTIVE");eq(files["/doc/book.sdr/cover.jpg"],"SHADOW")
end)
os.remove,os.rename=real_remove,real_rename
local function networkEnv(responses)
    local a={fs=select(1,virtual()),settings=settings()}
    a.cache={key=app.cache.key}
    local index,connections=0,{}
    a.tls={create=function(host,ip) connections[#connections+1]={host=host,ip=ip};return {} end}
    package.loaded.socket={gettime=function()return os.time() end,sleep=function()end,
        dns={getaddrinfo=function()return {{family="inet",addr="8.8.8.8"}}end}}
    package.loaded.socketutil={set_timeout=function()end,reset_timeout=function()end}
    package.loaded["socket.url"]={absolute=function(_,target)return target end}
    local http={PROXY="http://private-proxy.example"}
    function http.request(request)
        index=index+1
        local response=assert(responses[index],"Unexpected request")
        request.create()
        if response.body then
            local ok,err=request.sink(response.body)
            if not ok then return nil,err end
        end
        return 1,response.status or 200,response.headers or {}
    end
    package.loaded["socket.http"]=http
    a.network=dofile(root .. "network.lua")(a)
    return a,connections,http
end
test("verified transport receives a pinned public address and HTTP proxies are restored",function()
    local a,connections,http=networkEnv{{body="ok"}}
    eq(a.network.text("https://images.example.com/x"),"ok")
    eq(connections[1].host,"images.example.com");eq(connections[1].ip,"8.8.8.8")
    eq(http.PROXY,"http://private-proxy.example")
end)
test("redirects cannot downgrade HTTPS or reach private destinations",function()
    for _,target in ipairs{"http://example.com/x","https://127.0.0.1/x"} do
        local a,connections=networkEnv{{status=302,headers={location=target},body="redirect"}}
        eq(a.network.text("https://images.example.com/x"),nil)
        eq(#connections,1)
    end
end)
test("redirect bodies are discarded and redirect limits are enforced",function()
    local a=networkEnv{{status=302,body="wrong",headers={location="https://cdn.example.com/x"}},{body="image"}}
    eq(a.network.text("https://images.example.com/x"),"image")
    a=networkEnv{{status=302,headers={location="https://cdn.example.com/x"}},{status=302,headers={location="https://cdn.example.com/x"}}}
    a.settings:set("max_redirects",1)
    eq(a.network.text("https://images.example.com/x"),nil)
end)
test("body size limits and 404 responses fail without returning response bodies",function()
    local a=networkEnv{{body="oversized"}}
    eq(a.network.text("https://images.example.com/x",3),nil)
    a=networkEnv{{status=404,body="not found"}}
    eq(a.network.text("https://images.example.com/x"),nil)
end)
test("429 responses persist a cooldown and prevent another request",function()
    local a,connections=networkEnv{{status=429,headers={["retry-after"]="120"}}}
    eq(a.network.text("https://images.example.com/x"),nil)
    eq(a.network.text("https://images.example.com/x"),nil)
    eq(#connections,1)
end)
test("Amazon cooldown permits Open Library and unrelated image imports, including after restart",function()
    local a,connections=networkEnv{
        {status=429,headers={["retry-after"]="120"}}, {body="library"}, {body="cover"},
    }
    eq(a.network.text("https://www.amazon.com/s"),nil)
    -- A new transport instance reads the same on-disk limiter state.
    a.network=dofile(root .. "network.lua")(a)
    eq(a.network.text("https://www.amazon.com/dp/B000000001"),nil)
    eq(a.network.text("https://openlibrary.org/search.json"),"library")
    eq(a.network.text("https://my-cover.example/image.png"),"cover")
    eq(#connections,3)
end)
test("a redirect into a rate-limited destination stops before another connection",function()
    local a,connections=networkEnv{
        {status=429,headers={["retry-after"]="120"}},
        {status=302,headers={location="https://www.amazon.com/cover.jpg"}},
    }
    eq(a.network.text("https://www.amazon.com/s"),nil)
    eq(a.network.text("https://images.example.com/cover.jpg"),nil)
    eq(#connections,2)
end)
print(string.format("%d tests, %d failures",count,failed))
os.exit(failed > 0 and 1 or 0)
