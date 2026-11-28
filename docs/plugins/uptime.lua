-- @name Site monitor
-- @name:pt Monitor de site
-- @description Checks your sites every minute and warns you when one goes down and when it comes back. Before using it, put your own sites in the @hosts line at the top of this file, then add the addresses on its panel (/uptime).
-- @description:pt Confere seus sites a cada minuto e avisa quando um cai e quando volta. Antes de usar, ponha os seus sites na linha @hosts no começo deste arquivo e depois adicione os endereços no painel (/uptime).
-- @version 1.0.0
-- @capabilities http, timers, panel, storage, notify
-- @hosts example.com
--
-- COMO USAR
-- 1. Troque example.com na linha @hosts acima pelos seus sites, separados por vírgula
--    (até 8). *.seusite.com vale para os subdomínios de seusite.com, mas não para
--    seusite.com: ponha os dois se precisar dos dois.
-- 2. Salve, clique em Recarregar em Configurações → Plugins e aprove cada host no cartão.
-- 3. Abra o painel (/uptime) e adicione os endereços https:// que quer acompanhar.
--
-- HOW TO USE
-- 1. Replace example.com in the @hosts line above with your own sites, separated by
--    commas (up to 8). *.yoursite.com covers the subdomains of yoursite.com, but not
--    yoursite.com itself: list both if you need both.
-- 2. Save, click Reload in Settings → Plugins and approve each host on the card.
-- 3. Open the panel (/uptime) and add the https:// addresses you want to watch.

local tr = larper.tr
local MAX = 8
local EVERY = 60
-- Segundos entre dois pedidos, e quantos podem estar no ar ao mesmo tempo (o app
-- recusa o quarto).
local GAP = 2
local FLYING_MAX = 3
-- Falhas seguidas para contar como fora do ar.
local DOWN_AFTER = 2

