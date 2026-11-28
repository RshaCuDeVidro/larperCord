-- @name Steam prices
-- @name:pt Preço da Steam
-- @description Messages with a store.steampowered.com/app/ link get a note with the price, the discount and the review score, up to 3 games per message. Only the game's number goes to store.steampowered.com and api.steampowered.com, after you approve the hosts below. Each answer is kept for an hour.
-- @description:pt Mensagens com um link store.steampowered.com/app/ ganham uma nota com o preço, o desconto e as análises, até 3 jogos por mensagem. Só o número do jogo vai para store.steampowered.com e api.steampowered.com, depois de aprovar os hosts aqui embaixo. Cada resposta fica guardada por uma hora.
-- @version 1.0.0
-- @capabilities messages, decorate, http, settings, storage, timers, notify
-- @hosts store.steampowered.com, api.steampowered.com

local tr = larper.tr
local STORE_HOST = "store.steampowered.com"
local API_HOST = "api.steampowered.com"
local LINK = "store.steampowered.com/app/"
local TTL = 3600
-- Resposta pela metade (sem as análises) ou erro: tenta de novo antes.
local TTL_PARTIAL = 600
local TTL_FAILED = 300
local MAX_APPS = 3
local MAX_WAITING = 30
local MAX_TRACKED = 1000
local MAX_CACHE = 300
-- O app deixa 30 por minuto; sobra um pouco.
local PER_MINUTE = 28
local IN_FLIGHT = 3

-- O antigo store.steampowered.com/appreviews saiu do ar em outubro de 2026 (agora só
-- redireciona para a página inicial). As análises vêm do IUserReviewsService, sem chave.
local DETAILS = "https://" .. STORE_HOST .. "/api/appdetails?appids="
local REVIEWS = "https://" .. API_HOST .. "/IUserReviewsService/GetAppReviews/v1/?input_json="

-- "eu" usa a loja da Alemanha, que cobra em euro.
local COUNTRIES = { br = "br", us = "us", eu = "de" }
local country = larper.storage.get("country")
if not COUNTRIES[country] then country = "br" end

local cache = {}
local cached = 0
local tracked = {}
local order = {}
local dismissed = {}
local waiting = {}
local loading = {}
local asked_count = 0
local jobs = {}
local flying = 0
local sent_at = {}
local paused = false
local warned = false

local function is_pt() return (larper.lang() or ""):match("^pt") ~= nil end

