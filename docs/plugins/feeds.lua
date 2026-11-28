-- @name Feeds
-- @name:pt Feeds
-- @description RSS and Atom feeds in a panel: YouTube channels, Hacker News, GitHub releases and some news sites. Checks every 15 minutes, one notice per feed with new items, and each item can be opened or shared in the open channel. Each site only after you approve it below.
-- @description:pt Feeds RSS e Atom num painel: canais do YouTube, Hacker News, versões do GitHub e alguns sites de notícia. Confere a cada 15 minutos, um aviso por feed com itens novos, e cada item abre ou vai para o canal aberto. Cada site só depois de aprovar aqui embaixo.
-- @version 1.0.0
-- @capabilities panel, storage, http, timers, notify, links, send
-- @hosts www.youtube.com, hnrss.org, github.com, g1.globo.com, feeds.bbci.co.uk, www.theverge.com, feeds.arstechnica.com, rss.tecmundo.com.br

-- Só dá para assinar feeds dos sites da linha @hosts lá em cima: o app só deixa o plugin
-- falar com eles (até 8, e cada um precisa ser aprovado no cartão). Para assinar outro
-- site, troque um deles na linha @hosts e na lista HOSTS logo abaixo (os mesmos nomes),
-- salve e clique em Recarregar em Configurações → Plugins. O reddit ficou de fora: ele
-- responde 404 e 429 para o User-Agent dos plugins.
local HOSTS = { "www.youtube.com", "hnrss.org", "github.com", "g1.globo.com", "feeds.bbci.co.uk",
  "www.theverge.com", "feeds.arstechnica.com", "rss.tecmundo.com.br" }

local tr = larper.tr
local EVERY = 15 * 60
local MAX_FEEDS = 20
local MAX_ITEMS = 30
local MAX_SEEN = 200
local MAX_SHOWN = 60
-- O app deixa 3 pedidos no ar; um fica livre para quem adiciona um feed.
local IN_FLIGHT = 2

local allowed_host = {}
for _, h in ipairs(HOSTS) do allowed_host[h] = true end

local feeds = larper.storage.get("feeds") or {}
local seen = larper.storage.get("seen") or {}
local items = {}
local meta = {}
local note = nil
local show = "all"
local queue = {}
local queued = {}
local flying = 0
local retry = nil

local draw

