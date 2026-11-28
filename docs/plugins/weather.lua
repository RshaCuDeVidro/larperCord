-- @name Weather
-- @name:pt Clima
-- @description /clima Recife puts the weather in the message box: temperature, sky, high and low, and when rain is likely. With no city it uses the one saved on the panel, which shows 7 days. From Open-Meteo, no account; only the city and its coordinates go out.
-- @description:pt /clima Recife põe o tempo na caixa de mensagem: temperatura, céu, máxima e mínima e quando deve chover. Sem cidade, usa a salva no painel, que mostra 7 dias. Dados do Open-Meteo, sem conta; só a cidade e as coordenadas saem do app.
-- @version 1.0.0
-- @capabilities composer, http, notify, panel, storage
-- @hosts geocoding-api.open-meteo.com, api.open-meteo.com

local tr = larper.tr
local GEO = "geocoding-api.open-meteo.com"
local API = "api.open-meteo.com"
local FRESH = 600          -- o /clima reaproveita a previsão por 10 minutos
local PANEL_FRESH = 1800   -- o painel busca de novo ao abrir depois de 30 minutos
local RAIN = 50            -- chance de chuva que vale avisar

local function is_pt() return (larper.lang() or ""):match("^pt") ~= nil end

local saved = larper.storage.get("city")       -- { name, region, country, cc, lat, lon }
local last = larper.storage.get("forecast")    -- { at, data } da cidade salva
local status = nil                             -- o último problema, mostrado no painel

-- Código WMO → emoji e descrição.
local WMO = {
  [0] = { "☀️", "céu limpo", "clear sky" }, [1] = { "🌤️", "poucas nuvens", "mainly clear" },
  [2] = { "⛅", "parcialmente nublado", "partly cloudy" }, [3] = { "☁️", "nublado", "overcast" },
  [45] = { "🌫️", "neblina", "fog" }, [48] = { "🌫️", "neblina com geada", "freezing fog" },
  [51] = { "🌦️", "garoa fraca", "light drizzle" }, [53] = { "🌦️", "garoa", "drizzle" },
  [55] = { "🌧️", "garoa forte", "heavy drizzle" }, [56] = { "🌧️", "garoa congelante", "freezing drizzle" },
  [57] = { "🌧️", "garoa congelante forte", "heavy freezing drizzle" }, [61] = { "🌦️", "chuva fraca", "light rain" },
  [63] = { "🌧️", "chuva", "rain" }, [65] = { "🌧️", "chuva forte", "heavy rain" },
  [66] = { "🌧️", "chuva congelante", "freezing rain" }, [67] = { "🌧️", "chuva congelante forte", "heavy freezing rain" },
  [71] = { "🌨️", "neve fraca", "light snow" }, [73] = { "🌨️", "neve", "snow" }, [75] = { "❄️", "neve forte", "heavy snow" },
  [77] = { "🌨️", "grãos de neve", "snow grains" }, [80] = { "🌦️", "pancadas de chuva fracas", "light showers" },
  [81] = { "🌧️", "pancadas de chuva", "showers" }, [82] = { "⛈️", "pancadas de chuva fortes", "violent showers" },
  [85] = { "🌨️", "pancadas de neve", "snow showers" }, [86] = { "❄️", "pancadas de neve fortes", "heavy snow showers" },
  [95] = { "⛈️", "trovoada", "thunderstorm" }, [96] = { "⛈️", "trovoada com granizo", "thunderstorm with hail" },
  [99] = { "⛈️", "trovoada com granizo forte", "thunderstorm with heavy hail" },
}

local function sky(code, night)
  local w = WMO[type(code) == "number" and math.tointeger(code) or -1] or { "🌡️", "tempo indefinido", "unknown conditions" }
  local emoji = w[1]
  if night and (code == 0 or code == 1) then emoji = "🌙" end
  return emoji, tr{ pt = w[2], en = w[3] }
end

-- Um valor que a API não mandou aparece como "–", nunca como 0°.
local function deg(t)
  if type(t) ~= "number" then return "–" end
  return tostring(math.floor(t + 0.5))
end

-- Siglas dos estados, para "Recife, PE" escolher o Recife certo.
local UF = {
  AC = "Acre", AL = "Alagoas", AP = "Amapá", AM = "Amazonas", BA = "Bahia", CE = "Ceará", DF = "Distrito Federal",
  ES = "Espírito Santo", GO = "Goiás", MA = "Maranhão", MT = "Mato Grosso", MS = "Mato Grosso do Sul",
  MG = "Minas Gerais", PA = "Pará", PB = "Paraíba", PR = "Paraná", PE = "Pernambuco", PI = "Piauí",
  RJ = "Rio de Janeiro", RN = "Rio Grande do Norte", RS = "Rio Grande do Sul", RO = "Rondônia", RR = "Roraima",
  SC = "Santa Catarina", SP = "São Paulo", SE = "Sergipe", TO = "Tocantins",
}

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

