-- @name Brazil toolkit
-- @name:pt Canivete BR
-- @description /cep 01001000 gives the address, /feriados [year] the national holidays, /ddd 81 the state and cities of an area code, /cnpj 00.000.000/0001-91 the company's name, status and city. Answers go to the message box. Only what you type goes to brasilapi.com.br.
-- @description:pt /cep 01001000 dá o endereço, /feriados [ano] os feriados nacionais, /ddd 81 o estado e as cidades do DDD, /cnpj 00.000.000/0001-91 o nome, a situação e a cidade da empresa. A resposta vai para a caixa de mensagem. Só o que você digita vai para brasilapi.com.br.
-- @version 1.0.0
-- @capabilities composer, http, notify
-- @hosts brasilapi.com.br

local tr = larper.tr
local HOST = "brasilapi.com.br"
local BASE = "https://" .. HOST .. "/api/"

local function is_pt() return (larper.lang() or ""):match("^pt") ~= nil end

-- --- Pedidos: cache, teto por minuto e mensagens de erro ---------------------------------

local cache, cache_order = {}, {}
local function remember(key, value)
  if not cache[key] then cache_order[#cache_order + 1] = key end
  cache[key] = { value = value, at = os.time() }
  while #cache_order > 100 do cache[table.remove(cache_order, 1)] = nil end
end
local function recall(key, ttl)
  local c = cache[key]
  if c and os.time() - c.at < ttl then return c.value end
end

-- O app corta em 30 por minuto; paro um pouco antes para sobrar margem.
local stamps = {}
local function budget()
  local now, keep = os.time(), {}
  for _, t in ipairs(stamps) do if now - t < 60 then keep[#keep + 1] = t end end
  stamps = keep
  if #keep >= 25 then
    larper.notify(tr{ pt = "Muitas consultas em pouco tempo. Tente de novo daqui a pouco", en = "Too many lookups in a short time. Try again in a moment" })
    return false
  end
  keep[#keep + 1] = now
  return true
end

local function failure(res)
  if res.error == "not_approved" then
    return tr{ pt = "Aprove " .. HOST .. " no cartão do plugin, em Configurações → Plugins", en = "Approve " .. HOST .. " on the plugin's card in Settings → Plugins" }
  elseif res.error == "rate_limited" or res.status == 429 then
    return tr{ pt = "Muitas consultas seguidas. Tente de novo daqui a pouco", en = "Too many lookups in a row. Try again in a moment" }
  elseif res.error == "network" then
    return tr{ pt = "Sem conexão com a BrasilAPI agora", en = "Couldn't reach BrasilAPI right now" }
  elseif (res.status or 0) >= 500 then
    return tr{ pt = "A BrasilAPI está com problemas agora (erro " .. res.status .. "). Tente mais tarde", en = "BrasilAPI is having trouble right now (error " .. res.status .. "). Try again later" }
  end
  return tr{ pt = "Não consegui consultar a BrasilAPI", en = "Couldn't look that up on BrasilAPI" }
end

-- Um pedido por chave de cada vez: repetir o comando enquanto espera não pede de novo.
local busy = {}
local function fetch(key, path, ttl, not_found, done)
  local hit = recall(key, ttl)
  if hit then return done(hit) end
  if busy[key] then return end
  if not budget() then return end
  busy[key] = true
  larper.http.get(BASE .. path, { headers = { Accept = "application/json" } }, function(res)
    busy[key] = nil
    local data = res.ok and larper.json.decode(res.body) or nil
    if data ~= nil then
      remember(key, data)
      return done(data)
    end
    if res.status == 404 or res.status == 400 then
      larper.notify(not_found)
    else
      larper.notify(failure(res))
    end
  end)
end

-- --- Texto ----------------------------------------------------------------------------

-- Minúsculas também nas letras acentuadas (Á → á), que o string.lower não conhece.
local function lower(s)
  return (s:lower():gsub("\xC3([\x80-\x9E])", function(b)
    if b == "\x97" then return "\xC3\x97" end
    return "\xC3" .. string.char(b:byte() + 32)
  end))
end
local function upper_first(w)
  local c = w:sub(1, 1)
  if c == "\xC3" then
    local b = w:byte(2) or 0
    if b >= 0xA0 and b <= 0xBE and b ~= 0xB7 then return "\xC3" .. string.char(b - 32) .. w:sub(3) end
    return w
  end
  return c:upper() .. w:sub(2)
end
local SMALL = { de = true, da = true, ["do"] = true, das = true, dos = true, e = true, d = true }
-- "SÃO JOSÉ DA COROA GRANDE" → "São José da Coroa Grande".
local function title(s)
  local out = {}
  for w in lower(s):gmatch("%S+") do
    if #out > 0 and SMALL[w] then out[#out + 1] = w
    else
      w = upper_first(w):gsub("([%-'])(.)", function(sep, c) return sep .. c:upper() end)
      out[#out + 1] = w
    end
  end
  return table.concat(out, " ")
end
-- Para ordenar: sem acento.
local function fold(s)
  local map = { ["á"] = "a", ["à"] = "a", ["â"] = "a", ["ã"] = "a", ["é"] = "e", ["ê"] = "e", ["í"] = "i",
    ["ó"] = "o", ["ô"] = "o", ["õ"] = "o", ["ú"] = "u", ["ü"] = "u", ["ç"] = "c" }
  return (lower(s):gsub("\xC3.", map))
end

local UF = {
  AC = { "Acre", "Rio Branco" }, AL = { "Alagoas", "Maceió" }, AP = { "Amapá", "Macapá" },
  AM = { "Amazonas", "Manaus" }, BA = { "Bahia", "Salvador" }, CE = { "Ceará", "Fortaleza" },
  DF = { "Distrito Federal", "Brasília" }, ES = { "Espírito Santo", "Vitória" }, GO = { "Goiás", "Goiânia" },
  MA = { "Maranhão", "São Luís" }, MT = { "Mato Grosso", "Cuiabá" }, MS = { "Mato Grosso do Sul", "Campo Grande" },
  MG = { "Minas Gerais", "Belo Horizonte" }, PA = { "Pará", "Belém" }, PB = { "Paraíba", "João Pessoa" },
  PR = { "Paraná", "Curitiba" }, PE = { "Pernambuco", "Recife" }, PI = { "Piauí", "Teresina" },
  RJ = { "Rio de Janeiro", "Rio de Janeiro" }, RN = { "Rio Grande do Norte", "Natal" },
  RS = { "Rio Grande do Sul", "Porto Alegre" }, RO = { "Rondônia", "Porto Velho" }, RR = { "Roraima", "Boa Vista" },
  SC = { "Santa Catarina", "Florianópolis" }, SP = { "São Paulo", "São Paulo" }, SE = { "Sergipe", "Aracaju" },
  TO = { "Tocantins", "Palmas" },
}

local function digits(s) return (s:gsub("%D", "")) end

-- --- /cep -------------------------------------------------------------------------------

larper.command("/cep", function(args)
  local cep = digits(args)
  if #cep ~= 8 or args:find("[^%d%s%.%-]") then
    larper.notify(tr{ pt = "O CEP tem 8 números. Use assim: /cep 01001-000", en = "A CEP has 8 digits. Use it like this: /cep 01001-000" })
    return
  end
  local shown = cep:sub(1, 5) .. "-" .. cep:sub(6)
  fetch("cep:" .. cep, "cep/v1/" .. cep, 86400,
    tr{ pt = "Não achei o CEP " .. shown, en = "Couldn't find CEP " .. shown },
    function(d)
      local parts = {}
      for _, k in ipairs({ "street", "neighborhood" }) do
        if type(d[k]) == "string" and d[k] ~= "" then parts[#parts + 1] = d[k] end
      end
      local city = (d.city or "?") .. (d.state and ("/" .. d.state) or "")
      parts[#parts + 1] = city
      larper.insert("📮 CEP " .. shown .. ": " .. table.concat(parts, ", "))
    end)
end)

-- --- /feriados ----------------------------------------------------------------------------

-- Dia da semana sem os.time (que no Windows não volta antes de 1970). 0 = domingo.
local function weekday(y, m, d)
  local t = { 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 }
  if m < 3 then y = y - 1 end
  return (y + y // 4 - y // 100 + y // 400 + t[m] + d) % 7
end
local function day_number(y, m, d)
  if m <= 2 then y = y - 1 end
  local era = y // 400
  local yoe = y - era * 400
  local doy = (153 * (m + (m > 2 and -3 or 9)) + 2) // 5 + d - 1
  return era * 146097 + yoe * 365 + yoe // 4 - yoe // 100 + doy
end

local WEEK_PT = { "dom", "seg", "ter", "qua", "qui", "sex", "sáb" }
local WEEK_EN = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }
local MONTH_EN = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }
-- A API só tem os nomes em português.
local HOLIDAY_EN = {
  ["confraternização mundial"] = "New Year's Day", ["carnaval"] = "Carnival", ["sexta-feira santa"] = "Good Friday",
  ["páscoa"] = "Easter", ["tiradentes"] = "Tiradentes Day", ["dia do trabalho"] = "Labour Day",
  ["corpus christi"] = "Corpus Christi", ["independência do brasil"] = "Independence Day",
  ["nossa senhora aparecida"] = "Our Lady of Aparecida", ["finados"] = "All Souls' Day",
  ["proclamação da república"] = "Republic Day", ["dia da consciência negra"] = "Black Consciousness Day",
  ["natal"] = "Christmas",
}

local function holiday_line(h)
  local y, m, d = tostring(h.date or ""):match("^(%d+)%-(%d+)%-(%d+)$")
  if not y then return nil end
  y, m, d = tonumber(y), tonumber(m), tonumber(d)
  local wd = weekday(y, m, d) + 1
  local name = tostring(h.name or "?")
  if is_pt() then
    return string.format("%02d/%02d (%s) %s", d, m, WEEK_PT[wd], name), y, m, d
  end
  return string.format("%s %d (%s) %s", MONTH_EN[m], d, WEEK_EN[wd], HOLIDAY_EN[lower(name)] or name), y, m, d
end

larper.command("/feriados", function(args)
  local now = os.date("*t")
  local year = now.year
  if args ~= "" then
    year = args:match("^(%d%d%d%d)$") and tonumber(args)
    if not year or year < 1900 or year > 2199 then
      larper.notify(tr{ pt = "Use um ano entre 1900 e 2199, assim: /feriados 2027", en = "Use a year between 1900 and 2199, like this: /feriados 2027" })
      return
    end
  end
  fetch("feriados:" .. year, "feriados/v1/" .. year, 7 * 86400,
    tr{ pt = "Não achei os feriados de " .. year, en = "Couldn't find the holidays for " .. year },
    function(list)
      if type(list) ~= "table" or #list == 0 then
        larper.notify(tr{ pt = "Não achei os feriados de " .. year, en = "Couldn't find the holidays for " .. year })
        return
      end
      local lines = { tr{ pt = "📅 Feriados nacionais de " .. year .. ":", en = "📅 Brazil's national holidays in " .. year .. ":" } }
      local today = day_number(now.year, now.month, now.day)
      local next_line
      for _, h in ipairs(list) do
        local line, y, m, d = holiday_line(h)
        if line then
          lines[#lines + 1] = line
          local n = y and day_number(y, m, d)
          if not next_line and year == now.year and n and n >= today then next_line = { h = h, days = n - today, d = d, m = m } end
        end
      end
      if next_line then
        local nm = tostring(next_line.h.name)
        local when
        if next_line.days == 0 then when = tr{ pt = "hoje", en = "today" }
        elseif next_line.days == 1 then when = tr{ pt = "amanhã", en = "tomorrow" }
        else when = tr{ pt = "em " .. next_line.days .. " dias", en = "in " .. next_line.days .. " days" } end
        lines[#lines + 1] = tr{
          pt = string.format("Próximo: %s, %02d/%02d (%s)", nm, next_line.d, next_line.m, when),
          en = string.format("Next: %s, %s %d (%s)", HOLIDAY_EN[lower(nm)] or nm, MONTH_EN[next_line.m], next_line.d, when),
        }
      end
      larper.insert(table.concat(lines, "\n"))
    end)
end)

-- --- /ddd -------------------------------------------------------------------------------

local SHOW_CITIES = 8

larper.command("/ddd", function(args)
  local ddd = args:match("^%(?(%d%d)%)?$")
  -- Os DDDs vão de 11 a 99 e nenhum tem zero.
  if not ddd or ddd:find("0") then
    larper.notify(tr{ pt = "O DDD tem 2 números, de 11 a 99. Use assim: /ddd 81", en = "An area code (DDD) has 2 digits, from 11 to 99. Use it like this: /ddd 81" })
    return
  end
  fetch("ddd:" .. ddd, "ddd/v1/" .. ddd, 30 * 86400,
    tr{ pt = "O DDD " .. ddd .. " não existe", en = "Area code " .. ddd .. " doesn't exist" },
    function(d)
      local uf = tostring(d.state or "?")
      local info = UF[uf]
      local cities = {}
      for _, c in ipairs(type(d.cities) == "table" and d.cities or {}) do
        if type(c) == "string" then cities[#cities + 1] = title(c) end
      end
      table.sort(cities, function(a, b) return fold(a) < fold(b) end)
      -- A capital primeiro, quando é desse DDD.
      if info then
        for i, c in ipairs(cities) do
          if fold(c) == fold(info[2]) then table.remove(cities, i); table.insert(cities, 1, c); break end
        end
      end
      local shown = {}
      for i = 1, math.min(SHOW_CITIES, #cities) do shown[i] = cities[i] end
      local text = "☎️ DDD " .. ddd .. ": " .. (info and (info[1] .. " (" .. uf .. ")") or uf)
      if #shown > 0 then
        text = text .. " · " .. table.concat(shown, ", ")
        local rest = #cities - #shown
        if rest > 0 then
          text = text .. tr{ pt = " e mais " .. rest .. (rest == 1 and " cidade" or " cidades"), en = " and " .. rest .. " more" }
        end
      end
      larper.insert(text)
    end)
end)

-- --- /cnpj ------------------------------------------------------------------------------

-- Dígitos verificadores do CNPJ. Desde 2026 os 12 primeiros podem ter letras (o valor é o
-- código ASCII menos 48); os dois últimos continuam números.
local function cnpj_ok(c)
  if #c ~= 14 or not c:match("^[%dA-Z]+%d%d$") or c == c:sub(1, 1):rep(14) then return false end
  local function dv(n)
    local w = n == 12 and { 5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2 } or { 6, 5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2 }
    local s = 0
    for i = 1, n do s = s + (c:byte(i) - 48) * w[i] end
    local r = s % 11
    return r < 2 and 0 or 11 - r
  end
  return dv(12) == tonumber(c:sub(13, 13)) and dv(13) == tonumber(c:sub(14, 14))
end

local function cnpj_shown(c)
  return c:sub(1, 2) .. "." .. c:sub(3, 5) .. "." .. c:sub(6, 8) .. "/" .. c:sub(9, 12) .. "-" .. c:sub(13, 14)
end

local STATUS = {
  ATIVA = { "✅ ativa", "✅ active" }, BAIXADA = { "⛔ baixada", "⛔ closed" }, INAPTA = { "⚠️ inapta", "⚠️ unfit" },
  SUSPENSA = { "⚠️ suspensa", "⚠️ suspended" }, NULA = { "⛔ nula", "⛔ void" },
}

larper.command("/cnpj", function(args)
  local c = args:upper():gsub("[%s%./%-]", "")
  if not cnpj_ok(c) then
    larper.notify(tr{ pt = "Esse CNPJ não é válido. Confira os números: /cnpj 00.000.000/0001-91", en = "That CNPJ isn't valid. Check the digits: /cnpj 00.000.000/0001-91" })
    return
  end
  fetch("cnpj:" .. c, "cnpj/v1/" .. c, 3600,
    tr{ pt = "Não achei o CNPJ " .. cnpj_shown(c), en = "Couldn't find CNPJ " .. cnpj_shown(c) },
    function(d)
      local name = tostring(d.razao_social or "?")
      local fantasy = type(d.nome_fantasia) == "string" and d.nome_fantasia ~= "" and d.nome_fantasia ~= name and d.nome_fantasia
      local parts = { "🏢 " .. name .. (fantasy and (" (" .. fantasy .. ")") or "") }
      local st = tostring(d.descricao_situacao_cadastral or "")
      if st ~= "" then
        local s = STATUS[st:upper()]
        parts[#parts + 1] = s and tr{ pt = s[1], en = s[2] } or lower(st)
      end
      if type(d.municipio) == "string" and d.municipio ~= "" then
        parts[#parts + 1] = title(d.municipio) .. (d.uf and ("/" .. d.uf) or "")
      end
      if type(d.cnae_fiscal_descricao) == "string" and d.cnae_fiscal_descricao ~= "" then
        parts[#parts + 1] = d.cnae_fiscal_descricao
      end
      parts[#parts + 1] = "CNPJ " .. cnpj_shown(c)
      larper.insert(table.concat(parts, " · "))
    end)
end)
