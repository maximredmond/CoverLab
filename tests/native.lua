-- Run from an extracted official KOReader Linux distribution:
-- KO_HOME=/tmp/coverlab-test SDL_VIDEODRIVER=dummy ./luajit /path/tests/native.lua /path/coverlab.koplugin /tmp/fixtures
require("setupkoenv")
G_defaults=require("luadefaults"):open()
G_reader_settings=require("luasettings"):open(require("datastorage"):getDataDir() .. "/settings.reader.lua")
local plugin,fixtures=assert(arg[1]),assert(arg[2])
local Device=require("device")
require("document/canvascontext"):init(Device)
local UIManager=require("ui/uimanager")
local CoverLab=dofile(plugin .. "/main.lua")
local host={menu={registerToMainMenu=function()end}}
local instance=CoverLab:new{ui=host}
local app=instance.app
local book=fixtures .. "/book.epub"
local original=assert(app.fs.read(book))
local metadata=app.metadata.read(book)
assert(metadata.title == "The Count of Monte Cristo",metadata.title)
assert(metadata.author == "Alexandre Dumas",metadata.author)
assert(metadata.isbn == "9780140449266",metadata.isbn)
local unusual=app.metadata.read(fixtures .. "/[download-site.example] unusual filename - no ISBN.epub")
assert(unusual.title == metadata.title and unusual.isbn == "")
print("PASS native document metadata / no-ISBN / unusual filename")
local image=assert(app.images.validate(fixtures .. "/replacement.png"))
assert(image.width==600 and image.height==900)
for _,location in ipairs{"doc","dir","hash"} do
    G_reader_settings:saveSetting("document_metadata_folder",location)
    assert(app.covers.apply(book,fixtures .. "/previous.png"))
    assert(app.covers.apply(book,image.path))
    local path=require("docsettings"):findCustomCoverFile(book)
    local actual=assert(app.images.validate(path));assert(actual.width==600 and actual.height==900)
    local before=assert(app.fs.read(path))
    local record_path=app.fs.dirname(path) .. "/coverlab/previous.json"
    local before_record=assert(app.fs.read(record_path))
    local real_rename,real_copy,real_atomic=os.rename,app.fs.copy,app.fs.atomic
    local full=false
    os.rename=function(src,dst)
        if src:find("/previous-next-",1,true) and dst == record_path then full=true;return nil,"No space left on device" end
        return real_rename(src,dst)
    end
    app.fs.copy=function(...)if full then return nil,"No space left on device" end;return real_copy(...) end
    app.fs.atomic=function(...)if full then return nil,"No space left on device" end;return real_atomic(...) end
    local call_ok,applied,err=pcall(app.covers.apply,book,fixtures .. "/previous.png")
    os.rename,app.fs.copy,app.fs.atomic=real_rename,real_copy,real_atomic
    assert(call_ok,applied);assert(not applied and full,err)
    assert(app.fs.read(path)==before,"Failed apply changed the active cover")
    assert(app.fs.read(record_path)==before_record,"Failed apply changed previous-cover metadata")
    assert(app.covers.recover(book))
    assert(app.covers.restorePrevious(book))
    actual=assert(app.images.validate(require("docsettings"):findCustomCoverFile(book)));assert(actual.width==300)
    assert(app.covers.original(book));assert(not require("docsettings"):findCustomCoverFile(book))
    assert(app.fs.read(book)==original)
end
print("PASS native apply / full-storage rollback / previous / original / unchanged EPUB in doc, dir, hash modes")
app.view.open(book)
UIManager:forceRePaint()
local stack=UIManager._window_stack
local dialog=stack[#stack].widget
assert(dialog:getContentSize().h <= require("device").screen:getHeight(),"Main dialog overflows screen")
require("device").screen.bb:writePNG(fixtures .. "/main.png")
UIManager:close(dialog)
app.view.query={title=metadata.title,author=metadata.author,isbn=metadata.isbn,asin=""}
app.view.candidates={}
for i=1,6 do
    app.view.candidates[i]={id=tostring(i),title=metadata.title,author=metadata.author,source="Amazon Kindle",source_priority=1,
        url="https://m.media-amazon.com/images/I/fixture" .. i .. ".jpg",thumbnail=fixtures .. "/candidate-" .. i .. ".png",width=600,height=900,
        exact=false,match_label="Kindle edition · verify match",edition="Kindle ASIN B00000000" .. i}
end
app.view.active_source="Amazon Kindle";app.view.provider="amazon"
app.view.gallery(1,false)
UIManager:forceRePaint()
dialog=stack[#stack].widget
assert(dialog:getContentSize().h <= require("device").screen:getHeight(),"Gallery overflows screen: " .. dialog:getContentSize().h)
require("device").screen.bb:writePNG(fixtures .. "/gallery.png")
UIManager:close(dialog)
app.view.preview(image,"Local image",function()end,false)
UIManager:forceRePaint()
dialog=stack[#stack].widget
assert(dialog:getContentSize().h <= require("device").screen:getHeight(),"Preview overflows screen")
require("device").screen.bb:writePNG(fixtures .. "/preview.png")
UIManager:close(dialog)
print("PASS native main / gallery / preview paint and fit screen")
-- Exercise provider-page merging through the real UI callbacks. The initial
-- batch has one candidate, so its gallery is partial at every tested size.
local real_run,real_page,real_thumbnails=app.view.run,app.search.page,app.search.thumbnails
local first,better=app.view.candidates[1],app.view.candidates[2]
better.exact=true
app.view.candidates={first};app.view.gallery_offsets={};app.view.offset=1
app.view.more=true;app.view.provider_page=1
app.view.gallery(1,false)
app.view.run=function(_,task,callback)callback(assert(task()))end
app.search.thumbnails=function(candidates)return candidates end
app.search.page=function()return {provider="amazon",active_source="Amazon Kindle",more=false,warnings={},candidates={better,first}}end
local function press(label)
    local top=UIManager._window_stack[#UIManager._window_stack].widget
    for _,row in ipairs(top.buttons) do
        for _,b in ipairs(row) do if b.text == label then b.callback();return end end
    end
    error("Missing pagination action: " .. label)
end
press("More Results")
assert(app.view.offset==2 and app.view.candidates[1]==first and app.view.candidates[2]==better,"Provider pagination skipped or reordered candidates")
press("Previous");assert(app.view.offset==1)
press("More Results");assert(app.view.offset==2,"Partial gallery page boundary was not preserved")
UIManager:close(UIManager._window_stack[#UIManager._window_stack].widget)
app.view.run,app.search.page,app.search.thumbnails=real_run,real_page,real_thumbnails
print("PASS native pagination / partial pages / back-forward navigation")
if os.getenv("COVERLAB_LIVE_TEST") then
    local result=assert(app.search.page(app.view.query,1))
    assert(#result.candidates>0)
    print("PASS live source",result.active_source,#result.candidates)
    local c=result.candidates[1]
    app.images.thumbnail(c,1)
    assert(c.thumbnail,c.image_error)
    local downloaded=assert(app.images.fetch(c.url,app.settings.temp_dir .. "/live"))
    print("PASS live image download / decode / dimensions",downloaded.width,downloaded.height)
    os.remove(downloaded.path)
end
print("Native integration checks passed")
