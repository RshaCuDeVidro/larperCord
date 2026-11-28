-- @name Free games
-- @name:pt Jogos de graça
-- @description Free game giveaways on Epic, Steam and GOG from gamerpower.com: one notice when new ones appear (checked at start and every 6 hours), and a panel to open each one or post it in the channel. Only the list request goes out, after you approve the host below. /freegames opens it.
-- @description:pt Jogos de graça na Epic, Steam e GOG, do gamerpower.com: um aviso quando aparecem novos (confere ao abrir e a cada 6 horas) e um painel para abrir cada um ou avisar no canal. Só o pedido da lista sai, depois de aprovar o host aqui. /freegames abre.
-- @version 1.0.0
-- @capabilities panel, settings, storage, http, timers, notify, links, send
-- @hosts www.gamerpower.com

local tr = larper.tr
local HOST = "www.gamerpower.com"
-- gamerpower.com sem www redireciona para http://, que o app não segue.
local URL = "https://" .. HOST .. "/api/filter?platform=epic-games-store.steam.gog&type=game"
local EVERY = 6 * 3600
local MAX_SEEN = 300
local MAX_GAMES = 100

-- Como cada loja aparece no campo "platforms" da resposta ("PC, Epic Games Store").
local STORES = {
  { key = "epic", match = "Epic Games Store", name = "Epic Games Store" },
  { key = "steam", match = "Steam", name = "Steam" },
  { key = "gog", match = "GOG", name = "GOG" },
}

local enabled = larper.storage.get("stores") or {}
for _, s in ipairs(STORES) do
  if enabled[s.key] == nil then enabled[s.key] = true end
end
local seen_list = larper.storage.get("seen") or {}
local seen = {}
for _, id in ipairs(seen_list) do seen[id] = true end

local games = {}
local status = nil
local checked_at = nil
local busy = false

local draw

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

local function decode(body)
  local ok, d = pcall(larper.json.decode, body)
  if ok and type(d) == "table" then return d end
end

local function is_pt() return (larper.lang() or ""):match("^pt") ~= nil end

-- "Dwarven Realms (Steam) Key Giveaway" -> "Dwarven Realms".
local function clean(title)
  local t = title:gsub("%s+[Gg]iveaway%s*$", "")
  t = t:gsub("%s*%(Epic Games%)", ""):gsub("%s*%(GOG%)", ""):gsub("%s*%(Steam%)", "")
  t = t:gsub("%s+Steam Key$", ""):gsub("%s+Key$", "")
  t = trim(t)
  if t == "" then return trim(title) end
  return t
end

local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }

-- "2026-12-03 23:59:00" -> "até 03/12" ou "until Dec 3".
local function until_text(date)
  local y, m, d = (date or ""):match("^(%d%d%d%d)%-(%d%d)%-(%d%d)")
  if not y then return tr("sem data para acabar", "no end date") end
  local year = y ~= os.date("%Y") and (is_pt() and "/" .. y or ", " .. y) or ""
  if is_pt() then return "até " .. d .. "/" .. m .. year end
  return "until " .. MONTHS[tonumber(m)] .. " " .. tonumber(d) .. year
end

