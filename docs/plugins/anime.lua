-- @name Next episode
-- @name:pt Próximo episódio
-- @description /anime <name> follows an anime on AniList and a system notification tells you when each episode airs. The panel searches, shows a countdown ("Ep 7 in 2d 4h") and unfollows. Only searches and ids go to graphql.anilist.co, after you approve it below.
-- @description:pt /anime <nome> segue um anime do AniList, e uma notificação do sistema avisa quando sai cada episódio. O painel busca, mostra a contagem ("Ep 7 em 2d 4h") e para de seguir. Só a busca e os números vão para graphql.anilist.co, depois de aprovar aqui.
-- @version 1.0.0
-- @capabilities panel, storage, http, timers, notify
-- @hosts graphql.anilist.co

local tr = larper.tr
local HOST = "graphql.anilist.co"
local API = "https://" .. HOST
local EVERY = 6 * 3600
local MAX_FOLLOW = 50
-- Episódio que saiu faz mais de uma semana com o app fechado não vira aviso.
local TOO_OLD = 7 * 86400

local FIELDS = "id title{romaji english} status episodes nextAiringEpisode{episode airingAt} siteUrl"
local SEARCH = "query($s:String){Page(perPage:6){media(search:$s,type:ANIME,sort:SEARCH_MATCH,isAdult:false){" .. FIELDS .. "}}}"
local REFRESH = "query($ids:[Int]){Page(perPage:50){media(id_in:$ids,type:ANIME){" .. FIELDS .. "}}}"

local follow = larper.storage.get("follow") or {}
-- Números guardados podem voltar como 21.0: as keys do painel usam o id como texto.
for _, a in ipairs(follow) do
  a.id = math.tointeger(a.id) or a.id
  a.ep, a.at, a.done = math.tointeger(a.ep), math.tointeger(a.at), math.tointeger(a.done)
end
local results = nil
local search_note = nil
local status = nil
local refreshed_at = nil
local timer = nil
local soon = nil
local tick = nil

local draw

local function save() larper.storage.set("follow", follow) end

local function is_pt() return (larper.lang() or ""):match("^pt") ~= nil end

local function decode(body)
  local ok, d = pcall(larper.json.decode, body)
  if ok and type(d) == "table" then return d end
end

local function name(a)
  if is_pt() then return a.romaji or a.english or ("#" .. a.id) end
  return a.english or a.romaji or ("#" .. a.id)
end

local function find(id)
  for i, a in ipairs(follow) do
    if a.id == id then return i, a end
  end
end

local function span(secs)
  if secs < 60 then return tr("menos de 1 min", "under 1 min") end
  local d, h, m = secs // 86400, secs % 86400 // 3600, secs % 3600 // 60
  if d > 0 then return d .. "d " .. h .. "h" end
  if h > 0 then return h .. "h " .. m .. "min" end
  return m .. " min"
end

local STATUS = {
  FINISHED = { pt = "Terminou", en = "Finished" },
  CANCELLED = { pt = "Cancelado", en = "Cancelled" },
  HIATUS = { pt = "Em pausa", en = "On hiatus" },
  NOT_YET_RELEASED = { pt = "Ainda sem data de estreia", en = "No premiere date yet" },
}

local function next_text(a)
  if a.ep and a.at then
    local left = a.at - os.time()
    if left > 0 then return tr("Ep " .. a.ep .. " em " .. span(left), "Ep " .. a.ep .. " in " .. span(left)) end
    return tr("Ep " .. a.ep .. " já saiu", "Ep " .. a.ep .. " is out")
  end
  return tr(STATUS[a.status] or { pt = "Sem episódio marcado", en = "No episode scheduled" })
end

local function when(t)
  return os.date(is_pt() and "%d/%m %H:%M" or "%b %d %H:%M", t)
end

local function read(m)
  local id = type(m) == "table" and math.tointeger(m.id)
  if not id then return nil end
  local t = type(m.title) == "table" and m.title or {}
  local n = type(m.nextAiringEpisode) == "table" and m.nextAiringEpisode or {}
  return {
    id = id,
    romaji = type(t.romaji) == "string" and t.romaji or nil,
    english = type(t.english) == "string" and t.english or nil,
    status = type(m.status) == "string" and m.status or nil,
    ep = math.tointeger(n.episode),
    at = math.tointeger(n.airingAt),
  }
end

local APPROVE = { pt = "Aprove " .. HOST .. " em Configurações → Plugins.", en = "Approve " .. HOST .. " in Settings → Plugins." }

