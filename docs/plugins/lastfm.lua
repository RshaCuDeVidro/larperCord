-- @name Last.fm
-- @name:pt Last.fm
-- @description /np shares what you're playing on Last.fm, and the panel shows the song with lyrics from lrclib.net while it's open. Set your user and API key below: the key stays in the system keyring and only goes to ws.audioscrobbler.com. Nothing goes out before you approve the hosts.
-- @description:pt /np mostra o que você ouve no Last.fm, e o painel mostra a música com a letra do lrclib.net enquanto está aberto. Configure aqui o usuário e a chave da API: a chave fica no chaveiro do sistema e só vai para ws.audioscrobbler.com. Nada sai antes de aprovar os hosts.
-- @version 1.0.0
-- @capabilities send, composer, panel, settings, secrets, storage, http, timers, notify
-- @hosts ws.audioscrobbler.com, lrclib.net

local tr = larper.tr
local FM_HOST = "ws.audioscrobbler.com"
local LRC_HOST = "lrclib.net"
local FM = "https://" .. FM_HOST .. "/2.0/?method=user.getrecenttracks&format=json&limit=1"
local LRC = "https://" .. LRC_HOST .. "/api/"
-- /np manda direto só com a música buscada há menos disso.
local FRESH = 60
local PANEL_EVERY = 30
local MAX_LYRICS = 20
local MAX_LINES = 400

local key = larper.secrets.get("api_key")
local user = larper.storage.get("user")
local now = nil
local status = nil
local lyrics = {}
local lyrics_order = {}
local loop = nil
local busy = false

local draw

