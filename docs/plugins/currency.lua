-- @name Currency
-- @name:pt Cotação
-- @description /dolar, /euro, /btc and /cotacao GBP give the rate in reais: sent right away if under 5 minutes old, otherwise put in the message box. The panel shows rates and alerts like "USD < 5", checked every 5 minutes. From economia.awesomeapi.com.br.
-- @description:pt /dolar, /euro, /btc e /cotacao GBP dão a cotação em reais: vai direto se tem menos de 5 minutos, senão vai para a caixa de mensagem. O painel mostra as cotações e alertas como "USD < 5", conferidos a cada 5 minutos. Dados de economia.awesomeapi.com.br.
-- @version 1.0.0
-- @capabilities send, composer, http, notify, panel, storage, timers
-- @hosts economia.awesomeapi.com.br

local tr = larper.tr
local HOST = "economia.awesomeapi.com.br"
local FRESH = 300          -- uma cotação com menos de 5 minutos vai direto
local CHECK = 300          -- os alertas são conferidos a cada 5 minutos
local MAX_ALERTS = 20
local WATCH = { "USD-BRL", "EUR-BRL", "BTC-BRL" }

local function is_pt() return (larper.lang() or ""):match("^pt") ~= nil end

local NAMES = {
  USD = { "💵", "Dólar", "US Dollar" }, EUR = { "💶", "Euro", "Euro" }, BTC = { "₿", "Bitcoin", "Bitcoin" },
  GBP = { "💷", "Libra", "British Pound" }, JPY = { "💴", "Iene", "Japanese Yen" }, ETH = { "💎", "Ethereum", "Ethereum" },
  ARS = { "💱", "Peso argentino", "Argentine Peso" }, CAD = { "💱", "Dólar canadense", "Canadian Dollar" },
  AUD = { "💱", "Dólar australiano", "Australian Dollar" }, CHF = { "💱", "Franco suíço", "Swiss Franc" },
  CNY = { "💱", "Yuan", "Chinese Yuan" }, BRL = { "💱", "Real", "Brazilian Real" },
}
local SYMBOL = { BRL = "R$", USD = "US$", EUR = "€", GBP = "£", JPY = "¥" }
local ALIASES = { dolar = "USD", ["dólar"] = "USD", euro = "EUR", libra = "GBP", bitcoin = "BTC", iene = "JPY",
  ethereum = "ETH", peso = "ARS", real = "BRL" }

local rates = {}                                       -- "USD-BRL" → { bid, pct, code, codein, api_name, at }
local alerts = larper.storage.get("alerts") or {}      -- { id, pair, op, value, fired, fired_at, fired_bid }
local next_id = larper.storage.get("next_id") or 1
local timer, last_check, status, unseen = nil, nil, nil, 0
local draw

local function save()
  larper.storage.set("alerts", alerts)
  larper.storage.set("next_id", next_id)
end

-- --- Números --------------------------------------------------------------------------

local function num(v, dec)
  local s = string.format("%." .. dec .. "f", v)
  local sign, int, frac = s:match("^(-?)(%d+)%.?(%d*)$")
  local th, dp = ".", ","
  if not is_pt() then th, dp = ",", "." end
  int = int:reverse():gsub("(%d%d%d)", "%1" .. th):reverse()
  if int:sub(1, 1) == th then int = int:sub(2) end
  return sign .. int .. (frac ~= "" and (dp .. frac) or "")
end

local function money(v, code)
  local dec = v >= 1000 and 0 or (v >= 1 and 2 or 4)
  return (SYMBOL[code] or code) .. " " .. num(v, dec)
end

local function percent(p)
  local a = math.abs(p)
  local s = num(a, a < 0.1 and 2 or 1)
  return (p < 0 and "-" or "+") .. s .. "%"
end

-- "5,43", "5.43", "400.000", "1.234,56", "1,234.56". Com um separador só, seguido de três
-- dígitos, ele é de milhar.
local function parse_number(s)
  s = s:gsub("[^%d%.,]", "")
  if s == "" then return nil end
  local dot, comma = s:match(".*()%."), s:match(".*(),")
  if dot and comma then
    if dot > comma then s = s:gsub(",", "") else s = s:gsub("%.", ""):gsub(",", ".") end
  elseif dot or comma then
    local sep = dot and "%." or ","
    local _, count = s:gsub(sep, "")
    if count > 1 or #s - (dot or comma) == 3 then s = s:gsub(sep, "") else s = s:gsub(",", ".") end
  end
  return tonumber(s)
end

-- --- Nomes e texto ----------------------------------------------------------------------

