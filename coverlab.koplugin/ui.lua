return function(app)
    local UIManager = require("ui/uimanager")
    local ButtonDialog = require("ui/widget/buttondialog")
    local ConfirmBox = require("ui/widget/confirmbox")
    local InfoMessage = require("ui/widget/infomessage")
    local ImageWidget = require("ui/widget/imagewidget")
    local TextBoxWidget = require("ui/widget/textboxwidget")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local Geom = require("ui/geometry")
    local Font = require("ui/font")
    local Screen = require("device").screen
    local M = { busy = false }
    function M.message(text) UIManager:show(InfoMessage:new{text=tostring(text)}) end
    local function close(widget) if widget then UIManager:close(widget) end end
    local function width() return math.floor(Screen:getWidth()*0.94) end
    local function button(text,callback,enabled) return {text=text,callback=callback,enabled=enabled} end
    local function text(value,w)
        return TextBoxWidget:new{text=value,width=w,face=Font:getFace("smallinfofont"),alignment="center"}
    end
    local function centered(widget,w,h)
        local center = CenterContainer:new{dimen=Geom:new{w=w,h=h},widget}
        center.not_focusable = true
        return center
    end
    function M.run(label, task, callback, online)
        if M.busy then return end
        local function run()
            M.busy = true
            require("ui/trapper"):wrap(function()
                local completed, result, err = require("ui/trapper"):dismissableRunInSubprocess(function()
                    local ok, value, why = pcall(task)
                    if not ok then return nil,tostring(value) end
                    return value,why
                end, label .. "\nTap to cancel.")
                M.busy = false
                if not completed then app.images.cleanup(); M.main(); return end
                if not result then app.images.cleanup(); M.main(); M.message(err or "Operation failed. Check Wi-Fi or choose a local image."); return end
                callback(result)
            end)
        end
        if online then require("ui/network/manager"):runWhenOnline(run) else run() end
    end
    function M.open(file)
        if M.busy then return end
        local ok, err = app.covers.recover(file)
        if not ok then M.message(err); return end
        local success, book = pcall(app.metadata.read,file)
        if not success then M.message("Could not read book metadata: " .. tostring(book)); return end
        M.book = book
        M.main()
    end
    function M.main()
        local book = M.book
        local title = book.title ~= "" and book.title or "Missing title — edit the search terms"
        local label = "CoverLab\n" .. title .. "\n" .. book.author
            .. (book.isbn ~= "" and "\nISBN " .. book.isbn or "")
            .. (book.asin ~= "" and "\nKindle ASIN " .. book.asin or "")
            .. (book.publisher and "\n" .. book.publisher or "")
            .. (book.year and " · " .. tostring(book.year) or "")
        local widgets = {}
        local ok, bb = pcall(function()
            return require("apps/filemanager/filemanagerbookinfo"):getCoverImage(app.host.ui.document,book.file)
        end)
        if ok and bb then
            local w,h = bb:getWidth(),bb:getHeight()
            local boxh = math.floor(Screen:getHeight()*0.22)
            widgets[#widgets+1] = centered(ImageWidget:new{image=bb,width=math.floor(boxh*w/h),height=boxh},width()-60,boxh)
            widgets[#widgets+1] = text(string.format("Current cover · %d × %d px",w,h),width()-60)
            widgets[#widgets].not_focusable = true
        else
            widgets[#widgets+1] = text("No current cover is available.",width()-60)
            widgets[#widgets].not_focusable = true
        end
        local dialog
        local function leave(fn) return function() close(dialog); fn() end end
        dialog = ButtonDialog:new{ title=label, width=width(), _added_widgets=widgets, buttons={
            {button("Find Better Cover",leave(function() M.editSearch(true) end))},
            {button("Choose Local Image",leave(M.localImage)),button("Enter Image URL",leave(M.url))},
            {button("Restore Previous Custom Cover",leave(function() M.restore(false) end),app.covers.previous(book.file) ~= nil)},
            {button("Use Original Book Cover",leave(function() M.restore(true) end))},
            {button("Settings",leave(M.settings)),button("Close",function() close(dialog) end)},
        }}
        UIManager:show(dialog)
    end
    function M.editSearch(immediate)
        local book = M.book
        if immediate and (book.title ~= "" or book.isbn ~= "" or book.asin ~= "") then
            M.query={title=book.title,author=book.author,isbn=book.isbn,asin=book.asin}
            M.provider="amazon"
            M.search(1); return
        end
        local MultiInputDialog = require("ui/widget/multiinputdialog")
        local q = M.query or book
        local dialog
        dialog = MultiInputDialog:new{title="CoverLab — Edit Search",fields={
            {text=q.title or "",hint="Title",description="Search title"},
            {text=q.author or "",hint="Author",description="Search author"},
            {text=q.isbn or "",hint="ISBN (optional)",description="ISBN-10 or ISBN-13"},
            {text=q.asin or "",hint="Kindle ASIN (optional)",description="Kindle ASIN"},
        },buttons={{button("Cancel",function() close(dialog); M.main() end),button("Search",function()
            local fields=dialog:getFields()
            local title,author,isbn=fields[1]:match("^%s*(.-)%s*$"),fields[2]:match("^%s*(.-)%s*$"),fields[3]:match("^%s*(.-)%s*$")
            local asin=fields[4]:match("^%s*(.-)%s*$")
            if title == "" and isbn == "" and asin == "" then M.message("Enter a title, ISBN, or Kindle ASIN."); return end
            if isbn ~= "" and not app.metadata.normalizeISBN(isbn) then M.message("Enter a valid ISBN, or clear it to search by title and author."); return end
            if asin ~= "" and not app.metadata.normalizeASIN(asin) then M.message("Enter a 10-character Kindle ASIN starting with B, or clear it.");return end
            M.query={title=title,author=author,isbn=isbn,asin=asin}
            M.provider="amazon"
            close(dialog); M.search(1)
        end)}}}
        UIManager:show(dialog); dialog:onShowKeyboard()
    end
    function M.search(page)
        M.run(M.provider == "openlibrary" and "Searching Open Library…" or "Searching Amazon Kindle…",function() return app.search.page(M.query,page,M.provider) end,function(result)
            M.provider=result.provider
            M.active_source=result.active_source
            M.provider_page=page
            M.more=result.more
            M.warnings=result.warnings
            if page == 1 then M.candidates={};M.gallery_offsets={} end
            local previous_count=#M.candidates
            M.candidates=app.search.append(M.candidates,result.candidates,M.query)
            if #M.candidates == 0 then
                local dialog
                dialog=ButtonDialog:new{title="No covers found. Try another title/author or import an image.",buttons={
                    {button("Edit Search",function() close(dialog); M.editSearch() end)},
                    {button("Choose Local Image",function() close(dialog); M.localImage() end)},
                    {button("Back",function() close(dialog); M.main() end)},
                }}; UIManager:show(dialog); return
            end
            -- A partially filled last gallery page does not end on a multiple
            -- of the page size. Start at the first new candidate, not offset+size.
            local offset=page == 1 and 1 or (#M.candidates > previous_count and previous_count+1 or M.offset or 1)
            M.gallery(offset,true)
        end,true)
    end
    function M.gallery(offset,load)
        offset=math.max(1,math.min(offset,#M.candidates))
        M.offset=offset
        M.gallery_offsets=M.gallery_offsets or {}
        local index
        for i,saved in ipairs(M.gallery_offsets) do if saved == offset then index=i;break end end
        if not index then
            M.gallery_offsets[#M.gallery_offsets+1]=offset
            index=#M.gallery_offsets
        end
        local scaled = function(n) return Screen:scaleBySize(n) end
        local columns=Screen:getWidth() >= 500 and 2 or 1
        local rows=math.min(3,math.max(1,math.floor((Screen:getHeight()-scaled(340))/scaled(195))))
        local count=columns*rows
        local page={}
        local next_saved=M.gallery_offsets[index+1]
        -- Keep a previously displayed partial page partial when navigating back.
        local last=math.min(#M.candidates,offset+count-1,next_saved and next_saved-1 or #M.candidates)
        for i=offset,last do page[#page+1]=M.candidates[i] end
        if load then
            M.run("Loading cover thumbnails…",function() return app.search.thumbnails(page) end,function(loaded)
                for i,c in ipairs(loaded) do M.candidates[offset+i-1]=c end
                M.gallery(offset,false)
            end,true)
            return
        end
        app.search.rank(page,M.query)
        page=app.search.deduplicate(page)
        local grid=VerticalGroup:new{align="center"}
        grid.not_focusable=true
        local w=math.floor((width()-scaled(60))/columns)
        local imageh=scaled(100)
        local buttons={}
        local dialog
        for row=1,math.ceil(#page/columns) do
            local group=HorizontalGroup:new{}
            local actions={}
            for col=1,columns do
                local index=(row-1)*columns+col
                local candidate=page[index]
                if candidate then
                    local tile=VerticalGroup:new{align="center"}
                    if candidate.thumbnail then
                        tile[#tile+1]=centered(ImageWidget:new{file=candidate.thumbnail,width=math.floor(imageh*0.7),height=imageh},w,imageh)
                    else tile[#tile+1]=centered(text("Image unavailable",w),w,imageh) end
                    tile[#tile+1]=text(index .. ". " .. (candidate.width and string.format("%d × %d px",candidate.width,candidate.height) or "Dimensions unavailable")
                        .. "\n" .. (candidate.match_label or (candidate.exact and "Exact ISBN edition" or "Alternative edition")),w)
                    group[#group+1]=tile
                    actions[#actions+1]=button("Preview " .. index,function() close(dialog); M.candidate(candidate) end)
                end
            end
            grid[#grid+1]=group
            buttons[#buttons+1]=actions
        end
        local nav={}
        if index > 1 then nav[#nav+1]=button("Previous",function() close(dialog); M.gallery(M.gallery_offsets[index-1],true) end) end
        local next_offset=next_saved or offset+count
        if next_offset <= #M.candidates then
            nav[#nav+1]=button("More Results",function() close(dialog); M.gallery(next_offset,true) end)
        elseif M.more then
            nav[#nav+1]=button("More Results",function() close(dialog); M.search(M.provider_page+1) end)
        end
        if #nav > 0 then buttons[#buttons+1]=nav end
        if M.provider ~= "openlibrary" and app.settings:get("openlibrary_enabled") then
            buttons[#buttons+1]={button("Search Open Library",function() close(dialog);M.provider="openlibrary";M.search(1) end)}
        elseif M.provider == "openlibrary" then
            buttons[#buttons+1]={button("Search Amazon Kindle",function() close(dialog);M.provider="amazon";M.search(1) end)}
        end
        buttons[#buttons+1]={button("Edit Search",function() close(dialog); M.editSearch() end),button("Back",function() close(dialog); M.main() end)}
        local warning=M.warnings and M.warnings[1]
        local widgets={}
        local cover_ok,cover=pcall(function()
            return require("apps/filemanager/filemanagerbookinfo"):getCoverImage(app.host.ui.document,M.book.file)
        end)
        if cover_ok and cover then
            local cw,ch=cover:getWidth(),cover:getHeight()
            local h=scaled(60)
            local current=HorizontalGroup:new{
                ImageWidget:new{image=cover,width=math.floor(h*cw/ch),height=h},
                text(string.format("Current cover\n%d × %d px",cw,ch),width()-scaled(140)),
            }
            current.not_focusable=true
            widgets[#widgets+1]=current
        end
        widgets[#widgets+1]=grid
        dialog=ButtonDialog:new{title="Cover Results · " .. (M.active_source or "Amazon Kindle") .. "\n" .. M.query.title .. (warning and "\n" .. warning or ""),
            width=width(),_added_widgets=widgets,buttons=buttons}
        UIManager:show(dialog)
    end
    function M.candidate(candidate)
        M.run("Downloading original cover…",function()
            return app.images.fetch(candidate.url,app.settings.temp_dir .. "/preview")
        end,function(image)
            M.preview(image,candidate.source .. "\n" .. candidate.title .. "\n" .. candidate.author
                .. "\n" .. (candidate.match_label or (candidate.exact and "Exact ISBN edition" or "Alternative edition"))
                .. "\n" .. (candidate.edition or "") .. " · " .. (candidate.publisher or "") .. " · " .. (candidate.year or ""),
                function() M.gallery(M.offset,false) end,true)
        end,true)
    end
    function M.preview(image,source,back,temporary)
        local dialog
        local function cleanup() if temporary then os.remove(image.path) end end
        local h=math.floor(Screen:getHeight()*0.38)
        local w=math.min(width()-60,math.floor(h*image.width/image.height))
        local imagewidget=ImageWidget:new{file=image.path,width=w,height=math.floor(w*image.height/image.width)}
        dialog=ButtonDialog:new{title="Cover Preview\n" .. app.images.describe(image) .. "\n" .. source,width=width(),
            _added_widgets={centered(imagewidget,width()-60,imagewidget.height)},
            tap_close_callback=function() cleanup(); back() end,
            buttons={
                {button("Full-screen Preview",function()
                    UIManager:show(require("ui/widget/imageviewer"):new{file=image.path,fullscreen=true,with_title_bar=true,
                        title=app.images.describe(image),buttons_visible=true})
                end)},
                {button("Apply Cover",function()
                    UIManager:show(ConfirmBox:new{text="Replace this book’s cover in KOReader? The ebook stays unchanged. Any current custom cover will be preserved.",
                        ok_text="Apply Cover",ok_callback=function()
                            local ok,err=app.covers.apply(M.book.file,image.path)
                            if not ok then M.message(err); return end
                            close(dialog); cleanup(); M.main()
                        end})
                end)},
                {button("Back",function() close(dialog); cleanup(); back() end)},
            }}
        UIManager:show(dialog)
    end
    function M.localImage()
        UIManager:show(require("ui/widget/pathchooser"):new{select_directory=false,file_filter=function(path)
            return path:lower():match("%.jpe?g$") or path:lower():match("%.png$")
        end,onConfirm=function(path)
            M.run("Validating image…",function() return app.images.validate(path) end,function(image)
                M.preview(image,"Local image",M.main,false)
            end,false)
        end})
    end
    function M.url()
        local dialog
        dialog=require("ui/widget/inputdialog"):new{title="HTTPS image URL",input="",input_hint="https://…",buttons={{
            button("Cancel",function() close(dialog); M.main() end),
            button("Download",function()
                local parsed,err=app.network.parse(dialog:getInputText())
                if not parsed then M.message(err); return end
                close(dialog)
                M.run("Downloading image…",function() return app.images.fetch(parsed.url,app.settings.temp_dir .. "/import") end,function(image)
                    M.preview(image,"Direct URL: " .. parsed.host,M.main,true)
                end,true)
            end),
        }}}
        UIManager:show(dialog); dialog:onShowKeyboard()
    end
    function M.restore(original)
        UIManager:show(ConfirmBox:new{text=original and "Use the cover embedded in the book? The active custom cover will be preserved."
            or "Restore the previous custom cover?",ok_text="Restore",cancel_callback=M.main,ok_callback=function()
            local ok,err
            if original then ok,err=app.covers.original(M.book.file) else ok,err=app.covers.restorePrevious(M.book.file) end
            if not ok then M.message(err) end
            M.main()
        end})
    end
    function M.settings()
        local dialog
        dialog=ButtonDialog:new{title="CoverLab Sources\nPrimary: Amazon Kindle",buttons={
            {button("Open Library fallback: " .. (app.settings:get("openlibrary_enabled") and "On" or "Off"),function()
                app.settings:set("openlibrary_enabled",not app.settings:get("openlibrary_enabled"))
                close(dialog);M.settings()
            end)},
            {button("Download and Cache Settings",function()close(dialog);M.preferences()end)},
            {button("Back",function()close(dialog);M.main()end)},
        }}
        UIManager:show(dialog)
    end
    function M.preferences()
        local dialog
        dialog=require("ui/widget/multiinputdialog"):new{title="CoverLab Settings",fields={
            {text=app.settings:get("contact"),description="Open Library contact email (optional)"},
            {text=tostring(app.settings:get("max_download")/1024/1024),description="Maximum image download (MB, 1–20)",input_type="number"},
            {text=tostring(app.settings:get("cache_lifetime")/86400),description="Cache lifetime (days, 1–30)",input_type="number"},
        },buttons={{button("Cancel",function() close(dialog); M.main() end),button("Save",function()
            local fields=dialog:getFields()
            local mb,days=tonumber(fields[2]),tonumber(fields[3])
            if not mb or mb<1 or mb>20 or not days or days<1 or days>30 then M.message("Use 1–20 MB and 1–30 cache days."); return end
            app.settings:set("contact",fields[1]); app.settings:set("max_download",math.floor(mb*1024*1024)); app.settings:set("cache_lifetime",math.floor(days*86400))
            close(dialog); M.main()
        end)}}}
        UIManager:show(dialog); dialog:onShowKeyboard()
    end
    return M
end