local function failure(res, host)
  if res.error == "not_approved" then
    return tr{ pt = "Aprove " .. host .. " no cartão do plugin, em Configurações → Plugins", en = "Approve " .. host .. " on the plugin's card in Settings → Plugins" }
  elseif res.error == "rate_limited" or res.status == 429 then
    return tr{ pt = "Muitas consultas seguidas. Tente de novo daqui a pouco", en = "Too many lookups in a row. Try again in a moment" }
  elseif res.error == "network" then
    return tr{ pt = "Sem conexão com o Open-Meteo agora", en = "Couldn't reach Open-Meteo right now" }
  elseif (res.status or 0) >= 500 then
    return tr{ pt = "O Open-Meteo está com problemas agora (erro " .. res.status .. "). Tente mais tarde", en = "Open-Meteo is having trouble right now (error " .. res.status .. "). Try again later" }
  end
  return tr{ pt = "Não consegui consultar o tempo", en = "Couldn't get the weather" }
end

local function lower(s)
  return (s:lower():gsub("\xC3([\x80-\x9E])", function(b)
    if b == "\x97" then return "\xC3\x97" end
    return "\xC3" .. string.char(b:byte() + 32)
  end))
end
local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

local places = {}      -- busca → lugar
local forecasts = {}   -- "lat,lon" → { at, data }

-- done(lugar) ou done(nil, mensagem); mensagem false = já avisado.
local function geocode(query, done)
  local name, qual = query:match("^([^,]+),%s*(.+)$")
  name = trim(name or query)
  qual = qual and lower(trim(qual)) or nil
  local lang = is_pt() and "pt" or ((larper.lang() or "en"):match("^(%a%a)") or "en"):lower()
  local key = lang .. ":" .. lower(query)
  if places[key] then return done(places[key]) end
  if not budget() then return done(nil, false) end
  local url = "https://" .. GEO .. "/v1/search?format=json&count=" .. (qual and 10 or 1) .. "&language=" .. lang .. "&name=" .. larper.urlencode(name)
  larper.http.get(url, function(res)
    local data = res.ok and larper.json.decode(res.body) or nil
    if type(data) ~= "table" then return done(nil, failure(res, GEO)) end
    local list = type(data.results) == "table" and data.results or {}
    local pick = list[1]
    if qual then
      for _, r in ipairs(list) do
        local uf = r.country_code == "BR" and qual:upper() or nil
        if (uf and UF[uf] and r.admin1 == UF[uf]) or lower(tostring(r.admin1 or "")) == qual
          or lower(tostring(r.country or "")) == qual or lower(tostring(r.country_code or "")) == qual then
          pick = r
          break
        end
      end
    end
    if type(pick) ~= "table" or not tonumber(pick.latitude) or not tonumber(pick.longitude) then
      return done(nil, tr{ pt = "Não achei a cidade \"" .. query .. "\"", en = "Couldn't find the city \"" .. query .. "\"" })
    end
    local place = { name = tostring(pick.name or name), region = pick.admin1, country = pick.country, cc = pick.country_code,
      lat = tonumber(pick.latitude), lon = tonumber(pick.longitude) }
    places[key] = place
    done(place)
  end)
end

local function place_key(p) return string.format("%.3f,%.3f", p.lat, p.lon) end

