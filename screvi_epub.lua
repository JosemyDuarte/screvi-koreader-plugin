-- EPUB packaging adapted from KOReader's newsdownloader (AGPL-3.0).
local logger = require("logger")
local _ = require("gettext")
local Epub = {}

local function utf8(n)
    if n < 128 then return string.char(n)
    elseif n < 2048 then return string.char(192 + math.floor(n / 64), 128 + n % 64)
    elseif n < 65536 then return string.char(224 + math.floor(n / 4096), 128 + math.floor(n / 64) % 64, 128 + n % 64) end
    return string.char(240 + math.floor(n / 262144), 128 + math.floor(n / 4096) % 64, 128 + math.floor(n / 64) % 64, 128 + n % 64)
end
local function valid(n)
    return n and n <= 1114111 and not (n >= 55296 and n <= 57343)
        and not (n >= 64976 and n <= 65007) and n % 65536 < 65534
        and (n >= 32 or n == 9 or n == 10 or n == 13)
end

-- Smallest code point each UTF-8 sequence length may encode (rejects overlong forms).
local MIN_CODE = { [2] = 128, [3] = 2048, [4] = 65536 }

--- Remove forbidden XML characters from literal text and attributes too.
local function clean(value)
    -- Fast path: printable ASCII plus tab and newlines is always kept as is.
    if not value:find("[%z\1-\8\11\12\14-\31\128-\255]") then return value end
    local out, i = {}, 1
    while i <= #value do
        local first = value:byte(i)
        local size = first < 128 and 1 or first >= 194 and first < 224 and 2
            or first >= 224 and first < 240 and 3 or first >= 240 and first < 245 and 4 or 0
        local n = size == 1 and first or size > 1 and first % (2 ^ (7 - size)) or nil
        for j = 1, size - 1 do
            local byte = value:byte(i + j)
            if not byte or byte < 128 or byte > 191 then n = nil; break end
            n = n * 64 + byte - 128
        end
        if n and (size == 1 or n >= MIN_CODE[size]) and valid(n) then
            out[#out + 1] = value:sub(i, i + size - 1)
        end
        i = i + math.max(size, 1)
    end
    return table.concat(out)
end

local ESCAPES = { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;" }

function Epub.escape(value)
    return clean(tostring(value or "")):gsub('[&<>"]', ESCAPES)
end

local named = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'" }
local codes = { nbsp=160, mdash=8212, ndash=8211, hellip=8230, lsquo=8216, rsquo=8217,
    ldquo=8220, rdquo=8221, laquo=171, raquo=187, copy=169, reg=174, trade=8482,
    deg=176, middot=183, bull=8226, times=215, eacute=233, egrave=232, aacute=225,
    agrave=224, oacute=243, uacute=250, iacute=237, ntilde=241, ccedil=231,
    uuml=252, ouml=246, auml=228, szlig=223, euro=8364, pound=163, shy=173, zwj=8205, zwnj=8204 }
for name, code in pairs(codes) do named[name] = utf8(code) end

--- Decode exactly once: &#38;lt; represents literal &lt;, not a less-than sign.
local function entities(value)
    return value:gsub("&(#?[%w]+);", function(name)
        if name:sub(1, 1) == "#" then
            local code = name:match("^#[xX]([%da-fA-F]+)$")
            local n = code and tonumber(code, 16) or tonumber(name:match("^#(%d+)$"))
            return valid(n) and utf8(n) or ""
        end
        return named[name] or "&" .. name .. ";"
    end)
end

--- Resolve article-relative images with LuaSocket's RFC URL resolver.
function Epub.resolveUrl(base, src)
    if not src or src:match("^data:") then return nil end
    local url = require("socket.url").absolute(base, entities(src))
    if url and url:match("^https?://") then return url end
end

--- Fetch an image without ever sending the Screvi key to its host.
Epub.MAX_IMAGE_BYTES = 5 * 1024 * 1024

function Epub.downloadImage(url, user_agent)
    local sink = {}
    local socketutil = require("socketutil")
    socketutil:set_timeout(10, 30)
    local target = socketutil.table_sink and socketutil.table_sink(sink) or require("ltn12").sink.table(sink)
    local bytes = 0
    local function limited(chunk, err)
        if chunk then
            bytes = bytes + #chunk
            if bytes > Epub.MAX_IMAGE_BYTES then return nil, "Image too large" end
        end
        return target(chunk, err)
    end
    local ok, _, code, headers = pcall(require("socket.http").request, {
        url = url, sink = limited,
        headers = { ["User-Agent"] = user_agent },
    })
    socketutil:reset_timeout()
    if not ok or code ~= 200 or bytes > Epub.MAX_IMAGE_BYTES then return nil end
    return table.concat(sink), headers and (headers["content-type"] or headers["Content-Type"])
end

local allowed = {}
-- A safe subset of XHTML 1.1; legacy presentational tags such as u/s/font
-- are not part of that vocabulary. Unsupported wrappers retain their text.
for tag in ("p div span h1 h2 h3 h4 h5 h6 blockquote pre code em strong b i del ins a ul ol li dl dt dd table caption col colgroup thead tbody tfoot tr th td sup sub br hr img abbr acronym address big cite dfn kbd q samp small tt var"):gmatch("%S+") do allowed[tag] = true end
local mapped = { figcaption = "div", mark = "span", time = "span" }
for tag in ("figure article section header footer aside nav main hgroup details summary"):gmatch("%S+") do mapped[tag] = "div" end
local void = { br = true, hr = true, img = true, col = true }
local IMAGE_EXTENSIONS = {
    ["image/jpeg"] = "jpg",
    ["image/png"] = "png",
    ["image/gif"] = "gif",
    ["image/webp"] = "webp",
    ["image/svg+xml"] = "svg",
}

--- Serialize a sanitized HTML fragment as balanced XHTML and bundle successful images.
function Epub.xhtml(html, article, fetch, add_image)
    local images, cache, output, stack = {}, {}, {}, {}
    local function image(src)
        local resolved, url = pcall(Epub.resolveUrl, article.url, src)
        if not resolved or not url then return nil end
        if cache[url] ~= nil then return cache[url] or nil end
        cache[url] = false
        local ok, data, mime = pcall(fetch or Epub.downloadImage, url)
        if not ok or not data or data == "" or #data > Epub.MAX_IMAGE_BYTES then
            logger.warn("Screvi: image download failed", url)
            return nil
        end
        mime = mime and mime:match("^[^;]+")
        local ext = IMAGE_EXTENSIONS[mime]
        if not ext then
            if data:sub(1, 8) == "\137PNG\13\10\26\10" then ext, mime = "png", "image/png"
            elseif data:sub(1, 2) == "\255\216" then ext, mime = "jpg", "image/jpeg"
            elseif data:sub(1, 3) == "GIF" then ext, mime = "gif", "image/gif"
            else logger.warn("Screvi: unsupported image", url); return nil end
        end
        local item = { id = "image" .. (#images + 1), path = "images/" .. (#images + 1) .. "." .. ext, data = data, mime = mime }
        if add_image then add_image(item.path, data); item.data = nil end
        images[#images + 1], cache[url] = item, item
        return item
    end
    local cover = article.image_url and image(article.image_url)
    if cover then output[#output + 1] = '<p><img src="' .. cover.path .. '" alt=""/></p>' end
    local function closeTo(index)
        for i = #stack, index, -1 do output[#output + 1] = "</" .. table.remove(stack).tag .. ">" end
    end
    html = html:gsub("<!%-%-.-%-%->", "")
    local pos, blocked = 1, nil
    local lower_html = html:lower()
    while pos <= #html do
        if blocked then
            -- Raw-text content can contain unmatched quotes and '<' comparisons.
            -- Find the closing tag without parsing the blocked body as markup.
            local closing = lower_html:find("</" .. blocked, pos, true)
            while closing and not lower_html:sub(closing + #blocked + 2, closing + #blocked + 2):match("[%s/>]") do
                closing = lower_html:find("</" .. blocked, closing + 2, true)
            end
            if not closing then break end
            local finish = html:find(">", closing, true)
            if not finish then break end
            pos, blocked = finish + 1, nil
        end
        local first = html:find("<[%a/!?]", pos)
        -- `blocked` is always nil from here: the block above either cleared it or broke out.
        if not first then
            output[#output + 1] = Epub.escape(entities(html:sub(pos)))
            break
        end
        output[#output + 1] = Epub.escape(entities(html:sub(pos, first - 1)))
        -- A '>' only ends the token outside a quoted attribute.
        local last, quote = first + 1, nil
        while last do
            if quote then
                last = html:find(quote, last, true)
                if last then quote, last = nil, last + 1 end
            else
                last = html:find("[\"'>]", last)
                if not last or html:byte(last) == 62 then break end -- 62 is '>'
                quote, last = html:sub(last, last), last + 1
            end
        end
        if not last then
            output[#output + 1] = Epub.escape(entities(html:sub(first)))
            break
        end
        local token = html:sub(first, last)
        local closing, source_tag = token:match("^<%s*(/?)%s*([%a][%w:._%-]*)")
        source_tag = source_tag and source_tag:lower()
        local tag = mapped[source_tag] or source_tag
        if source_tag == "script" or source_tag == "style" or source_tag == "iframe" or source_tag == "noscript" then
            if closing ~= "/" and not token:match("/%s*>$") then blocked = source_tag end
        elseif allowed[tag] then
            if closing == "/" then
                for i = #stack, 1, -1 do if stack[i].source == source_tag then closeTo(i); break end end
            else
                if (tag == "p" or tag == "li") and stack[#stack] and stack[#stack].tag == tag then closeTo(#stack) end
                local attrs = {}
                local rest = token:match("^<%s*[%a][%w:._%-]*(.-)>$") or ""
                while #rest > 0 do
                    rest = rest:gsub("^%s+", "")
                    local key, tail = rest:match("^([%w_:%-]+)(.*)$")
                    if not key then break end
                    rest = tail:gsub("^%s+", "")
                    if rest:sub(1, 1) == "=" then
                        rest = rest:sub(2):gsub("^%s+", "")
                        local q, value = rest:sub(1, 1)
                        if q == '"' or q == "'" then
                            local finish = rest:find(q, 2, true)
                            if not finish then break end
                            value, rest = rest:sub(2, finish - 1), rest:sub(finish + 1)
                        else
                            value = rest:match("^[^%s<>]+") or ""
                            rest = rest:sub(#value + 1)
                            if rest == "" then value = value:gsub("/$", "") end
                        end
                        attrs[key:lower()] = value
                    end
                end
                local suffix = ""
                -- Emit only attributes legal on this specific XHTML element.
                if source_tag == "figcaption" then suffix = ' class="caption"' end
                if tag == "img" then
                    local src = attrs.src
                    if not src or src == "" or src:lower():match("^data:") then
                        src = attrs["data-src"] or (attrs.srcset and attrs.srcset:match("^%s*([^%s,]+)"))
                    end
                    local img = image(src)
                    if img then suffix = ' src="' .. img.path .. '" alt="' .. Epub.escape(entities(attrs.alt or "")) .. '"' else tag = nil end
                elseif tag == "a" and attrs.href then
                    local ok, href = pcall(Epub.resolveUrl, article.url, attrs.href)
                    if ok and href then suffix = ' href="' .. Epub.escape(href) .. '"' end
                elseif tag == "td" or tag == "th" then
                    for _, key in ipairs({ "colspan", "rowspan" }) do
                        local value = attrs[key] and entities(attrs[key])
                        local n = value and value:match("^%d+$") and tonumber(value)
                        if n and n > 0 then suffix = suffix .. ' ' .. key .. '="' .. math.min(n, 1000) .. '"' end
                    end
                end
                if tag then
                    output[#output + 1] = "<" .. tag .. suffix .. (void[tag] and "/>" or ">")
                    if not void[tag] then
                        stack[#stack + 1] = { source = source_tag, tag = tag }
                        if token:match("/%s*>$") then closeTo(#stack) end
                    end
                end
            end
        end
        pos = last + 1
    end
    closeTo(1)
    return table.concat(output), images, cover
end

local function nonempty(value)
    if type(value) ~= "string" then return nil end
    value = value:gsub("^%s+", ""):gsub("%s+$", "")
    return value ~= "" and value or nil
end

local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }
local function humanDate(value)
    local y, m, d = (nonempty(value) or ""):match("^(%d%d%d%d)%-(%d%d)%-(%d%d)")
    m, d = tonumber(m), tonumber(d)
    if not m or not MONTHS[m] or d < 1 or d > 31 then return nil end
    return d .. " " .. MONTHS[m] .. " " .. y
end

local function articleHeader(article, title)
    local lines, byline = {}, {}
    local author = nonempty(article.author)
    local site = nonempty(article.site_name) or nonempty(article.source_domain)
    if author then byline[#byline + 1] = author end
    if site then byline[#byline + 1] = site end
    if #byline > 0 then lines[#lines + 1] = "<p>" .. Epub.escape(table.concat(byline, " · ")) .. "</p>" end
    local date = humanDate(article.published_date) or humanDate(article.saved_at)
    if date then lines[#lines + 1] = "<p>" .. date .. "</p>" end
    local url = nonempty(article.url)
    if url then
        url = Epub.escape(url)
        lines[#lines + 1] = '<p><a href="' .. url .. '">' .. url .. '</a></p>'
    end
    return "<h1>" .. Epub.escape(title) .. '</h1><div class="header">' .. table.concat(lines) .. "</div>"
end

--- Write an EPUB to a temporary file, then rename only after successful packaging.
function Epub.build(article, path, fetch, user_agent, before_rename)
    local writer, tmp = nil, path .. ".tmp"
    local ok, err = pcall(function()
        local esc = Epub.escape
        local title = article.title or _("Untitled article")
        local header = articleHeader(article, title)
        writer = require("ffi/archiver").Writer:new{}
        assert(writer:open(tmp, "epub"), "Cannot open EPUB")
        local function add(name, data) assert(writer:addFileFromMemory(name, data, os.time()), "Cannot write " .. name) end
        writer:setZipCompression("store")
        -- ffi/archiver always sets mtime and exposes no option to suppress ZIP
        -- timestamp extra fields; keep mimetype first and uncompressed.
        add("mimetype", "application/epub+zip")
        writer:setZipCompression("deflate")
        add("META-INF/container.xml", '<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>')
        local body, images, cover = Epub.xhtml(article.content, article,
            fetch or function(url) return Epub.downloadImage(url, user_agent) end,
            function(name, data) add("OEBPS/" .. name, data) end)
        local items = { '<item id="content" href="content.xhtml" media-type="application/xhtml+xml"/><item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>' }
        for _, img in ipairs(images) do items[#items + 1] = '<item id="' .. img.id .. '" href="' .. img.path .. '" media-type="' .. img.mime .. '"/>' end
        local manifest = table.concat(items)
        add("OEBPS/content.opf", '<?xml version="1.0" encoding="utf-8"?><package xmlns="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/" version="2.0" unique-identifier="bookid"><metadata><dc:title>' .. esc(title) .. '</dc:title><dc:creator>' .. esc(article.author) .. '</dc:creator><dc:source>' .. esc(article.url) .. '</dc:source><dc:identifier id="bookid">' .. esc(article.id) .. '</dc:identifier><dc:language>' .. esc(article.language or "en") .. '</dc:language>' .. (cover and '<meta name="cover" content="' .. cover.id .. '"/>' or "") .. '</metadata><manifest>' .. manifest .. '</manifest><spine toc="ncx"><itemref idref="content"/></spine></package>')
        add("OEBPS/toc.ncx", '<?xml version="1.0"?><ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><head><meta name="dtb:uid" content="' .. esc(article.id) .. '"/></head><docTitle><text>' .. esc(title) .. '</text></docTitle><navMap><navPoint id="article" playOrder="1"><navLabel><text>' .. esc(title) .. '</text></navLabel><content src="content.xhtml"/></navPoint></navMap></ncx>')
        add("OEBPS/content.xhtml", '<?xml version="1.0" encoding="utf-8"?><html xmlns="http://www.w3.org/1999/xhtml"><head><title>' .. esc(title) .. '</title><style type="text/css">.header p { text-indent: 0; margin: 0; font-size: small; } .caption { font-size: small; text-align: center; } img { max-width: 100%; }</style></head><body>' .. header .. body .. '</body></html>')
        writer:close()
        if before_rename then before_rename(tmp) end
        assert(os.rename(tmp, path))
    end)
    if not ok then
        if writer then pcall(writer.close, writer) end
        os.remove(tmp)
        logger.warn("Screvi: EPUB build failed", err)
        return nil, _("Couldn't create the article EPUB.")
    end
    return true
end

return Epub
