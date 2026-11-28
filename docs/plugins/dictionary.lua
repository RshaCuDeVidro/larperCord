-- @name Dictionary
-- @name:pt Dicionário
-- @description /significado palavra puts the first 3 meanings of a Portuguese word in the message box (from Dicionário Aberto), and /define word does the same for English (from dictionaryapi.dev). Only the word goes out, after you approve the hosts below.
-- @description:pt /significado palavra põe na caixa de mensagem os 3 primeiros significados de uma palavra em português (do Dicionário Aberto), e /define word faz o mesmo em inglês (do dictionaryapi.dev). Só a palavra sai do app, depois de aprovar os hosts aqui embaixo.
-- @version 1.0.0
-- @capabilities composer, http, notify
-- @hosts api.dicionario-aberto.net, api.dictionaryapi.dev

local tr = larper.tr
local PT_HOST = "api.dicionario-aberto.net"
local EN_HOST = "api.dictionaryapi.dev"
local TOP = 3

-- --- Pedidos ----------------------------------------------------------------------------

local cache, cache_order = {}, {}
local function remember(key, value)
  if not cache[key] then cache_order[#cache_order + 1] = key end
  cache[key] = value
  while #cache_order > 100 do cache[table.remove(cache_order, 1)] = nil end
end

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

local function failure(res, host, service)
  if res.error == "not_approved" then
    return tr{ pt = "Aprove " .. host .. " no cartão do plugin, em Configurações → Plugins", en = "Approve " .. host .. " on the plugin's card in Settings → Plugins" }
  elseif res.error == "rate_limited" or res.status == 429 then
    return tr{ pt = "Muitas consultas seguidas. Tente de novo daqui a pouco", en = "Too many lookups in a row. Try again in a moment" }
  elseif res.error == "network" then
    return tr{ pt = "Sem conexão com o " .. service .. " agora", en = "Couldn't reach " .. service .. " right now" }
  elseif (res.status or 0) >= 500 then
    return tr{ pt = "O " .. service .. " está com problemas agora (erro " .. res.status .. "). Tente mais tarde", en = service .. " is having trouble right now (error " .. res.status .. "). Try again later" }
  end
  return tr{ pt = "Não consegui consultar o " .. service, en = "Couldn't look that up on " .. service }
end

-- Minúsculas também nas letras acentuadas: o Dicionário Aberto só acha "água", nunca "Água".
local function lower(s)
  return (s:lower():gsub("\xC3([\x80-\x9E])", function(b)
    if b == "\x97" then return "\xC3\x97" end
    return "\xC3" .. string.char(b:byte() + 32)
  end))
end

-- Uma palavra (ou expressão curta): letras, espaço, hífen e apóstrofo.
local function clean_word(args)
  local w = lower(args):gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
  if w == "" or #w > 60 or w:find("[^%a%s%-'\128-\255]") then return nil end
  return w
end

-- Acepções muito longas ficam cortadas num espaço.
local function short(text)
  if #text <= 300 then return text end
  local cut = text:sub(1, 300):match("^(.*)%s") or text:sub(1, 300)
  return cut .. "…"
end

-- Sorteia as acepções entre as entradas (ou classes de palavra): "manga" dá a do vestuário,
-- a fruta e a pastagem, em vez de três da primeira entrada.
local function top(groups)
  local out, round = {}, 1
  while #out < TOP do
    local any = false
    for _, g in ipairs(groups) do
      local d = g[round]
      if d then
        any = true
        out[#out + 1] = d
        if #out == TOP then break end
      end
    end
    if not any then break end
    round = round + 1
  end
  return out
end

local function numbered(head, defs)
  local lines = { head }
  for i, d in ipairs(defs) do
    lines[#lines + 1] = i .. ". " .. (d.tag and ("_" .. d.tag .. "_ ") or "") .. short(d.text)
  end
  return table.concat(lines, "\n")
end

-- --- Dicionário Aberto ------------------------------------------------------------------
-- A resposta é uma lista de entradas, e cada uma traz o verbete em XML num texto:
-- <sense><gramGrp>f.</gramGrp><def>uma acepção por linha</def></sense>.

local ENTITIES = { ["&lt;"] = "<", ["&gt;"] = ">", ["&amp;"] = "&", ["&quot;"] = '"', ["&apos;"] = "'" }

local function strip_xml(s)
  return (s:gsub("<[^>]*>", ""):gsub("&%a+;", ENTITIES):gsub("%^%d+", ""))
end

local function parse_entry(xml)
  local defs, tag0 = {}, nil
  for sense in xml:gmatch("<sense[^>]*>(.-)</sense>") do
    local tag = sense:match("<gramGrp>(.-)</gramGrp>")
    tag = tag and strip_xml(tag):gsub("^%s+", ""):gsub("%s+$", "") or nil
    if tag == "" then tag = nil end
    tag0 = tag0 or tag
    local body = sense:match("<def>(.-)</def>")
    if body then
      for line in strip_xml(body):gsub("\r", ""):gmatch("[^\n]+") do
        line = line:gsub("^%s+", ""):gsub("%s+$", "")
        if line ~= "" then defs[#defs + 1] = { tag = tag or tag0, text = line } end
      end
    end
  end
  return defs
end

local function suggest(word, done)
  if not budget() then return done(nil) end
  larper.http.get("https://" .. PT_HOST .. "/near/" .. larper.urlencode(word), function(res)
    local list = res.ok and larper.json.decode(res.body) or nil
    done(type(list) == "table" and #list > 0 and list or nil)
  end)
end

local busy = {}

larper.command("/significado", function(args)
  local word = clean_word(args)
  if not word then
    larper.notify(tr{ pt = "Use assim: /significado saudade", en = "Use it like this: /significado saudade" })
    return
  end
  local key = "pt:" .. word
  local function show(defs) larper.insert(numbered("📖 **" .. word .. "**", defs)) end
  if cache[key] then return show(cache[key]) end
  if busy[key] or not budget() then return end
  busy[key] = true
  larper.http.get("https://" .. PT_HOST .. "/word/" .. larper.urlencode(word), function(res)
    busy[key] = nil
    local list = res.ok and larper.json.decode(res.body) or nil
    if type(list) ~= "table" then
      larper.notify(failure(res, PT_HOST, "Dicionário Aberto"))
      return
    end
    local groups = {}
    for _, e in ipairs(list) do
      if type(e) == "table" and type(e.xml) == "string" and e.deleted ~= 1 then
        local defs = parse_entry(e.xml)
        if #defs > 0 then groups[#groups + 1] = defs end
      end
    end
    local defs = top(groups)
    if #defs == 0 then
      suggest(word, function(near)
        local msg = tr{ pt = "Não achei \"" .. word .. "\" no Dicionário Aberto", en = "Couldn't find \"" .. word .. "\" in Dicionário Aberto" }
        if near then
          local some = {}
          for i = 1, math.min(5, #near) do some[i] = tostring(near[i]) end
          msg = msg .. tr{ pt = ". Talvez: ", en = ". Maybe: " } .. table.concat(some, ", ")
        end
        larper.notify(msg)
      end)
      return
    end
    remember(key, defs)
    show(defs)
  end)
end)

-- --- dictionaryapi.dev ------------------------------------------------------------------

larper.command("/define", function(args)
  local word = clean_word(args)
  if not word then
    larper.notify(tr{ pt = "Use assim: /define serendipity", en = "Use it like this: /define serendipity" })
    return
  end
  local key = "en:" .. word
  -- O "(inglês)" depende do idioma do app: o texto é montado na hora.
  local function show(c)
    local head = "📖 **" .. word .. "**" .. (c.phonetic and (" " .. c.phonetic) or "")
    if (larper.lang() or ""):match("^pt") then head = head .. " (inglês)" end
    larper.insert(numbered(head, c.defs))
  end
  if cache[key] then return show(cache[key]) end
  if busy[key] or not budget() then return end
  busy[key] = true
  larper.http.get("https://" .. EN_HOST .. "/api/v2/entries/en/" .. larper.urlencode(word), function(res)
    busy[key] = nil
    if res.status == 404 then
      larper.notify(tr{ pt = "Não achei \"" .. word .. "\" no dicionário de inglês", en = "Couldn't find \"" .. word .. "\" in the dictionary" })
      return
    end
    local list = res.ok and larper.json.decode(res.body) or nil
    if type(list) ~= "table" then
      larper.notify(failure(res, EN_HOST, "dictionaryapi.dev"))
      return
    end
    -- Uma lista por classe de palavra, juntando as entradas iguais.
    local groups, by_pos = {}, {}
    local phonetic
    for _, e in ipairs(list) do
      if type(e) == "table" then
        phonetic = phonetic or (type(e.phonetic) == "string" and e.phonetic ~= "" and e.phonetic) or nil
        for _, m in ipairs(type(e.meanings) == "table" and e.meanings or {}) do
          local pos = tostring(m.partOfSpeech or "")
          local g = by_pos[pos]
          if not g then g = {}; by_pos[pos] = g; groups[#groups + 1] = g end
          for _, d in ipairs(type(m.definitions) == "table" and m.definitions or {}) do
            if type(d.definition) == "string" and d.definition ~= "" then
              g[#g + 1] = { tag = pos ~= "" and pos or nil, text = d.definition }
            end
          end
        end
      end
    end
    local defs = top(groups)
    if #defs == 0 then
      larper.notify(tr{ pt = "Não achei \"" .. word .. "\" no dicionário de inglês", en = "Couldn't find \"" .. word .. "\" in the dictionary" })
      return
    end
    local c = { defs = defs, phonetic = phonetic }
    remember(key, c)
    show(c)
  end)
end)