local function trim(s) return ((s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end

local function decode(body)
  local ok, d = pcall(larper.json.decode, body)
  if ok and type(d) == "table" then return d end
end

local function valid_user(u)
  return #u >= 2 and #u <= 32 and u:match("^[%w][%w_%-%.]*$") ~= nil
end

-- Negrito sem quebrar com * ou _ no nome, e sem chamar ninguém.
local function safe(text)
  text = text:gsub("[\\*_~`|>]", "\\%0")
  return (text:gsub("@(%a)", "@\u{200B}%1"))
end

local function np_text(t)
  local song = "**" .. safe(t.name) .. "**"
  if t.artist ~= "" then song = song .. " – " .. safe(t.artist) end
  if t.playing then return tr("🎵 ouvindo ", "🎵 listening to ") .. song end
  return tr("🎵 ouviu por último ", "🎵 last listened to ") .. song
end

local CONFIG = { pt = "Configure o usuário e a chave da API do Last.fm no cartão do plugin, em Configurações → Plugins.",
  en = "Set your Last.fm user and API key on the plugin's card, in Settings → Plugins." }

local function fm_failure(res, d)
  if res.error == "not_approved" then return { pt = "Aprove " .. FM_HOST .. " em Configurações → Plugins.", en = "Approve " .. FM_HOST .. " in Settings → Plugins." } end
  if res.error == "network" then return { pt = "Sem conexão com o Last.fm.", en = "Can't reach Last.fm." } end
  if res.error == "rate_limited" then return { pt = "Pedidos demais agora; tente de novo daqui a pouco.", en = "Too many requests right now; try again in a moment." } end
  local code = d and math.tointeger(d.error)
  if code == 10 or code == 26 then return { pt = "O Last.fm recusou a chave da API. Confira no cartão do plugin.", en = "Last.fm refused the API key. Check it on the plugin's card." } end
  if code == 6 then return { pt = "Usuário \"" .. (user or "") .. "\" não encontrado no Last.fm.", en = "User \"" .. (user or "") .. "\" not found on Last.fm." } end
  if code == 17 then return { pt = "Esse perfil do Last.fm esconde o que ouve.", en = "That Last.fm profile hides what it listens to." } end
  if code == 29 or res.status == 429 then return { pt = "O Last.fm pediu para esperar um pouco.", en = "Last.fm asked to wait a little." } end
  if res.error then return { pt = "Resposta estranha do Last.fm (" .. res.error .. ").", en = "Odd answer from Last.fm (" .. res.error .. ")." } end
  return { pt = "O Last.fm não respondeu (" .. tostring(res.status) .. ").", en = "Last.fm didn't answer (" .. tostring(res.status) .. ")." }
end

local function text_of(v)
  if type(v) == "table" then v = v["#text"] or v.name end
  return type(v) == "string" and v or ""
end

-- A música mais nova; false quando a conta ainda não ouviu nada.
local function read_recent(d)
  local rt = type(d.recenttracks) == "table" and d.recenttracks
  if not rt then return nil end
  local list = rt.track
  if type(list) ~= "table" then return false end
  -- Com uma música só, o JSON do Last.fm às vezes vem como objeto, não lista.
  if list.name then list = { list } end
  local t = list[1]
  if type(t) ~= "table" or type(t.name) ~= "string" or t.name == "" then return false end
  local attr = type(t["@attr"]) == "table" and t["@attr"] or {}
  return {
    name = t.name,
    artist = text_of(t.artist),
    album = text_of(t.album),
    playing = attr.nowplaying == "true",
    uts = type(t.date) == "table" and tonumber(t.date.uts) or nil,
    at = os.time(),
  }
end

-- done(música) ou done(nil, motivo); motivo "empty" quando não há nada.
local function fetch_now(done)
  if not user or not key then return done(nil, CONFIG) end
  if not larper.http.allowed(FM_HOST) then return done(nil, fm_failure({ error = "not_approved" })) end
  larper.http.get(FM .. "&user=" .. larper.urlencode(user) .. "&api_key=" .. larper.urlencode(key), function(res)
    local d = decode(res.body)
    local t = res.ok and d and read_recent(d)
    if t then
      now = t
      return done(t)
    end
    if res.ok and t == false then return done(nil, "empty") end
    done(nil, fm_failure(res, d))
  end)
end

-- --- Letras ------------------------------------------------------------------------------

local function lyric_key(t) return (t.artist .. "\n" .. t.name):lower() end

local function keep_lyrics(k, entry)
  if not lyrics[k] then
    lyrics_order[#lyrics_order + 1] = k
    if #lyrics_order > MAX_LYRICS then lyrics[table.remove(lyrics_order, 1)] = nil end
  end
  lyrics[k] = entry
end

local function lyric_entry(d)
  if type(d) ~= "table" then return nil end
  if d.instrumental == true then return { instrumental = true } end
  if type(d.plainLyrics) == "string" and d.plainLyrics:find("%S") then return { text = d.plainLyrics } end
end

local function lyrics_for(t)
  local k = lyric_key(t)
  local e = lyrics[k]
  if e and not (e.failed and os.time() - e.at >= 300) then return end
  if not larper.http.allowed(LRC_HOST) then
    keep_lyrics(k, { failed = { pt = "Aprove " .. LRC_HOST .. " em Configurações → Plugins para ver a letra.", en = "Approve " .. LRC_HOST .. " in Settings → Plugins to see the lyrics." }, at = -math.huge })
    return
  end
  keep_lyrics(k, { loading = true })
  local q = "artist_name=" .. larper.urlencode(t.artist) .. "&track_name=" .. larper.urlencode(t.name)
  local function fail(res)
    if res.error == "rate_limited" then
      -- Pedidos demais de uma vez: a próxima atualização do painel tenta de novo.
      lyrics[k] = { failed = { pt = "Buscando a letra…", en = "Looking for the lyrics…" }, at = -math.huge }
      return
    end
    local why = res.error == "network" and { pt = "Sem conexão com o lrclib.net.", en = "Can't reach lrclib.net." }
      or { pt = "O lrclib.net não respondeu (" .. (res.error or tostring(res.status)) .. ").", en = "lrclib.net didn't answer (" .. (res.error or tostring(res.status)) .. ")." }
    keep_lyrics(k, { failed = why, at = os.time() })
    draw()
  end
  local function search()
    larper.http.get(LRC .. "search?" .. q, function(res)
      if not res.ok then return fail(res) end
      local list = decode(res.body)
      local found
      for _, d in ipairs(list or {}) do
        found = lyric_entry(d)
        if found then break end
      end
      keep_lyrics(k, found or { none = true })
      draw()
    end)
  end
  -- Com o álbum é mais certeiro; sem ele (ou com outro nome de álbum) vai pela busca.
  local exact = q
  if t.album ~= "" then exact = exact .. "&album_name=" .. larper.urlencode(t.album) end
  larper.http.get(LRC .. "get?" .. exact, function(res)
    local found = res.ok and lyric_entry(decode(res.body))
    if found then
      keep_lyrics(k, found)
      draw()
    elseif res.ok or res.status == 404 then
      search()
    else
      fail(res)
    end
  end)
end

local function refresh()
  if busy then return end
  busy = true
  fetch_now(function(t, why)
    busy = false
    if t then
      status = nil
      lyrics_for(t)
    elseif why == "empty" then
      status = { pt = "Essa conta ainda não ouviu nada.", en = "That account hasn't listened to anything yet." }
      now = nil
    else
      status = why
    end
    draw()
  end)
end

-- --- Painel e cartão ---------------------------------------------------------------------

draw = function()
  local tree = { title = "Last.fm" }
  if status then tree[#tree + 1] = { type = "text", style = "danger", text = tr(status) } end
  if now then
    tree[#tree + 1] = { type = "heading", text = now.name }
    local by = now.artist
    if now.album ~= "" then by = by .. " · " .. now.album end
    tree[#tree + 1] = { type = "text", style = "muted", text = by }
    local when
    if now.playing then
      when = tr("Tocando agora", "Playing now")
    elseif not now.uts then
      when = tr("Ouviu por último", "Last played")
    elseif os.date("%Y%m%d", now.uts) == os.date("%Y%m%d") then
      when = tr("Ouviu por último às ", "Last played at ") .. os.date("%H:%M", now.uts)
    else
      local pt = (larper.lang() or ""):match("^pt")
      when = tr("Ouviu por último em ", "Last played on ") .. os.date(pt and "%d/%m %H:%M" or "%b %d %H:%M", now.uts)
    end
    tree[#tree + 1] = { type = "text", style = now.playing and "accent" or "muted", text = when }
    tree[#tree + 1] = { type = "separator" }
    local e = lyrics[lyric_key(now)]
    if not e or e.loading then
      tree[#tree + 1] = { type = "text", style = "muted", text = tr("Buscando a letra…", "Looking for the lyrics…") }
    elseif e.failed then
      tree[#tree + 1] = { type = "text", style = "muted", text = tr(e.failed) }
    elseif e.none then
      tree[#tree + 1] = { type = "text", style = "muted", text = tr("Letra não encontrada no lrclib.net.", "Lyrics not found on lrclib.net.") }
    elseif e.instrumental then
      tree[#tree + 1] = { type = "text", style = "muted", text = tr("Instrumental.", "Instrumental.") }
    else
      local n = 0
      for line in (e.text .. "\n"):gmatch("(.-)\r?\n") do
        n = n + 1
        if n > MAX_LINES then break end
        tree[#tree + 1] = { type = "text", text = line ~= "" and line or " " }
      end
      tree[#tree + 1] = { type = "text", style = "muted", text = tr("Letra: lrclib.net", "Lyrics: lrclib.net") }
    end
  elseif not status then
    tree[#tree + 1] = { type = "text", style = "muted", text = (user and key) and tr("Abra o painel para ver a música atual.", "Open the panel to see the current song.") or tr(CONFIG) }
  end
  tree[#tree + 1] = { type = "row", { type = "button", key = "refresh", label = tr("Atualizar", "Refresh"), on_click = refresh } }
  larper.panel.set(tree)
end

local options

local function set_user(v, loud)
  local u = trim(v)
  if u ~= "" and not valid_user(u) then
    if loud then larper.notify(tr("Esse nome de usuário do Last.fm não vale", "That's not a valid Last.fm user name")) end
    return
  end
  if u == "" then u = nil end
  if u == user then return end
  user = u
  larper.storage.set("user", u)
  now = nil
  status = nil
  draw()
end

local function save_key(text)
  text = trim(text)
  if not text:match("^%x+$") or #text ~= 32 then
    larper.notify(tr("Isso não parece uma chave da API do Last.fm (32 letras e números)", "That doesn't look like a Last.fm API key (32 letters and digits)"))
    return
  end
  if not pcall(larper.secrets.set, "api_key", text) then
    larper.notify(tr("O chaveiro do sistema recusou a chave", "The system keyring refused the key"))
    return
  end
  key = text
  status = nil
  options()
  draw()
end

options = function()
  local list = {
    { type = "input", key = "user", value = user or "", placeholder = tr("Seu usuário do Last.fm", "Your Last.fm user"),
      on_change = function(v) set_user(v, false) end,
      on_submit = function(v) set_user(v, true) end },
  }
  if key then
    list[#list + 1] = { type = "text", text = tr("Chave salva", "Key saved") }
    list[#list + 1] = { type = "row",
      { type = "button", key = "forget", style = "danger", label = tr("Remover chave", "Remove key"), on_click = function()
        pcall(larper.secrets.delete, "api_key")
        key = nil
        now = nil
        status = nil
        options()
        draw()
      end } }
  else
    list[#list + 1] = { type = "input", key = "apikey", clear = true,
      placeholder = tr("Chave da API do Last.fm (Enter para salvar)", "Last.fm API key (Enter to save)"),
      on_submit = save_key }
    list[#list + 1] = { type = "text", style = "muted", text = tr(
      "Crie uma em last.fm/api/account/create. Ela fica no chaveiro do sistema e só vai para " .. FM_HOST .. ".",
      "Create one at last.fm/api/account/create. It stays in the system keyring and only goes to " .. FM_HOST .. ".") }
  end
  larper.settings.set(list)
end

larper.command("/np", function()
  if not user or not key then
    larper.notify(tr(CONFIG))
    return
  end
  -- Buscada agora há pouco: dá para mandar direto, ainda no gesto.
  if now and os.time() - now.at < FRESH then
    larper.send(nil, np_text(now))
    return
  end
  -- Senão a resposta vai para a caixa de mensagem, e quem envia é você.
  fetch_now(function(t, why)
    if t then
      larper.insert(np_text(t))
      draw()
    elseif why == "empty" then
      larper.notify(tr("Essa conta ainda não ouviu nada", "That account hasn't listened to anything yet"))
    else
      larper.notify(tr(why))
    end
  end)
end)

-- Só busca enquanto o painel está na tela.
larper.on("panel", function(open)
  if loop then larper.cancel(loop) end
  loop = nil
  if open then
    refresh()
    loop = larper.every(PANEL_EVERY, refresh)
  end
end)
larper.on("hosts", function()
  for k, e in pairs(lyrics) do
    if e.failed then e.at = -math.huge end
  end
  if loop then refresh() end
end)
larper.on("lang", function()
  options()
  draw()
end)

options()
draw()
