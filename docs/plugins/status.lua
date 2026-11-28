-- @name Service status
-- @name:pt Status dos serviços
-- @description Every 5 minutes, reads the public status pages of GitHub, Cloudflare, npm, Reddit, Twitch, DigitalOcean, Vercel and Epic Games. Warns when one has trouble and when it recovers; /status lists them with the open incidents. Each service has a switch below, and only approved hosts are read.
-- @description:pt A cada 5 minutos, lê as páginas públicas de status de GitHub, Cloudflare, npm, Reddit, Twitch, DigitalOcean, Vercel e Epic Games. Avisa quando um tem problema e quando volta; /status lista todos com os incidentes abertos. Cada serviço tem uma chave aqui embaixo, e só lê os hosts aprovados.
-- @version 1.0.0
-- @capabilities http, timers, panel, settings, storage, notify
-- @hosts www.githubstatus.com, www.cloudflarestatus.com, status.npmjs.org, www.redditstatus.com, status.twitch.com, status.digitalocean.com, www.vercel-status.com, status.epicgames.com

local tr = larper.tr
local EVERY = 300
-- "Atualizar" e /status não pedem de novo antes disso.
local FRESH = 60

-- Todos são páginas do Statuspage (/api/v2/summary.json), conferidas uma a uma.
local SERVICES = {
  { key = "github", name = "GitHub", host = "www.githubstatus.com" },
  { key = "cloudflare", name = "Cloudflare", host = "www.cloudflarestatus.com" },
  { key = "npm", name = "npm", host = "status.npmjs.org" },
  { key = "reddit", name = "Reddit", host = "www.redditstatus.com" },
  { key = "twitch", name = "Twitch", host = "status.twitch.com" },
  { key = "digitalocean", name = "DigitalOcean", host = "status.digitalocean.com" },
  { key = "vercel", name = "Vercel", host = "www.vercel-status.com" },
  { key = "epic", name = "Epic Games", host = "status.epicgames.com" },
}

local EMOJI = { none = "🟢", minor = "🟡", major = "🟠", critical = "🔴", maintenance = "🔧" }
local LEVEL = { none = 0, maintenance = 0, minor = 1, major = 2, critical = 3 }
local LABEL = {
  none = { pt = "Tudo funcionando", en = "All systems operational" },
  minor = { pt = "Problemas menores", en = "Minor issues" },
  major = { pt = "Falha grave", en = "Major outage" },
  critical = { pt = "Fora do ar", en = "Critical outage" },
  maintenance = { pt = "Em manutenção", en = "Under maintenance" },
}
local STAGE = {
  investigating = { pt = "investigando", en = "investigating" },
  identified = { pt = "causa identificada", en = "identified" },
  monitoring = { pt = "monitorando", en = "monitoring" },
}
local ERRORS = {
  not_approved = { pt = "aprove o host no cartão do plugin", en = "approve the host on the plugin's card" },
  network = { pt = "sem resposta", en = "no answer" },
  rate_limited = { pt = "pedidos demais, tenta de novo depois", en = "too many requests, trying again later" },
  too_big = { pt = "resposta grande demais", en = "answer too big" },
  redirect = { pt = "redirecionou para outro host", en = "redirected to another host" },
  bad = { pt = "resposta inesperada", en = "unexpected answer" },
}

-- Desligados nas opções, e o último estado avisado (para avisar o que mudou com o app fechado).
local off = larper.storage.get("off") or {}
local known = larper.storage.get("known") or {}

-- Só na memória: [key] = { indicator, description, incidents, checked, error, etag }
local state = {}
local queue = {}
local busy = false
local last_poll = nil
local render

local function enabled(s) return not off[s.key] end

local function clock(t)
  return os.date("%H:%M", t)
end

local function short(text, n)
  text = (text or ""):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
  if #text <= n then return text end
  while n > 0 and (text:byte(n + 1) or 0) & 0xC0 == 0x80 do n = n - 1 end
  return text:sub(1, n) .. "…"
end

local function error_text(code)
  if ERRORS[code] then return tr(ERRORS[code]) end
  return tr{ pt = "erro ", en = "error " } .. tostring(code)
end

