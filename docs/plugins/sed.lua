-- @name Fix last message
-- @name:pt Corrigir última mensagem
-- @description /s old/new fixes your last message in the open channel, /s old/new/g changes every occurrence and /s old new works for single words. The text is replaced exactly as written. It only remembers, in memory, what you sent with the app open or what is loaded in the channel.
-- @description:pt /s velho/novo corrige sua última mensagem no canal aberto, /s velho/novo/g troca todas as ocorrências e /s velho novo serve para palavras soltas. O texto é trocado exatamente como está escrito. Só lembra, na memória, o que você mandou com o app aberto ou o que está carregado no canal.
-- @version 1.0.0
-- @capabilities messages, actions, notify

local tr = larper.tr
-- Canais lembrados, no máximo; o mais antigo sai primeiro.
local MAX_CHANNELS = 200

-- [id do canal] = { id = id da mensagem, content = texto }
local last = {}
local order = {}

-- IDs do Discord crescem com o tempo: o mais comprido, ou o maior com o mesmo tamanho.
local function newer(a, b)
  if #a ~= #b then return #a > #b end
  return a > b
end

local function remember(m)
  local ch = m.channel and m.channel.id
  if not ch then return end
  local old = last[ch]
  if old and old.id ~= m.id and newer(old.id, m.id) then return end
  if not old then
    local listed = false
    for _, c in ipairs(order) do
      if c == ch then listed = true break end
    end
    if not listed then
      order[#order + 1] = ch
      if #order > MAX_CHANNELS then last[table.remove(order, 1)] = nil end
    end
  end
  last[ch] = { id = m.id, content = m.content or "" }
end

local function usage()
  larper.notify(tr{
    pt = "Use assim: /s velho/novo, /s velho/novo/g (todas) ou /s velho novo",
    en = "Use it like this: /s old/new, /s old/new/g (all of them) or /s old new",
  })
end

-- "velho/novo/g" -> "velho", "novo", true. Uma barra no texto vai como \/.
local function split_slashes(args)
  local parts, cur, i = {}, {}, 1
  while i <= #args do
    local c = args:sub(i, i)
    if c == "\\" and args:sub(i + 1, i + 1) == "/" then
      cur[#cur + 1] = "/"
      i = i + 2
    elseif c == "/" then
      parts[#parts + 1] = table.concat(cur)
      cur = {}
      i = i + 1
    else
      cur[#cur + 1] = c
      i = i + 1
    end
  end
  parts[#parts + 1] = table.concat(cur)
  if #parts < 2 or #parts > 3 then return nil end
  local flags = parts[3] or ""
  if flags ~= "" and flags ~= "g" then return nil end
  if parts[1] == "" then return nil end
  return parts[1], parts[2], flags == "g"
end

local function parse(args)
  if args:find("/", 1, true) then
    local old, new, all = split_slashes(args)
    if old then return old, new, all end
  end
  -- Duas palavras soltas (também quando elas têm barra, como dois links).
  local a, b = args:match("^(%S+)%s+(%S+)$")
  if a then return a, b, false end
  return nil
end

-- Troca o texto como está, sem padrões do Lua.
local function replace(text, old, new, all)
  local out, pos, n = {}, 1, 0
  while true do
    local a, b = text:find(old, pos, true)
    if not a then break end
    out[#out + 1] = text:sub(pos, a - 1)
    out[#out + 1] = new
    pos = b + 1
    n = n + 1
    if not all then break end
  end
  out[#out + 1] = text:sub(pos)
  return table.concat(out), n
end

local function short(s)
  s = s:gsub("%s+", " ")
  if #s <= 40 then return s end
  local n = 40
  while n > 0 and (s:byte(n + 1) or 0) & 0xC0 == 0x80 do n = n - 1 end
  return s:sub(1, n) .. "…"
end

larper.command("/s", function(args)
  local old, new, all = parse(args)
  if not old then return usage() end
  local ch = larper.channel()
  if not ch then
    larper.notify(tr{ pt = "Abra um canal primeiro", en = "Open a channel first" })
    return
  end
  local t = last[ch.id]
  if not t then
    larper.notify(tr{
      pt = "Não achei uma mensagem sua recente neste canal",
      en = "I couldn't find a recent message of yours in this channel",
    })
    return
  end
  local out, n = replace(t.content, old, new, all)
  if n == 0 then
    larper.notify(tr{ pt = "“" .. short(old) .. "” não aparece na sua última mensagem", en = "“" .. short(old) .. "” isn't in your last message" })
  elseif out:gsub("%s", "") == "" then
    larper.notify(tr{ pt = "A mensagem ficaria vazia: nada foi mudado", en = "The message would be empty: nothing was changed" })
  elseif out == t.content then
    larper.notify(tr{ pt = "O texto ficaria igual: nada foi mudado", en = "The text would stay the same: nothing was changed" })
  elseif #out > 2000 then
    larper.notify(tr{ pt = "A mensagem passaria de 2000 bytes", en = "The message would go over 2000 bytes" })
  else
    larper.edit(t.id, out)
    t.content = out
  end
end)

larper.on("message", function(m)
  if m.mine then remember(m) end
end)

larper.on("edit", function(m)
  local t = m.channel and last[m.channel.id]
  if t and t.id == m.id then t.content = m.content or "" end
end)

larper.on("delete", function(d)
  local t = last[d.channel]
  if t and t.id == d.id then last[d.channel] = nil end
end)

-- O que já está carregado no canal não dispara "message": a última sua vem daqui.
local function scan(ch)
  if not ch or last[ch.id] then return end
  larper.messages({ limit = 100 }, function(list)
    for i = #list, 1, -1 do
      local m = list[i]
      if m.mine and m.channel and m.channel.id == ch.id then
        remember(m)
        return
      end
    end
  end)
end

larper.on("channel", scan)
scan(larper.channel())
