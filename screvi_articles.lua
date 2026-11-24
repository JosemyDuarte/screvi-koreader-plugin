local DocSettings = require("docsettings")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")
local T = require("ffi/util").template
local _ = require("gettext")
local Epub = require("screvi_epub")
local Articles = {}
Articles.API_URL = "https://api.screvi.com/api/v1"

-- These live in the shared plugin state so every plugin instance sees the same values.
local SHARED_FIELDS = { tag = true, folder = true, running = true }

local function isDeleted(article)
    return type(article) == "table"
        and (article.deleted == true or type(article.deleted_at) == "string" and article.deleted_at ~= "")
end

--- The result of every request that finds the article deleted.
local function gone()
    return nil, _("Article no longer on Screvi (kept on device)."), "gone"
end

--- Create the article controller, sharing settings, HTTP and highlight bookkeeping.
function Articles.new(plugin)
    local state = plugin.state
    local self = setmetatable({ plugin = plugin, tracked = state.tracked }, {
        __index = function(_, key)
            if SHARED_FIELDS[key] then return state[key] end
            return Articles[key]
        end,
        __newindex = function(t, key, value)
            if SHARED_FIELDS[key] then
                state[key] = value
            else
                rawset(t, key, value)
            end
        end,
    })
    self.tag = state.tag or plugin.settings:readSetting("download_tag", "koreader")
    -- Only flush when something changed: this runs on every ReaderUI and FileManager start.
    local changed = false
    for _, item in pairs(self.tracked) do
        if item.pending_file then
            if not lfs.attributes(item.file) and lfs.attributes(item.pending_file, "mode") == "file" then
                os.rename(item.pending_file, item.file)
            end
            if lfs.attributes(item.file, "mode") == "file" then
                os.remove(item.pending_file)
                item.pending_file = nil
                changed = true
            end
        end
    end
    local home = G_reader_settings and G_reader_settings:readSetting("home_dir")
    if not home then
        local ok, util = pcall(require, "apps/filemanager/filemanagerutil")
        home = ok and util.getDefaultDir and util.getDefaultDir() or "."
    end
    self.folder = state.folder or plugin.settings:readSetting("download_folder", home .. "/Screvi")
    if changed then self:save() end
    return self
end

--- Persist ownership only for files that this plugin successfully created.
function Articles:save()
    self.plugin.settings:saveSetting("articles", self.tracked)
    self.plugin.settings:saveSetting("gone_articles", self.plugin.state.gone)
    self.plugin.settings:flush()
end

--- Match tracked paths, with a full stable filename ID as a routing fallback.
function Articles.identify(tracked, file)
    if type(file) ~= "string" then return nil end
    for id, item in pairs(tracked) do if item.file == file then return tostring(id) end end
    return file:match("%[screvi%-([%w%-]+)%]%.epub$")
end

--- Share the authenticated JSON transport, and translate public API errors.
--- When `gone_id` is given, a 404 forgets that article.
function Articles:request(method, path, body, operation, gone_id)
    local code, result = self.plugin:requestJson(method, Articles.API_URL .. path, body, true, operation)
    if code == 404 or result.code == "not_found" or result.error == "not_found" then
        if gone_id then self:forgetGone(gone_id) end
        return gone()
    end
    if code and code >= 200 and code < 300 then return result end
    logger.warn("Screvi: article API failed", method, path, code, result.message or result.error)
    if code == 403 and result.code ~= "subscription_required" then
        if method == "GET" then
            return nil, _("This device's key can't read articles. Reconnect with Connect to Screvi, or paste a key with read access from app.screvi.com → Settings → API.")
        end
        return nil, _("This device's key can't write article highlights or archive articles. Reconnect with Connect to Screvi, or paste a key with read and write access from app.screvi.com → Settings → API.")
    end
    return nil, self.plugin:httpError(code, result)
end

--- Fetch an article's highlights, forgetting it when Screvi no longer has it.
function Articles:fetchRemote(id, operation)
    local remote, err, state = self:request("GET", "/articles/" .. id .. "?format=text&max_chars=1000", nil, operation, id)
    if not remote then return nil, err, state end
    if isDeleted(remote.data) then
        self:forgetGone(id)
        return gone()
    end
    return remote
