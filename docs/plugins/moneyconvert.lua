-- @name Money in chat
-- @name:pt Conversão no chat
-- @description Amounts in other currencies (US$ 20, 15€, 10 pounds…) get a note with the value in your currency, like "≈ R$ 110,00", up to 3 per message. Rates from economia.awesomeapi.com.br every 30 minutes; message text never leaves the app.
-- @description:pt Valores em outras moedas (US$ 20, 15€, 10 libras…) ganham uma nota com o valor na sua moeda, como "≈ R$ 110,00", até 3 por mensagem. Cotações de economia.awesomeapi.com.br a cada 30 minutos; o texto das mensagens nunca sai do app.
-- @version 1.0.0
-- @capabilities messages, decorate, http, settings, storage, timers
-- @hosts economia.awesomeapi.com.br

local tr = larper.tr
local HOST = "economia.awesomeapi.com.br"
local REFRESH = 1800
local MAX_AMOUNTS = 3
local MAX_NOTED = 2000
-- Só estas palavras fazem a mensagem chegar ao Lua. O app ignora maiúsculas só nas letras
-- sem acento, então "DÓLAR" precisa da sua própria entrada.
local CONTAINS = { "$", "€", "£", "dólar", "dÓlar", "dolar", "dollar", "eur", "libra", "pound", "usd", "gbp", "reais", "brl" }

local function is_pt() return (larper.lang() or ""):match("^pt") ~= nil end

local target = larper.storage.get("target") or "BRL"
-- Quantos reais vale uma unidade de cada moeda. Guardado para já servir ao abrir o app.
local saved = larper.storage.get("rates")
local rates = saved and saved.brl or nil
local rates_at = saved and saved.at or 0
if rates and os.time() - rates_at > 12 * 3600 then rates = nil end

local noted, noted_count = {}, 0   -- id → true: mensagens com nota nossa
local dismissed = {}               -- id → true: a pessoa fechou a nota
local waiting = {}                 -- mensagens que chegaram antes das cotações

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

-- "1.234,56", "1,234.56", "20", "2,5", "1.500". Um separador só seguido de três dígitos é de milhar.
local function parse_number(s)
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

local SYMBOL = { BRL = "R$", USD = "US$", EUR = "€", GBP = "£" }

-- O valor da mensagem sai como foi escrito (sem centavos se não tinha); a conversão, com centavos.
local function money(v, code, exact)
  local dec = (exact and v == math.floor(v)) and 0 or 2
  return SYMBOL[code] .. " " .. num(v, dec)
end

-- --- Achar os valores -----------------------------------------------------------------

local PREFIX = {   -- o que vem antes do número, da mais longa para a mais curta
  { "us$", "USD" }, { "u$", "USD" }, { "r$", "BRL" }, { "$", "USD" }, { "€", "EUR" }, { "£", "GBP" },
  { "usd", "USD" }, { "eur", "EUR" }, { "gbp", "GBP" }, { "brl", "BRL" },
}
local SUFFIX = {   -- a palavra (ou símbolo) logo depois do número
  ["€"] = "EUR", ["£"] = "GBP", ["usd"] = "USD", ["eur"] = "EUR", ["gbp"] = "GBP", ["brl"] = "BRL",
  ["dólares"] = "USD", ["dolares"] = "USD", ["dólar"] = "USD", ["dolar"] = "USD", ["dollars"] = "USD", ["dollar"] = "USD",
  ["euros"] = "EUR", ["euro"] = "EUR", ["libras"] = "GBP", ["libra"] = "GBP", ["pounds"] = "GBP", ["pound"] = "GBP",
  ["reais"] = "BRL",
}