local function stores_of(g)
  local names = {}
  for _, s in ipairs(STORES) do
    if g.platforms[s.match] and enabled[s.key] then names[#names + 1] = s.name end
  end
  return names
end

local function visible()
  local out = {}
  for _, g in ipairs(games) do
    if #stores_of(g) > 0 then out[#out + 1] = g end
  end
  return out
end

local function read(list)
  local out = {}
  for _, x in ipairs(list) do
    -- O id pode chegar como 3860 ou 3860.0, conforme o leitor de JSON.
    if type(x) == "table" and math.tointeger(x.id) and type(x.title) == "string"
      and (x.type == nil or x.type == "Game") and (x.status == nil or x.status == "Active") then
      local platforms = {}
      for p in (type(x.platforms) == "string" and x.platforms or ""):gmatch("[^,]+") do platforms[trim(p)] = true end
      local url = type(x.open_giveaway_url) == "string" and x.open_giveaway_url or ""
      -- Alguns vêm com o atalho quebrado ("/open/n-a"): aí vai a página do sorteio.
      if not url:match("^https://") or url:find("/open/n%-a$") then
        url = type(x.gamerpower_url) == "string" and x.gamerpower_url or ""
      end
      out[#out + 1] = {
        id = math.tointeger(x.id),
        title = clean(x.title),
        worth = type(x.worth) == "string" and x.worth ~= "N/A" and x.worth or nil,
        ends = type(x.end_date) == "string" and x.end_date or "",
        platforms = platforms,
        url = url:match("^https://") and url or nil,
      }
      if #out >= MAX_GAMES then break end
    end
  end
  return out
end

local function remember(ids)
  for _, id in ipairs(ids) do
    if not seen[id] then
      seen[id] = true
      seen_list[#seen_list + 1] = id
    end
  end
  while #seen_list > MAX_SEEN do seen[table.remove(seen_list, 1)] = nil end
  larper.storage.set("seen", seen_list)
end

-- Um aviso só, com todos os novos juntos.
local function announce()
  local news, ids = {}, {}
  for _, g in ipairs(visible()) do
    if not seen[g.id] then
      news[#news + 1] = g
      ids[#ids + 1] = g.id
    end
  end
  if #news == 0 then return end
  remember(ids)
  if #news == 1 then
    local g = news[1]
    local where = table.concat(stores_of(g), ", ")
    larper.notify(tr("🎁 De graça na " .. where .. ": ", "🎁 Free on " .. where .. ": ") .. g.title .. " (" .. until_text(g.ends) .. ")")
    return
  end
  local names = {}
  for i, g in ipairs(news) do
    if i > 5 then
      names[#names + 1] = tr("e mais " .. (#news - 5), "and " .. (#news - 5) .. " more")
      break
    end
    names[#names + 1] = g.title
  end
  larper.notify(tr("🎁 " .. #news .. " jogos de graça: ", "🎁 " .. #news .. " free games: ") .. table.concat(names, ", "))
end

local function any_store()
  for _, s in ipairs(STORES) do
    if enabled[s.key] then return true end
  end
  return false
end

local APPROVE = { pt = "Aprove " .. HOST .. " em Configurações → Plugins.", en = "Approve " .. HOST .. " in Settings → Plugins." }

local function failure(res)
  if res.error == "not_approved" then return APPROVE end
  if res.error == "network" then return { pt = "Sem conexão com o GamerPower.", en = "Can't reach GamerPower." } end
  if res.error then return { pt = "Resposta estranha do GamerPower (" .. res.error .. ").", en = "Odd answer from GamerPower (" .. res.error .. ")." } end
  return { pt = "O GamerPower não respondeu (" .. tostring(res.status) .. ").", en = "GamerPower didn't answer (" .. tostring(res.status) .. ")." }
end

local function check(manual)
  if busy then return end
  if not any_store() then
    draw()
    return
  end
  if not larper.http.allowed(HOST) then
    status = APPROVE
    if manual then larper.notify(tr(status)) end
    draw()
    return
  end
  busy = true
  larper.http.get(URL, { headers = { Accept = "application/json" } }, function(res)
    busy = false
    -- Pedidos demais no momento: tenta de novo em um minuto.
    if res.error == "rate_limited" then
      larper.after(60, function() check(false) end)
      return
    end
    local d = res.ok and decode(res.body)
    if not res.ok then
      status = failure(res)
    elseif not d then
      status = { pt = "Resposta estranha do GamerPower.", en = "Odd answer from GamerPower." }
    elseif d[1] == nil and d.status ~= nil then
      -- Um objeto com status 0 (HTTP 201): nenhum sorteio agora.
      games = {}
      status = nil
      checked_at = os.time()
    else
      games = read(d)
      status = nil
      checked_at = os.time()
      announce()
    end
    if manual and status then larper.notify(tr(status)) end
    draw()
  end)
end

-- Negrito sem quebrar com * ou _ no nome, e sem chamar ninguém.
local function safe(text)
  text = text:gsub("[\\*_~`|>]", "\\%0")
  return (text:gsub("@(%a)", "@\u{200B}%1"))
end

local function share(g)
  if not larper.channel() then
    larper.notify(tr("Abra um canal primeiro", "Open a channel first"))
    return
  end
  if not g.url then return end
  local where = table.concat(stores_of(g), ", ")
  local title = safe(g.title:sub(1, 200))
  larper.send(nil, tr("🎁 **" .. title .. "** de graça na " .. where .. ", " .. until_text(g.ends) .. ": " .. g.url,
    "🎁 **" .. title .. "** free on " .. where .. ", " .. until_text(g.ends) .. ": " .. g.url))
end

local function row(g)
  local sub = table.concat(stores_of(g), ", ")
  if g.worth then sub = sub .. " · " .. tr("vale ", "worth ") .. g.worth end
  local actions = {}
  if g.url then
    actions[#actions + 1] = { label = tr("Abrir", "Open"), key = "open" .. g.id, on_click = function() larper.open(g.url) end }
    actions[#actions + 1] = { label = tr("Avisar no canal", "Post in channel"), key = "share" .. g.id, on_click = function() share(g) end }
  end
  return { title = g.title, subtitle = sub, meta = until_text(g.ends), key = "g" .. g.id, actions = actions }
end

draw = function()
  local tree = { title = tr("Jogos de graça", "Free games") }
  if status then tree[#tree + 1] = { type = "text", style = "danger", text = tr(status) } end
  if not any_store() then
    tree[#tree + 1] = { type = "text", style = "accent", text = tr("Ligue ao menos uma loja no cartão do plugin.", "Turn on at least one store on the plugin's card.") }
  end
  local items = {}
  for _, g in ipairs(visible()) do items[#items + 1] = row(g) end
  tree[#tree + 1] = { type = "list", key = "games", items = items,
    empty = checked_at and tr("Nenhum jogo de graça agora nessas lojas.", "No free games right now in those stores.")
      or tr("Ainda não conferi.", "Not checked yet.") }
  if checked_at then
    tree[#tree + 1] = { type = "text", style = "muted", text = tr("Conferido às ", "Checked at ") .. os.date("%H:%M", checked_at) .. " · gamerpower.com" }
  end
  tree[#tree + 1] = { type = "row", { type = "button", key = "refresh", label = tr("Atualizar", "Refresh"), on_click = function() check(true) end } }
  larper.panel.set(tree)
end

local function options()
  local list = { { type = "text", style = "muted", text = tr("Lojas que contam:", "Stores that count:") } }
  for _, s in ipairs(STORES) do
    list[#list + 1] = { type = "toggle", key = s.key, label = s.name, value = enabled[s.key],
      on_change = function(on)
        enabled[s.key] = on == true
        larper.storage.set("stores", enabled)
        if on then
          announce()
          if not checked_at then check(false) end
        end
        draw()
      end }
  end
  larper.settings.set(list)
end

larper.command("/freegames", function()
  draw()
  larper.panel.open()
end)

larper.on("hosts", function()
  status = nil
  check(false)
end)
larper.on("lang", function()
  options()
  draw()
end)

larper.every(EVERY, function() check(false) end)
options()
draw()
check(false)
