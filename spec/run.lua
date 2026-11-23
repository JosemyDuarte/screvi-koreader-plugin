-- Runs the plugin's real main.lua against stubbed KOReader modules.
-- Usage (from koreader-plugin/): luajit spec/run.lua
package.path = "./?.lua;" .. package.path

-- Use a private test directory under the sandbox's temporary root.
local temp_root = os.getenv("TMPDIR") or "/tmp"
math.randomseed(os.time())
local temp_dir = temp_root:gsub("/$", "") .. "/screvi-spec-" .. os.time() .. "-" .. math.random(1, 2147483647)
if arg[1] == "--date-regression" then temp_dir = temp_dir .. "-" .. assert(os.getenv("TZ")):gsub("/", "-") end
assert(os.execute("mkdir -p '" .. temp_dir:gsub("'", "'\\''") .. "'") == 0)
local failures, passed = 0, 0
local function check(cond, msg)
    if cond then passed = passed + 1 else failures = failures + 1; print("FAIL: " .. msg) end
end
local function eq(a, b, msg) check(a == b, msg .. " (got " .. tostring(a) .. ", want " .. tostring(b) .. ")") end

-- Minimal JSON encoder for transport assertions; decoded fixtures stand in for rapidjson.
local function encode(v)
    local t = type(v)
    if t == "nil" then return "null"
    elseif t == "boolean" or t == "number" then return tostring(v)
    elseif t == "string" then
        return '"' .. v:gsub('[%c"\\]', function(c)
            return ({ ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n' })[c] or string.format("\\u%04x", c:byte())
        end) .. '"'
    end
    if #v > 0 or next(v) == nil then
        local out = {}
        for _, x in ipairs(v) do out[#out + 1] = encode(x) end
        return "[" .. table.concat(out, ",") .. "]"
    end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys)
    local out = {}
    for _, k in ipairs(keys) do out[#out + 1] = encode(k) .. ":" .. encode(v[k]) end
    return "{" .. table.concat(out, ",") .. "}"
end

-- ---------------------------------------------------------------- stubs
local shown = {}
local settings_opens, settings_flushes = 0, 0
local settings_store = { download_with_sync = false }
local json_fixtures = {}
local events = {}
local sidecars = {}
local history = {}
local online = true
local http_log = {}
local http_responses = {}
-- Separate queue for the new preflight GETs, leaving bulk/content failure fixtures explicit.
local article_get_responses, article_checks = {}, {}

local function stub(name, value) package.preload[name] = function() return value end end
stub("datastorage", { getSettingsDir = function() return temp_dir end })
local actions = {}
stub("dispatcher", { registerAction = function(_, key, action) actions[key] = action end })
stub("docsettings", {
    hasSidecarFile = function(_, f) return sidecars[f] ~= nil end,
    open = function(_, f)
        return { readSetting = function(_, k) return (sidecars[f] or {})[k] end,
            purge = function() events[#events + 1] = "purge:" .. f; sidecars[f] = nil end }
    end,
})
local function widget(kind)
    return { new = function(_, o) o = o or {}; o.kind = kind; return o end }
end
stub("ui/widget/infomessage", widget("info"))
stub("ui/widget/inputdialog", widget("input"))
stub("ui/widget/confirmbox", widget("confirm"))
stub("luasettings", {
    open = function()
        settings_opens = settings_opens + 1
        return {
            readSetting = function(_, k, d) if settings_store[k] == nil then return d end return settings_store[k] end,
            saveSetting = function(_, k, v) settings_store[k] = v end,
            flush = function() settings_flushes = settings_flushes + 1 end,
        }
    end,
})
stub("ui/network/manager", {
    isConnected = function() return online end,
    runWhenOnline = function(_, cb) if online then cb() end end,
})
local ticks = {}
local scheduled = {}
stub("ui/uimanager", {
    show = function(_, w) table.insert(shown, w) end,
    close = function() end,
    forceRePaint = function() end,
    nextTick = function(_, f) table.insert(ticks, f) end,
    scheduleIn = function(_, secs, f) table.insert(scheduled, { secs = secs, f = f }) end,
    unschedule = function(_, f)
        for i = #scheduled, 1, -1 do if scheduled[i].f == f then table.remove(scheduled, i) end end
    end,
})
stub("ui/widget/container/widgetcontainer", { extend = function(_, o) return o end })
stub("logger", { info = function() end, warn = function() end, dbg = function() end })
stub("ffi/sha2", { md5 = function(s)
    local h1, h2 = 5381, 7
    for i = 1, #s do h1 = (h1 * 33 + s:byte(i)) % 4294967296; h2 = (h2 * 31 + s:byte(i)) % 4294967296 end
    return string.format("%016x%016x", h1, h2)
end })
stub("rapidjson", {
    encode = encode,
    decode = function(s)
        if s == '{"data":{"highlights":[]}}' then return { data = { highlights = {} } } end
        if json_fixtures[s] then return json_fixtures[s] end
        local n = s:match('"newHighlights":(%d+)')
        local out = { results = n and { newHighlights = tonumber(n) } or nil }
        -- Flat string and number fields, enough for the pairing responses.
        for k, v in s:gmatch('"([%w_]+)":"([^"]*)"') do out[k] = v end
        for k, v in s:gmatch('"([%w_]+)":(%d+)') do if out[k] == nil then out[k] = tonumber(v) end end
        return out
    end,
})
stub("ffi/util", { template = function(s, ...)
    local args = { ... }
    return (s:gsub("%%(%d)", function(i) return tostring(args[tonumber(i)]) end))
end })
stub("gettext", function(s) return s end)
stub("readhistory", { hist = history })
stub("socket", { skip = function(n, ...) return select(n + 1, ...) end })
stub("ltn12", {
    source = { string = function(s) return s end },
    sink = { table = function(t) return t end },
})
stub("socketutil", { set_timeout = function() end, reset_timeout = function() end, LARGE_BLOCK_TIMEOUT = 1, LARGE_TOTAL_TIMEOUT = 1 })
stub("socket.http", { request = function(req)
    local preflight = req.method == "GET" and req.url:match("/api/v1/articles/[%w%-]+$") or req.method == "GET" and req.url:match("/api/v1/articles/[%w%-]+%?format=text&max_chars=1000$")
    table.insert(preflight and article_checks or http_log, req)
    local r = preflight and (table.remove(article_get_responses, 1) or { 200, '{"data":{"highlights":[]}}' }) or table.remove(http_responses, 1) or { 200, '{"results":{"newHighlights":0}}' }
    if r[1] == nil then return nil, "host not found" end
    if type(req.sink) == "function" then req.sink(r[2]); req.sink(nil)
    else table.insert(req.sink, r[2]) end
    return 1, r[1], r[3] or {}, "HTTP " .. r[1]
end })

stub("libs/libkoreader-lfs", { attributes = function(path, field)
    local f = io.open(path, "rb")
    if not f then return nil end
    f:close()
    return field == "mode" and "file" or { mode = "file" }
end })
stub("util", {
    getSafeFilename = function(s) return s:gsub("[/\\:*?]", "_") end,
    makePath = function() end,
})
stub("socket.url", { absolute = function(base, ref)
    if ref:match("^%a[%w+.-]*:") then return ref end
    local origin = base:match("^(https?://[^/]+)")
    if ref:sub(1, 2) == "//" then return base:match("^(%a+):") .. ":" .. ref end
    local path = ref:sub(1, 1) == "/" and ref or (base:match("https?://[^/]+(.*)") or "/"):gsub("[^/]*$", "") .. ref
    local parts = {}
    for part in path:gmatch("[^/]+") do
        if part == ".." then table.remove(parts) elseif part ~= "." then parts[#parts + 1] = part end
    end
    return origin .. "/" .. table.concat(parts, "/")
end })
local zip_entries, zip_compressions = {}, {}
stub("ffi/archiver", { Writer = { new = function()
    return {
        open = function(_, path, format)
            eq(format, "epub", "EPUB archive format")
            local f = assert(io.open(path, "wb")); f:write("EPUB stub"); f:close()
            zip_entries, zip_compressions = {}, {}
            return true
        end,
        setZipCompression = function(_, value) zip_compressions[#zip_compressions + 1] = value end,
        addFileFromMemory = function(_, path, data) zip_entries[#zip_entries + 1] = { path = path, data = data }; return true end,
        close = function() end,
    }
end } })

-- KOReader's Provider registry and the Exporter plugin's base class.
local providers = {}
stub("provider", { register = function(_, feature, name, impl) providers[feature .. "/" .. name] = impl; return true end })
local export_requests = {}
stub("base", {
    settings_key = "exporter",
    new = function(self, o)
        o = o or {}
        o.settings = {}
        setmetatable(o, { __index = self })
        return o
    end,
    isEnabled = function(self) return self.settings.enabled and self:isReadyToExport() end,
    toggleEnabled = function(self) if self:isReadyToExport() then self.settings.enabled = not self.settings.enabled end end,
    makeJsonRequest = function(_, url, method, body, headers)
        table.insert(export_requests, { url = url, method = method, body = body, headers = headers })
        return {}
    end,
})

local Screvi = dofile("main.lua")

local function newPlugin(ui)
    local p = setmetatable({ ui = ui }, { __index = Screvi })
    ui.menu = { registerToMainMenu = function() end }
    p:init()
    return p
end

-- ---------------------------------------------------------------- fixtures
local modern = {
    doc_props = { title = "Meditations", authors = "Marcus Aurelius\nGregory Hays", identifiers = "uuid:abc\nISBN: 978-0-8129-6825-6" },
    annotations = {
        { text = "in Book Two", page = "/body/DocFragment[3]", pageno = 12, datetime = "2024-03-01 09:00:00" }, -- page bookmark
        { text = "You could leave life right now.", drawer = "lighten", page = "/body/DocFragment[4]/p[2]", pageno = 20, chapter = "Book Two", datetime = "2024-03-01 09:05:00", note = "  memento mori " },
        { text = "  ", drawer = "lighten", pageno = 21 },
        { text = "The impediment to action advances action.", drawer = "underscore", pageno = 55, datetime = "2024-03-02 10:00:00", note = "" },
    },
}
local legacy = {
    doc_props = { title = "", authors = "" },
    highlight = {
        [7] = { { text = "Old highlight with note", datetime = "2020-01-01 08:00:00", chapter = "One" } },
        [3] = { { text = "Earlier highlight", datetime = "2020-01-01 07:00:00" } },
    },
    bookmarks = {
        { highlighted = true, datetime = "2020-01-01 08:00:00", notes = "Old highlight with note", text = "my thought" },
        { highlighted = true, datetime = "2020-01-01 07:00:00", notes = "Earlier highlight", text = "Page 3 Earlier highlight @ 2020-01-01 07:00:00" },
    },
}
sidecars["/books/Meditations.epub"] = modern
sidecars["/books/Some Legacy Book.pdf"] = legacy
sidecars["/books/Empty.epub"] = { doc_props = { title = "Empty" }, annotations = {} }
history[1] = { file = "/books/Meditations.epub" }
history[2] = { file = "/books/Some Legacy Book.pdf" }
history[3] = { file = "/books/Empty.epub" }
history[4] = { file = "/books/Gone.epub", dim = true }
history[5] = { file = "/books/NeverOpened.epub" }

-- ---------------------------------------------------------------- tests
-- pure helpers
eq(Screvi.parseIsbn("uuid:1\nISBN: 978-0-8129-6825-6"), "9780812968256", "isbn parsed")
eq(Screvi.parseIsbn("calibre:9780812968256"), nil, "unlabelled number not treated as isbn")
eq(Screvi.parseIsbn("urn:isbn:080442957X"), "080442957X", "isbn-10 with X")
local iso = Screvi.toIsoDate("2024-03-01 09:05:00")
check(iso and iso:match("^2024%-0[23]%-%d%dT%d%d:05:00Z$"), "iso date " .. tostring(iso))
eq(Screvi.toIsoDate("garbage"), nil, "bad date -> nil")

-- Start fresh LuaJIT processes: the C runtime may cache the process timezone.
if arg[1] == "--date-regression" then
    local zone = assert(os.getenv("TZ"))
    local stockholm = zone == "Europe/Stockholm"
    local fixtures = {
        { "2026-11-23 19:52:35", "2026-11-23T19:52:35Z", "2026-11-23T18:52:35Z" },
        { "2026-07-23 19:52:35", "2026-07-23T19:52:35Z", "2026-07-23T17:52:35Z" },
        { "2026-01-02 00:30:00", "2026-01-02T00:30:00Z", "2026-01-01T23:30:00Z" },
        { "2026-07-02 00:30:00", "2026-07-02T00:30:00Z", "2026-07-01T22:30:00Z" },
        { "2026-03-29 01:30:00", "2026-03-29T01:30:00Z", "2026-03-29T00:30:00Z" },
        { "2026-03-29 03:30:00", "2026-03-29T03:30:00Z", "2026-03-29T01:30:00Z" },
        { "2026-10-25 01:30:00", "2026-10-25T01:30:00Z", "2026-10-24T23:30:00Z" },
        { "2026-10-25 03:30:00", "2026-10-25T03:30:00Z", "2026-10-25T02:30:00Z" },
    }
    for _, fixture in ipairs(fixtures) do
        eq(Screvi.toIsoDate(fixture[1]), fixture[stockholm and 3 or 2], zone .. " local date " .. fixture[1])
    end
    local exported = require("screvi_exporter").createSource({ title = "Dates", {
        { text = "Winter", time = 1795463555 }, { text = "Summer", time = 1784836355 },
    } })
    eq(exported.highlights[1].date, "2026-11-23T19:52:35Z", zone .. " exporter winter timestamp")
    eq(exported.highlights[2].date, "2026-07-23T19:52:35Z", zone .. " exporter summer timestamp")
    print(string.format("%d passed, %d failed", passed, failures))
    assert(os.execute("rm -rf '" .. temp_dir:gsub("'", "'\\''") .. "'") == 0)
    os.exit(failures == 0 and 0 or 1)
end
for _, zone in ipairs({ "UTC", "Europe/Stockholm" }) do
    local proc = assert(io.popen("TZ=" .. zone .. " luajit spec/run.lua --date-regression 2>&1"))
    local result = proc:read("*a")
    proc:close()
    local count, failed = result:match("(%d+) passed, (%d+) failed")
    check(count and failed == "0", zone .. " date regressions: " .. result)
    if count then passed = passed + tonumber(count); failures = failures + tonumber(failed) end
end

-- modern parsing
local book = Screvi.getBookFromSidecar("/books/Meditations.epub")
eq(book.name, "Meditations", "title")
eq(book.author, "Marcus Aurelius, Gregory Hays", "authors joined")
eq(book.isbn, "9780812968256", "isbn on source")
eq(#book.highlights, 2, "bookmark and blank highlight skipped")
eq(book.highlights[1].note, "memento mori", "note trimmed")
eq(book.highlights[1].location, "20", "location from pageno, not xpointer")
eq(book.highlights[1].metadata.chapter, "Book Two", "chapter kept")
eq(book.highlights[2].note, nil, "empty note dropped")

-- legacy parsing
local lb = Screvi.getBookFromSidecar("/books/Some Legacy Book.pdf")
eq(lb.name, "Some Legacy Book", "title from filename")
eq(lb.author, "Unknown Author", "author fallback so server doesn't drop the source")
eq(#lb.highlights, 2, "legacy highlights")
eq(lb.highlights[1].content, "Earlier highlight", "legacy sorted by page")
eq(lb.highlights[1].note, nil, "auto-text bookmark is not a note")
eq(lb.highlights[2].note, "my thought", "legacy note from bookmark")

-- batching
local big = { name = "Big", author = "A", type = "book", highlights = {} }
for i = 1, 1203 do big.highlights[i] = { content = "h" .. i } end
local batches = Screvi.batchSources({ big, { name = "Small", author = "B", highlights = { { content = "x" } } } }, 500)
eq(#batches, 3, "three batches")
eq(#batches[1][1].highlights, 500, "first batch full")
eq(#batches[3], 2, "last batch carries the rest of Big plus Small")
eq(#batches[3][1].highlights + #batches[3][2].highlights, 204, "no highlight lost")

-- sync all (file manager context: no document)
local fm = newPlugin({})
fm.api_key = ""
fm:syncAllBooks()
eq(shown[#shown].text:match("isn.t connected") ~= nil, true, "offers to connect when no key")
fm.api_key = "sk_live_test"
http_responses = { { 200, '{"results":{"newHighlights":4}}' } }
fm:syncAllBooks()
eq(#http_log, 1, "one request")
local req = http_log[1]
eq(req.headers["X-API-Key"], "sk_live_test", "api key header")
eq(req.url, "https://api.screvi.com/api/extension/import", "url")
local f = io.open(temp_dir .. "/screvi_payload.json", "w"); f:write(req.source); f:close()
check(shown[#shown].text:find("Added 4 highlights from 2 books"), "success message: " .. shown[#shown].text)
check(settings_store.last_sync ~= nil, "last sync recorded")

-- second run: nothing pending, no request
fm:syncAllBooks()
eq(#http_log, 1, "no request when everything synced")
check(shown[#shown].text:find("already synced"), "already synced message")

-- new highlight in the open book goes out on its own; auto-sync on close
modern.annotations[#modern.annotations + 1] = { text = "New one", drawer = "lighten", pageno = 80 }
local reader = newPlugin({ document = { file = "/books/Meditations.epub" }, doc_props = modern.doc_props, annotation = { annotations = modern.annotations } })
reader.api_key = "sk_live_test"
reader.auto_sync = true
online = false
reader:onCloseDocument()
eq(#ticks, 0, "offline close does nothing (no wifi prompt)")
online = true
reader:onCloseDocument()
eq(#ticks, 1, "online close schedules upload")
ticks[1]()
eq(#http_log, 2, "close uploaded")
check(http_log[2].source:find('"New one"') and not http_log[2].source:find("impediment"), "only the new highlight sent")

-- failures don't mark synced
modern.annotations[#modern.annotations + 1] = { text = "Another", drawer = "lighten", pageno = 81 }
http_responses = { { 401, '{"error":"Invalid API key"}' } }
reader:syncCurrentBook()
check(shown[#shown].text:find("rejected the API key"), "401 message")
http_responses = { { nil } }
reader:syncCurrentBook()
check(shown[#shown].text:find("Couldn't reach Screvi"), "network message: " .. shown[#shown].text)
http_responses = { { 200, '{"results":{"newHighlights":1}}' } }
reader:syncCurrentBook()
check(shown[#shown].text:find("Added 1 highlights from “Meditations”"), "retry succeeds: " .. shown[#shown].text)

-- legacy 0.1 hashes are dropped on init
Screvi.sharedState().synced_hashes.deadbeef = true
local p2 = newPlugin({})
eq(p2.synced_hashes.deadbeef, nil, "old hashes cleared")

-- ---------------------------------------------------------------- pairing
local pp = newPlugin({})
pp.api_key = ""
settings_store.api_key = nil
http_log = {}
local built
pp.buildPairingDialog = function(_, pairing, on_cancel) built = { pairing = pairing, cancel = on_cancel }; return { kind = "pairing" } end

-- syncing without a key offers to connect
pp:syncAllBooks()
eq(shown[#shown].kind, "confirm", "no key offers to connect")

http_responses = { { 201, '{"code":"BCDF-2345","poll_token":"tok","verification_url_complete":"https://app.screvi.com/pair?code=BCDF-2345","interval":5,"expires_in":600}' } }
scheduled = {}
pp:connect()
eq(built.pairing.code, "BCDF-2345", "dialog shows the code")
eq(shown[#shown].kind, "pairing", "pairing dialog shown")
check(http_log[1].url:find("/device%-pairing/start$"), "start url: " .. http_log[1].url)
check(http_log[1].source:find('"client":"koreader"'), "start sends client")
eq(#scheduled, 1, "first poll scheduled")
eq(scheduled[1].secs, 5, "polls at the server's interval")

-- pending keeps polling, a network error too
http_responses = { { 200, '{"status":"pending"}' } }
local next_poll = table.remove(scheduled, 1).f
next_poll()
eq(#scheduled, 1, "pending reschedules")
http_responses = { { nil } }
table.remove(scheduled, 1).f()
eq(#scheduled, 1, "network error reschedules")
check(http_log[#http_log].source:find('"poll_token":"tok"'), "poll sends the token")

-- approval stores the key and stops
http_responses = { { 200, '{"status":"approved","api_key":"sk_live_paired"}' } }
table.remove(scheduled, 1).f()
eq(#scheduled, 0, "stops polling once connected")
eq(pp.api_key, "sk_live_paired", "key kept in memory")
eq(settings_store.api_key, "sk_live_paired", "key saved")
check(shown[#shown].text:find("Connected to Screvi"), "connected message: " .. tostring(shown[#shown].text))

-- denied and expired end the flow without a key
for _, case in ipairs({ { '{"status":"denied"}', "declined" }, { '{"status":"expired"}', "expired" } }) do
    pp.api_key = ""
    settings_store.api_key = nil
    scheduled = {}
    http_responses = { { 201, '{"code":"BCDF-2345","poll_token":"tok","interval":5,"expires_in":600}' }, { 200, case[1] } }
    pp:connect()
    table.remove(scheduled, 1).f()
    eq(#scheduled, 0, case[2] .. " stops polling")
    check(shown[#shown].text:find(case[2]), case[2] .. " message: " .. tostring(shown[#shown].text))
    eq(pp.api_key, "", case[2] .. " leaves no key")
end

-- cancel stops polling
scheduled = {}
http_responses = { { 201, '{"code":"BCDF-2345","poll_token":"tok","interval":5,"expires_in":600}' } }
pp:connect()
built.cancel()
eq(#scheduled, 0, "cancel unschedules the poll")

-- start failures are reported
http_responses = { { 429, '{"error":"Too many pairing attempts."}' } }
pp:connect()
check(shown[#shown].text:find("Too many attempts"), "429 message")
http_responses = { { nil } }
pp:connect()
check(shown[#shown].text:find("Couldn't reach Screvi"), "offline start message")

-- ---------------------------------------------------------------- export highlights target
local target = providers["exporter/screvi"]
check(target ~= nil, "registered with the exporter at load")
eq(target.is_remote, true, "remote target")
settings_store.api_key = nil
eq(target:isReadyToExport(), false, "not ready without a key")
settings_store.api_key = "sk_live_paired"
eq(target:isReadyToExport(), true, "ready with the paired key")
target:getMenuTable().callback()
eq(target:isEnabled(), true, "menu toggles it on")

local booknotes = {
    title = "Meditations", author = "Marcus Aurelius\nGregory Hays",
    { { text = "  You could leave life right now. ", note = " memento ", page = 20, chapter = "Book Two", time = 1709283900 } },
    { { text = "", page = 21, image = { png = "x" } } },
}
export_requests = {}
eq(target:export({ booknotes, { title = "Images only", { { text = "", image = {} } } } }), true, "export succeeds")
eq(#export_requests, 1, "one request")
local req = export_requests[1]
eq(req.headers["X-API-Key"], "sk_live_paired", "uses the paired key")
check(req.url:find("/api/extension/import$"), "import url")
eq(req.body.type, "koreader", "import type")
eq(#req.body.data, 1, "image-only book skipped")
local src = req.body.data[1]
eq(src.author, "Marcus Aurelius, Gregory Hays", "authors joined")
eq(#src.highlights, 1, "image clipping skipped")
eq(src.highlights[1].content, "You could leave life right now.", "text trimmed")
eq(src.highlights[1].note, "memento", "note trimmed")
eq(src.highlights[1].location, "20", "page as location")
eq(src.highlights[1].metadata.chapter, "Book Two", "chapter kept")
eq(src.highlights[1].date, os.date("!%Y-%m-%dT%H:%M:%SZ", 1709283900), "date in UTC")

-- big exports are split into batches of at most 500 highlights
local big = {}
for b = 1, 3 do
    local chapter = {}
    for i = 1, 300 do chapter[i] = { text = "h" .. b .. "-" .. i, page = i } end
    big[b] = { title = "Book " .. b, author = "A", chapter }
end
export_requests = {}
target:export(big)
eq(#export_requests, 3, "300+300 would exceed 500, so one book per request")

settings_store.api_key = nil
eq(target:export({ booknotes }), false, "no key, no export")

-- ---------------------------------------------------------------- articles
local Articles = require("screvi_articles")
local Epub = require("screvi_epub")
local function response(code, body)
    local encoded = encode(body)
    json_fixtures[encoded] = body
    return { code, encoded }
end
-- Model a UI loop: production resumes one article per tick, tests drain it deterministically.
local real_run = Articles.run
Articles.run = function(self)
    local counts = real_run(self)
    while self.running do
        local tick = table.remove(ticks, 1)
        assert(tick, "download continuation missing")
        tick()
    end
    return counts
end
local function clear(t) for k in pairs(t) do t[k] = nil end end
local function resetArticlePlugin(ui)
    local state = Screvi.sharedState()
    clear(state.tracked); clear(state.synced_hashes); clear(state.article_hashes); clear(state.gone)
    state.tag, state.folder = nil, nil
    settings_store.articles = state.tracked
    settings_store.synced_hashes = state.synced_hashes
    article_get_responses, article_checks, ticks = {}, {}, {}
    settings_store.api_key = "sk_live_test"
    local plugin = newPlugin(ui or {})
    plugin.articles.folder = temp_dir
    http_log, events = {}, {}
    return plugin
end
local ap = resetArticlePlugin()
ap.articles.tag = "read & learn/中文"
http_responses = {
    response(200, { data = { { id = "a", parse_state = "queued" } }, pagination = { has_more = true } }),
    response(200, { data = { { id = "b", home_status = "archive" } }, pagination = { has_more = false } }),
}
local listed = ap.articles:list()
eq(#listed, 2, "all pages fetched")
check(http_log[1].url:find("tag=read%%20%%26%%20learn%%2F"), "tag percent encoded")
check(http_log[2].url:find("per_page=100&page=2", 1, true), "pagination query")
eq(http_log[1].headers["X-API-Key"], "sk_live_test", "GET authenticated")
eq(http_log[1].source, nil, "GET has no body")
http_responses = {
    response(200, { data = { { id = "a", parse_state = "queued" }, { id = "b", home_status = "archive" }, { id = "c", deleted = true }, { id = "d", parse_state = "parsed" } }, pagination = { has_more = false } }),
    response(200, { data = { id = "d", parse_state = "parsed", content = nil } }),
}
http_log = {}
local counts = ap.articles:run()
eq(counts.not_ready, 2, "unparsed and null content counted not ready")
eq(counts.failed, 0, "not ready does not fail")
eq(#http_log, 2, "archived/deleted/unparsed not fetched")

http_log = {}
http_responses = {
    response(200, { data = { id = "a", parse_state = "parsed", content = "<p>café", content_offset = 0, content_length = 21, content_truncated = true } }),
    response(200, { data = { id = "a", parse_state = "parsed", content = " and tea</p>", content_offset = 7, content_length = 21, content_truncated = false } }),
}
local content = ap.articles:content("a")
eq(content.content, "<p>café and tea</p>", "truncated HTML concatenated")
check(http_log[2].url:find("offset=7", 1, true), "offset uses returned Unicode characters, not total length or bytes")

local epub_path = temp_dir .. "/screvi-spec-epub.epub"
local image_urls = {}
local article = { id = "1234-uuid", title = "Title & words", author = "Author", url = "https://example.com/posts/article", source_domain = "example.com", saved_at = "2026-01-02", image_url = "/lead.png", content = '<p>Text &amp; more<br><img src="../img/pic.jpg"><img src="/bad.png"><img src="data:image/png;base64,xx"></p>' }
check(Epub.build(article, epub_path, function(url)
    image_urls[#image_urls + 1] = url
    if url:find("bad", 1, true) then error("network failure") end
    return "image bytes", url:find("jpg", 1, true) and "image/jpeg" or "image/png"
end), "EPUB built despite failed image")
eq(zip_entries[1].path, "mimetype", "mimetype first")
eq(zip_entries[1].data, "application/epub+zip", "mimetype content")
eq(zip_compressions[1], "store", "mimetype uncompressed")
eq(zip_compressions[2], "deflate", "other files compressed")
local zip = {}
for _, entry in ipairs(zip_entries) do zip[entry.path] = entry.data end
check(zip["META-INF/container.xml"]:find("OEBPS/content.opf", 1, true), "container points at OPF")
for _, text in ipairs({ "<dc:title>Title &amp; words</dc:title>", "<dc:creator>Author</dc:creator>", "<dc:source>https://example.com/posts/article</dc:source>", '<dc:identifier id="bookid">1234-uuid</dc:identifier>' }) do
    check(zip["OEBPS/content.opf"]:find(text, 1, true), "OPF metadata " .. text)
end
check(zip["OEBPS/content.xhtml"]:find("<p>2 Jan 2026</p>", 1, true), "human saved date in header")
check(zip["OEBPS/content.xhtml"]:find("<br/>", 1, true), "void elements closed")
check(zip["OEBPS/images/1.png"] and zip["OEBPS/images/2.jpg"], "images bundled")
eq(image_urls[1], "https://example.com/lead.png", "root relative cover URL")
eq(image_urls[2], "https://example.com/img/pic.jpg", "relative image URL")
eq(#image_urls, 3, "data URI not fetched")
check(not zip["OEBPS/content.xhtml"]:find("bad.png", 1, true), "failed image dropped")
local f = assert(io.open(temp_dir .. "/screvi-spec-content.xhtml", "w")); f:write(zip["OEBPS/content.xhtml"]); f:close()
os.remove(epub_path)

local function trackedArticle(plugin, id, status)
    local file = temp_dir .. "/spec-article [screvi-" .. id .. "].epub"
    local f = assert(io.open(file, "w")); f:write("article"); f:close()
    plugin.articles.tracked[id] = { file = file, url = "https://example.com/article", title = "An article", tag = plugin.articles.tag }
    sidecars[file] = { doc_props = { title = "An article", authors = "Writer" }, summary = { status = status }, annotations = {
        { text = "Passage", drawer = "lighten", pageno = 8, note = "Note", datetime = "2026-01-02 10:00:00" },
    } }
    plugin.articles:save()
    return file
end
ap = resetArticlePlugin()
local file = trackedArticle(ap, "article-1", "complete")
http_responses = { response(201, { data = {} }), response(200, { data = { home_status = "archive" } }) }
local real_request = ap.requestJson
ap.requestJson = function(self, method, url, ...)
    events[#events + 1] = method .. ":" .. url
    return real_request(self, method, url, ...)
end
check(ap.articles:finish("article-1"), "finished article archived")
eq(http_log[1].method, "POST", "highlights before PATCH")
check(http_log[1].url:find("/api/v1/highlights/bulk", 1, true), "bulk URL")
check(http_log[1].source:find('"article_id":"article-1"', 1, true), "bulk includes article_id")
check(http_log[1].source:find('"location":8', 1, true), "numeric bulk location")
check(http_log[1].source:find('"note":"Note"', 1, true) and http_log[1].source:find('"date":', 1, true), "note and created date included")
eq(http_log[2].method, "PATCH", "archive PATCH second")
check(http_log[2].source:find('"home_status":"archive"', 1, true), "archive body")
eq(events[4], "purge:" .. file, "sidecar deletion after PATCH")
eq(io.open(file, "rb"), nil, "local file removed")
eq(ap.articles.tracked["article-1"], nil, "tracking forgotten")

ap = resetArticlePlugin()
file = trackedArticle(ap, "article-2", "complete")
http_responses = { response(201, { data = {} }), response(500, { error = "failed" }) }
local ok = ap.articles:finish("article-2")
eq(ok, nil, "failed PATCH reported")
local f = io.open(file, "rb"); check(f ~= nil, "failed PATCH preserves file"); if f then f:close() end
check(ap.articles.tracked["article-2"] and sidecars[file], "failed PATCH preserves tracking and sidecar")
eq(#events, 0, "no purge on PATCH failure")
http_log = {}
http_responses = { response(200, { data = { home_status = "archive" } }) }
check(ap.articles:finish("article-2"), "archive retried")
eq(#http_log, 1, "synced highlight not resent on retry")

ap = resetArticlePlugin()
file = trackedArticle(ap, "article-3", "reading")
http_responses = { response(200, { data = {}, pagination = { has_more = false } }), response(403, { code = "insufficient_scope", error = "Write scope required" }) }
counts = ap.articles:run()
eq(counts.failed, 1, "unsynced removed remote article failure counted")
local f = io.open(file, "rb"); check(f ~= nil, "unsynced highlights prevent deletion"); if f then f:close() end
check(ap.articles.tracked["article-3"] ~= nil, "unsynced file still tracked")
http_responses = { response(200, { data = { { id = "page-one", parse_state = "queued" } }, pagination = { has_more = true } }), response(500, {}) }
http_log = {}
counts = ap.articles:run()
check(ap.articles.tracked["article-3"] ~= nil, "partial listing never deletes")
http_responses = { response(200, { data = {}, pagination = { has_more = false } }), response(201, { data = {} }) }
counts = ap.articles:run()
eq(counts.removed, 1, "untagged copy removed after highlights synced")

ap = resetArticlePlugin()
file = trackedArticle(ap, "article-4", "reading")
history[#history + 1] = { file = file }
ap.ui.document = { file = file }
ap.ui.doc_props = sidecars[file].doc_props
ap.ui.annotation = { annotations = sidecars[file].annotations }
http_responses = { response(201, { data = {} }) }
ap:syncCurrentBook()
eq(#http_log, 1, "current article one bulk request")
check(not http_log[1].url:find("extension/import", 1, true), "article excluded from import")
local current = ap:getCurrentBook()
eq(current.article_id, "article-4", "current document tracked identity")
local fallback = Screvi.getBookFromSidecar(file)
eq(fallback.article_id, "article-4", "history sidecar article identity")
check(ap:post({ current }) == nil, "import helper refuses articles")
export_requests = {}
settings_store.api_key = "sk_live_test"
local notes = { file = file, title = "An article", { { text = "Passage" } } }
check(target:export({ notes }), "exporter safely skips article")
eq(#export_requests, 0, "exporter article never imported")

-- Close uses unsaved in-memory highlights; completed article syncs then archives.
clear(ap.synced_hashes)
ap.ui.doc_settings = { readSetting = function() return { status = "complete" } end }
ap.auto_sync = true
http_log, ticks = {}, {}
http_responses = { response(201, { data = {} }), response(200, { data = {} }) }
ap:onCloseDocument()
eq(#ticks, 1, "article close scheduled")
ticks[1]()
eq(#http_log, 2, "close bulk then archive")
eq(ap.articles.tracked["article-4"], nil, "close removes completed article")

ap = resetArticlePlugin()
http_responses = { response(403, { code = "insufficient_scope", error = "read required" }) }
ap:downloadArticles()
check(shown[#shown].text:find("can't read articles", 1, true), "403 explains read access")
check(shown[#shown].text:find("Connect to Screvi", 1, true) and shown[#shown].text:find("Settings → API", 1, true), "403 recovery instructions")
http_responses = { response(403, { code = "subscription_required", error = "Please subscribe" }) }
ap:downloadArticles()
eq(shown[#shown].text, "Please subscribe", "subscription server message preserved")

-- Bulk batching and failure bookkeeping.
local big_article = { article_id = "bulk-article", name = "Bulk", highlights = {} }
for i = 1, 205 do big_article.highlights[i] = { content = "text " .. i } end
http_log = {}
http_responses = { response(201, {}), response(500, {}) }
check(not ap.articles:upload(big_article), "bulk failure returned")
eq(#http_log, 2, "bulk stops after failed batch")
local body = http_log[1].source
local _, n = body:gsub('"article_id":', '')
eq(n, 100, "bulk capped at 100")
check(ap.synced_hashes[Screvi.highlightHash(big_article, big_article.highlights[100])], "accepted batch marked")
check(not ap.synced_hashes[Screvi.highlightHash(big_article, big_article.highlights[101])], "failed batch unmarked")

-- Full download run, image transport, persistence, repeat runs and ownership.
ap = resetArticlePlugin()
local downloadable = { id = "download-id", title = "Spec downloadable", url = "https://example.com/post", parse_state = "parsed", home_status = "inbox" }
local download_path = ap.articles:filename(downloadable)
os.remove(download_path)
http_responses = {
    response(200, { data = { { id = "bad-id", parse_state = "parsed" }, downloadable }, pagination = { has_more = false } }),
    response(500, { error = "One article failed" }),
    response(200, { data = { id = "download-id", title = downloadable.title, url = downloadable.url, parse_state = "parsed", content = '<p>Reading<img src="/pic.png"></p>', content_truncated = false } }),
    { 200, "image bytes", { ["content-type"] = "image/png" } },
}
counts = ap.articles:run()
eq(counts.downloaded, 1, "one failing article does not prevent other downloads")
eq(counts.failed, 1, "failing article counted")
eq(settings_store.articles["download-id"].file, download_path, "download ownership saved")
eq(settings_store.articles["download-id"].url, downloadable.url, "tracked URL saved")
local image_req = http_log[#http_log]
eq(image_req.url, "https://example.com/pic.png", "image transport URL resolved")
eq(image_req.headers["X-API-Key"], nil, "Screvi key never sent to image host")
eq(image_req.headers["User-Agent"], "screvi-koreader/1.3.0", "image user agent version")
http_log = {}
http_responses = { response(200, { data = { downloadable }, pagination = { has_more = false } }) }
counts = ap.articles:run()
eq(counts.downloaded, 0, "existing owned file not redownloaded")
eq(#http_log, 1, "existing owned article only needs listing")
-- A filename alone routes highlights but never grants deletion ownership.
clear(ap.articles.tracked)
ap.articles:save()
http_log = {}
http_responses = { response(200, { data = { downloadable }, pagination = { has_more = false } }) }
counts = ap.articles:run()
eq(#http_log, 1, "existing unowned file not downloaded")
eq(ap.articles.tracked["download-id"], nil, "existing unowned file not adopted")
http_responses = { response(200, { data = {}, pagination = { has_more = false } }) }
ap.articles:run()
local f = io.open(download_path, "rb"); check(f ~= nil, "untracked file never removed"); if f then f:close() end
os.remove(download_path)

-- Download run archives a completed article and never immediately downloads it again.
ap = resetArticlePlugin()
file = trackedArticle(ap, "finished-run", "complete")
http_log = {}
http_responses = {
    response(200, { data = { { id = "finished-run", parse_state = "parsed", home_status = "inbox" } }, pagination = { has_more = false } }),
    response(201, {}), response(200, {}),
}
counts = ap.articles:run()
eq(counts.archived, 1, "download run archives completed article")
eq(counts.downloaded, 0, "finished snapshot entry not redownloaded")
eq(http_log[2].method, "POST", "run syncs highlights before archiving")
eq(http_log[3].method, "PATCH", "run archive follows bulk")
eq(io.open(file, "rb"), nil, "run removes finished EPUB")

-- Open documents are archived but retained until close to avoid breaking the reader.
ap = resetArticlePlugin()
file = trackedArticle(ap, "open-run", "complete")
ap.ui.document = { file = file }
ap.ui.doc_props = sidecars[file].doc_props
ap.ui.annotation = { annotations = sidecars[file].annotations }
ap.ui.doc_settings = { readSetting = function() return { status = "complete" } end }
http_responses = {
    response(200, { data = { { id = "open-run", parse_state = "parsed", home_status = "inbox" } }, pagination = { has_more = false } }),
    response(201, {}), response(200, {}),
}
counts = ap.articles:run()
eq(counts.archived, 1, "open article archived")
check(ap.articles.tracked["open-run"] ~= nil and sidecars[file] ~= nil, "open article retained")
ap.ui.document = nil
http_responses = { response(200, { data = { { id = "open-run", home_status = "archive" } }, pagination = { has_more = false } }) }
counts = ap.articles:run()
eq(counts.removed, 1, "archived copy removed after close")

-- XML entity handling, balanced malformed fragments and UTF-8 safe filenames.
local html = Epub.xhtml('<p>A &#x1F600; &#233; &nbsp;<b>bold</p><IMG SRC="/bad">', { url = "https://example.com/article" }, function() return nil end)
check(html:find("A 😀 é", 1, true), "numeric Unicode entities decoded")
check(html:find("<b>bold</b></p>", 1, true), "mismatched HTML balanced")
local long_name = ap.articles:filename({ id = "utf8", title = string.rep("é", 100) })
check(not long_name:find("\195 %["), "filename truncation preserves UTF-8 character")

-- Optional API metadata may be rapidjson.null, not Lua nil.
local json_null = {}
package.loaded.rapidjson.null = json_null
local code, decoded
http_responses = { response(200, { data = { id = "null-article", image_url = json_null } }) }
code, decoded = ap:requestJson("GET", Articles.API_URL .. "/articles/null-article", nil, true)
eq(decoded.data.image_url, nil, "JSON null optional metadata normalized")
package.loaded.rapidjson.null = nil

ap = resetArticlePlugin()
file = trackedArticle(ap, "finished-untagged", "complete")
http_responses = { response(200, { data = {}, pagination = { has_more = false } }), response(201, {}), response(200, {}) }
counts = ap.articles:run()
eq(counts.archived, 1, "finished untagged article still archived")
eq(http_log[3].method, "PATCH", "finished untagged article gets archive PATCH")
eq(io.open(file, "rb"), nil, "finished untagged article removed after archive")
local menus = {}
ap:addToMainMenu(menus)
local labels = {}
for _, item in ipairs(menus.screvi.sub_item_table) do labels[item.text or (item.text_func and item.text_func())] = true end
check(labels["Download articles"] and labels["Download folder: " .. ap.articles.folder] and labels["Download tag: koreader"], "article menu entries present")
eq(actions.screvi_download.title, "Screvi: download articles", "download dispatcher title")
eq(actions.screvi_download.general, true, "download dispatcher general action")

-- Default toggle and no-pending sync still download.
settings_store.download_with_sync = nil
ap = resetArticlePlugin()
eq(ap.download_with_sync, true, "download with sync defaults on")
local runs = 0
ap.articles.run = function() runs = runs + 1 end
ap.getAllBooks = function() return {} end
ap:syncAllBooks()
eq(runs, 1, "no pending highlights still downloads")

-- Review regressions: separate plugin UIs share live settings and bookkeeping.
ap = resetArticlePlugin()
local opens_before = settings_opens
local second = newPlugin({})
eq(settings_opens, opens_before, "new UI never opens another settings snapshot")
eq(ap.settings, second.settings, "one settings object across ReaderUI and FileManager")
eq(ap.synced_hashes, second.synced_hashes, "hash table shared between UIs")
eq(ap.articles.tracked, second.articles.tracked, "ownership table shared between UIs")
local shared_book = { name = "Shared", highlights = { { content = "One" } } }
local shared_article = { name = "Shared article", article_id = "shared-id", highlights = { { content = "Article" } } }
ap:markSynced({ shared_book, shared_article })
second:markSynced({ { name = "Other", highlights = { { content = "Two" } } } })
check(settings_store.synced_hashes[Screvi.highlightHash(shared_book, shared_book.highlights[1])], "stale UI save preserves ReaderUI hashes")
eq(#second:pendingSources({ shared_book }), 0, "second UI does not duplicate a sent book")
local delayed_sources = { shared_book }
http_log = {}
second:upload(delayed_sources, true)
eq(#http_log, 0, "delayed upload refreshes pending hashes")
second:clearBookHashes()
eq(ap.synced_hashes[Screvi.highlightHash(shared_book, shared_book.highlights[1])], nil, "re-send clears book hashes in both UIs")
check(ap.synced_hashes[Screvi.highlightHash(shared_article, shared_article.highlights[1])], "re-send retains article hashes")
ap.articles.tag = "new-tag"
eq(second.articles.tag, "new-tag", "download tag shared between UIs")

-- Text matching covers a committed bulk request whose response timed out and edited notes.
ap = resetArticlePlugin()
local duplicate = { name = "Dedupe", article_id = "dedupe", highlights = { { content = "  Same\n text  ", note = "edited" } } }
article_get_responses = { response(200, { data = { highlights = { { content = "Same text", note = "original" } } } }) }
check(ap.articles:upload(duplicate), "edited note uploaded before being marked synced")
eq(#http_log, 1, "changed note causes bulk upload")
eq(#article_checks, 1, "article GET used before highlight sync")
check(ap.synced_hashes[Screvi.highlightHash(duplicate, duplicate.highlights[1])], "edited note's hash marked synced")
local timed = { name = "Timed", article_id = "timed", highlights = { { content = "Lost response" } } }
http_responses = { { nil } }
check(not ap.articles:upload(timed), "lost bulk response fails locally")
check(not ap.synced_hashes[Screvi.highlightHash(timed, timed.highlights[1])], "lost response remains pending")
http_log = {}
article_get_responses = { response(200, { data = { highlights = { { content = "Lost response" } } } }) }
check(ap.articles:upload(timed), "retry recognizes server-committed highlight")
eq(#http_log, 0, "timeout retry skips duplicate bulk send")
local local_dupes = { name = "Two", article_id = "local-dupes", highlights = { { content = "Same  quote" }, { content = "Same quote", note = "second" } } }
http_responses = { response(201, {}) }
check(ap.articles:upload(local_dupes), "local duplicate text handled")
local _, sent_dupes = http_log[1].source:gsub('"article_id":', '')
eq(sent_dupes, 2, "same local text with different notes submitted independently")
check(ap.synced_hashes[Screvi.highlightHash(local_dupes, local_dupes.highlights[2])], "both local variants marked after acceptance")

-- Deletions can race GET, bulk POST, PATCH or content download.
for _, stage in ipairs({ "get", "bulk", "patch", "body-code" }) do
    ap = resetArticlePlugin()
    file = trackedArticle(ap, "gone-" .. stage, "complete")
    if stage == "get" then article_get_responses = { response(404, {}) }
    elseif stage == "bulk" then http_responses = { response(404, {}) }
    elseif stage == "patch" then http_responses = { response(201, {}), response(404, {}) }
    else article_get_responses = { response(400, { code = "not_found" }) } end
    local done, why, state = ap.articles:finish("gone-" .. stage)
    eq(state, "gone", stage .. " deletion classified")
    eq(ap.articles.tracked["gone-" .. stage], nil, stage .. " deletion stops tracking")
    check(ap.state.gone["gone-" .. stage], stage .. " deletion persisted")
    local f = io.open(file, "rb"); check(f ~= nil and sidecars[file] ~= nil, stage .. " deletion preserves EPUB and notes"); if f then f:close() end
    local book = Screvi.getBookFromSidecar(file)
    eq(#ap:pendingSources({ book }), 0, stage .. " filename never retries deleted article")
    http_log, article_checks = {}, {}
    ap.articles:upload(book)
    eq(#http_log + #article_checks, 0, stage .. " gone upload does not contact API")
    os.remove(file)
end
ap = resetArticlePlugin()
file = trackedArticle(ap, "gone-content", "reading")
http_responses = { response(404, {}) }
local _, _, state = ap.articles:content("gone-content")
eq(state, nil, "content GET 404 is retryable")
check(ap.articles.tracked["gone-content"] ~= nil, "content GET preserves tracking")
os.remove(file)
ap = resetArticlePlugin()
file = trackedArticle(ap, "tombstone", "reading")
http_responses = { response(200, { data = { { id = "tombstone", deleted = true } }, pagination = { has_more = false } }) }
counts = ap.articles:run()
eq(counts.gone, 1, "deleted tombstone counted")
eq(counts.failed, 0, "deleted article is not a retryable failure")
check(shown[#shown].text:find("1 no longer on Screvi (kept on device)", 1, true), "gone summary explains kept copy")
check(http_log[1].url:find("include_deleted=true", 1, true), "list includes deletion tombstones")
check(sidecars[file], "tombstone keeps sidecar")
os.remove(file)
ap = resetArticlePlugin()
file = trackedArticle(ap, "gone-no-highlights", "reading")
sidecars[file].annotations = {}
http_responses = { response(200, { data = {}, pagination = { has_more = false } }) }
article_get_responses = { response(404, {}) }
counts = ap.articles:run()
eq(counts.gone, 1, "untagged lookup detects deletion even without highlights")
check(sidecars[file], "zero-highlight deletion keeps sidecar")
os.remove(file)

-- UTF-16 offsets include the emoji's surrogate pair at a page boundary.
ap = resetArticlePlugin()
http_responses = {
    response(200, { data = { parse_state = "parsed", content = "<p>😀", content_offset = 0, content_truncated = true } }),
    response(200, { data = { parse_state = "parsed", content = "é</p>", content_offset = 5, content_truncated = false } }),
}
content = ap.articles:content("emoji")
eq(content.content, "<p>😀é</p>", "emoji page boundary joined intact")
check(http_log[2].url:find("offset=5", 1, true), "astral character uses two UTF-16 units")
check(http_log[1].url:find("max_chars=1000000", 1, true), "bounded million-character page size requested")

-- Switching tags preserves earlier downloads, while completion still archives them.
ap = resetArticlePlugin()
file = trackedArticle(ap, "old-tag", "reading")
ap.articles.tag = "different"
http_responses = { response(200, { data = {}, pagination = { has_more = false } }) }
counts = ap.articles:run()
eq(counts.removed, 0, "old tag is outside cleanup scope")
eq(ap.articles.tracked["old-tag"].tag, "koreader", "download tag saved on tracked record")
eq(#article_checks, 0, "old tag cleanup makes no article API calls")
sidecars[file].summary.status = "complete"
http_responses = { response(200, { data = {}, pagination = { has_more = false } }), response(201, {}), response(200, {}) }
counts = ap.articles:run()
eq(counts.archived, 1, "finished older tag still archives normally")
ap = resetArticlePlugin()
file = trackedArticle(ap, "switch-back", "reading")
ap.articles.tag = "different"; ap.articles.tag = "koreader"
http_responses = { response(200, { data = {}, pagination = { has_more = false } }), response(201, {}) }
counts = ap.articles:run()
eq(counts.removed, 1, "switching back resumes untagged cleanup")

-- Empty Sync all stays local when article downloads are disabled.
ap = resetArticlePlugin()
ap.download_with_sync = false; ap.getAllBooks = function() return {} end
local network = package.loaded["ui/network/manager"]
local old_online, prompts = network.runWhenOnline, 0
network.runWhenOnline = function(_, cb) prompts = prompts + 1; cb() end
ap:syncAllBooks()
eq(prompts, 0, "no Wi-Fi prompt with no sources and downloads disabled")
eq(shown[#shown].text, "No highlights found.", "empty sync keeps old early message")
network.runWhenOnline = old_online

-- Named/numeric entities are decoded once, then escaped into XML.
local entity_cases = { nbsp=" ", amp="&amp;", lt="&lt;", gt="&gt;", quot="&quot;", apos="'", mdash="—", ndash="–", hellip="…", lsquo="‘", rsquo="’", ldquo="“", rdquo="”", laquo="«", raquo="»", copy="©", reg="®", trade="™", deg="°", middot="·", bull="•", times="×", eacute="é", egrave="è", aacute="á", agrave="à", oacute="ó", uacute="ú", iacute="í", ntilde="ñ", ccedil="ç", uuml="ü", ouml="ö", auml="ä", szlig="ß", euro="€", pound="£", shy="\194\173", zwj="\226\128\141", zwnj="\226\128\140" }
for name, expected in pairs(entity_cases) do
    eq(Epub.xhtml("&" .. name .. ";", { url = "https://example.com" }), expected, "entity " .. name)
end
eq(Epub.xhtml("&#38;lt; &unknown; &#60; &#x3E;", { url = "https://example.com" }), "&amp;lt; &amp;unknown; &lt; &gt;", "single-pass decoding and unknown entity escaping")
local forbidden = "\0\1\11\12\31\239\191\190\239\191\191\239\183\144\237\160\128\244\143\191\191"
eq(Epub.escape("A" .. forbidden .. "B\t\n\r"), "AB\t\n\r", "literal forbidden XML code points stripped")
eq(Epub.xhtml("A&#0;&#1;&#xFFFE;&#xFFFF;&#xFDD0;&#xD800;&#x10FFFF;B", {}), "AB", "numeric forbidden XML characters stripped")
local edge_urls = {}
local edge_html = Epub.xhtml('<SCRIPT>secret</SCRIPT><NoScript>fallback</NOSCRIPT><STYLE>css</STYLE><p><a href="/q?a=b=c">link</a><img src="/one.png" alt="a > b' .. forbidden .. '"><a href=/q?a=b=c>unquoted</a><img data-src="/lazy.png"><img src="data:image/gif,x" data-src="/real.png"><img srcset="/first.png 1x, /second.png 2x"></p>', { url = "https://example.com/post" }, function(url) edge_urls[#edge_urls + 1] = url; return "png", "image/png" end)
check(not edge_html:find("secret") and not edge_html:find("fallback") and not edge_html:find("css"), "case-insensitive script/style/noscript content dropped")
check(edge_html:find('alt="a &gt; b"', 1, true), "quoted greater-than and forbidden attribute characters handled")
local _, intact_links = edge_html:gsub('href="https://example.com/q%?a=b=c"', '')
eq(intact_links, 2, "quoted and unquoted equals signs preserved")
eq(edge_urls[2], "https://example.com/lazy.png", "missing src uses data-src")
eq(edge_urls[3], "https://example.com/real.png", "placeholder data URI uses data-src")
eq(edge_urls[4], "https://example.com/first.png", "first srcset candidate selected")

-- Collections use the actual KOReader removeItem API.
ap = resetArticlePlugin()
file = trackedArticle(ap, "collection", "reading")
ap:markSynced({ Screvi.getBookFromSidecar(file) })
local collection_removed
package.loaded.readcollection = { removeItem = function(_, path) collection_removed = path end }
check(ap.articles:remove("collection"), "collection article removed")
eq(collection_removed, file, "ReadCollection.removeItem called")
package.loaded.readcollection = nil

-- Total timeout sink, size cap, streaming into archive, and legacy sink fallback.
local socketutil = package.loaded.socketutil
local table_sink_calls = 0
socketutil.table_sink = function(t) table_sink_calls = table_sink_calls + 1; return function(chunk) if chunk then t[#t + 1] = chunk end; return 1 end end
local legacy_sink = package.loaded.ltn12.sink.table
package.loaded.ltn12.sink.table = function(t) return function(chunk) if chunk then t[#t + 1] = chunk end; return 1 end end
http_responses = { { 200, "image", { ["content-type"] = "image/png" } } }
eq(Epub.downloadImage("https://example.com/image", Screvi.USER_AGENT), "image", "image uses timeout-aware sink")
eq(table_sink_calls, 1, "socketutil.table_sink selected")
http_responses = { { 200, string.rep("x", Epub.MAX_IMAGE_BYTES + 1), { ["content-type"] = "image/png" } } }
eq(Epub.downloadImage("https://example.com/large", Screvi.USER_AGENT), nil, "image larger than 5 MB skipped")
socketutil.table_sink = nil
http_responses = { { 200, "legacy", { ["content-type"] = "image/png" } } }
eq(Epub.downloadImage("https://example.com/legacy", Screvi.USER_AGENT), "legacy", "older KOReader sink fallback works")
package.loaded.ltn12.sink.table = legacy_sink
local streamed = 0
local _, streamed_images = Epub.xhtml('<img src="/1"><img src="/2">', { url = "https://example.com" }, function() return "image", "image/png" end, function() streamed = streamed + 1 end)
eq(streamed, 2, "images written as fetched")
eq(streamed_images[1].data, nil, "first image bytes released after archive write")
eq(streamed_images[2].data, nil, "second image bytes released after archive write")
local _, large_images = Epub.xhtml('<img src="/big">', { url = "https://example.com" }, function() return string.rep("x", Epub.MAX_IMAGE_BYTES + 1), "image/png" end)
eq(#large_images, 0, "custom image fetch also respects size cap")

-- Rate limit stops a run after retaining successful downloads; UI ticks separate articles.
ap = resetArticlePlugin()
local rate_list = { { id = "rate-one", title = "First", parse_state = "parsed", url = "https://example.com" }, { id = "rate-two", parse_state = "parsed" }, { id = "rate-three", parse_state = "parsed" } }
http_responses = { response(200, { data = rate_list, pagination = { has_more = false } }), response(200, { data = { content = "First", parse_state = "parsed" } }), response(429, { code = "rate_limited" }) }
counts = real_run(ap.articles)
eq(counts.downloaded, 1, "first article completes before yielding")
eq(#http_log, 2, "next article waits for UI tick")
eq(#ticks, 1, "UI continuation scheduled")
while ap.articles.running do table.remove(ticks, 1)() end
eq(counts.downloaded, 1, "rate limit retains completed download")
eq(#http_log, 3, "rate limit prevents third article request")
check(shown[#shown].text:find("Wait a minute", 1, true), "rate limit wait message shown")
check(ap.articles.tracked["rate-one"], "rate limit preserves completed tracking")
os.remove(ap.articles.tracked["rate-one"].file)

-- Import payload strips snapshot-only fields.
ap = resetArticlePlugin()
http_responses = { response(200, {}) }
ap:post({ { file = "local", complete = true, name = "Snapshot", highlights = { { content = "text" } } } })
check(not http_log[1].source:find('"complete"', 1, true) and not http_log[1].source:find('"file"', 1, true), "import omits local snapshot fields")

-- Tracking precedes final rename, and startup recovers a tracked temporary EPUB.
local staged_path = temp_dir .. "/pending [screvi-pending].epub"
local tracked_before_rename = false
check(Epub.build({ id = "pending", title = "Pending", content = "text" }, staged_path, nil, Screvi.USER_AGENT, function(tmp)
    local f = io.open(tmp, "rb"); tracked_before_rename = f ~= nil and io.open(staged_path, "rb") == nil; if f then f:close() end
end), "EPUB with pre-rename tracking hook built")
check(tracked_before_rename, "tracking hook sees temp file before final rename")
os.remove(staged_path)
local f = assert(io.open(staged_path .. ".tmp", "w")); f:write("EPUB"); f:close()
ap.articles.tracked.pending = { file = staged_path, pending_file = staged_path .. ".tmp", tag = "koreader" }
ap.articles:save()
second = newPlugin({})
local f = io.open(staged_path, "rb"); check(f ~= nil, "startup promotes tracked temporary EPUB"); if f then f:close() end
eq(second.articles.tracked.pending.pending_file, nil, "recovered pending marker cleared")
os.remove(staged_path)

-- A missing tracked file re-downloads under its new title and purges its old sidecar.
ap = resetArticlePlugin()
file = trackedArticle(ap, "rename", "reading"); os.remove(file)
local renamed = { id = "rename", title = "New title", parse_state = "parsed", url = "https://example.com" }
http_responses = { response(200, { data = { renamed }, pagination = { has_more = false } }), response(201, {}), response(200, { data = { content = "New", parse_state = "parsed" } }) }
counts = ap.articles:run()
eq(counts.downloaded, 1, "missing tracked article re-downloaded")
eq(sidecars[file], nil, "old filename sidecar purged")
eq(ap.articles.tracked.rename.tag, "koreader", "new download records current tag")
os.remove(ap.articles.tracked.rename.file)

-- The exporter checks custom tracked paths in memory without reopening settings.
ap = resetArticlePlugin()
local custom_file = temp_dir .. "/custom.epub"
ap.articles.tracked.custom = { file = custom_file, tag = ap.articles.tag }
local old_opens = settings_opens
export_requests = {}
check(target:export({ { file = custom_file, title = "Custom", { { text = "Text" } } } }), "exporter checks shared custom article path")
eq(#export_requests, 0, "in-memory tracked article is excluded from book export")
eq(settings_opens, old_opens, "exporter never reopens settings for an article check")

-- Re-send's actual confirmation callback retains article hashes in every UI.
ap:markSynced({ shared_book, shared_article })
menus = {}; ap:addToMainMenu(menus)
for _, menu in ipairs(menus.screvi.sub_item_table) do
    if menu.text == "Re-send all highlights" then menu.callback(); shown[#shown].ok_callback() end
end
check(ap.synced_hashes[Screvi.highlightHash(shared_article, shared_article.highlights[1])], "re-send confirmation preserves article history")
eq(ap.synced_hashes[Screvi.highlightHash(shared_book, shared_book.highlights[1])], nil, "re-send confirmation clears book history")

-- A rate-limited bulk call or preflight stops remaining sources and book batches.
for _, phase in ipairs({ "bulk", "get" }) do
    ap = resetArticlePlugin()
    if phase == "bulk" then http_responses = { response(429, {}) }
    else article_get_responses = { response(429, {}) } end
    check(not ap:upload({ shared_article, duplicate, shared_book }, true), phase .. " 429 fails sync")
    eq(#article_checks, 1, phase .. " 429 stops further preflight requests")
    eq(#http_log, phase == "bulk" and 1 or 0, phase .. " 429 stops remaining writes")
end

-- Note edits on already-synced highlights survive completion and cleanup.
ap = resetArticlePlugin()
file = trackedArticle(ap, "note-edit", "reading")
ap:markSynced({ Screvi.getBookFromSidecar(file) })
sidecars[file].annotations[1].note = "Edited note"
sidecars[file].summary.status = "complete"
article_get_responses = { response(200, { data = { highlights = { { content = "Passage", note = "Note" } } } }) }
http_responses = { response(201, {}), response(200, {}) }
check(ap.articles:finish("note-edit"), "note edit finishes successfully")
check(http_log[1].source:find('"note":"Edited note"', 1, true), "edited note sent before archive")
eq(http_log[2].method, "PATCH", "edited note accepted before archive")
eq(io.open(file, "rb"), nil, "note edit cleanup after successful sync")

-- A deduped note does not hide another note on the same local text.
ap = resetArticlePlugin()
local separate = { article_id = "notes", name = "Notes", highlights = {
    { content = "Same quote", note = " First \n note " }, { content = "Same quote", note = "Second note" },
} }
article_get_responses = { response(200, { data = { highlights = { { content = "Same quote", note = "First note" } } } }) }
http_responses = { response(422, { message = "Highlight at index 0 is invalid" }) }
local before_flush = settings_flushes
check(not ap.articles:upload(separate), "second distinct note failure returned")
eq(settings_flushes - before_flush, 1, "dedupe hashes flushed once on partial failure")
check(ap.synced_hashes[Screvi.highlightHash(separate, separate.highlights[1])], "matching note marked synced")
check(not ap.synced_hashes[Screvi.highlightHash(separate, separate.highlights[2])], "failed different note remains unsynced")
check(http_log[1].source:find('"note":"Second note"', 1, true), "different local note submitted on its own")
check(article_checks[1].url:find("?format=text&max_chars=1000", 1, true), "dedupe GET limits article body")

-- Direct cleanup also refuses to unlink unsynced highlights.
ap = resetArticlePlugin()
file = trackedArticle(ap, "unsent-remove", "complete")
check(not ap.articles:remove("unsent-remove"), "remove refuses unsynced highlight")
check(sidecars[file] and ap.articles.tracked["unsent-remove"], "unsynced cleanup preserves notes and tracking")
local kept = io.open(file, "rb"); check(kept ~= nil, "unsynced cleanup preserves EPUB"); if kept then kept:close() end
os.remove(file)

-- Restored IDs resume syncing and tracked articles refresh their current tag.
ap = resetArticlePlugin()
file = trackedArticle(ap, "restored", "reading")
ap.state.gone.restored = true
ap.articles.tag = "new-tag"
http_responses = { response(200, { data = { { id = "restored", parse_state = "parsed" } }, pagination = { has_more = false } }) }
check(ap.articles:list(), "restored article listing succeeds")
eq(ap.state.gone.restored, nil, "live listing clears gone ID")
eq(ap.articles.tracked.restored.tag, "new-tag", "reappearing article updates stored tag")
eq(#ap:pendingSources({ Screvi.getBookFromSidecar(file) }), 1, "restored article highlights eligible again")
os.remove(file)

-- Content 404 after a successful listing is retried on the next run.
ap = resetArticlePlugin()
local transient = { id = "transient", title = "Transient", parse_state = "parsed", url = "https://example.com" }
http_responses = { response(200, { data = { transient }, pagination = { has_more = false } }), response(404, {}) }
counts = ap.articles:run()
eq(counts.failed, 1, "just-listed content 404 counted as failure")
eq(counts.gone, 0, "just-listed content 404 not classified as deletion")
eq(ap.state.gone.transient, nil, "content 404 does not persist gone flag")
http_responses = { response(200, { data = { transient }, pagination = { has_more = false } }), response(200, { data = { parse_state = "parsed", content = "Recovered" } }) }
counts = ap.articles:run()
eq(counts.downloaded, 1, "content 404 retried successfully next run")
os.remove(ap.articles.tracked.transient.file)

-- Bulk note length is Unicode-aware, and locations meet the integer schema.
ap = resetArticlePlugin()
local bounded = { article_id = "bounded", name = "Bounds", highlights = {
    { content = "long", note = string.rep("é", 20001), location = -2.5 },
    { content = "exact", note = string.rep("é", 20000), location = "8.9" },
    { content = "bad", location = "bad" }, { content = "nan", location = 0/0 },
    { content = "infinity", location = math.huge },
} }
local payload
ap.requestJson = function(_, method, _, body)
    if method == "GET" then return 200, { data = { highlights = {} } } end
    payload = body
    return 201, {}
end
check(ap.articles:upload(bounded), "bounded highlights accepted")
eq(payload.highlights[1].note, string.rep("é", 19999) .. "…", "long Unicode note truncated with ellipsis")
eq(payload.highlights[2].note, string.rep("é", 20000), "exact length note preserved")
eq(payload.highlights[1].location, 0, "negative location clamped")
eq(payload.highlights[2].location, 8, "fractional location clamped to integer")
for i = 3, 5 do eq(payload.highlights[i].location, nil, "invalid location omitted " .. i) end

-- Validation failure is logged, visible, and preserves completed articles.
ap = resetArticlePlugin()
file = trackedArticle(ap, "invalid", "complete")
local warn = package.loaded.logger.warn
local validation_logged = false
package.loaded.logger.warn = function(...)
    for _, value in ipairs({ ... }) do if value == 422 then validation_logged = true end end
end
http_responses = { response(200, { data = { { id = "invalid", parse_state = "parsed" } }, pagination = { has_more = false } }), response(422, { message = "Highlight at index 0: content too long" }) }
counts = ap.articles:run()
package.loaded.logger.warn = warn
eq(counts.failed, 1, "bulk validation failure counted")
check(validation_logged, "bulk 422 logged")
check(shown[#shown].text:find("Highlight at index 0: content too long", 1, true), "bulk validation server message shown in summary")
check(ap.articles.tracked.invalid and sidecars[file], "validation failure retains article and notes")
eq(#http_log, 2, "validation failure prevents archive PATCH")
os.remove(file)

-- Skipped highlights are not reported as added, with one flush for many matches.
ap = resetArticlePlugin()
local matches = { article_id = "matches", name = "Matches", highlights = {} }
local remote_matches = {}
for i = 1, 150 do
    matches.highlights[i] = { content = "Match " .. i, note = " Note " }
    remote_matches[i] = { content = "Match " .. i, note = "Note" }
end
article_get_responses = { response(200, { data = { highlights = remote_matches } }) }
before_flush = settings_flushes
check(ap:upload({ matches }, false), "manual dedupe sync succeeds")
eq(settings_flushes - before_flush, 1, "many deduped highlights flush once")
eq(#http_log, 0, "many server matches skip bulk")
eq(shown[#shown].text, "Screvi already had these highlights.", "deduped highlights not counted as added")

-- Partial bulk success flushes once and preserves only accepted hashes.
ap = resetArticlePlugin()
http_responses = { response(201, {}), response(500, { error = "failed" }) }
before_flush = settings_flushes
check(not ap.articles:upload(big_article), "partial bulk success returns failure")
eq(settings_flushes - before_flush, 1, "partial bulk hashes flush once per operation")
check(ap.synced_hashes[Screvi.highlightHash(big_article, big_article.highlights[100])], "partial operation retains accepted hashes")
check(not ap.synced_hashes[Screvi.highlightHash(big_article, big_article.highlights[101])], "partial operation leaves rejected hashes pending")

-- Collection/history helpers must see the file before unlinking (realpath).
ap = resetArticlePlugin()
file = trackedArticle(ap, "removal-order", "reading")
ap:markSynced({ Screvi.getBookFromSidecar(file) })
local history_module = package.loaded.readhistory
package.loaded.readcollection = { removeItem = function(_, path)
    local f = io.open(path, "rb"); check(f ~= nil, "collection resolves file before unlink"); if f then f:close() end
    events[#events + 1] = "collection"
end }
package.loaded.readhistory = { removeItemByPath = function(_, path)
    local f = io.open(path, "rb"); check(f ~= nil, "history sees file before unlink"); if f then f:close() end
    events[#events + 1] = "history"
end }
check(ap.articles:remove("removal-order"), "ordered cleanup succeeds")
eq(events[1], "collection", "collection removed first")
eq(events[2], "history", "history removed before purge")
package.loaded.readcollection, package.loaded.readhistory = nil, history_module

-- Reconciliation yields too; closing during the suspended run cannot archive.
ap = resetArticlePlugin()
local close_snapshot
for _, id in ipairs({ "tracked-one", "tracked-two", "tracked-three" }) do trackedArticle(ap, id, "reading") end
http_responses = { response(200, { data = {}, pagination = { has_more = false } }), response(429, {}) }
counts = real_run(ap.articles)
eq(counts.failed, 1, "tracked pass encounters rate limit")
check(ap.articles.running and #ticks == 1, "tracked pass yields after first item")
eq(#article_checks, 2, "tracked pass stops before second item until UI tick")
local requests_before_close = #http_log + #article_checks
for _, item in pairs(ap.articles.tracked) do
    sidecars[item.file].summary.status = "complete"
    close_snapshot = Screvi.getBookFromSidecar(item.file); close_snapshot.complete = true
end
ap.articles:onClose(close_snapshot)
eq(#http_log + #article_checks, requests_before_close, "onClose skips cleanup while run suspended")
check(counts.rate_limited, "onClose preserves suspended run rate limit")
local other_ui = newPlugin({})
http_responses = { response(200, { results = { newHighlights = 1 } }) }
check(other_ui:upload({ shared_book }, true), "manual sync can complete independently")
check(counts.rate_limited, "manual sync in another UI preserves suspended run rate limit")
while ap.articles.running do table.remove(ticks, 1)() end
eq(#article_checks, 2, "suspended tracked run stops after 429 despite manual sync")
for _, item in pairs(ap.articles.tracked) do os.remove(item.file) end

-- Sanitizer regressions: skipped markup must not consume following content.
for _, tag in ipairs({ "iframe", "script", "noscript", "style" }) do
    eq(Epub.xhtml('<p>one</p><' .. tag .. ' src="v"/><p>two</p>', {}),
        "<p>one</p><p>two</p>", tag .. " self-closing tag preserves following text")
end
eq(Epub.xhtml([[<p>one</p><script>if (a < b) { x = "unterminated; }</ScRiPt><p>two</p>]], {}),
    "<p>one</p><p>two</p>", "raw script scan ignores quotes and comparisons")
eq(Epub.xhtml([[<p>one < 'quoted text</p><p>two</p>]], {}),
    "<p>one &lt; 'quoted text</p><p>two</p>", "stray less-than remains text")

-- EPUB 2 uses XHTML 1.1: translate HTML5 containers and keep only legal attributes.
for _, tag in ipairs({ "figure", "article", "section", "header", "footer", "aside", "nav", "main", "hgroup", "details", "summary" }) do
    eq(Epub.xhtml("<" .. tag .. ' hidden="hidden"><p>Text</p></' .. tag .. ">", {}),
        "<div><p>Text</p></div>", tag .. " maps to div")
end
eq(Epub.xhtml('<figure><figcaption class="arbitrary">Caption &amp; text</figcaption></figure>', {}),
    '<div><div class="caption">Caption &amp; text</div></div>', "caption gets XHTML div and fixed class")
eq(Epub.xhtml('<mark>Marked</mark><time datetime="2026-01-02">Today</time>', {}),
    "<span>Marked</span><span>Today</span>", "HTML5 inline elements map to span")
eq(Epub.xhtml('<div><section>Inside</section>Outside</div>', {}),
    "<div><div>Inside</div>Outside</div>", "mapped closing tag preserves parent container")
eq(Epub.xhtml('<section><div>Inside</div>Outside</section>', {}),
    "<div><div>Inside</div>Outside</div>", "native closing tag preserves mapped parent")
eq(Epub.xhtml('<div><section/>Outside<mark/>Tail</div>', {}),
    "<div><div></div>Outside<span></span>Tail</div>", "self-closing mapped elements do not swallow following content")
eq(Epub.xhtml('<u>Underlined</u><s>Struck</s><font color="red">Font</font><video>Video</video><p-widget>Custom</p-widget>', {}),
    "UnderlinedStruckFontVideoCustom", "unsupported and legacy tags retain text only")
eq(Epub.xhtml('<p colspan="4" href="/bad" style="color:red" onclick="bad()">Text</p><div src="/bad">Div</div><a alt="bad" href="/ok">Link</a>', { url = "https://example.com" }),
    '<p>Text</p><div>Div</div><a href="https://example.com/ok">Link</a>', "attributes restricted by element")
eq(Epub.xhtml('<table><tr><th colspan="4">PHASE 0 — orientation</th></tr><tr><td rowspan="2" colspan="3">Cell</td></tr></table>', {}),
    '<table><tr><th colspan="4">PHASE 0 — orientation</th></tr><tr><td colspan="3" rowspan="2">Cell</td></tr></table>', "table cell spans preserved")
for _, value in ipairs({ "0", "-1", "1.5", "1e2", "2px", "", " 2" }) do
    eq(Epub.xhtml('<table><tr><td colspan="' .. value .. '" rowspan="' .. value .. '">Cell</td></tr></table>', {}),
        "<table><tr><td>Cell</td></tr></table>", "invalid table span rejected: " .. value)
end
eq(Epub.xhtml('<table><tr><td colspan="1001" rowspan="999999999999999999999999999999">Cell</td><th colspan="0004" rowspan="1000">Heading</th></tr></table>', {}),
    '<table><tr><td colspan="1000" rowspan="1000">Cell</td><th colspan="4" rowspan="1000">Heading</th></tr></table>', "table spans capped and normalized")
eq(Epub.xhtml('<table><tr><td colspan="&#52;" onclick="bad()" rowspan=2>Cell</td></tr></table>', {}),
    '<table><tr><td colspan="4" rowspan="2">Cell</td></tr></table>', "encoded and unquoted cell spans retained without event attributes")

local function builtHeader(metadata)
    metadata.id, metadata.title, metadata.content = "header", "Header & title", "<p>Body</p>"
    check(Epub.build(metadata, epub_path), "header fixture builds")
    local xhtml
    for _, entry in ipairs(zip_entries) do if entry.path == "OEBPS/content.xhtml" then xhtml = entry.data end end
    os.remove(epub_path)
    return xhtml:match('(<h1>.-</div>)'), xhtml
end
local header, header_xhtml = builtHeader({ author = " Writer & co ", site_name = "Site", source_domain = "example.com", published_date = "2026-11-23T19:48:30.164Z", saved_at = "2026-01-02", url = "https://example.com/?a=1&b=2" })
eq(header, '<h1>Header &amp; title</h1><div class="header"><p>Writer &amp; co · Site</p><p>23 Nov 2026</p><p><a href="https://example.com/?a=1&amp;b=2">https://example.com/?a=1&amp;b=2</a></p></div>', "header has byline, publication date, then URL")
check(header_xhtml:find('.header p { text-indent: 0; margin: 0; font-size: small; }', 1, true), "header paragraph CSS overrides reader defaults")
check(header_xhtml:find('.caption { font-size: small; text-align: center; }', 1, true), "caption CSS is small and centered")
check(header_xhtml:find('img { max-width: 100%; }', 1, true), "responsive image CSS retained")
eq(builtHeader({ source_domain = "example.com", saved_at = "2026-11-23T19:48:30.164Z" }),
    '<h1>Header &amp; title</h1><div class="header"><p>example.com</p><p>23 Nov 2026</p></div>', "missing author and URL leave no blank lines")
eq(builtHeader({ author = "Writer", site_name = " ", source_domain = "example.com" }),
    '<h1>Header &amp; title</h1><div class="header"><p>Writer · example.com</p></div>', "blank site name falls back to domain")
eq(builtHeader({ author = "Writer" }), '<h1>Header &amp; title</h1><div class="header"><p>Writer</p></div>', "author-only header has no separator")
eq(builtHeader({ author = " ", saved_at = "bad-date" }), '<h1>Header &amp; title</h1><div class="header"></div>', "missing metadata has no empty paragraphs or raw date")

print(string.format("%d passed, %d failed", passed, failures))
assert(os.execute("rm -rf '" .. temp_dir:gsub("'", "'\\''") .. "'") == 0)
os.exit(failures == 0 and 0 or 1)
