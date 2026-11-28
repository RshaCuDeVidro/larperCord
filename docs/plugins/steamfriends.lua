-- @name Steam friends
-- @name:pt Amigos na Steam
-- @description A panel with which Steam friends are online and what they're playing, which Discord doesn't give plugins. Needs your Steam Web API key, kept in the system keyring and sent only to api.steampowered.com once you approve it below. Checks every 2 minutes. /steam opens it.
-- @description:pt Um painel com quem dos seus amigos da Steam está online e o que está jogando, que o Discord não passa para plugins. Precisa da sua chave da Steam Web API, guardada no chaveiro do sistema e enviada só para api.steampowered.com depois de aprovar aqui. /steam abre.
-- @version 1.0.0
-- @capabilities panel, settings, secrets, storage, http, timers, notify
-- @hosts api.steampowered.com

local tr = larper.tr
local HOST = "api.steampowered.com"
local API = "https://" .. HOST .. "/ISteamUser/"
local EVERY = 120
-- Abrir e fechar o painel várias vezes não vira uma enxurrada de pedidos.
local MIN_GAP = 20
-- A Steam aceita até 100 SteamIDs por pedido.
local MAX_WATCH = 100

-- A chave só existe no chaveiro: o app pergunta a ele a cada get, então fica aqui.
local key = larper.secrets.get("api_key")
local watch = larper.storage.get("watch") or {}
local notify_games = larper.storage.get("notify") == true
local info = {}
local status = nil
local updated_at = nil
local polling = false
-- Pedido de conferir enquanto outro estava no ar (alguém entrou na lista): roda depois.
local again = false
local last_poll = -math.huge
local hold_until = 0

-- personastate da Steam: 0 offline, 1 online, 2 ocupado, 3 ausente, 4 soneca,
-- 5 quer trocar, 6 quer jogar.
local STATES = {
  [0] = { pt = "offline", en = "offline" },
  [1] = { pt = "online", en = "online" },
  [2] = { pt = "ocupado", en = "busy" },
  [3] = { pt = "ausente", en = "away" },
  [4] = { pt = "ausente", en = "away" },
  [5] = { pt = "online", en = "online" },
  [6] = { pt = "online", en = "online" },
}
local RANK = { [1] = 1, [5] = 1, [6] = 1, [2] = 2, [3] = 3, [4] = 3, [0] = 4 }

local draw

local function save()
  larper.storage.set("watch", watch)
end

local function decode(body)
  local ok, d = pcall(larper.json.decode, body)
  if ok and type(d) == "table" then return d end
end