-- Os incidentes que ainda não acabaram, com a última atualização de cada um.
local function open_incidents(data)
  local out = {}
  for _, inc in ipairs(type(data.incidents) == "table" and data.incidents or {}) do
    if type(inc) == "table" and inc.status ~= "resolved" and inc.status ~= "postmortem" and #out < 5 then
      local updates = type(inc.incident_updates) == "table" and inc.incident_updates or {}
      local latest = updates[1] and updates[1].body
      out[#out + 1] = { name = tostring(inc.name or "?"), status = inc.status, impact = inc.impact, text = latest }
    end
  end
  return out
end

local function apply(s, st, data)
  local new = data.status.indicator
  local old = st.indicator or known[s.key]
  st.indicator = new
  st.description = type(data.status.description) == "string" and data.status.description or ""
  st.incidents = open_incidents(data)
  local was, now = LEVEL[old] or 0, LEVEL[new] or 0
  if old and now > was then
    larper.notify((EMOJI[new] or "⚪") .. " " .. s.name .. ": " .. tr(LABEL[new]) .. " (" .. short(st.description, 80) .. ")")
  elseif old and was > 0 and now == 0 then
    larper.notify("🟢 " .. tr{ pt = s.name .. " voltou ao normal", en = s.name .. " is back to normal" })
  end
  if known[s.key] ~= new then
    known[s.key] = new
    larper.storage.set("known", known)
  end
end

local function fetch(s, done)
  local st = state[s.key] or {}
  state[s.key] = st
  if not larper.http.allowed(s.host) then
    st.error = "not_approved"
    return done()
  end
  -- Com o ETag, quem não mudou responde 304 sem corpo (a da Cloudflare tem uns 200 KB).
  local opts = st.etag and { headers = { ["If-None-Match"] = st.etag } } or {}
  larper.http.get("https://" .. s.host .. "/api/v2/summary.json", opts, function(res)
    -- Desligado enquanto o pedido ia: a resposta não vale mais.
    if state[s.key] ~= st then return done() end
    st.checked = os.time()
    if res.status == 304 and st.indicator and not res.error then
      st.error = nil
    elseif res.ok then
      local data = larper.json.decode(res.body)
      if type(data) == "table" and type(data.status) == "table" and type(data.status.indicator) == "string" then
        st.error = nil
        st.etag = res.headers and res.headers.etag or nil
        apply(s, st, data)
      else
        st.error = "bad"
      end
    else
      st.error = res.error or res.status
    end
    done()
  end)
end

-- Um pedido de cada vez: o app recusa o quarto ao mesmo tempo.
local function step()
  local s = table.remove(queue, 1)
  if not s then
    busy = false
    return render()
  end
  busy = true
  fetch(s, step)
end

-- which: nil (todos), um serviço, ou uma função que escolhe.
local function poll(which)
  last_poll = os.time()
  for _, s in ipairs(SERVICES) do
    local pick = which == nil or which == s or (type(which) == "function" and which(s))
    if enabled(s) and pick then
      local queued = false
      for _, q in ipairs(queue) do
        if q == s then queued = true end
      end
      if not queued then queue[#queue + 1] = s end
    end
  end
  if not busy then step() end
  render()
end

local function refresh()
  if not last_poll or os.time() - last_poll >= FRESH then poll() else render() end
end

render = function()
  local tree = { title = tr{ pt = "Status dos serviços", en = "Service status" } }
  local function add(item) tree[#tree + 1] = item end
  local note = tr{ pt = "Confere a cada 5 minutos.", en = "Checks every 5 minutes." }
  if last_poll then note = note .. tr{ pt = " Última vez às ", en = " Last time at " } .. clock(last_poll) .. "." end
  if busy then note = note .. tr{ pt = " Conferindo…", en = " Checking…" } end
  add({ type = "text", style = "muted", text = note })
  add({ type = "row", { type = "button", key = "refresh", label = tr{ pt = "Atualizar", en = "Refresh" }, on_click = refresh } })

  local items, incidents, waiting = {}, {}, {}
  for _, s in ipairs(SERVICES) do
    if enabled(s) then
      local st = state[s.key] or {}
      local ind = st.indicator
      local sub
      if ind then
        sub = tr(LABEL[ind] or { pt = ind, en = ind })
        if ind ~= "none" and st.description ~= "" then sub = sub .. " · " .. st.description end
        if st.error then
          sub = sub .. " · " .. tr{ pt = "última conferência falhou: ", en = "last check failed: " } .. error_text(st.error)
        end
      elseif st.error then
        sub = error_text(st.error):gsub("^%l", string.upper)
      else
        sub = tr{ pt = "Conferindo…", en = "Checking…" }
      end
      if st.error == "not_approved" then waiting[#waiting + 1] = s.name end
      items[#items + 1] = {
        key = "s-" .. s.key,
        title = (EMOJI[ind] or "⚪") .. " " .. s.name,
        subtitle = sub,
        meta = st.checked and clock(st.checked) or "",
      }
      for i, inc in ipairs(ind and st.incidents or {}) do
        local stage = STAGE[inc.status] and tr(STAGE[inc.status]) or tostring(inc.status or "")
        incidents[#incidents + 1] = {
          key = "i-" .. s.key .. i,
          title = s.name .. ": " .. short(inc.name, 120),
          subtitle = short(inc.text, 240),
          meta = stage,
        }
      end
    end
  end
  if #waiting > 0 then
    add({ type = "text", style = "danger", text = tr{
      pt = "Aprove os hosts em Configurações → Plugins → Status dos serviços para conferir: ",
      en = "Approve the hosts in Settings → Plugins → Service status to check: ",
    } .. table.concat(waiting, ", ") })
  end
  add({ type = "list", key = "services", items = items, empty = tr{
    pt = "Todos os serviços estão desligados nas opções do plugin.",
    en = "Every service is switched off in the plugin's options.",
  } })
  if #incidents > 0 then
    add({ type = "heading", text = tr{ pt = "Incidentes abertos", en = "Open incidents" } })
    add({ type = "list", key = "incidents", items = incidents })
  end
  larper.panel.set(tree)
end

local function options()
  local list = {}
  for _, s in ipairs(SERVICES) do
    list[#list + 1] = { type = "toggle", key = "svc-" .. s.key, label = s.name, hint = s.host, value = enabled(s),
      on_change = function(on)
        off[s.key] = (not on) or nil
        larper.storage.set("off", off)
        if on then
          poll(s)
        else
          state[s.key] = nil
          -- Ligado de novo depois, começa do zero: sem aviso do que mudou enquanto estava desligado.
          known[s.key] = nil
          larper.storage.set("known", known)
          render()
        end
      end }
  end
  larper.settings.set(list)
end

larper.command("/status", function()
  render()
  larper.panel.open()
  refresh()
end)

-- Um host aprovado agora: só quem ainda esperava a aprovação, não todos de novo.
larper.on("hosts", function()
  poll(function(s)
    local st = state[s.key]
    return not st or not st.indicator or st.error == "not_approved"
  end)
end)
larper.on("lang", function()
  options()
  render()
end)

larper.every(EVERY, function() poll() end)
options()
poll()
