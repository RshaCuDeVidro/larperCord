-- @name Channel X-ray
-- @name:pt Raio-X do canal
-- @description /xray, or the button on its panel, sums up the messages loaded in the open channel (up to 500): who writes the most, at what time of day, the busiest weekday, how many have links or files, and the average length. It only looks when you ask, and saves nothing.
-- @description:pt /raiox, ou o botão no painel, resume as mensagens carregadas no canal aberto (até 500): quem mais escreve, em que hora do dia, o dia da semana mais movimentado, quantas têm links ou arquivos e o tamanho médio. Só olha quando você pede, e não guarda nada.
-- @version 1.0.0
-- @capabilities messages, panel

local tr = larper.tr
local LIMIT = 500
local TOP = 10

local stats = nil   -- o último resultado
local state = nil   -- nil, "loading", "nochannel", "busy"

local function pt() return larper.lang():match("^pt") ~= nil end

-- 12345 -> "12.345" / "12,345".
local function num(n)
  local s = tostring(math.floor(n + 0.5))
  local sep = pt() and "." or ","
  s = s:reverse():gsub("(%d%d%d)", "%1" .. sep):reverse()
  if s:sub(1, 1) == sep then s = s:sub(2) end
  return s
end

-- 0.125 -> "12,5%" / "12.5%".
local function pct(part, total)
  if total == 0 then return "0%" end
  local s = string.format("%.1f", part * 100 / total)
  s = s:gsub("%.0$", "")
  if pt() then s = s:gsub("%.", ",") end
  return s .. "%"
end

local function when(t)
  return os.date(pt() and "%d/%m/%Y %H:%M" or "%b %d, %Y %H:%M", t)
end

local function span(sec)
  if sec < 3600 then
    local m = math.max(1, math.floor(sec / 60 + 0.5))
    return num(m) .. " min"
  elseif sec < 2 * 86400 then
    local h = math.floor(sec / 3600 + 0.5)
    return num(h) .. " h"
  end
  local d = math.floor(sec / 86400 + 0.5)
  return num(d) .. tr{ pt = " dias", en = " days" }
end

local WEEKDAYS = {
  { pt = "domingo", en = "Sunday" }, { pt = "segunda-feira", en = "Monday" }, { pt = "terça-feira", en = "Tuesday" },
  { pt = "quarta-feira", en = "Wednesday" }, { pt = "quinta-feira", en = "Thursday" }, { pt = "sexta-feira", en = "Friday" },
  { pt = "sábado", en = "Saturday" },
}