local function name_of(code, api_name)
  local n = NAMES[code]
  if n then return is_pt() and n[2] or n[3] end
  if is_pt() and type(api_name) == "string" then return api_name:match("^([^/]+)") or code end
  return code
end

local function emoji_of(code) return (NAMES[code] or { "💱" })[1] end

local function label(r)
  local base = name_of(r.code, r.api_name)
  if r.codein == "BRL" then return base end
  local quote = name_of(r.codein)
  return tr{ pt = base .. " em " .. quote:lower(), en = base .. " in " .. quote }
end

local function line(r)
  local text = emoji_of(r.code) .. " " .. label(r) .. ": " .. money(r.bid, r.codein)
  if r.pct then text = text .. " (" .. percent(r.pct) .. " " .. tr{ pt = "hoje", en = "today" } .. ")" end
  return text
end

-- "USD", "usd-eur", "USD/EUR", "USDEUR", "dólar" → "USD-BRL" e afins.
local function parse_pair(s)
  local low = s:lower():gsub("%s", "")
  if ALIASES[low] then return ALIASES[low] .. "-BRL" end
  local up = low:upper()
  local a, b = up:match("^(%u+)[%-/](%u+)$")
  if not a and up:match("^%u+$") then
    if #up == 6 then a, b = up:sub(1, 3), up:sub(4) else a, b = up, "BRL" end
  end
  if not a or #a < 2 or #a > 5 or #b < 2 or #b > 5 or a == b then return nil end
  return a .. "-" .. b
end

-- --- Pedidos ----------------------------------------------------------------------------