local function group(n)
  local s = tostring(math.floor(n))
  local sep = is_pt() and "." or ","
  local out = s:reverse():gsub("(%d%d%d)", "%1" .. sep):reverse()
  if out:sub(1, #sep) == sep then out = out:sub(#sep + 1) end
  return out
end

local function decode(body)
  local ok, d = pcall(larper.json.decode, body)
  if ok and type(d) == "table" then return d end
end

local function warn_hosts()
  if warned then return end
  warned = true
  larper.notify(tr("Preço da Steam: aprove " .. STORE_HOST .. " e " .. API_HOST .. " em Configurações → Plugins",
    "Steam prices: approve " .. STORE_HOST .. " and " .. API_HOST .. " in Settings → Plugins"))
end

-- --- Fila de pedidos: 3 de cada vez e no máximo PER_MINUTE por minuto ---------------------

local pump

local function pause_for(seconds)
  if paused then return end
  paused = true
  larper.after(seconds, function()
    paused = false
    pump()
  end)
end

pump = function()
  while not paused and flying < IN_FLIGHT and #jobs > 0 do
    local now = os.time()
    local keep = {}
    for _, t in ipairs(sent_at) do
      if now - t < 60 then keep[#keep + 1] = t end
    end
    sent_at = keep
    if #sent_at >= PER_MINUTE then
      pause_for(math.max(1, 60 - (now - sent_at[1])))
      return
    end
    local job = table.remove(jobs, 1)
    if not larper.http.allowed(job.host) then
      warn_hosts()
      job.done({ ok = false, status = 0, body = "", error = "not_approved" })
    else
      flying = flying + 1
      sent_at[#sent_at + 1] = now
      larper.http.get(job.url, function(res)
        flying = flying - 1
        if res.error == "rate_limited" then
          table.insert(jobs, 1, job)
          pause_for(60)
          return
        end
        if res.status == 429 then pause_for(5 * 60) end
        if res.error == "not_approved" then warn_hosts() end
        job.done(res)
        pump()
      end)
    end
  end
end

local function push(host, url, done)
  jobs[#jobs + 1] = { host = host, url = url, done = done }
end

-- --- Respostas ---------------------------------------------------------------------------

local function read_details(res, id)
  if not res.ok then return nil end
  local d = decode(res.body)
  local entry = d and d[id]
  if type(entry) ~= "table" then return nil end
  if entry.success == false then return { missing = true } end
  local data = entry.data
  if type(data) ~= "table" then return { missing = true } end
  local out = {
    name = type(data.name) == "string" and data.name or nil,
    free = data.is_free == true,
  }
  local rd = data.release_date
  if type(rd) == "table" then
    out.soon = rd.coming_soon == true
    out.date = type(rd.date) == "string" and rd.date or ""
  end
  local p = data.price_overview
  if type(p) == "table" and type(p.final_formatted) == "string" and p.final_formatted ~= "" then
    out.price = {
      final = p.final_formatted,
      initial = type(p.initial_formatted) == "string" and p.initial_formatted or "",
      pct = math.tointeger(p.discount_percent) or 0,
    }
  end
  return out
end

local function read_reviews(res)
  if not res.ok then return nil end
  local d = decode(res.body)
  local s = d and type(d.response) == "table" and d.response.query_summary
  if type(s) ~= "table" or type(s.total_reviews) ~= "number" then return nil end
  return { pos = tonumber(s.total_positive) or 0, total = s.total_reviews }
end

-- --- Texto da nota -----------------------------------------------------------------------

local function price_text(d)
  if d.missing then return tr("fora da loja deste país", "not in this country's store") end
  if d.price then
    local p = d.price
    local text = p.final
    if p.pct > 0 and p.initial ~= "" then
      text = text .. tr(" (-" .. p.pct .. "%, era " .. p.initial .. ")", " (-" .. p.pct .. "%, was " .. p.initial .. ")")
    end
    if d.soon then text = tr("pré-venda ", "pre-order ") .. text end
    return text
  end
  if d.free then return tr("Grátis", "Free to play") end
  if d.soon then
    local soon = tr("Em breve", "Coming soon")
    if d.date and d.date ~= "" and d.date:lower() ~= soon:lower() then soon = soon .. " (" .. d.date .. ")" end
    return soon
  end
  return tr("sem preço na loja", "no price on the store")
end

local function reviews_text(r)
  if r.total <= 0 then return tr("sem análises", "no reviews yet") end
  local pct = math.floor(r.pos * 100 / r.total + 0.5)
  if r.total == 1 then
    return tr(pct .. "% positivas (1 análise)", pct .. "% positive (1 review)")
  end
  return tr(pct .. "% positivas (" .. group(r.total) .. " análises)", pct .. "% positive (" .. group(r.total) .. " reviews)")
end

local function describe(key, with_name)
  local e = cache[key]
  if not e or e.failed then return nil end
  local text = price_text(e.d)
  if e.r and not e.d.missing then text = text .. " · " .. reviews_text(e.r) end
  if with_name and e.d.name then text = e.d.name .. ": " .. text end
  return text
end

local function fresh(e)
  return e ~= nil and os.time() - e.at < e.ttl
end

local function paint(msg_id)
  if dismissed[msg_id] then return end
  local t = tracked[msg_id]
  if not t then return end
  local parts = {}
  for _, id in ipairs(t.ids) do
    local text = describe(country .. ":" .. id, #t.ids > 1)
    if text then parts[#parts + 1] = text end
  end
  if #parts == 0 then return end
  local note = table.concat(parts, "  |  ")
  if t.note == note then return end
  t.note = note
  larper.decorate(msg_id, { note = note })
end

local function remember(key, entry)
  if not cache[key] then cached = cached + 1 end
  cache[key] = entry
  if cached > MAX_CACHE then
    local oldest, at
    for k, e in pairs(cache) do
      if not at or e.at < at then oldest, at = k, e.at end
    end
    cache[oldest] = nil
    cached = cached - 1
  end
end

local function settle(key)
  local list = waiting[key]
  waiting[key] = nil
  if list then
    for msg_id in pairs(list) do paint(msg_id) end
  end
end

local function fetch(id, key)
  loading[key] = true
  asked_count = asked_count + 1
  local cc = COUNTRIES[country]
  local l = is_pt() and "brazilian" or "english"
  local got = { left = 2 }
  local function finish(why)
    got.left = got.left - 1
    if why then got.why = why end
    if got.left > 0 then return end
    loading[key] = nil
    asked_count = asked_count - 1
    if got.d then
      remember(key, { at = os.time(), d = got.d, r = got.r, ttl = (got.r or got.d.missing) and TTL or TTL_PARTIAL })
    elseif got.why ~= "not_approved" then
      -- Sem rede ou erro da Steam: nada para mostrar, e não insiste na hora.
      remember(key, { at = os.time(), failed = true, ttl = TTL_FAILED })
    end
    settle(key)
  end
  push(STORE_HOST, DETAILS .. id .. "&cc=" .. cc .. "&l=" .. l .. "&filters=basic%2Cprice_overview%2Crelease_date", function(res)
    got.d = read_details(res, id)
    finish(res.error)
  end)
  local query = larper.json.encode({ appid = tonumber(id), languages = { "all" }, purchase_type = 1, num_per_page = 1 })
  push(API_HOST, REVIEWS .. larper.urlencode(query), function(res)
    got.r = read_reviews(res)
    finish(nil)
  end)
  pump()
end

local function ask(id, msg_id)
  local key = country .. ":" .. id
  local list = waiting[key] or {}
  list[msg_id] = true
  waiting[key] = list
  if loading[key] or asked_count >= MAX_WAITING then return end
  fetch(id, key)
end

-- Até 3 jogos por mensagem, sem repetir. Código fica de fora.
local function ids_in(content)
  local text = content:gsub("```.-```", " "):gsub("`[^`]*`", " "):lower()
  local ids, have = {}, {}
  for digits in text:gmatch("store%.steampowered%.com/app/(%d+)") do
    local n = #digits <= 10 and tonumber(digits)
    local id = n and n > 0 and tostring(math.tointeger(n))
    if id and not have[id] then
      have[id] = true
      ids[#ids + 1] = id
      if #ids >= MAX_APPS then break end
    end
  end
  return ids
end

local function examine(m)
  if m.ignored then return end
  local ids = ids_in(m.content or "")
  local old = tracked[m.id]
  if #ids == 0 then
    if old then
      tracked[m.id] = nil
      larper.undecorate(m)
    end
    return
  end
  if not old then
    order[#order + 1] = m.id
    if #order > MAX_TRACKED then tracked[table.remove(order, 1)] = nil end
  end
  tracked[m.id] = { ids = ids, note = old and old.note or nil }
  for _, id in ipairs(ids) do
    if not fresh(cache[country .. ":" .. id]) then ask(id, m.id) end
  end
  paint(m.id)
end

local function refresh_all()
  for msg_id, t in pairs(tracked) do
    t.note = nil
    for _, id in ipairs(t.ids) do
      if not fresh(cache[country .. ":" .. id]) then ask(id, msg_id) end
    end
    paint(msg_id)
  end
end

-- O que já está na tela: as mais novas primeiro, sem gastar o limite com o histórico todo.
local again = false
local function scan()
  local ok = larper.messages({ limit = 100, contains = { LINK } }, function(list)
    local n = 0
    for i = #list, 1, -1 do
      examine(list[i])
      n = n + 1
      if n >= 20 then break end
    end
  end)
  if ok == false and not again then
    again = true
    larper.after(0.6, function()
      again = false
      scan()
    end)
  end
end

local function options()
  larper.settings.set({
    { type = "select", key = "country", label = tr("Preços de", "Prices from"), value = country,
      options = {
        { value = "br", label = tr("Brasil (R$)", "Brazil (R$)") },
        { value = "us", label = tr("Estados Unidos (US$)", "United States (US$)") },
        { value = "eu", label = tr("Europa (€)", "Europe (€)") },
      },
      on_change = function(v)
        if not COUNTRIES[v] or v == country then return end
        country = v
        larper.storage.set("country", v)
        refresh_all()
      end },
  })
end

larper.on("message", examine, { contains = { LINK } })
-- Sem filtro: uma edição pode tirar o link, e aí a nota sai.
larper.on("edit", function(m)
  if tracked[m.id] or (m.content or ""):lower():find(LINK, 1, true) then examine(m) end
end)
larper.on("channel", function()
  scan()
  larper.after(1.5, scan)
end)
larper.on("hosts", function()
  warned = false
  for k, e in pairs(cache) do
    if e.failed then cache[k] = nil; cached = cached - 1 end
  end
  pump()
  scan()
end)
larper.on("delete", function(d)
  tracked[d.id] = nil
  dismissed[d.id] = nil
end)
larper.on("dismiss", function(d)
  dismissed[d.id] = true
end)
larper.on("lang", function()
  options()
  for msg_id, t in pairs(tracked) do
    t.note = nil
    paint(msg_id)
  end
end)

options()
larper.after(1, scan)