-- Só o que o plugin usa, em listas sem buracos: um null da API vira false (o storage não
-- guarda lista com buraco) e as horas sem chance de chuva ficam de fora.
local DAILY = { "time", "weather_code", "temperature_2m_max", "temperature_2m_min", "precipitation_probability_max" }
local function compact(data)
  local cur = data.current
  local out = { current = { time = cur.time, temperature_2m = cur.temperature_2m, weather_code = cur.weather_code, is_day = cur.is_day },
    hourly = { time = {}, precipitation_probability = {} }, daily = {} }
  local h = type(data.hourly) == "table" and data.hourly or {}
  local ht, hp = type(h.time) == "table" and h.time or {}, type(h.precipitation_probability) == "table" and h.precipitation_probability or {}
  for i = 1, math.min(#ht, 48) do
    if type(ht[i]) == "string" and type(hp[i]) == "number" then
      out.hourly.time[#out.hourly.time + 1] = ht[i]
      out.hourly.precipitation_probability[#out.hourly.precipitation_probability + 1] = hp[i]
    end
  end
  local d = type(data.daily) == "table" and data.daily or {}
  local days = type(d.time) == "table" and math.min(#d.time, 16) or 0
  for _, k in ipairs(DAILY) do
    local src, list = type(d[k]) == "table" and d[k] or {}, {}
    for i = 1, days do
      local v = src[i]
      list[i] = (type(v) == "number" or type(v) == "string") and v or false
    end
    out.daily[k] = list
  end
  return out
end

local function forecast(place, max_age, done, quiet)
  local key = place_key(place)
  local c = forecasts[key]
  if c and os.time() - c.at < max_age then return done(c.data) end
  if not budget(quiet) then return done(nil, false) end
  local url = string.format("https://%s/v1/forecast?latitude=%.4f&longitude=%.4f", API, place.lat, place.lon)
    .. "&current=temperature_2m,weather_code,is_day&hourly=precipitation_probability"
    .. "&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max"
    .. "&timezone=auto&forecast_days=7&forecast_hours=24"
  larper.http.get(url, function(res)
    local data = res.ok and larper.json.decode(res.body) or nil
    if type(data) ~= "table" or type(data.current) ~= "table" then return done(nil, failure(res, API)) end
    data = compact(data)
    forecasts[key] = { at = os.time(), data = data }
    done(data)
  end)
end

-- --- Texto ----------------------------------------------------------------------------

local function clock(h)
  if is_pt() then return h .. "h" end
  if h == 0 then return "12 AM" elseif h < 12 then return h .. " AM" elseif h == 12 then return "12 PM" end
  return (h - 12) .. " PM"
end

-- A primeira hora das próximas 24 com chance de chuva alta.
local function rain_text(data)
  local hourly = type(data.hourly) == "table" and data.hourly or {}
  local times, probs = hourly.time or {}, hourly.precipitation_probability or {}
  local today = tostring(data.current.time or ""):sub(1, 10)
  for i, t in ipairs(times) do
    local p = tonumber(probs[i])
    if p and p >= RAIN then
      local day, hour = tostring(t):match("^(%d+%-%d+%-%d+)T(%d+)")
      if hour then
        local h = tonumber(hour)
        local tomorrow = day ~= today
        return tr{
          pt = "chuva " .. (tomorrow and "amanhã " or "") .. "às " .. clock(h) .. " (" .. math.floor(p) .. "%)",
          en = "rain " .. (tomorrow and "tomorrow " or "") .. "at " .. clock(h) .. " (" .. math.floor(p) .. "%)",
        }
      end
    end
  end
  return tr{ pt = "sem chuva nas próximas 24h", en = "no rain in the next 24h" }
end

local function now_line(place, data)
  local cur = data.current
  local emoji, desc = sky(cur.weather_code, cur.is_day == 0)
  local parts = { emoji .. " " .. deg(cur.temperature_2m) .. "°C " .. tr{ pt = "em ", en = "in " } .. place.name .. ", " .. desc }
  local daily = type(data.daily) == "table" and data.daily or {}
  local hi, lo = daily.temperature_2m_max and daily.temperature_2m_max[1], daily.temperature_2m_min and daily.temperature_2m_min[1]
  if hi and lo then
    parts[#parts + 1] = tr{ pt = "máx " .. deg(hi) .. "° mín " .. deg(lo) .. "°", en = "high " .. deg(hi) .. "° low " .. deg(lo) .. "°" }
  end
  parts[#parts + 1] = rain_text(data)
  return table.concat(parts, " · ")
end

local WEEK_PT = { "Dom", "Seg", "Ter", "Qua", "Qui", "Sex", "Sáb" }
local WEEK_EN = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }
local MONTH_EN = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }

local function weekday(y, m, d)
  local t = { 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 }
  if m < 3 then y = y - 1 end
  return (y + y // 4 - y // 100 + y // 400 + t[m] + d) % 7
end

local function day_label(date, i)
  if i == 1 then return tr{ pt = "Hoje", en = "Today" } end
  if i == 2 then return tr{ pt = "Amanhã", en = "Tomorrow" } end
  local y, m, d = tostring(date):match("^(%d+)%-(%d+)%-(%d+)$")
  if not y then return tostring(date) end
  y, m, d = tonumber(y), tonumber(m), tonumber(d)
  local wd = weekday(y, m, d) + 1
  if is_pt() then return string.format("%s %02d/%02d", WEEK_PT[wd], d, m) end
  return string.format("%s %s %d", WEEK_EN[wd], MONTH_EN[m], d)
end

local function where(p)
  local bits = { p.name }
  if p.region and p.region ~= p.name then bits[#bits + 1] = p.region end
  if p.country then bits[#bits + 1] = p.country end
  return table.concat(bits, ", ")
end

-- --- Painel ---------------------------------------------------------------------------

local draw

local function load_saved(max_age, quiet)
  if not saved then return end
  forecast(saved, max_age, function(data, err)
    if data then
      last = { at = os.time(), data = data }
      status = nil
      larper.storage.set("forecast", last)
    elseif err then
      status = err
    end
    draw()
  end, quiet)
end

function draw()
  local tree = { title = tr{ pt = "Clima", en = "Weather" } }
  tree[#tree + 1] = { type = "input", key = "city", placeholder = tr{ pt = "Sua cidade (ex.: Recife, PE) e Enter", en = "Your city (e.g. Lisbon) and Enter" },
    value = saved and saved.name or "",
    on_submit = function(text)
      text = trim(text or "")
      if text == "" then return end
      geocode(text, function(place, err)
        if not place then
          if err then larper.notify(err) end
          return
        end
        saved = place
        larper.storage.set("city", place)
        last = nil
        larper.storage.delete("forecast")
        load_saved(FRESH)
      end)
    end }
  if not saved then
    tree[#tree + 1] = { type = "text", style = "muted", text = tr{ pt = "Salve uma cidade para ver a previsão e usar /clima sem nada depois.", en = "Save a city to see the forecast and use /clima with nothing after it." } }
  else
    tree[#tree + 1] = { type = "heading", text = where(saved) }
    if status then tree[#tree + 1] = { type = "text", style = "danger", text = status } end
    local data = last and last.data
    if data and type(data.current) == "table" then
      tree[#tree + 1] = { type = "text", text = now_line(saved, data) }
      local daily = type(data.daily) == "table" and data.daily or {}
      local items = {}
      for i, date in ipairs(daily.time or {}) do
        local emoji, desc = sky((daily.weather_code or {})[i])
        local rain = tonumber((daily.precipitation_probability_max or {})[i])
        local sub = tr{ pt = "máx ", en = "high " } .. deg((daily.temperature_2m_max or {})[i]) .. "° · "
          .. tr{ pt = "mín ", en = "low " } .. deg((daily.temperature_2m_min or {})[i]) .. "°"
        if rain then sub = sub .. " · " .. tr{ pt = "chuva ", en = "rain " } .. math.floor(rain) .. "%" end
        items[#items + 1] = { title = emoji .. " " .. day_label(date, i) .. " · " .. desc, subtitle = sub }
      end
      tree[#tree + 1] = { type = "list", items = items, empty = tr{ pt = "Sem previsão ainda.", en = "No forecast yet." } }
      tree[#tree + 1] = { type = "text", style = "muted", text = tr{ pt = "Atualizado às ", en = "Updated at " } .. os.date("%H:%M", last.at) }
    else
      tree[#tree + 1] = { type = "text", style = "muted", text = tr{ pt = "Buscando a previsão…", en = "Getting the forecast…" } }
    end
    tree[#tree + 1] = { type = "row",
      { type = "button", label = tr{ pt = "Atualizar", en = "Refresh" }, on_click = function() load_saved(60) end },
    }
  end
  larper.panel.set(tree)
end

larper.on("panel", function(open)
  if open and saved and (not last or os.time() - last.at >= PANEL_FRESH) then load_saved(PANEL_FRESH, true) end
end)
larper.on("lang", draw)
draw()

-- --- /clima -----------------------------------------------------------------------------

larper.command("/clima", function(args)
  local function go(place)
    forecast(place, FRESH, function(data, err)
      if not data then
        if err then larper.notify(err) end
        return
      end
      larper.insert(now_line(place, data))
    end)
  end
  if args == "" then
    if not saved then
      larper.notify(tr{ pt = "Diga a cidade (/clima Recife) ou salve uma no painel do Clima", en = "Name a city (/clima Lisbon) or save one on the Weather panel" })
      return
    end
    return go(saved)
  end
  if #args > 100 then
    larper.notify(tr{ pt = "Esse nome de cidade é longo demais", en = "That city name is too long" })
    return
  end
  geocode(args, function(place, err)
    if not place then
      if err then larper.notify(err) end
      return
    end
    go(place)
  end)
end)