local function compute(list, channel)
  local s = { channel = channel, total = 0, links = 0, files = 0, chars = 0, with_text = 0,
    hours = { 0, 0, 0, 0, 0, 0, 0, 0 }, days = { 0, 0, 0, 0, 0, 0, 0 }, authors = {} }
  local count, names = {}, {}
  for _, m in ipairs(list) do
    s.total = s.total + 1
    local t = m.time or 0
    if not s.first or t < s.first then s.first = t end
    if not s.last or t > s.last then s.last = t end
    local who = m.author and m.author.id or "?"
    count[who] = (count[who] or 0) + 1
    names[who] = m.author and m.author.name or "?"
    local d = os.date("*t", t)
    local b = d.hour // 3 + 1
    s.hours[b] = s.hours[b] + 1
    s.days[d.wday] = s.days[d.wday] + 1
    local text = m.content or ""
    if text:find("://", 1, true) then s.links = s.links + 1 end
    if (m.attachments or 0) > 0 then s.files = s.files + 1 end
    if text:find("%S") then
      s.with_text = s.with_text + 1
      s.chars = s.chars + (utf8.len(text) or #text)
    end
  end
  for id, n in pairs(count) do s.authors[#s.authors + 1] = { name = names[id], n = n } end
  table.sort(s.authors, function(a, b)
    if a.n ~= b.n then return a.n > b.n end
    return a.name < b.name
  end)
  while #s.authors > TOP do table.remove(s.authors) end
  return s
end

local render
local pending = false

local function analyze()
  local ch = larper.channel()
  if not ch then
    state = "nochannel"
    return render()
  end
  local asked = larper.messages({ limit = LIMIT }, function(list)
    pending = false
    state = nil
    stats = compute(list, ch.name or "")
    render()
  end)
  if asked == false and not pending then
    state = "busy"
  else
    pending = true
    state = "loading"
  end
  render()
end

render = function()
  local tree = { title = tr{ pt = "Raio-X do canal", en = "Channel X-ray" } }
  local function add(item) tree[#tree + 1] = item end
  add({ type = "text", style = "muted", text = tr{
    pt = "Conta as mensagens carregadas no app para o canal aberto, até 500. Horários deste computador.",
    en = "Counts the messages the app has loaded for the open channel, up to 500. Times are this computer's.",
  } })
  add({ type = "row", { type = "button", key = "analyze", style = "accent",
    label = tr{ pt = "Analisar este canal", en = "Analyze this channel" }, on_click = analyze } })
  if state == "loading" then
    add({ type = "text", text = tr{ pt = "Analisando…", en = "Analyzing…" } })
  elseif state == "nochannel" then
    add({ type = "text", style = "danger", text = tr{ pt = "Abra um canal primeiro.", en = "Open a channel first." } })
  elseif state == "busy" then
    add({ type = "text", style = "danger", text = tr{ pt = "Espere um instante e tente de novo.", en = "Wait a moment and try again." } })
  end
  local s = stats
  if not s then
    larper.panel.set(tree)
    return
  end
  add({ type = "separator" })
  add({ type = "heading", text = "#" .. s.channel })
  if s.total == 0 then
    add({ type = "text", text = tr{ pt = "Nenhuma mensagem carregada neste canal.", en = "No messages loaded in this channel." } })
    larper.panel.set(tree)
    return
  end
  local period
  if s.last - s.first < 60 then
    period = tr{ pt = "em ", en = "on " } .. when(s.last)
  else
    period = tr{ pt = "de ", en = "from " } .. when(s.first) .. tr{ pt = " a ", en = " to " } .. when(s.last) .. " (" .. span(s.last - s.first) .. ")"
  end
  local word = s.total == 1 and tr{ pt = " mensagem, ", en = " message, " } or tr{ pt = " mensagens, ", en = " messages, " }
  add({ type = "text", text = num(s.total) .. word .. period })

  add({ type = "heading", text = tr{ pt = "Quem mais escreve", en = "Who writes the most" } })
  local top = s.authors[1] and s.authors[1].n or 1
  for i, a in ipairs(s.authors) do
    add({ type = "bar", key = "a" .. i, label = a.name, value = a.n, max = top, text = num(a.n) .. " · " .. pct(a.n, s.total) })
  end

  add({ type = "heading", text = tr{ pt = "Por hora do dia", en = "By time of day" } })
  local busiest = 1
  for i = 1, 8 do
    if s.hours[i] > s.hours[busiest] then busiest = i end
  end
  for i = 1, 8 do
    local from = (i - 1) * 3
    add({ type = "bar", key = "h" .. i, label = string.format("%02d–%02dh", from, from + 3), value = s.hours[i],
      max = s.hours[busiest], text = num(s.hours[i]), style = i == busiest and "accent" or nil })
  end

  local day = 1
  for i = 2, 7 do
    if s.days[i] > s.days[day] then day = i end
  end
  add({ type = "separator" })
  add({ type = "text", text = tr{ pt = "Dia mais movimentado: ", en = "Busiest weekday: " } .. tr(WEEKDAYS[day]) .. " (" .. num(s.days[day]) .. ")" })
  add({ type = "text", text = tr{ pt = "Com links: ", en = "With links: " } .. pct(s.links, s.total) .. " (" .. num(s.links) .. ")"
    .. tr{ pt = " · com anexos: ", en = " · with attachments: " } .. pct(s.files, s.total) .. " (" .. num(s.files) .. ")" })
  if s.with_text > 0 then
    add({ type = "text", text = tr{ pt = "Tamanho médio: ", en = "Average length: " } .. num(s.chars / s.with_text)
      .. tr{ pt = " caracteres por mensagem com texto", en = " characters per message with text" } })
  end
  larper.panel.set(tree)
end

local function command()
  larper.panel.open()
  analyze()
end

larper.command("/raiox", command)
larper.command("/xray", command)
larper.on("lang", function() render() end)

render()