-- Guardado: { url, state ("up"/"down"/nil), since }. O resto fica na memória.
local sites = {}
for _, s in ipairs(larper.storage.get("sites") or {}) do
  if type(s) == "table" and type(s.url) == "string" and #sites < MAX then
    sites[#sites + 1] = { url = s.url, state = (s.state == "up" or s.state == "down") and s.state or nil, since = tonumber(s.since) }
  end
end

local flying = 0
local last_sent = nil
local timer = nil
local message = nil -- o aviso do campo de endereço: { why = "http" } ou { host = "..." }
local render
local arm

local function save()
  local out = {}
  for _, s in ipairs(sites) do out[#out + 1] = { url = s.url, state = s.state, since = s.since } end
  larper.storage.set("sites", out)
end

local function listed(site)
  for _, s in ipairs(sites) do
    if s == site then return true end
  end
  return false
end

local function label(url)
  return (url:gsub("^https://", ""):gsub("^([^/]+)/$", "%1"))
end

local function host_of(url)
  return url:match("^https://([^/?#]+)")
end

local check

local function result(site, res, method)
  flying = math.max(flying - 1, 0)
  if not listed(site) then return end
  local now = os.time()
  site.checked = now
  site.problem = nil
  if res.error == "not_approved" then
    site.problem = "approve"
    return render()
  elseif res.error == "rate_limited" then
    site.due = now + 10
    arm()
    return render()
  end
  -- Alguns servidores não aceitam HEAD: aí vai um GET, e resposta grande também conta como no ar.
  if method == "HEAD" and (res.status == 405 or res.status == 501) and not res.error then
    if not check(site, "GET") then render() end
    return
  end
  local up = res.ok or res.error == "redirect" or res.error == "too_big"
    or (not res.error and res.status >= 300 and res.status < 400)
  if up then
    site.fails = 0
    site.code = res.status
    site.redirect = res.error == "redirect"
    if site.state == "down" then
      larper.notify("🟢 " .. tr{ pt = label(site.url) .. " voltou", en = label(site.url) .. " is back up" }, { desktop = true })
    end
    if site.state ~= "up" then
      site.state = "up"
      site.since = now
      save()
    end
  else
    site.fails = (site.fails or 0) + 1
    site.code = res.error or res.status
    if site.fails >= DOWN_AFTER and site.state ~= "down" then
      site.state = "down"
      site.since = now
      save()
      local why = type(site.code) == "number" and "HTTP " .. site.code or tostring(site.code)
      larper.notify("🔴 " .. tr{ pt = label(site.url) .. " caiu (" .. why .. ")", en = label(site.url) .. " is down (" .. why .. ")" }, { desktop = true })
    end
  end
  render()
end

-- Devolve false, e o erro, se o app recusar o endereço (em geral, host fora de @hosts).
check = function(site, method)
  method = method or "HEAD"
  local fn = method == "GET" and larper.http.get or larper.http.head
  flying = flying + 1
  last_sent = os.time()
  local ok, err = pcall(fn, site.url, function(res) result(site, res, method) end)
  if not ok then
    flying = math.max(flying - 1, 0)
    site.problem = "hosts"
    return false, tostring(err)
  end
  return true
end

local function tick()
  timer = nil
  local now = os.time()
  local pick
  for _, s in ipairs(sites) do
    if s.due <= now and (not pick or s.due < pick.due) then pick = s end
  end
  if pick then
    if flying >= FLYING_MAX then
      pick.due = now + GAP
    else
      pick.due = now + EVERY
      if not check(pick) then render() end
    end
  end
  arm()
end

-- Um temporizador só, para o próximo que vence, com um respiro entre os pedidos.
arm = function()
  if timer then larper.cancel(timer) end
  timer = nil
  local nearest
  for _, s in ipairs(sites) do
    if not nearest or s.due < nearest then nearest = s.due end
  end
  if not nearest then return end
  local now = os.time()
  local wait = nearest - now
  if last_sent then wait = math.max(wait, last_sent + GAP - now) end
  timer = larper.after(math.max(wait, 1), tick)
end

-- Espalha as conferências pelo minuto.
local function spread(first)
  local now = os.time()
  for i, s in ipairs(sites) do
    s.due = now + first + (i - 1) * math.floor(EVERY / #sites)
  end
end

local MESSAGES = {
  http = { pt = "Só endereços https://: o plugin não usa http sem criptografia.", en = "Only https:// addresses: the plugin doesn't use unencrypted http." },
  bad = { pt = "Não entendi esse endereço. Exemplo: https://example.com/saude", en = "I didn't get that address. Example: https://example.com/health" },
  port = { pt = "Sem porta nem usuário no endereço.", en = "No port or user in the address." },
  chars = { pt = "O endereço tem espaços ou caracteres sem codificar.", en = "The address has spaces or characters that aren't encoded." },
  dup = { pt = "Esse endereço já está na lista.", en = "That address is already on the list." },
  refused = { pt = "O app não aceitou esse endereço. Confira como ele está escrito.", en = "The app didn't accept that address. Check how it's written." },
  full = { pt = "Até 8 endereços: remova um antes.", en = "Up to 8 addresses: remove one first." },
}

local function hosts_message(host)
  return tr{
    pt = host .. " não está na linha @hosts do plugin. Abra uptime.lua na pasta de plugins, ponha " .. host .. " em @hosts (no começo do arquivo), salve e clique em Recarregar em Configurações → Plugins.",
    en = host .. " isn't in the plugin's @hosts line. Open uptime.lua in the plugins folder, add " .. host .. " to @hosts (at the top of the file), save and click Reload in Settings → Plugins.",
  }
end

local function normalize(text)
  text = text:match("^%s*(.-)%s*$")
  if text == "" then return nil, "bad" end
  if text:lower():match("^http://") then return nil, "http" end
  if not text:lower():match("^https://") then
    if text:match("^%a[%w+.-]*://") then return nil, "bad" end
    text = "https://" .. text
  end
  local host, rest = text:match("^[hH][tT][tT][pP][sS]://([^/?#]+)(.*)$")
  if not host or not host:find(".", 1, true) then return nil, "bad" end
  if host:find("[@:]") then return nil, "port" end
  if text:find("[%s\"<>{}|\\^`\128-\255]") then return nil, "chars" end
  if rest == "" then rest = "/" end
  return "https://" .. host:lower() .. rest
end

local function add(text)
  local url, why = normalize(text)
  if not url then
    message = { why = why }
    return render()
  end
  for _, s in ipairs(sites) do
    if s.url == url then
      message = { why = "dup" }
      return render()
    end
  end
  if #sites >= MAX then
    message = { why = "full" }
    return render()
  end
  local site = { url = url, due = os.time() + EVERY }
  sites[#sites + 1] = site
  -- A primeira conferência já diz se o host está em @hosts: o app recusa o que não está.
  local ok, err = check(site)
  if not ok then
    table.remove(sites)
    message = err:find("@hosts", 1, true) and { host = host_of(url) } or { why = "refused" }
    return render()
  end
  message = nil
  save()
  arm()
  render()
end

local function remove(site)
  for i, s in ipairs(sites) do
    if s == site then
      table.remove(sites, i)
      save()
      arm()
      return render()
    end
  end
end

-- 45 s, 12 min, 2 h 5 min, 3 d 4 h.
local function span(sec)
  sec = math.max(sec, 0)
  if sec < 60 then return sec .. " s" end
  if sec < 3600 then return (sec // 60) .. " min" end
  if sec < 86400 then
    local m = (sec % 3600) // 60
    return (sec // 3600) .. " h" .. (m > 0 and " " .. m .. " min" or "")
  end
  local h = (sec % 86400) // 3600
  return (sec // 86400) .. " d" .. (h > 0 and " " .. h .. " h" or "")
end

render = function()
  local now = os.time()
  local tree = { title = tr{ pt = "Monitor de site", en = "Site monitor" } }
  local function put(item) tree[#tree + 1] = item end
  put({ type = "text", style = "muted", text = tr{
    pt = "Confere cada endereço a cada minuto e avisa quando cai (2 falhas seguidas) e quando volta. Só hosts da linha @hosts de uptime.lua.",
    en = "Checks each address every minute and warns you when it goes down (2 failures in a row) and when it comes back. Only hosts in the @hosts line of uptime.lua.",
  } })
  put({ type = "input", key = "url", clear = true,
    placeholder = tr{ pt = "https://seusite.com/saude (Enter para adicionar)", en = "https://yoursite.com/health (Enter to add)" },
    on_submit = add })
  if message then
    put({ type = "text", key = "message", style = "danger", text = message.host and hosts_message(message.host) or tr(MESSAGES[message.why]) })
  end
  local items = {}
  for i, s in ipairs(sites) do
    local icon, sub = "⚪", tr{ pt = "Conferindo…", en = "Checking…" }
    if s.state == "up" then
      icon = "🟢"
      sub = tr{ pt = "No ar há ", en = "Up for " } .. span(now - (s.since or now))
    elseif s.state == "down" then
      icon = "🔴"
      sub = tr{ pt = "Fora do ar há ", en = "Down for " } .. span(now - (s.since or now))
    end
    if s.redirect then sub = sub .. tr{ pt = " · redireciona", en = " · redirects" } end
    if s.state ~= "down" and (s.fails or 0) > 0 then
      local why = type(s.code) == "number" and "HTTP " .. s.code or tostring(s.code)
      sub = sub .. tr{ pt = " · falhou agora há pouco (", en = " · just failed (" } .. why .. ")"
    end
    if s.problem == "approve" then
      sub = sub .. tr{ pt = " · aprove o host no cartão do plugin", en = " · approve the host on the plugin's card" }
    elseif s.problem == "hosts" then
      sub = sub .. tr{ pt = " · o host não está mais em @hosts", en = " · the host isn't in @hosts anymore" }
    end
    local meta = s.checked and tr{ pt = "conferido ", en = "checked " } .. os.date("%H:%M", s.checked) or ""
    items[#items + 1] = {
      key = "site" .. i,
      title = icon .. " " .. label(s.url),
      subtitle = sub,
      meta = meta,
      actions = { { label = tr{ pt = "Remover", en = "Remove" }, style = "danger", key = "remove" .. i, on_click = function() remove(s) end } },
    }
  end
  put({ type = "list", key = "sites", items = items, empty = tr{
    pt = "Nenhum endereço ainda. Escreva um aqui em cima e aperte Enter.",
    en = "No addresses yet. Type one above and press Enter.",
  } })
  larper.panel.set(tree)
end

larper.command("/uptime", function()
  render()
  larper.panel.open()
end)

-- Um host aprovado agora: confere logo quem esperava por ele.
larper.on("hosts", function()
  local now = os.time()
  local n = 0
  for _, s in ipairs(sites) do
    if s.problem == "approve" then
      s.due = now + 1 + n * GAP
      n = n + 1
    end
  end
  arm()
end)

larper.on("lang", function() render() end)

spread(3)
arm()
render()
