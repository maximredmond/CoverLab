local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local base = debug.getinfo(1,"S").source:sub(2):match("^(.*)/") .. "/"
local CoverLab = WidgetContainer:extend{name="coverlab",is_doc_only=false}

function CoverLab:init()
    local app = {host=self,ca_bundle=base .. "data/ca-bundle.crt"}
    app.fs = dofile(base .. "fs.lua")
    app.compression=dofile(base .. "compression.lua")
    for _, name in ipairs{"settings","metadata","tls","network","cache","images","covers","search"} do
        app[name]=dofile(base .. name .. ".lua")(app)
    end
    app.sources={amazon=dofile(base .. "sources/amazon.lua")(app),openlibrary=dofile(base .. "sources/openlibrary.lua")(app)}
    app.view=dofile(base .. "ui.lua")(app)
    self.app=app
    app.images.cleanup()
    app.cache.prune()
    self.ui.menu:registerToMainMenu(self)
    -- KOReader's public extension point also covers History and Collections.
    if self.ui.addFileDialogButtons then
        self.ui:addFileDialogButtons("coverlab",function(file,is_file)
            if not is_file or not file:lower():match("%.epub$") then return end
            return {{text="CoverLab",callback=function()
                if self.ui.file_chooser and self.ui.file_chooser.file_dialog then
                    UIManager:close(self.ui.file_chooser.file_dialog)
                end
                self.app.view.open(file)
            end}}
        end)
    end
end

function CoverLab:addToMainMenu(items)
    items.coverlab={text="CoverLab",sorting_hint="tools",callback=function()
        local file=self.ui.document and self.ui.document.file
        if file then
            if not file:lower():match("%.epub$") then self.app.view.message("CoverLab v0.1 supports EPUB books."); return end
            self.app.view.open(file)
        else
            UIManager:show(require("ui/widget/pathchooser"):new{select_directory=false,
                file_filter=function(path) return path:lower():match("%.epub$") end,
                onConfirm=function(path) self.app.view.open(path) end})
        end
    end}
end

function CoverLab:onCloseWidget()
    if self.ui.removeFileDialogButtons then self.ui:removeFileDialogButtons("coverlab") end
    if self.app and not self.app.view.busy then self.app.images.cleanup() end
end
return CoverLab