local function failure(res, d)
  if res.error == "not_approved" then return APPROVE end
  if res.error == "network" then return { pt = "Sem conexão com o AniList.", en = "Can't reach AniList." } end
  if res.status == 429 or res.error == "rate_limited" then
    return { pt = "O AniList pediu para esperar um pouco.", en = "AniList asked to wait a little." }
  end
  if res.error then return { pt = "Resposta estranha do AniList (" .. res.error .. ").", en = "Odd answer from AniList (" .. res.error .. ")." } end
  if d and d.errors then return { pt = "O AniList recusou o pedido (" .. res.status .. ").", en = "AniList refused the request (" .. res.status .. ")." } end
  return { pt = "O AniList não respondeu (" .. tostring(res.status) .. ").", en = "AniList didn't answer (" .. tostring(res.status) .. ")." }
end

-- done(lista) ou done(nil, motivo).
local function ask(query, vars, done)
  if not larper.http.allowed(HOST) then return done(nil, APPROVE) end
  local body = larper.json.encode({ query = query, variables = vars })
  larper.http.post(API, { body = body, headers = { ["Content-Type"] = "application/json", Accept = "application/json" } }, function(res)
    local d = decode(res.body)
    local media = res.ok and d and type(d.data) == "table" and type(d.data.Page) == "table" and d.data.Page.media
    if type(media) ~= "table" then return done(nil, failure(res, d)) end
    local list = {}
    for _, m in ipairs(media) do
      local a = read(m)
      if a then list[#list + 1] = a end
    end
    done(list)
  end)
end

-- --- Avisos na hora do episódio ---------------------------------------------------------

local arm
local refresh

local function check(late)
  local now = os.time()
  local out = {}
  for _, a in ipairs(follow) do
    if a.ep and a.at and a.at <= now and (a.done or 0) < a.ep then
      a.done = a.ep
      if now - a.at <= TOO_OLD then out[#out + 1] = a end
    end
  end
  if #out == 0 then return end
  save()
  -- A própria pessoa pediu para saber: aparece mesmo com a janela em foco.
  local text
  if #out == 1 then
    text = tr("📺 Saiu o episódio " .. out[1].ep .. " de " .. name(out[1]), "📺 Episode " .. out[1].ep .. " of " .. name(out[1]) .. " is out")
  else
    local parts = {}
    for _, a in ipairs(out) do parts[#parts + 1] = tr("ep " .. a.ep .. " de ", "ep " .. a.ep .. " of ") .. name(a) end
    text = tr("📺 Saíram: ", "📺 Out now: ") .. table.concat(parts, ", ")
  end
  if late then text = text .. tr(" (enquanto o app estava fechado)", " (while the app was closed)") end
  larper.notify(text, { desktop = true })
  -- O AniList já sabe o próximo logo depois: busca daqui a pouco.
  if not soon then
    soon = larper.after(600, function()
      soon = nil
      refresh()
    end)
  end
end

arm = function()
  if timer then larper.cancel(timer) end
  timer = nil
  local now, nearest = os.time(), nil
  for _, a in ipairs(follow) do
    if a.ep and a.at and a.at > now and (a.done or 0) < a.ep and (not nearest or a.at < nearest) then nearest = a.at end
  end
  if nearest then
    timer = larper.after(nearest - now, function()
      timer = nil
      check(false)
      arm()
      draw()
    end)
  end
end

refresh = function()
  if #follow == 0 then return end
  local ids = {}
  for _, a in ipairs(follow) do ids[#ids + 1] = a.id end
  ask(REFRESH, { ids = ids }, function(list, why)
    if not list then
      status = why
      draw()
      return
    end
    -- O que venceu antes da resposta avisa com o número velho.
    check(false)
    for _, m in ipairs(list) do
      local _, a = find(m.id)
      if a then
        a.romaji, a.english, a.status = m.romaji, m.english, m.status
        a.ep, a.at = m.ep, m.at
      end
    end
    status = nil
    refreshed_at = os.time()
    save()
    arm()
    draw()
  end)
end

local function start(a)
  if find(a.id) then
    larper.notify(tr("Você já segue " .. name(a), "You already follow " .. name(a)))
    return
  end
  if #follow >= MAX_FOLLOW then
    larper.notify(tr("Dá para seguir até 50 animes", "You can follow up to 50 anime"))
    return
  end
  -- Um episódio que já saiu não avisa de novo.
  local entry = { id = a.id, romaji = a.romaji, english = a.english, status = a.status, ep = a.ep, at = a.at }
  if a.ep and a.at and a.at <= os.time() then entry.done = a.ep end
  follow[#follow + 1] = entry
  save()
  arm()
  draw()
  larper.notify(tr("Seguindo ", "Following ") .. name(entry) .. " · " .. next_text(entry))
end

local function stop(id)
  local i = find(id)
  if not i then return end
  table.remove(follow, i)
  save()
  arm()
  draw()
end

-- O melhor resultado: entre os que têm o texto no nome, o que está passando, depois o que
-- vai estrear, depois o primeiro do AniList.
local function pick(list, query)
  local q = query:lower()
  local pool = {}
  for _, a in ipairs(list) do
    if (a.romaji or ""):lower():find(q, 1, true) or (a.english or ""):lower():find(q, 1, true) then pool[#pool + 1] = a end
  end
  if #pool == 0 then pool = list end
  for _, want in ipairs({ "RELEASING", "NOT_YET_RELEASED" }) do
    for _, a in ipairs(pool) do
      if a.status == want then return a end
    end
  end
  return pool[1]
end

local function clean_query(text)
  text = (text or ""):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
  if #text > 100 then return nil, "long" end
  return text
end

local function search(text)
  local q, why = clean_query(text)
  if why then
    search_note = { pt = "Nome longo demais.", en = "Name too long." }
    draw()
    return
  end
  if q == "" then
    results, search_note = nil, nil
    draw()
    return
  end
  search_note = { pt = "Buscando…", en = "Searching…" }
  draw()
  ask(SEARCH, { s = q }, function(list, fail)
    results = list
    if not list then
      search_note = fail
    elseif #list == 0 then
      search_note = { pt = "Nada encontrado para \"" .. q .. "\".", en = "Nothing found for \"" .. q .. "\"." }
    else
      search_note = nil
    end
    draw()
  end)
end

-- --- Painel ------------------------------------------------------------------------------

local function result_row(a)
  local following = find(a.id) ~= nil
  local action
  if following then
    action = { label = tr("Parar de seguir", "Unfollow"), style = "danger", key = "rstop" .. a.id, on_click = function() stop(a.id) end }
  else
    action = { label = tr("Seguir", "Follow"), style = "accent", key = "follow" .. a.id, on_click = function() start(a) end }
  end
  return { title = name(a), subtitle = next_text(a), meta = following and tr("seguindo", "following") or "", key = "r" .. a.id, actions = { action } }
end

local function by_next(x, y)
  local ax, ay = x.at or math.huge, y.at or math.huge
  if ax ~= ay then return ax < ay end
  return name(x):lower() < name(y):lower()
end

draw = function()
  local tree = { title = tr("Próximo episódio", "Next episode") }
  if status then tree[#tree + 1] = { type = "text", style = "danger", text = tr(status) } end
  tree[#tree + 1] = { type = "input", key = "search", placeholder = tr("Buscar anime (Enter)", "Search anime (Enter)"), on_submit = search }
  if search_note then tree[#tree + 1] = { type = "text", style = "muted", text = tr(search_note) } end
  if results and #results > 0 then
    local items = {}
    for _, a in ipairs(results) do items[#items + 1] = result_row(a) end
    tree[#tree + 1] = { type = "list", key = "results", items = items }
    tree[#tree + 1] = { type = "row", { type = "button", key = "clear", label = tr("Limpar busca", "Clear search"), on_click = function()
      results, search_note = nil, nil
      draw()
    end } }
  end
  tree[#tree + 1] = { type = "heading", text = tr("Seguindo", "Following") }
  local sorted = {}
  for _, a in ipairs(follow) do sorted[#sorted + 1] = a end
  table.sort(sorted, by_next)
  local items = {}
  for _, a in ipairs(sorted) do
    items[#items + 1] = {
      title = name(a),
      subtitle = next_text(a),
      meta = a.at and a.at > os.time() and when(a.at) or "",
      key = "a" .. a.id,
      actions = { { label = tr("Parar de seguir", "Unfollow"), style = "danger", key = "stop" .. a.id, on_click = function() stop(a.id) end } },
    }
  end
  tree[#tree + 1] = { type = "list", key = "following", items = items,
    empty = tr("Nada ainda. Busque acima ou use /anime nome.", "Nothing yet. Search above or use /anime name.") }
  if refreshed_at then
    tree[#tree + 1] = { type = "text", style = "muted", text = tr("Atualizado às ", "Updated at ") .. os.date("%H:%M", refreshed_at) .. " · AniList" }
  end
  larper.panel.set(tree)
end

larper.command("/anime", function(args)
  local q, why = clean_query(args)
  if why then
    larper.notify(tr("Nome longo demais", "Name too long"))
    return
  end
  if q == "" then
    draw()
    larper.panel.open()
    return
  end
  ask(SEARCH, { s = q }, function(list, fail)
    if not list then
      larper.notify(tr(fail))
    elseif #list == 0 then
      larper.notify(tr("Não achei nenhum anime com \"" .. q .. "\"", "Couldn't find any anime called \"" .. q .. "\""))
    else
      start(pick(list, q))
    end
  end)
end)

-- A contagem só anda com o painel aberto.
larper.on("panel", function(open)
  if tick then larper.cancel(tick) end
  tick = nil
  if open then
    draw()
    tick = larper.every(60, draw)
  end
end)
larper.on("hosts", function()
  status = nil
  refresh()
end)
larper.on("lang", draw)

larper.every(EVERY, refresh)
-- O que saiu com o app fechado avisa agora.
check(true)
arm()
draw()
refresh()