end

--- Fetch all pages before allowing any local reconciliation.
function Articles:list(operation)
    local all, page = {}, 1
    local tag = self.tag:gsub("([^%w%-_%.~])", function(c) return string.format("%%%02X", c:byte()) end)
    repeat
        local result, err = self:request("GET", "/articles?tag=" .. tag .. "&include_deleted=true&per_page=100&page=" .. page, nil, operation)
        if not result then return nil, err end
        if type(result.data) ~= "table" or type(result.pagination) ~= "table"
            or type(result.pagination.has_more) ~= "boolean" then
            return nil, _("Screvi returned an invalid article list. Try again.")
        end
        for _, article in ipairs(result.data) do
            if type(article) ~= "table" or type(article.id) ~= "string" or not article.id:match("^[%w%-]+$") then
                return nil, _("Screvi returned an invalid article list. Try again.")
            end
            all[#all + 1] = article
        end
        if not result.pagination.has_more then break end
        if #result.data == 0 then return nil, _("Screvi returned an incomplete article list. Try again.") end
        page = page + 1
    until false
    local changed = false
    for _, article in ipairs(all) do
        if not isDeleted(article) then
            local id = tostring(article.id)
            if self.plugin.state.gone[id] then self.plugin.state.gone[id] = nil; changed = true end
            if self.tracked[id] and self.tracked[id].tag ~= self.tag then
                self.tracked[id].tag = self.tag; changed = true
            end
        end
    end
    if changed then self:save() end
    return all
end

--- Assume JavaScript string offsets: UTF-16 units, not bytes or code points.
-- The OpenAPI calls these "characters" without specifying the encoding.
local function characters(s)
    local _, count = s:gsub("[^\128-\191]", "")
    local _, astral = s:gsub("[\240-\244]", "")
    return count + astral
end

-- Bound individual responses while paging longer articles.
--- Join every HTML slice; content_length is the total length, not this slice's length.
function Articles:content(id, operation)
    local chunks, article, offset = {}, nil, 0
    repeat
        local result, err, state = self:request("GET", "/articles/" .. id .. "?format=html&max_chars=1000000&offset=" .. offset, nil, operation)
        if not result then
            -- A just-listed article may temporarily have no readable body.
            -- Keep retrying rather than persisting a deletion from this fetch.
            return nil, state == "gone" and _("Couldn't fetch the article content. Try again.") or err
        end
        local part = result.data
        if isDeleted(part) then
            self:forgetGone(id)
            return gone()
        end
        if type(part) ~= "table" then return nil, _("Screvi returned invalid article content.") end
        if part.parse_state ~= "parsed" or type(part.content) ~= "string" then return nil, nil, "not_ready" end
        if part.content_offset ~= nil and tonumber(part.content_offset) ~= offset then
            return nil, _("Screvi returned incomplete article content.")
        end
        article = article or part
        chunks[#chunks + 1] = part.content
        local next_offset = (tonumber(part.content_offset) or offset) + characters(part.content)
        if not part.content_truncated then break end
        if next_offset <= offset then return nil, _("Screvi returned incomplete article content.") end
        offset = next_offset
    until false
    article.content = table.concat(chunks)
    return article
end

--- Keep the EPUB and sidecar, and remember the ID so filename routing never retries it.
function Articles:forgetGone(id)
    id = tostring(id)
    self.plugin.state.gone[id] = true
    self.tracked[id] = nil
    self:save()
end

local function normalized(text)
    return (text or ""):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
end

-- Truncate by Unicode code points, leaving room for the final ellipsis.
local function noteForApi(note)
    if not note then return nil end
    local count, cutoff = 0, nil
    for pos in note:gmatch("()[^\128-\191]") do
        count = count + 1
        if count == 20000 then cutoff = pos end
        if count > 20000 then return note:sub(1, cutoff - 1) .. "…" end
    end
    return note
end

local function highlightKey(h)
    return normalized(h.content) .. "\0" .. normalized(h.note)
end

local function locationForApi(value)
    local n = tonumber(value)
    if not n or n ~= n or n == math.huge or n == -math.huge then return nil end
    return math.max(0, math.floor(n))
end

--- Send at most 100 highlights per transaction; preserve each distinct note.
function Articles:upload(source, operation)
    local owns_operation = operation == nil
    operation = operation or {}
    local added = 0
    local function done(ok, err, state)
        if owns_operation then self.plugin:flushSynced(operation) end
        return ok, err, state, added
    end
    local id = tostring(source.article_id)
    if self.plugin.state.gone[id] then return done(gone()) end
    local remote, err, state = self:fetchRemote(id, operation)
    if not remote then return done(nil, err, state) end
    if not remote.data or type(remote.data.highlights) ~= "table" then
        return done(nil, _("Screvi returned invalid article highlights."))
    end
    local existing, pending, originals, matched = {}, {}, {}, {}
    for _, h in ipairs(remote.data.highlights) do
        existing[highlightKey(h)] = true
    end
    local function mark(highlights)
        if #highlights == 0 then return end
        local batch = {}
        for k, v in pairs(source) do batch[k] = v end
        batch.highlights = highlights
        self.plugin:markSynced({ batch }, operation)
    end
    for _, h in ipairs(source.highlights) do
        local key = highlightKey(h)
        if existing[key] then
            matched[#matched + 1] = h
        else
            if not originals[key] then
                pending[#pending + 1] = key
                originals[key] = {}
            end
            originals[key][#originals[key] + 1] = h
        end
    end
    mark(matched)
    for first = 1, #pending, 100 do
        local highlights, original = {}, {}
        for i = first, math.min(first + 99, #pending) do
            local key = pending[i]
            local h = originals[key][1]
            highlights[#highlights + 1] = {
                article_id = source.article_id, content = h.content, note = noteForApi(h.note),
                location = locationForApi(h.location), date = h.date, metadata = h.metadata,
            }
            for _, h2 in ipairs(originals[key]) do original[#original + 1] = h2 end
        end
        local result, why, status = self:request("POST", "/highlights/bulk", { highlights = highlights }, operation, id)
        if not result then return done(nil, why, status) end
        added = added + #highlights
        mark(original)
    end
    return done(true)
end

--- Read even missing book files' sidecars, so unsent highlights never get discarded.
function Articles:book(id, item, snapshot)
    if snapshot and snapshot.file == item.file then return snapshot end
    local p = self.plugin
    if p.ui.document and p.ui.document.file == item.file then return p:getCurrentBook() end
    return p.getBookFromSidecar(item.file)
end

--- Sync before archiving or removing anything; a sidecar read failure preserves the file.
function Articles:syncBeforeRemoval(id, item, snapshot, operation)
    local book = self:book(id, item, snapshot)
    if not book then return nil, _("Couldn't read the article highlights.") end
    local pending = self.plugin:pendingSources({ book })
    for _, source in ipairs(pending) do
        local ok, err, state = self:upload(source, operation)
        if not ok then return nil, err, state end
    end
    if self:hasUnsent(book) then return nil, _("Some article highlights are still unsynced.") end
    return true
end

function Articles:hasUnsent(book)
    for _, h in ipairs(book.highlights) do
        if not self.plugin.synced_hashes[self.plugin.highlightHash(book, h)] then return true end
    end
    return false
end

--- Open metadata before unlinking, so KOReader can resolve hashed sidecars.
function Articles:remove(id, snapshot)
    local item = self.tracked[id]
    if not item then return true end
    local file = item.file
    local closed_file = snapshot and snapshot.file
    if self.plugin.ui.document and self.plugin.ui.document.file == file and closed_file ~= file then return false end
    local book = self:book(id, item, snapshot)
    if not book or self:hasUnsent(book) then return false, _("Some article highlights are still unsynced.") end
    local settings = DocSettings:open(file)
    local mode = lfs.attributes(file, "mode")
    if mode ~= nil and mode ~= "file" then return false end
    -- Collection removal resolves realpath, so it must precede unlinking.
    local ok, collection = pcall(require, "readcollection")
    if ok and collection.removeItem then collection:removeItem(file) end
    local history
    ok, history = pcall(require, "readhistory")
    if ok and history.removeItemByPath then history:removeItemByPath(file) end
    -- Keep the sidecar when unlinking fails. Once unlinked, purge through the open settings.
    if mode == "file" then
        local removed, err = os.remove(file)
        if not removed then
            logger.warn("Screvi: cannot remove article", file, err)
            return false, _("Couldn't remove the local article file.")
        end
    end
    if settings.purge then settings:purge() end
    self.tracked[id] = nil
    self:save()
    return true
end

--- Only the explicit KOReader complete status archives an article.
function Articles:isFinished(item, snapshot)
    if snapshot and snapshot.file == item.file then return snapshot.complete end
    local settings = self.plugin.ui.document and self.plugin.ui.document.file == item.file and self.plugin.ui.doc_settings
        or DocSettings:open(item.file)
    local summary = settings and settings:readSetting("summary")
    return summary and summary.status == "complete"
end

--- Archive after syncing, then remove. Never delete an open document during a download run.
function Articles:finish(id, snapshot, operation)
    local item = self.tracked[id]
    local ok, err, state = self:syncBeforeRemoval(id, item, snapshot, operation)
    if not ok then return nil, err, state end
    local result
    result, err, state = self:request("PATCH", "/articles/" .. id, { home_status = "archive" }, operation, id)
    if not result then return nil, err, state end
    local removed, remove_error = self:remove(id, snapshot)
    if not removed and remove_error then return nil, remove_error end
    return true
end

--- Stable IDs avoid title collisions and allow routing even if tracking was lost.
function Articles:filename(article)
    local title = article.title or _("Untitled article")
    title = util.getSafeFilename(title, self.folder, 170, 0)
    title = title:gsub("[%z\1-\31/\\:*?\"<>|]", "_")
    if #title > 170 then
        local limit = 171
        while title:byte(limit) and title:byte(limit) >= 128 and title:byte(limit) < 192 do limit = limit - 1 end
        title = title:sub(1, limit - 1)
    end
    local id = tostring(article.id):gsub("[^%w%-]", "")
    return self.folder .. "/" .. title .. " [screvi-" .. id .. "].epub"
end

local function unavailable(a)
    return isDeleted(a) or a.home_status == "archive" or a.status == "archived"
end

--- Download and reconcile one complete tagged snapshot, isolating each article's failures.
function Articles:runBody(counts)
    local list, err = self:list(counts)
    if not list then
        UIManager:show(InfoMessage:new{ text = err })
        return nil, err
    end
    local by_id, finished = {}, {}
    for _, article in ipairs(list) do by_id[tostring(article.id)] = article end
    local errors, seen_errors = {}, {}
    local function attempt(fn)
        local ok, result, why, state = pcall(fn)
        if state == "gone" then counts.gone = counts.gone + 1; return end
        if not ok or not result then
            counts.failed = counts.failed + 1
            local message = ok and why or _("Couldn't process an article. Try again.")
            if message and not seen_errors[message] then
                errors[#errors + 1] = message; seen_errors[message] = true
            end
            logger.warn("Screvi: article failed", ok and why or result)
        end
    end
    local progress
    local function showProgress(text)
        if progress then UIManager:close(progress) end
        progress = InfoMessage:new{ text = text }
        UIManager:show(progress)
        UIManager:forceRePaint()
    end
    local function notReady(id)
        counts.not_ready = counts.not_ready + 1
        logger.dbg("Screvi: article not ready", id)
        return true
    end
    local index, total = 0, 0
    for _ in pairs(self.tracked) do total = total + 1 end
    for id, item in pairs(self.tracked) do
        if counts.rate_limited then break end
        index = index + 1
        showProgress(T(_("Syncing article %1 of %2…"), index, total))
        attempt(function()
            local remote = by_id[tostring(id)]
            if isDeleted(remote) then
                self:forgetGone(id)
                counts.gone = counts.gone + 1
                return true
            end
            if self:isFinished(item) and not (remote and unavailable(remote)) then
                local ok, why, state = self:finish(id, nil, counts)
                if not ok then return nil, why, state end
                finished[tostring(id)] = true
                counts.archived = counts.archived + 1
            elseif (not remote and item.tag == self.tag) or (remote and unavailable(remote)) then
                -- Even without pending highlights, distinguish deletion from an untagged article.
                local check, why, state = self:fetchRemote(id, counts)
                if not check then return nil, why, state end
                local ok
                ok, why, state = self:syncBeforeRemoval(id, item, nil, counts)
                if not ok then return nil, why, state end
                local removed, remove_error = self:remove(id)
                if removed then counts.removed = counts.removed + 1
                elseif remove_error then return nil, remove_error end
            end
            return true
        end)
        coroutine.yield() -- Reconciliation also performs network requests per item.
    end
    for i, article in ipairs(list) do
        if counts.rate_limited then break end
        showProgress(T(_("Downloading %1 of %2…"), i, #list))
        attempt(function()
            local id = tostring(article.id)
            if self.plugin.state.gone[id] or unavailable(article) or finished[id] then return true end
            if article.parse_state ~= "parsed" then return notReady(id) end
            local old_item
            if self.tracked[id] then
                if lfs.attributes(self.tracked[id].file, "mode") == "file" then return true end
                -- Sync any surviving sidecar before replacing a missing owned file.
                local ok, why, state = self:syncBeforeRemoval(id, self.tracked[id], nil, counts)
                if not ok then return nil, why, state end
                old_item = self.tracked[id]
            end
            local file = self:filename(article)
            if lfs.attributes(file) then return true end
            local full, why, state = self:content(id, counts)
            if state == "not_ready" then return notReady(id) end
            if not full then return nil, why, state end
            if unavailable(full) then return true end
            full.id = id
            for k, v in pairs(article) do if full[k] == nil then full[k] = v end end
            util.makePath(self.folder)
            local ok
            -- Flush ownership after packaging but before rename. A power loss leaves
            -- a tracked .tmp file which the next controller safely recovers.
            ok, why = Epub.build(full, file, nil, self.plugin.USER_AGENT, function(tmp)
                self.tracked[id] = { file = file, pending_file = tmp, url = full.url, title = full.title, tag = self.tag }
                self:save()
            end)
            if not ok then
                self.tracked[id] = old_item
                self:save()
                return nil, why
            end
            self.tracked[id].pending_file = nil
            self:save()
            if old_item and old_item.file ~= file then
                local settings = DocSettings:open(old_item.file)
                if settings.purge then settings:purge() end
            end
            counts.downloaded = counts.downloaded + 1
            return true
        end)
        coroutine.yield() -- Let input and the progress message repaint between articles.
    end
    if progress then UIManager:close(progress) end
    local message = T(_("Downloaded %1, archived %2, removed %3, not ready %4, failed %5."), counts.downloaded, counts.archived, counts.removed, counts.not_ready, counts.failed)
    message = message .. " " .. T(_("%1 no longer on Screvi (kept on device)."), counts.gone)
    if #errors > 0 then message = message .. "\n\n" .. table.concat(errors, "\n\n") end
    UIManager:show(InfoMessage:new{ text = message })
    return counts
end

--- Continue on UI ticks so downloads do not monopolize the event loop.
function Articles:run()
    if self.running then return self.running end
    local counts = { downloaded = 0, archived = 0, removed = 0, gone = 0, not_ready = 0, failed = 0 }
    self.running = counts
    local worker = coroutine.create(function() return self:runBody(counts) end)
    local function step()
        local ok, err = coroutine.resume(worker)
        if not ok then
            logger.warn("Screvi: download failed", err)
            UIManager:show(InfoMessage:new{ text = _("Couldn't process articles. Try again.") })
        end
        if ok and coroutine.status(worker) ~= "dead" then
            UIManager:nextTick(step)
        else
            self.plugin:flushSynced(counts)
            self.running = nil
        end
    end
    step()
    return counts
end

--- Close processing uses captured in-memory highlights, after document teardown.
function Articles:onClose(snapshot)
    if self.running then return end
    local operation = {}
    for id, item in pairs(self.tracked) do
        if operation.rate_limited then break end
        local ok, err = pcall(function()
            if self:isFinished(item, snapshot) then
                local done, why = self:finish(id, snapshot, operation)
                if not done then logger.warn("Screvi: archive on close failed", why) end
            end
        end)
        if not ok then logger.warn("Screvi: archive on close failed", err) end
    end
    self.plugin:flushSynced(operation)
end

return Articles