local function trim(s)
  return (s or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function find(id)
  for i, w in ipairs(watch) do
    if w.id == id then return i end
  end
end

-- O motivo de uma resposta ruim, para mostrar no painel.
local function failure(res)
  if res.error == "not_approved" then
    return { pt = "Aprove " .. HOST .. " em Configurações → Plugins.", en = "Approve " .. HOST .. " in Settings → Plugins." }
  elseif res.error == "network" then
    return { pt = "Sem conexão com a Steam.", en = "Can't reach Steam." }
  elseif res.error == "redirect" or res.error == "too_big" then
    return { pt = "Resposta estranha da Steam (" .. res.error .. ").", en = "Odd answer from Steam (" .. res.error .. ")." }
  elseif res.status == 401 or res.status == 403 then
    return { pt = "A Steam recusou a chave (" .. res.status .. "). Confira ou troque a chave no cartão do plugin.",
      en = "Steam refused the key (" .. res.status .. "). Check or replace the key on the plugin's card." }
  elseif res.status == 400 then
    return { pt = "A Steam recusou o pedido (400).", en = "Steam rejected the request (400)." }
  elseif res.status == 429 then
    hold_until = os.time() + 5 * 60
    return { pt = "A Steam pediu para esperar. Tento de novo em 5 minutos.", en = "Steam asked to wait. Trying again in 5 minutes." }
  end
  return { pt = "A Steam não respondeu (" .. tostring(res.status) .. ").", en = "Steam didn't answer (" .. tostring(res.status) .. ")." }
end

local function started(list)
  if #list == 1 then
    return tr("🎮 " .. list[1].name .. " começou a jogar " .. list[1].game, "🎮 " .. list[1].name .. " started playing " .. list[1].game)
  end
  local parts = {}
  for i, s in ipairs(list) do
    if i > 4 then
      parts[#parts + 1] = tr("e mais " .. (#list - 4), "and " .. (#list - 4) .. " more")
      break
    end
    parts[#parts + 1] = s.name .. " (" .. s.game .. ")"
  end
  return tr("🎮 Começaram a jogar: ", "🎮 Started playing: ") .. table.concat(parts, ", ")
end

local function apply(players)
  local news = {}
  local renamed = false
  for _, p in ipairs(players) do
    if type(p) == "table" and type(p.steamid) == "string" then
      local game = type(p.gameextrainfo) == "string" and p.gameextrainfo ~= "" and p.gameextrainfo or nil
      if not game and p.gameid then game = tr("um jogo", "a game") end
      local name = type(p.personaname) == "string" and p.personaname or p.steamid
      local old = info[p.steamid]
      if old and game and game ~= old.game then news[#news + 1] = { name = name, game = game } end
      info[p.steamid] = { name = name, state = math.tointeger(p.personastate) or 0, game = game }
      local i = find(p.steamid)
      if i and watch[i].name ~= name then
        watch[i].name = name
        renamed = true
      end
    end
  end
  if renamed then save() end
  if notify_games and #news > 0 then larper.notify(started(news)) end
end

local function poll(force)
  if not key or #watch == 0 then return end
  if polling then
    if force then again = true end
    return
  end
  local now = os.time()
  if now < hold_until then return end
  if not force and now - last_poll < MIN_GAP then return end
  if not larper.http.allowed(HOST) then
    status = failure({ error = "not_approved" })
    draw()
    return
  end
  local ids = {}
  for _, w in ipairs(watch) do ids[#ids + 1] = w.id end
  polling = true
  last_poll = now
  larper.http.get(API .. "GetPlayerSummaries/v2/?key=" .. larper.urlencode(key) .. "&steamids=" .. larper.urlencode(table.concat(ids, ",")), function(res)
    polling = false
    -- Pedidos demais de uma vez: a próxima rodada confere.
    if res.error ~= "rate_limited" then
      local d = res.ok and decode(res.body)
      local players = d and type(d.response) == "table" and d.response.players
      if type(players) ~= "table" then
        status = res.ok and { pt = "Resposta estranha da Steam.", en = "Odd answer from Steam." } or failure(res)
      else
        status = nil
        updated_at = os.time()
        apply(players)
      end
      draw()
    end
    if again then
      again = false
      poll(true)
    end
  end)
end

local function add_id(id, name)
  if find(id) then
    larper.notify(tr("Já está na lista", "Already on the list"))
    return
  end
  if #watch >= MAX_WATCH then
    larper.notify(tr("A lista vai até 100 pessoas", "The list holds up to 100 people"))
    return
  end
  watch[#watch + 1] = { id = id, name = name }
  save()
  draw()
  poll(true)
end

local function resolve(vanity)
  if not larper.http.allowed(HOST) then
    status = failure({ error = "not_approved" })
    larper.notify(tr(status))
    draw()
    return
  end
  larper.http.get(API .. "ResolveVanityURL/v1/?key=" .. larper.urlencode(key) .. "&vanityurl=" .. larper.urlencode(vanity), function(res)
    local d = res.ok and decode(res.body)
    local r = d and type(d.response) == "table" and d.response
    if r and r.success == 1 and type(r.steamid) == "string" and r.steamid:match("^%d+$") then
      add_id(r.steamid, vanity)
    elseif res.error == "rate_limited" then
      larper.notify(tr("Pedidos demais agora; tente de novo daqui a pouco", "Too many requests right now; try again in a moment"))
    elseif r then
      larper.notify(tr("Não achei o perfil \"" .. vanity .. "\" na Steam", "Couldn't find the profile \"" .. vanity .. "\" on Steam"))
    else
      status = res.ok and { pt = "Resposta estranha da Steam.", en = "Odd answer from Steam." } or failure(res)
      larper.notify(tr(status))
      draw()
    end
  end)
end

-- "76561197960435530", ".../profiles/7656...", ".../id/nome" ou só "nome".
local function add_from_input(text)
  text = trim(text)
  if text == "" then return end
  if not key then
    larper.notify(tr("Salve a chave da Steam Web API no cartão do plugin primeiro", "Save the Steam Web API key on the plugin's card first"))
    return
  end
  local id = text:match("steamcommunity%.com/profiles/(%d+)") or text:match("^(%d+)$")
  if id then
    if #id ~= 17 or id:sub(1, 4) ~= "7656" then
      larper.notify(tr("Um SteamID64 tem 17 dígitos e começa com 7656", "A SteamID64 has 17 digits and starts with 7656"))
      return
    end
    add_id(id, nil)
    return
  end
  local vanity = text:match("steamcommunity%.com/id/([%w_%-]+)") or text:match("^([%w_%-]+)$")
  if not vanity or #vanity < 2 or #vanity > 32 then
    larper.notify(tr("Use um SteamID64, o nome do perfil ou o link dele", "Use a SteamID64, the profile name or its link"))
    return
  end
  resolve(vanity)
end

local function remove(id)
  local i = find(id)
  if not i then return end
  table.remove(watch, i)
  info[id] = nil
  save()
  draw()
end

local function row(w)
  local p = info[w.id]
  local state = p and STATES[p.state] or nil
  local subtitle
  if p and p.game then
    subtitle = tr("jogando ", "playing ") .. p.game
  elseif state then
    subtitle = tr(state)
  else
    subtitle = tr("ainda sem notícia", "no news yet")
  end
  return {
    title = (p and p.name) or w.name or w.id,
    subtitle = subtitle,
    meta = p and p.game and "🎮" or (p and RANK[p.state] == 1 and "●" or ""),
    key = "f" .. w.id,
    actions = { { label = tr("Remover", "Remove"), style = "danger", key = "rm" .. w.id, on_click = function() remove(w.id) end } },
  }
end

local function rank(w)
  local p = info[w.id]
  if not p then return 5 end
  if p.game then return 0 end
  return RANK[p.state] or 4
end

draw = function()
  local tree = { title = tr("Amigos na Steam", "Steam friends") }
  if not key then
    tree[#tree + 1] = { type = "text", style = "accent", text = tr(
      "Salve a sua chave da Steam Web API no cartão do plugin, em Configurações → Plugins. Ela sai em steamcommunity.com/dev/apikey.",
      "Save your Steam Web API key on the plugin's card, in Settings → Plugins. You get one at steamcommunity.com/dev/apikey.") }
  end
  if status then tree[#tree + 1] = { type = "text", style = "danger", text = tr(status) } end
  tree[#tree + 1] = { type = "input", key = "add", clear = true,
    placeholder = tr("SteamID64, nome do perfil ou link (Enter)", "SteamID64, profile name or link (Enter)"),
    on_submit = add_from_input }
  local sorted = {}
  for _, w in ipairs(watch) do sorted[#sorted + 1] = w end
  table.sort(sorted, function(a, b)
    local ra, rb = rank(a), rank(b)
    if ra ~= rb then return ra < rb end
    local na = ((info[a.id] and info[a.id].name) or a.name or a.id):lower()
    local nb = ((info[b.id] and info[b.id].name) or b.name or b.id):lower()
    if na ~= nb then return na < nb end
    return a.id < b.id
  end)
  local items = {}
  for _, w in ipairs(sorted) do items[#items + 1] = row(w) end
  tree[#tree + 1] = { type = "list", key = "friends", items = items,
    empty = tr("Ninguém na lista ainda. Adicione um SteamID64 ou nome de perfil acima.", "Nobody on the list yet. Add a SteamID64 or profile name above.") }
  local foot = tr("Perfis privados aparecem offline.", "Private profiles show as offline.")
  if updated_at then foot = tr("Atualizado às ", "Updated at ") .. os.date("%H:%M", updated_at) .. " · " .. foot end
  tree[#tree + 1] = { type = "text", style = "muted", text = foot }
  tree[#tree + 1] = { type = "row", { type = "button", key = "refresh", label = tr("Atualizar", "Refresh"), on_click = function() poll(true) end } }
  larper.panel.set(tree)
end

local options

local function save_key(text)
  text = trim(text)
  if not text:match("^%x+$") or #text ~= 32 then
    larper.notify(tr("Isso não parece uma chave da Steam Web API (32 letras e números)", "That doesn't look like a Steam Web API key (32 letters and digits)"))
    return
  end
  local ok = pcall(larper.secrets.set, "api_key", text)
  if not ok then
    larper.notify(tr("O chaveiro do sistema recusou a chave", "The system keyring refused the key"))
    return
  end
  key = text
  status = nil
  options()
  draw()
  poll(true)
end

options = function()
  local list = {}
  if key then
    list[#list + 1] = { type = "text", text = tr("Chave salva", "Key saved") }
    list[#list + 1] = { type = "row",
      { type = "button", key = "forget", style = "danger", label = tr("Remover chave", "Remove key"), on_click = function()
        pcall(larper.secrets.delete, "api_key")
        key = nil
        info = {}
        status = nil
        updated_at = nil
        options()
        draw()
      end } }
  else
    list[#list + 1] = { type = "input", key = "apikey", clear = true,
      placeholder = tr("Chave da Steam Web API (Enter para salvar)", "Steam Web API key (Enter to save)"),
      on_submit = save_key }
    list[#list + 1] = { type = "text", style = "muted", text = tr(
      "Pegue a sua em steamcommunity.com/dev/apikey. Ela fica no chaveiro do sistema e só vai para " .. HOST .. ".",
      "Get yours at steamcommunity.com/dev/apikey. It stays in the system keyring and only goes to " .. HOST .. ".") }
  end
  list[#list + 1] = { type = "toggle", key = "notify", value = notify_games,
    label = tr("Avisar quando um amigo começar um jogo", "Tell me when a friend starts a game"),
    on_change = function(on)
      notify_games = on == true
      larper.storage.set("notify", notify_games)
    end }
  larper.settings.set(list)
end

larper.command("/steam", function()
  draw()
  larper.panel.open()
  poll(false)
end)

larper.on("panel", function(open)
  if open then poll(false) end
end)
larper.on("hosts", function()
  status = nil
  poll(true)
  draw()
end)
larper.on("lang", function()
  options()
  draw()
end)

larper.every(EVERY, function() poll(false) end)
options()
draw()
poll(true)