local stamps = {}
local function budget(quiet)
  local now, keep = os.time(), {}
  for _, t in ipairs(stamps) do if now - t < 60 then keep[#keep + 1] = t end end
  stamps = keep
  if #keep >= 25 then
    if not quiet then
      larper.notify(tr{ pt = "Muitas consultas em pouco tempo. Tente de novo daqui a pouco", en = "Too many lookups in a short time. Try again in a moment" })
    end
    return false
  end
  keep[#keep + 1] = now
  return true
end

local function failure(res, pairs)
  if res.error == "not_approved" then
    return tr{ pt = "Aprove " .. HOST .. " no cartão do plugin, em Configurações → Plugins", en = "Approve " .. HOST .. " on the plugin's card in Settings → Plugins" }
  elseif res.error == "rate_limited" or res.status == 429 then
    return tr{ pt = "Muitas consultas seguidas. Tente de novo daqui a pouco", en = "Too many lookups in a row. Try again in a moment" }
  elseif res.error == "network" then
    return tr{ pt = "Sem conexão com a AwesomeAPI agora", en = "Couldn't reach AwesomeAPI right now" }
  elseif res.status == 404 then
    local which = table.concat(pairs, ", ")
    return tr{ pt = "A AwesomeAPI não tem a cotação " .. which, en = "AwesomeAPI has no rate for " .. which }
  elseif (res.status or 0) >= 500 then
    return tr{ pt = "A AwesomeAPI está com problemas agora (erro " .. res.status .. "). Tente mais tarde", en = "AwesomeAPI is having trouble right now (error " .. res.status .. "). Try again later" }
  end
  return tr{ pt = "Não consegui buscar a cotação", en = "Couldn't get the rate" }
end

local busy = {}
-- done(true) ou done(false, mensagem); mensagem false = já avisado pelo teto.
local function fetch(list, done, quiet)
  local key = table.concat(list, ",")
  if busy[key] then return end
  if not budget(quiet) then return done(false, false) end
  busy[key] = true
  larper.http.get("https://" .. HOST .. "/json/last/" .. key, function(res)
    busy[key] = nil
    local data = res.ok and larper.json.decode(res.body) or nil
    if type(data) ~= "table" then return done(false, failure(res, list)) end
    local got = 0
    for _, pair in ipairs(list) do
      local a, b = pair:match("^(%u+)%-(%u+)$")
      local q = data[a .. b]
      local bid = type(q) == "table" and tonumber(q.bid)
      if bid then
        rates[pair] = { bid = bid, pct = tonumber(q.pctChange), code = a, codein = b, api_name = q.name, at = os.time() }
        got = got + 1
      end
    end
    if got == 0 then return done(false, failure({ status = 404 }, list)) end
    done(true)
  end)
end

local function fresh(pair)
  local r = rates[pair]
  return r and os.time() - r.at < FRESH and r or nil
end

-- --- Comandos ---------------------------------------------------------------------------

-- Com a cotação nova à mão, o próprio comando envia; senão a resposta vai para a caixa,
-- que é o que dá para fazer depois de esperar a rede.
local function quote(pair)
  local r = fresh(pair)
  if r then
    larper.send(nil, line(r))
    return
  end
  fetch({ pair }, function(ok, err)
    if ok and rates[pair] then
      larper.insert(line(rates[pair]))
      if draw then draw() end
    elseif err then
      larper.notify(err)
    end
  end)
end

larper.command("/dolar", function() quote("USD-BRL") end)
larper.command("/euro", function() quote("EUR-BRL") end)
larper.command("/btc", function() quote("BTC-BRL") end)
larper.command("/cotacao", function(args)
  local pair = args ~= "" and parse_pair(args)
  if not pair then
    larper.notify(tr{ pt = "Use assim: /cotacao GBP ou /cotacao USD-EUR", en = "Use it like this: /cotacao GBP or /cotacao USD-EUR" })
    return
  end
  quote(pair)
end)

-- --- Alertas ----------------------------------------------------------------------------

local OPS = { ["<"] = function(a, b) return a < b end, ["<="] = function(a, b) return a <= b end,
  [">"] = function(a, b) return a > b end, [">="] = function(a, b) return a >= b end }

local function alert_title(a)
  local code, quote_code = a.pair:match("^(%u+)%-(%u+)$")
  return code .. " " .. a.op .. " " .. money(a.value, quote_code)
end

local function armed_pairs()
  local seen, list = {}, {}
  for _, a in ipairs(alerts) do
    if not a.fired and not seen[a.pair] then seen[a.pair] = true; list[#list + 1] = a.pair end
  end
  table.sort(list)
  return list
end

local function fire(a, r)
  a.fired, a.fired_at, a.fired_bid = true, os.time(), r.bid
  unseen = unseen + 1
  local below = a.op:sub(1, 1) == "<"
  local name = name_of(r.code, r.api_name)
  local limit = money(a.value, r.codein)
  local now = money(r.bid, r.codein)
  larper.notify(below
    and tr{ pt = "🔔 " .. name .. " abaixo de " .. limit .. ": agora " .. now, en = "🔔 " .. name .. " below " .. limit .. ": now " .. now }
    or tr{ pt = "🔔 " .. name .. " acima de " .. limit .. ": agora " .. now, en = "🔔 " .. name .. " above " .. limit .. ": now " .. now },
    { desktop = true })
end

-- Confere os alertas armados com as cotações que já estão na memória.
local function evaluate()
  local changed = false
  for _, a in ipairs(alerts) do
    local r = rates[a.pair]
    if not a.fired and r and OPS[a.op] and OPS[a.op](r.bid, a.value) then
      fire(a, r)
      changed = true
    end
  end
  if changed then save() end
end

local ensure_timer

local function check()
  local list = armed_pairs()
  if #list == 0 then return ensure_timer() end
  last_check = os.time()
  fetch(list, function(ok, err)
    if ok then
      status = nil
      evaluate()
    elseif err then
      status = err
    end
    ensure_timer()
    draw()
  end, true)
end

-- O temporizador só existe enquanto houver alerta armado.
function ensure_timer()
  local need = #armed_pairs() > 0
  if need and not timer then
    timer = larper.every(CHECK, check)
  elseif not need and timer then
    larper.cancel(timer)
    timer = nil
  end
end

local function add_alert(text)
  local t = (text or ""):gsub("R%$", ""):gsub("US%$", "")
  local code, op, value = t:match("^%s*([%a][%a%-/]*)%s*([<>]=?)%s*([%d%.,]+)%s*$")
  local pair = code and parse_pair(code)
  value = value and parse_number(value)
  if not pair or not value or value <= 0 then
    larper.notify(tr{ pt = "Escreva o alerta assim: USD < 5 ou BTC > 400000", en = "Write the alert like this: USD < 5 or BTC > 400000" })
    return
  end
  if #alerts >= MAX_ALERTS then
    larper.notify(tr{ pt = "Já são " .. MAX_ALERTS .. " alertas. Remova algum antes", en = "That's " .. MAX_ALERTS .. " alerts already. Remove one first" })
    return
  end
  -- Confere se a moeda existe antes de guardar: um código errado estragaria a checagem de todos.
  fetch({ pair }, function(ok, err)
    if not ok then
      if err then larper.notify(err) end
      return
    end
    alerts[#alerts + 1] = { id = next_id, pair = pair, op = op, value = value, fired = false }
    next_id = next_id + 1
    evaluate()
    save()
    ensure_timer()
    draw()
  end)
end

local function find_alert(id)
  for i, a in ipairs(alerts) do if a.id == id then return i, a end end
end

-- --- Painel ---------------------------------------------------------------------------

local function shown_pairs()
  local seen, list = {}, {}
  for _, p in ipairs(WATCH) do seen[p] = true; list[#list + 1] = p end
  for _, a in ipairs(alerts) do
    if not seen[a.pair] then seen[a.pair] = true; list[#list + 1] = a.pair end
  end
  return list
end

local function refresh(quiet)
  fetch(shown_pairs(), function(ok, err)
    if ok then status = nil; evaluate() elseif err then status = err end
    draw()
  end, quiet)
end

function draw()
  local tree = { title = tr{ pt = "Cotação", en = "Currency" } }
  if unseen > 0 then tree.badge = tostring(unseen) end
  local items = {}
  for _, pair in ipairs(shown_pairs()) do
    local r = rates[pair]
    local code = pair:match("^(%u+)")
    if r then
      local sub = money(r.bid, r.codein)
      if r.pct then sub = sub .. " · " .. percent(r.pct) .. " " .. tr{ pt = "hoje", en = "today" } end
      items[#items + 1] = { title = emoji_of(r.code) .. " " .. label(r), subtitle = sub, meta = os.date("%H:%M", r.at),
        on_click = function() larper.insert(line(r)) end }
    else
      items[#items + 1] = { title = emoji_of(code) .. " " .. name_of(code), subtitle = tr{ pt = "Ainda sem cotação", en = "No rate yet" } }
    end
  end
  tree[#tree + 1] = { type = "list", items = items }
  tree[#tree + 1] = { type = "text", style = "muted", text = tr{ pt = "Clique numa cotação para pôr na caixa de mensagem.", en = "Click a rate to put it in the message box." } }
  tree[#tree + 1] = { type = "row", { type = "button", label = tr{ pt = "Atualizar", en = "Refresh" }, on_click = function() refresh(false) end } }
  if status then tree[#tree + 1] = { type = "text", style = "danger", text = status } end
  tree[#tree + 1] = { type = "separator" }
  tree[#tree + 1] = { type = "heading", text = tr{ pt = "Alertas", en = "Alerts" } }
  tree[#tree + 1] = { type = "input", key = "alert", clear = true,
    placeholder = tr{ pt = "Novo alerta: USD < 5 ou BTC > 400000, e Enter", en = "New alert: USD < 5 or BTC > 400000, then Enter" },
    on_submit = add_alert }
  local list = {}
  for _, a in ipairs(alerts) do
    local id = a.id
    local r = rates[a.pair]
    local sub
    if a.fired then
      local quote_code = a.pair:match("%-(%u+)$")
      sub = tr{ pt = "Disparou às ", en = "Went off at " } .. os.date("%H:%M", a.fired_at or 0)
        .. (a.fired_bid and (tr{ pt = " com ", en = " at " } .. money(a.fired_bid, quote_code)) or "")
    elseif r then
      sub = tr{ pt = "Armado · agora ", en = "Armed · now " } .. money(r.bid, r.codein)
    else
      sub = tr{ pt = "Armado", en = "Armed" }
    end
    local actions = {}
    if a.fired then
      actions[#actions + 1] = { label = tr{ pt = "Rearmar", en = "Re-arm" }, on_click = function()
        local _, x = find_alert(id)
        if not x then return end
        x.fired, x.fired_at, x.fired_bid = false, nil, nil
        save()
        ensure_timer()
        draw()
      end }
    end
    actions[#actions + 1] = { label = tr{ pt = "Remover", en = "Remove" }, style = "danger", on_click = function()
      local i = find_alert(id)
      if i then table.remove(alerts, i) end
      save()
      ensure_timer()
      draw()
    end }
    list[#list + 1] = { title = (a.fired and "🔔 " or "⏳ ") .. alert_title(a), subtitle = sub, actions = actions }
  end
  tree[#tree + 1] = { type = "list", items = list, empty = tr{ pt = "Nenhum alerta ainda.", en = "No alerts yet." } }
  tree[#tree + 1] = { type = "text", style = "muted", text = tr{
    pt = "Os alertas armados são conferidos a cada 5 minutos enquanto o app está aberto. Cada um avisa uma vez; depois é só rearmar.",
    en = "Armed alerts are checked every 5 minutes while the app is open. Each one tells you once; re-arm it to watch again." } }
  larper.panel.set(tree)
end

larper.on("panel", function(open)
  if not open then return end
  if unseen > 0 then unseen = 0; draw() end
  for _, p in ipairs(shown_pairs()) do
    if not fresh(p) then return refresh(true) end
  end
end)

-- Ao conectar, confere logo o que pode ter mudado com o app fechado.
larper.on("ready", function()
  if #armed_pairs() > 0 and (not last_check or os.time() - last_check >= 60) then check() end
end)

larper.on("lang", draw)
ensure_timer()
draw()