local function trim(s) return ((s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end

local function is_pt() return (larper.lang() or ""):match("^pt") ~= nil end

local function cut(text, max)
  if #text <= max then return text end
  local n = max
  while n > 0 and (text:byte(n + 1) or 0) & 0xC0 == 0x80 do n = n - 1 end
  return text:sub(1, n) .. "…"
end

-- Um número curto no lugar do id inteiro: a lista de vistos cabe folgada no storage.
local function hash(s)
  local h = 5381
  for i = 1, #s do h = (h * 33 + s:byte(i)) & 0xffffffff end
  return string.format("%08x", h)
end

-- --- XML: RSS 2.0 e Atom -----------------------------------------------------------------

local NAMED = {
  amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = " ", hellip = "…", mdash = "—", ndash = "–",
  lsquo = "‘", rsquo = "’", ldquo = "“", rdquo = "”", laquo = "«", raquo = "»", middot = "·", bull = "•",
  copy = "©", reg = "®", trade = "™", deg = "°", euro = "€",
  aacute = "á", agrave = "à", acirc = "â", atilde = "ã", auml = "ä", ccedil = "ç", eacute = "é", egrave = "è",
  ecirc = "ê", iacute = "í", oacute = "ó", ocirc = "ô", otilde = "õ", ouml = "ö", uacute = "ú", uuml = "ü", ntilde = "ñ",
  Aacute = "Á", Agrave = "À", Acirc = "Â", Atilde = "Ã", Ccedil = "Ç", Eacute = "É", Ecirc = "Ê", Iacute = "Í",
  Oacute = "Ó", Ocirc = "Ô", Otilde = "Õ", Uacute = "Ú",
}

local function entity(name)
  local num = name:match("^#[xX](%x+)$")
  local cp = num and tonumber(num, 16) or tonumber(name:match("^#(%d+)$") or "")
  if cp then
    if cp > 0 and cp <= 0x10FFFF and not (cp >= 0xD800 and cp <= 0xDFFF) then return utf8.char(cp) end
    return ""
  end
  return NAMED[name]
end

local function unescape(s)
  return (s:gsub("&(#?[%w]+);", function(name) return entity(name) end))
end

-- O texto de um elemento: CDATA como está, o resto sem entidades, sem tags de HTML (título
-- do tipo html) e com os espaços juntados.
local function text(raw)
  if not raw then return nil end
  local parts, pos = {}, 1
  while true do
    local s, e, inner = raw:find("<!%[CDATA%[(.-)%]%]>", pos)
    if not s then
      parts[#parts + 1] = unescape(raw:sub(pos))
      break
    end
    parts[#parts + 1] = unescape(raw:sub(pos, s - 1))
    parts[#parts + 1] = inner
    pos = e + 1
  end
  local t = table.concat(parts):gsub("<[^>]*>", "")
  -- Muito feed codifica o HTML duas vezes ("&amp;#8217;").
  if t:find("&", 1, true) then t = unescape(t) end
  return (t:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))
end

local function element(block, name)
  return block:match("<" .. name .. "%f[%s>][^>]*>(.-)</" .. name .. ">")
end

local function attr(attrs, name)
  return attrs:match(name .. '%s*=%s*"([^"]*)"') or attrs:match(name .. "%s*=%s*'([^']*)'")
end

-- No Atom o link vem em <link href="..."/>; vale o rel="alternate" (ou sem rel).
local function atom_link(block)
  local other
  for attrs in block:gmatch("<link%f[%s/>]([^>]*)>") do
    local href = attr(attrs, "href")
    local rel = attr(attrs, "rel")
    if href and (not rel or rel == "alternate") then return unescape(href) end
    other = other or href
  end
  return other and unescape(other)
end

local MON = { jan = 1, feb = 2, mar = 3, apr = 4, may = 5, jun = 6, jul = 7, aug = 8, sep = 9, oct = 10, nov = 11, dec = 12 }
local ZONES = { GMT = 0, UT = 0, UTC = 0, Z = 0, EST = -5, EDT = -4, CST = -6, CDT = -5, MST = -7, MDT = -6, PST = -8, PDT = -7 }

-- Dias desde 1970 de uma data do calendário, sem depender do fuso do computador.
local function days(y, m, d)
  if m <= 2 then y = y - 1 end
  local era = (y >= 0 and y or y - 399) // 400
  local yoe = y - era * 400
  local doy = (153 * (m + (m > 2 and -3 or 9)) + 2) // 5 + d - 1
  return era * 146097 + yoe * 365 + yoe // 4 - yoe // 100 + doy - 719468
end

local function offset(sign, hh, mm)
  return (tonumber(hh) * 3600 + tonumber(mm) * 60) * (sign == "-" and -1 or 1)
end

-- "2026-11-27T16:08:25+00:00" (Atom) ou "Fri, 27 Nov 2026 23:50:17 +0000" (RSS).
local function parse_date(s)
  if not s then return nil end
  local y, mo, d, h, mi, sec, rest = s:match("(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):?(%d*)[%.%d]*(.*)")
  local off = 0
  if y then
    local sign, oh, om = rest:match("([+-])(%d%d):?(%d%d)")
    if sign then off = offset(sign, oh, om) end
  else
    local mon
    d, mon, y, h, mi, sec, rest = s:match("(%d%d?)%s+(%a%a%a)%a*%s+(%d%d%d%d)%s+(%d%d?):(%d%d):?(%d*)%s*(%S*)")
    mo = mon and MON[mon:lower()]
    if not mo then return nil end
    local sign, oh, om = rest:match("^([+-])(%d%d)(%d%d)$")
    if sign then off = offset(sign, oh, om) elseif ZONES[rest] then off = ZONES[rest] * 3600 end
  end
  return days(tonumber(y), tonumber(mo), tonumber(d)) * 86400 + tonumber(h) * 3600 + tonumber(mi) * 60 + (tonumber(sec) or 0) - off
end

local function web(link)
  if type(link) == "string" and link:match("^https?://[%w%-%.]+") then return link end
end

-- { title, items = { { id, title, link, t } } }, ou nil se não for RSS nem Atom.
local function parse(xml)
  if type(xml) ~= "string" then return nil end
  local atom = xml:find("<entry%f[%s>]") ~= nil
  local tag = atom and "entry" or "item"
  local first = xml:find("<" .. tag .. "%f[%s>]")
  local is_feed = first or xml:find("<rss%f[%s>]") or xml:find("<feed%f[%s>]") or xml:find("<rdf:RDF%f[%s>]")
  if not is_feed then return nil end
  local feed = { title = text(element(first and xml:sub(1, first - 1) or xml, "title")) or "", items = {} }
  for block in xml:gmatch("<" .. tag .. "%f[%s>][^>]*>(.-)</" .. tag .. ">") do
    local it = { title = text(element(block, "title")) or "" }
    if atom then
      it.link = atom_link(block)
      it.id = text(element(block, "id"))
      it.t = parse_date(text(element(block, "published")) or text(element(block, "updated")))
    else
      it.link = text(element(block, "link"))
      local guid = text(element(block, "guid"))
      if (not it.link or it.link == "") and web(guid) then it.link = guid end
      it.id = guid
      it.t = parse_date(text(element(block, "pubDate")) or text(element(block, "dc:date")))
    end
    it.link = web(it.link)
    if not it.id or it.id == "" then it.id = it.link or it.title end
    if it.title == "" then it.title = it.link or "" end
    if it.id ~= "" and it.title ~= "" then
      it.h = hash(it.id)
      feed.items[#feed.items + 1] = it
      if #feed.items >= MAX_ITEMS then break end
    end
  end
  return feed
end

-- --- Feeds -------------------------------------------------------------------------------

local function host_of(url) return url:match("^https://([^/?#]+)") end

local function find(url)
  for i, f in ipairs(feeds) do
    if f.url == url then return i, f end
  end
end

local function save() larper.storage.set("feeds", feeds) end
local function save_seen() larper.storage.set("seen", seen) end

-- Marca como vistos e devolve os que eram novos.
local function mark(url, list)
  local known, set, news = seen[url] or {}, {}, {}
  for _, h in ipairs(known) do set[h] = true end
  for _, it in ipairs(list) do
    if not set[it.h] then
      set[it.h] = true
      known[#known + 1] = it.h
      news[#news + 1] = it
    end
  end
  while #known > MAX_SEEN do table.remove(known, 1) end
  seen[url] = known
  return news
end

local function feed_name(f) return (f.title and f.title ~= "") and f.title or host_of(f.url) or f.url end

local function announce(f, news)
  local parts = {}
  for i, it in ipairs(news) do
    if i > 3 then
      parts[#parts + 1] = "…"
      break
    end
    parts[#parts + 1] = cut(it.title, 80)
  end
  local head = "📰 " .. cut(feed_name(f), 60)
  if #news == 1 then
    larper.notify(head .. ": " .. parts[1])
  else
    larper.notify(head .. tr(": " .. #news .. " novos — ", ": " .. #news .. " new — ") .. table.concat(parts, " · "))
  end
end

local function failure(res, url)
  if res.error == "not_approved" then
    local h = host_of(url) or ""
    return { pt = "Aprove " .. h .. " em Configurações → Plugins.", en = "Approve " .. h .. " in Settings → Plugins." }
  end
  if res.error == "network" then return { pt = "Sem conexão.", en = "No connection." } end
  if res.error == "too_big" then return { pt = "Feed grande demais (mais de 1 MB).", en = "Feed too big (over 1 MB)." } end
  if res.error == "redirect" then return { pt = "O site mandou para outro endereço, fora da lista.", en = "The site redirected to another address, outside the list." } end
  if res.error then return { pt = "Erro: " .. res.error .. ".", en = "Error: " .. res.error .. "." } end
  return { pt = "O site não respondeu (" .. tostring(res.status) .. ").", en = "The site didn't answer (" .. tostring(res.status) .. ")." }
end

local NOT_FEED = { pt = "Isso não parece um feed RSS ou Atom.", en = "That doesn't look like an RSS or Atom feed." }

-- done(feed) ou done(nil, motivo). 304 devolve done(true): nada mudou.
local function fetch(url, done)
  local m = meta[url] or {}
  meta[url] = m
  local headers = { Accept = "application/rss+xml, application/atom+xml, application/xml;q=0.9, text/xml;q=0.8" }
  -- Só pergunta "mudou?" quando já tem os itens na memória para mostrar.
  if items[url] then
    if m.etag then headers["If-None-Match"] = m.etag end
    if m.modified then headers["If-Modified-Since"] = m.modified end
  end
  larper.http.get(url, { headers = headers }, function(res)
    if res.status == 304 then return done(true) end
    if not res.ok then return done(nil, res.error == "rate_limited" and "rate_limited" or failure(res, url)) end
    local feed = parse(res.body)
    if not feed then return done(nil, NOT_FEED) end
    local h = res.headers or {}
    m.etag = type(h.etag) == "string" and h.etag or nil
    m.modified = type(h["last-modified"]) == "string" and h["last-modified"] or nil
    done(feed)
  end)
end

local pump

local function settle(f, feed, why)
  local m = meta[f.url] or {}
  meta[f.url] = m
  if why == "rate_limited" then
    -- Volta para a fila e tenta em um minuto.
    if not queued[f.url] then
      queue[#queue + 1] = f
      queued[f.url] = true
    end
    if not retry then
      retry = larper.after(60, function()
        retry = nil
        pump()
      end)
    end
    return
  end
  if not feed then
    m.status = why
    draw()
    return
  end
  m.status = nil
  m.checked = os.time()
  if feed ~= true then
    local first = seen[f.url] == nil
    if feed.title ~= "" and feed.title ~= f.title then
      f.title = feed.title
      save()
    end
    items[f.url] = feed.items
    local news = mark(f.url, feed.items)
    save_seen()
    -- Na primeira vez tudo é novo: só guarda, sem avisar.
    if not first and #news > 0 then announce(f, news) end
  end
  draw()
end

pump = function()
  -- Depois de um rate_limited, a fila espera o minuto passar.
  if retry then return end
  while flying < IN_FLIGHT and #queue > 0 do
    local f = table.remove(queue, 1)
    queued[f.url] = nil
    if find(f.url) then
      local host = host_of(f.url)
      if not larper.http.allowed(host) then
        meta[f.url] = meta[f.url] or {}
        meta[f.url].status = failure({ error = "not_approved" }, f.url)
      else
        flying = flying + 1
        fetch(f.url, function(feed, why)
          flying = flying - 1
          settle(f, feed, why)
          pump()
        end)
      end
    end
  end
end

local function poll_all()
  for _, f in ipairs(feeds) do
    if not queued[f.url] then
      queue[#queue + 1] = f
      queued[f.url] = true
    end
  end
  pump()
  draw()
end

-- O endereço como o plugin vai pedir e o host, ou nil, o motivo e o host.
local function normalize(input)
  local u = trim(input)
  if u == "" then return nil end
  if not u:match("^%a[%w+.-]*://") then u = "https://" .. u end
  u = u:gsub("^[Hh][Tt][Tt][Pp]://", "https://")
  local scheme, host, rest = u:match("^(%a[%w+.-]*)://([^/?#]+)(.*)$")
  if not scheme or scheme:lower() ~= "https" or host:find("[@:]") then return nil, "bad" end
  host = host:lower()
  rest = rest:gsub("#.*$", "")
  if host == "youtube.com" or host == "m.youtube.com" then host = "www.youtube.com" end
  -- Página de um canal do YouTube: vira o feed dele.
  if host == "www.youtube.com" then
    local channel = rest:match("^/channel/(UC[%w_%-]+)")
    if channel then rest = "/feeds/videos.xml?channel_id=" .. channel end
  end
  if rest:find("[%s\"<>{}|\\^`]") then return nil, "bad" end
  if rest == "" then rest = "/" end
  if not allowed_host[host] then return nil, "host", host end
  return "https://" .. host .. rest, nil, host
end

local function add(input)
  local url, why, host = normalize(input)
  if not url then
    if why == "host" then
      note = { style = "danger",
        pt = host .. " não está na lista do plugin. Dá para assinar: " .. table.concat(HOSTS, ", ") .. ". Para outro site, edite a linha @hosts do arquivo feeds.lua.",
        en = host .. " isn't on the plugin's list. You can subscribe to: " .. table.concat(HOSTS, ", ") .. ". For another site, edit the @hosts line in feeds.lua." }
    elseif why == "bad" then
      note = { style = "danger", pt = "Endereço inválido. Use um link https:// do feed.", en = "Invalid address. Use the feed's https:// link." }
    end
    draw()
    return
  end
  if find(url) then
    note = { style = "muted", pt = "Esse feed já está na lista.", en = "That feed is already on the list." }
    draw()
    return
  end
  if #feeds >= MAX_FEEDS then
    note = { style = "danger", pt = "A lista vai até 20 feeds.", en = "The list holds up to 20 feeds." }
    draw()
    return
  end
  if not larper.http.allowed(host) then
    -- Fica na lista; com o host aprovado, o plugin busca sozinho.
    feeds[#feeds + 1] = { url = url }
    save()
    note = { style = "accent", pt = "Feed adicionado. Aprove " .. host .. " em Configurações → Plugins para buscar.",
      en = "Feed added. Approve " .. host .. " in Settings → Plugins to fetch it." }
    meta[url] = { status = failure({ error = "not_approved" }, url) }
    draw()
    return
  end
  note = { style = "muted", pt = "Buscando…", en = "Fetching…" }
  draw()
  fetch(url, function(feed, why2)
    if not feed or feed == true then
      local reason = why2 == "rate_limited" and { pt = "Pedidos demais agora; tente de novo daqui a pouco.", en = "Too many requests right now; try again in a moment." } or why2 or NOT_FEED
      note = { style = "danger", pt = reason.pt, en = reason.en }
      draw()
      return
    end
    if find(url) then return end
    local f = { url = url, title = feed.title ~= "" and feed.title or nil }
    feeds[#feeds + 1] = f
    save()
    items[url] = feed.items
    mark(url, feed.items)
    save_seen()
    meta[url] = meta[url] or {}
    meta[url].checked = os.time()
    note = { style = "accent", pt = "Adicionado: " .. feed_name(f) .. " (" .. #feed.items .. " itens).",
      en = "Added: " .. feed_name(f) .. " (" .. #feed.items .. " items)." }
    draw()
  end)
end

local function remove(url)
  local i = find(url)
  if not i then return end
  table.remove(feeds, i)
  seen[url], items[url], meta[url] = nil, nil, nil
  if show == url then show = "all" end
  save()
  save_seen()
  draw()
end

-- --- Painel ------------------------------------------------------------------------------

local function when(t)
  if not t then return "" end
  if os.date("%Y%m%d", t) == os.date("%Y%m%d") then return os.date("%H:%M", t) end
  return os.date(is_pt() and "%d/%m %H:%M" or "%b %d %H:%M", t)
end

local function safe(s) return (s:gsub("@(%a)", "@\u{200B}%1")) end

local function share(it)
  if not larper.channel() then
    larper.notify(tr("Abra um canal primeiro", "Open a channel first"))
    return
  end
  larper.send(nil, safe(cut(it.title, 300)) .. "\n" .. it.link)
end

local function feed_row(f)
  local m = meta[f.url] or {}
  local sub
  if m.status then
    sub = tr(m.status)
  elseif items[f.url] then
    sub = tr(#items[f.url] .. " itens", #items[f.url] .. " items")
    if m.checked then sub = sub .. tr(" · conferido às ", " · checked at ") .. os.date("%H:%M", m.checked) end
  else
    sub = tr("Ainda não buscado.", "Not fetched yet.")
  end
  return { title = feed_name(f), subtitle = sub, meta = host_of(f.url) or "", key = "feed" .. hash(f.url),
    actions = { { label = tr("Remover", "Remove"), style = "danger", key = "rm" .. hash(f.url), on_click = function() remove(f.url) end } } }
end

local function shown_items()
  local out = {}
  for fi, f in ipairs(feeds) do
    if show == "all" or show == f.url then
      for ii, it in ipairs(items[f.url] or {}) do out[#out + 1] = { it = it, f = f, order = fi * 1000 + ii } end
    end
  end
  table.sort(out, function(a, b)
    local ta, tb = a.it.t or -math.huge, b.it.t or -math.huge
    if ta ~= tb then return ta > tb end
    return a.order < b.order
  end)
  while #out > MAX_SHOWN do table.remove(out) end
  return out
end

draw = function()
  local tree = { title = "Feeds" }
  if note then tree[#tree + 1] = { type = "text", style = note.style, text = tr({ pt = note.pt, en = note.en }) } end
  tree[#tree + 1] = { type = "input", key = "add", clear = true,
    placeholder = tr("Endereço do feed ou de um canal do YouTube (Enter)", "Feed address or a YouTube channel link (Enter)"),
    on_submit = add }
  tree[#tree + 1] = { type = "text", style = "muted", text = tr("Sites aceitos: ", "Accepted sites: ") .. table.concat(HOSTS, ", ") }
  local rows = {}
  for _, f in ipairs(feeds) do rows[#rows + 1] = feed_row(f) end
  tree[#tree + 1] = { type = "list", key = "feeds", items = rows,
    empty = tr("Nenhum feed ainda. Cole o endereço de um acima.", "No feeds yet. Paste one's address above.") }
  if #feeds > 1 then
    local options = { { value = "all", label = tr("Todos", "All") } }
    for _, f in ipairs(feeds) do options[#options + 1] = { value = f.url, label = cut(feed_name(f), 60) } end
    tree[#tree + 1] = { type = "select", key = "show", label = tr("Mostrar", "Show"), value = show, options = options,
      on_change = function(v)
        show = (v == "all" or find(v)) and v or "all"
        draw()
      end }
  end
  if #feeds > 0 then
    tree[#tree + 1] = { type = "heading", text = tr("Itens", "Items") }
    local list = {}
    for _, e in ipairs(shown_items()) do
      local it = e.it
      local k = hash(e.f.url) .. it.h
      local actions
      if it.link then
        actions = {
          { label = tr("Abrir", "Open"), key = "open" .. k, on_click = function() larper.open(it.link) end },
          { label = tr("Compartilhar no canal", "Share in channel"), key = "share" .. k, on_click = function() share(it) end },
        }
      end
      list[#list + 1] = { title = it.title, subtitle = feed_name(e.f), meta = when(it.t), key = "it" .. k, actions = actions }
    end
    tree[#tree + 1] = { type = "list", key = "items", items = list, empty = tr("Nada por aqui ainda.", "Nothing here yet.") }
  end
  tree[#tree + 1] = { type = "row", { type = "button", key = "refresh", label = tr("Atualizar", "Refresh"), on_click = poll_all } }
  larper.panel.set(tree)
end

larper.command("/feeds", function()
  draw()
  larper.panel.open()
end)

larper.on("hosts", poll_all)
larper.on("lang", draw)

larper.every(EVERY, poll_all)
draw()
poll_all()