local function currency_before(low, s)
  local before = low:sub(1, s - 1):gsub(" $", "")
  for _, p in ipairs(PREFIX) do
    local sym, code = p[1], p[2]
    if before:sub(-#sym) == sym then
      local prev = before:sub(-#sym - 1, -#sym - 1)
      -- "$20" vale, mas não o "$" de "R$" (já pego acima) nem "usd" no meio de uma palavra.
      if prev == "" or not prev:match("[%w\128-\255]") or sym:match("^[\128-\255]") then return code end
    end
  end
end

local function currency_after(low, e)
  local after = low:sub(e):gsub("^ ", "")
  -- Em UTF-8 o € tem 3 bytes e o £ tem 2.
  if after:sub(1, 3) == "€" then return "EUR" end
  if after:sub(1, 2) == "£" then return "GBP" end
  local word = after:match("^([%a\128-\255]+)")
  if word then return SUFFIX[word] end
end

-- Os valores { value, code } na ordem do texto (no máximo 10).
local function find_amounts(text)
  local low = text:lower():gsub("\xC3\x93", "\xC3\xB3")   -- "DÓLAR" → "dólar"
  local out = {}
  for s, raw, e in low:gmatch("()(%d[%d%.,]*)()") do
    -- Um número colado em letras ("mp3", "4k") não é dinheiro.
    local prev = low:sub(s - 1, s - 1)
    if not prev:match("[%a%d]") then
      local trimmed = raw:gsub("[%.,]+$", "")
      local stop = s + #trimmed
      local code = currency_before(low, s) or currency_after(low, stop)
      local value = code and parse_number(trimmed)
      if value and value > 0 and value < 1e12 then
        out[#out + 1] = { value = value, code = code }
        if #out == 10 then break end
      end
    end
  end
  return out
end

-- --- Notas ----------------------------------------------------------------------------

local function convert(v, from)
  if not rates then return nil end
  local a, b = rates[from], rates[target]
  if not a or not b then return nil end
  return v * a / b
end

-- Até MAX_AMOUNTS conversões; o que já está na moeda escolhida (ou repetido) fica de fora.
local function note_for(text)
  local parts, seen = {}, {}
  for _, m in ipairs(find_amounts(text)) do
    local key = m.code .. m.value
    if m.code ~= target and not seen[key] then
      seen[key] = true
      local v = convert(m.value, m.code)
      if v then parts[#parts + 1] = money(m.value, m.code, true) .. " ≈ " .. money(v, target) end
      if #parts == MAX_AMOUNTS then break end
    end
  end
  if #parts == 0 then return nil end
  return "💱 " .. table.concat(parts, " · ")
end

local function forget(id)
  if noted[id] then noted[id] = nil; noted_count = noted_count - 1 end
end

local function decorate(m)
  if dismissed[m.id] or m.ignored then return end
  if not rates then
    if #waiting < 50 then waiting[#waiting + 1] = m end
    return
  end
  local note = note_for(m.content or "")
  if note then
    if not noted[m.id] then
      if noted_count >= MAX_NOTED then return end
      noted[m.id] = true
      noted_count = noted_count + 1
    end
    larper.decorate(m, { note = note })
  elseif noted[m.id] then
    larper.undecorate(m)
    forget(m.id)
  end
end

-- As mensagens já na tela não disparam "message": pede as carregadas. Pedir de novo em
-- menos de meio segundo volta false, então tenta outra vez daqui a 1 segundo.
local retry = nil
local function scan_open_channel()
  if not larper.channel() then return end
  local asked = larper.messages({ contains = CONTAINS, limit = 500 }, function(list)
    for _, m in ipairs(list) do decorate(m) end
  end)
  if asked == false and not retry then
    retry = larper.after(1, function()
      retry = nil
      scan_open_channel()
    end)
  end
end

local function redo_all()
  for id in pairs(noted) do larper.undecorate(id) end
  noted, noted_count = {}, 0
  scan_open_channel()
end

-- --- Cotações -------------------------------------------------------------------------

local status = nil
local options

local function fetch_rates()
  larper.http.get("https://" .. HOST .. "/json/last/USD-BRL,EUR-BRL,GBP-BRL", function(res)
    local data = res.ok and larper.json.decode(res.body) or nil
    local function bid(k) return type(data) == "table" and type(data[k]) == "table" and tonumber(data[k].bid) or nil end
    local usd, eur, gbp = bid("USDBRL"), bid("EURBRL"), bid("GBPBRL")
    if not (usd and eur and gbp) then
      if res.error == "not_approved" then
        status = tr{ pt = "Aprove " .. HOST .. " aqui no cartão para as conversões aparecerem.", en = "Approve " .. HOST .. " on this card for the conversions to show." }
      else
        status = tr{ pt = "Não consegui buscar as cotações agora; tento de novo em 30 minutos.", en = "Couldn't get the rates right now; trying again in 30 minutes." }
      end
      return options()
    end
    local first = rates == nil
    rates, rates_at, status = { BRL = 1, USD = usd, EUR = eur, GBP = gbp }, os.time(), nil
    larper.storage.set("rates", { brl = rates, at = rates_at })
    local pending = waiting
    waiting = {}
    for _, m in ipairs(pending) do decorate(m) end
    if first then scan_open_channel() end
    options()
  end)
end

-- --- Cartão ---------------------------------------------------------------------------

function options()
  local list = {
    { type = "select", key = "target", label = tr{ pt = "Mostrar valores em", en = "Show amounts in" }, value = target,
      options = {
        { value = "BRL", label = tr{ pt = "Real (R$)", en = "Brazilian real (R$)" } },
        { value = "USD", label = tr{ pt = "Dólar (US$)", en = "US dollar (US$)" } },
        { value = "EUR", label = tr{ pt = "Euro (€)", en = "Euro (€)" } },
      },
      on_change = function(v)
        if not SYMBOL[v] or v == "GBP" then return end
        target = v
        larper.storage.set("target", v)
        redo_all()
      end },
  }
  if status then list[#list + 1] = { type = "text", style = "danger", text = status } end
  if rates then
    list[#list + 1] = { type = "text", style = "muted", text = tr{ pt = "Cotações de ", en = "Rates from " } .. os.date("%d/%m %H:%M", rates_at) }
  end
  larper.settings.set(list)
end

-- --- Eventos --------------------------------------------------------------------------

larper.on("message", decorate, { contains = CONTAINS })
larper.on("edit", decorate, { contains = CONTAINS })
-- Uma edição que tira o valor não passa pelo filtro acima, mas a nota antiga precisa sair.
larper.on("edit", function(m)
  if noted[m.id] and not note_for(m.content or "") then
    larper.undecorate(m)
    forget(m.id)
  end
end)
larper.on("delete", function(d) forget(d.id); dismissed[d.id] = nil end)
larper.on("dismiss", function(d) forget(d.id); dismissed[d.id] = true end)
larper.on("channel", function(c)
  if c then scan_open_channel() end
end)
-- Aprovou o host agora: não espera os 30 minutos.
larper.on("hosts", function()
  if not rates then fetch_rates() end
end)
larper.on("lang", function()
  options()
  redo_all()
end)

larper.every(REFRESH, fetch_rates)
fetch_rates()
options()
-- Com as cotações guardadas da última vez, a tela aberta já ganha as notas.
if rates then scan_open_channel() end
