-- @name Hide people
-- @name:pt Esconder pessoas
-- @description Right-click someone and pick "Hide or show messages" to collapse what they write to one line, on your screen only, with "show" to read it. /hidden lists who is hidden, with a button to show each one again.
-- @description:pt Botão direito numa pessoa e "Esconder ou mostrar mensagens" para recolher o que ela escreve numa linha, só na sua tela, com "mostrar" para ler. /escondidos lista quem está escondido, com um botão para mostrar de novo.
-- @version 1.0.0
-- @capabilities menu, decorate, storage, panel, notify

local tr = larper.tr
-- larper.rules aceita até 256 regras.
local MAX = 256

-- { { id = "1001", name = "ana", since = 1795000000 }, ... }
local people = {}
for _, p in ipairs(larper.storage.get("people") or {}) do
  if type(p) == "table" and type(p.id) == "string" and #people < MAX then
    people[#people + 1] = { id = p.id, name = type(p.name) == "string" and p.name or p.id, since = tonumber(p.since) }
  end
end

local function find(id)
  for i, p in ipairs(people) do
    if p.id == id then return i end
  end
end

local function apply()
  local list = {}
  for _, p in ipairs(people) do
    list[#list + 1] = {
      user = p.id,
      collapse = true,
      label = tr{ pt = "Mensagem de " .. p.name .. " escondida", en = "Message from " .. p.name .. " hidden" },
    }
  end
  larper.rules(list)
end

local render

local function save()
  larper.storage.set("people", people)
  apply()
  render()
end

local function show(id)
  local i = find(id)
  if not i then return end
  table.remove(people, i)
  save()
end

local function day(t)
  return os.date(larper.lang():match("^pt") and "%d/%m/%Y" or "%b %d, %Y", t)
end

render = function()
  local items = {}
  for _, p in ipairs(people) do
    items[#items + 1] = {
      key = "p" .. p.id,
      title = p.name,
      subtitle = tr{ pt = "Escondida desde ", en = "Hidden since " } .. day(p.since or os.time()),
      actions = { { label = tr{ pt = "Mostrar", en = "Show" }, key = "show" .. p.id, on_click = function() show(p.id) end } },
    }
  end
  larper.panel.set({
    title = tr{ pt = "Pessoas escondidas", en = "Hidden people" },
    { type = "text", style = "muted", text = tr{
      pt = "As mensagens delas aparecem numa linha só, com \"mostrar\" para ler. Só na sua tela: ninguém fica sabendo.",
      en = "Their messages show as one line, with \"show\" to read them. Only on your screen: nobody is told.",
    } },
    { type = "list", key = "people", items = items, empty = tr{
      pt = "Ninguém escondido. Botão direito numa pessoa → Esconder ou mostrar mensagens.",
      en = "Nobody hidden. Right-click someone → Hide or show messages.",
    } },
  })
end

-- Um menu não muda o rótulo para cada pessoa: a mesma entrada esconde e mostra.
larper.menu("user", { pt = "Esconder ou mostrar mensagens", en = "Hide or show messages" }, function(u)
  local name = (u.name and u.name ~= "") and u.name or u.id
  local i = find(u.id)
  if i then
    table.remove(people, i)
    save()
    larper.notify(tr{ pt = "Mensagens de " .. name .. " à mostra de novo", en = "Messages from " .. name .. " are shown again" })
    return
  end
  if #people >= MAX then
    larper.notify(tr{ pt = "Gente demais escondida: até 256", en = "Too many people hidden: up to 256" })
    return
  end
  people[#people + 1] = { id = u.id, name = name, since = os.time() }
  save()
  larper.notify(tr{ pt = "Mensagens de " .. name .. " escondidas. /escondidos mostra a lista", en = "Messages from " .. name .. " hidden. /hidden shows the list" })
end)

local function open()
  render()
  larper.panel.open()
end

larper.command("/escondidos", open)
larper.command("/hidden", open)

larper.on("lang", function()
  apply()
  render()
end)

apply()
render()
