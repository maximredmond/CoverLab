-- The ebook and DocSettings metadata.lua are never opened for writing.
-- A persistent journal allows the next open to roll back interrupted writes.
return function(app)
    local DocSettings = require("docsettings")
    local lfs = require("libs/libkoreader-lfs")
    local util = require("util")
    local json = require("json")
    local M = {}
    local serial = 0
    local function locations(file)
        local dirs, seen = {}, {}
        for _, location in ipairs{"doc", "dir", "hash"} do
            local path = DocSettings:getSidecarDir(file,location)
            if path and path ~= "" and not seen[path] then dirs[#dirs+1]=path; seen[path]=true end
        end
        return dirs
    end
    local function customFiles(file)
        local files = {}
        for _, dir in ipairs(locations(file)) do
            local ok, iter, obj = pcall(lfs.dir,dir)
            if ok then
                for name in iter,obj do
                    if name:match("^cover%.[^.]+$") and lfs.attributes(dir .. "/" .. name,"mode") == "file" then
                        files[#files+1]=dir .. "/" .. name
                    end
                end
            end
        end
        return files
    end
    local function storage(file)
        local current = DocSettings:findCustomCoverFile(file)
        local candidates = current and {app.fs.dirname(current)} or DocSettings:getCustomLocationCandidates(file)
        for _, dir in ipairs(candidates) do
            local path = dir .. "/coverlab"
            local ok = pcall(util.makePath,path)
            if ok and app.fs.write(path .. "/.write-check", "CoverLab") then
                os.remove(path .. "/.write-check")
                return path, dir, current
            end
        end
        return nil, "Cover storage is read-only or full. Check permissions and free space."
    end
    local function decode(path)
        local ok, value = pcall(json.decode, app.fs.read(path) or "")
        if ok and type(value) == "table" then return value end
    end
    local function notify(file)
        local ui = app.host.ui
        if ui.doc_settings and ui.document and ui.document.file == file then ui.doc_settings:getCustomCoverFile(true) end
        local UIManager = require("ui/uimanager")
        local Event = require("ui/event")
        UIManager:broadcastEvent(Event:new("InvalidateMetadataCache",file))
        UIManager:broadcastEvent(Event:new("BookMetadataChanged"))
        UIManager:setDirty("all","full")
    end
    local function rollback(journal, dir)
        -- Version 2 journals keep each original beside its destination. Moving
        -- it back does not allocate another image, even when storage is full.
        -- Retain the verified backups until journal removal succeeds, so this
        -- operation can be retried after any interrupted or failed rollback.
        for _, old in ipairs(journal.originals) do
            local data=app.fs.read(old.backup)
            if not data then return nil, "Recovery backup is missing: " .. old.backup end
            if old.rollback then
                local saved=app.fs.read(old.rollback)
                if saved and saved ~= data or not saved and app.fs.read(old.path) ~= data then
                    return nil,"Recovery original is missing or damaged; backups retained in " .. dir
                end
            end
        end
        local target_was_original = false
        for _, old in ipairs(journal.originals) do
            local ok,err=true,nil
            if old.rollback then
                if lfs.attributes(old.rollback,"mode") == "file" then ok,err=os.rename(old.rollback,old.path) end
            elseif app.fs.read(old.path) ~= app.fs.read(old.backup) then
                -- Compatibility with journals written before allocation-free rollback.
                ok,err=app.fs.copy(old.backup,old.path)
            end
            if not ok then return nil, "Recovery failed; backups retained in " .. dir .. ": " .. tostring(err) end
            if old.path == journal.target then target_was_original = true end
        end
        if not target_was_original and journal.target and lfs.attributes(journal.target) then
            local ok, err = os.remove(journal.target)
            if not ok then return nil, err end
        end
        if journal.previous_raw then
            local ok,err=true,nil
            if journal.previous_restore then
                if lfs.attributes(journal.previous_restore,"mode") == "file" then
                    ok,err=os.rename(journal.previous_restore,dir .. "/previous.json")
                elseif app.fs.read(dir .. "/previous.json") ~= journal.previous_raw then
                    return nil,"Previous-cover recovery record is missing; backups retained in " .. dir
                end
            else
                ok,err=app.fs.atomic(dir .. "/previous.json",journal.previous_raw)
            end
            if not ok then return nil, err end
        elseif lfs.attributes(dir .. "/previous.json") then
            local ok,err=os.remove(dir .. "/previous.json")
            if not ok then return nil,err end
        end
        local ok,err=os.remove(dir .. "/transaction.json")
        if not ok then return nil,"Cannot finish recovery; backups retained in " .. dir .. ": " .. tostring(err) end
        os.remove(dir .. "/incoming.part")
        if journal.previous_next then os.remove(journal.previous_next) end
        for _, old in ipairs(journal.originals) do os.remove(old.backup) end
        return true
    end
    function M.recover(file)
        for _, parent in ipairs(locations(file)) do
            local dir = parent .. "/coverlab"
            local path = dir .. "/transaction.json"
            if lfs.attributes(path,"mode") == "file" then
                local journal = decode(path)
                if not journal or journal.file ~= file or type(journal.originals) ~= "table" then
                    return nil, "Cover recovery journal is unreadable. Backups are in " .. dir
                end
                local ok, err = rollback(journal,dir)
                if not ok then return nil, err end
                notify(file)
            end
        end
        return true
    end
    function M.previous(file)
        local newest
        for _, dir in ipairs(locations(file)) do
            local record = decode(dir .. "/coverlab/previous.json")
            if record and record.file == file and record.path and lfs.attributes(record.path,"mode") == "file"
                and (not newest or (record.time or 0) > (newest.time or 0)) then newest=record end
        end
        return newest
    end
    local function transaction(file, image, original, trusted)
        local ok, err = M.recover(file)
        if not ok then return nil, err end
        local validated
        if image and not trusted then
            local valid; valid, err = app.images.validate(image)
            if not valid then return nil, err end
            validated=valid
        end
        local dir, parent, active = storage(file)
        if not dir then return nil, parent end
        local originals, active_backup = {}, nil
        serial = serial + 1
        local token = tostring(os.time()) .. "-" .. serial
        local function discardPrepared()
            os.remove(dir .. "/incoming.part")
            for _,old in ipairs(originals) do os.remove(old.backup) end
        end
        for i, path in ipairs(customFiles(file)) do
            local extension = path:match("%.([^.]+)$")
            local backup = dir .. "/backup-" .. token .. "-" .. i .. "." .. extension
            ok, err = app.fs.copy(path,backup)
            if not ok then
                for _, old in ipairs(originals) do os.remove(old.backup) end
                os.remove(backup)
                return nil, "Could not back up existing cover. " .. tostring(err)
            end
            local restore=app.fs.dirname(path) .. "/.coverlab-restore-" .. token .. "-" .. i .. "." .. extension
            if lfs.attributes(restore) then
                discardPrepared();os.remove(backup)
                return nil,"A previous recovery file already exists: " .. restore
            end
            originals[#originals+1] = {path=path,backup=backup,rollback=restore}
            if path == active then active_backup = backup end
        end
        local target
        if image then
            local extension = validated and validated.format or image:match("%.([%w]+)$")
            if not extension then discardPrepared();return nil, "Image has no supported file suffix." end
            target = parent .. "/cover." .. extension:lower()
            ok, err = app.fs.copy(image, dir .. "/incoming.part")
            if not ok then
                for _, old in ipairs(originals) do os.remove(old.backup) end
                return nil, "Not enough space to stage cover: " .. tostring(err)
            end
        end
        local journal = {version=2,file=file,originals=originals,target=target,
            previous_raw=app.fs.read(dir .. "/previous.json")}
        -- Preallocate both metadata records before changing any active cover.
        if journal.previous_raw then
            journal.previous_restore=dir .. "/previous-restore-" .. token .. ".json"
            ok,err=app.fs.copy(dir .. "/previous.json",journal.previous_restore)
            if not ok then
                discardPrepared();os.remove(journal.previous_restore)
                return nil,"Cannot stage previous-cover recovery: " .. tostring(err)
            end
        end
        if active_backup then
            journal.previous_next=dir .. "/previous-next-" .. token .. ".json"
            ok,err=app.fs.atomic(journal.previous_next,json.encode{file=file,path=active_backup,time=os.time()})
            if not ok then
                discardPrepared()
                if journal.previous_restore then os.remove(journal.previous_restore) end
                return nil,"Cannot stage previous-cover record: " .. tostring(err)
            end
        end
        ok, err = app.fs.atomic(dir .. "/transaction.json",json.encode(journal))
        if not ok then
            discardPrepared()
            if journal.previous_restore then os.remove(journal.previous_restore) end
            if journal.previous_next then os.remove(journal.previous_next) end
            return nil, "Cannot write recovery journal: " .. tostring(err)
        end
        local function fail(why)
            local restored, restore_err = rollback(journal,dir)
            notify(file)
            return nil, restored and why or (tostring(why) .. "\n" .. tostring(restore_err))
        end
        for _, old in ipairs(originals) do
            ok, err = os.rename(old.path,old.rollback)
            if not ok then return fail("Cannot replace cover: " .. tostring(err)) end
        end
        if image then
            ok, err = os.rename(dir .. "/incoming.part",target)
            if not ok then return fail("Cannot install cover: " .. tostring(err)) end
            if app.fs.read(target) ~= app.fs.read(image) or DocSettings:findCustomCoverFile(file) ~= target then
                return fail("KOReader could not verify the installed cover.")
            end
            if not trusted and not app.images.validate(target) then return fail("Installed image failed validation.") end
        elseif DocSettings:findCustomCoverFile(file) then
            return fail("Another custom cover is still active.")
        end
        if active_backup then
            ok, err = os.rename(journal.previous_next,dir .. "/previous.json")
            if not ok then return fail("Cannot preserve previous-cover record: " .. tostring(err)) end
        end
        -- Removing the journal commits the transaction. On failure, keep it recoverable.
        ok, err = os.remove(dir .. "/transaction.json")
        if not ok then return fail("Cannot commit cover change: " .. tostring(err)) end
        local old_previous
        if journal.previous_raw then local parsed, value = pcall(json.decode,journal.previous_raw); if parsed then old_previous=value end end
        if active_backup and old_previous and old_previous.path ~= active_backup then os.remove(old_previous.path) end
        for _, old in ipairs(originals) do
            os.remove(old.rollback)
            if old.backup ~= active_backup then os.remove(old.backup) end
        end
        if journal.previous_restore then os.remove(journal.previous_restore) end
        notify(file)
        return true
    end
    function M.apply(file,image) return transaction(file,image,false,false) end
    function M.restorePrevious(file)
        local previous = M.previous(file)
        if not previous then return nil, "No previous custom cover is available." end
        return transaction(file,previous.path,false,true)
    end
    function M.original(file) return transaction(file,nil,true,false) end
    return M
end
