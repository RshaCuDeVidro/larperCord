-- @name Pokédex
-- @name:pt Pokédex
-- @description /pokemon pikachu (or /pokemon 25) puts a compact card in the message box: number, name, types, height, weight and base stats, from PokeAPI. Only the name or number goes out, after you approve the host below.
-- @description:pt /pokemon pikachu (ou /pokemon 25) põe uma ficha curta na caixa de mensagem: número, nome, tipos, altura, peso e atributos, da PokeAPI. Só o nome ou o número sai do app, depois de aprovar o host aqui embaixo.
-- @version 1.0.0
-- @capabilities composer, http, notify
-- @hosts pokeapi.co

local tr = larper.tr
local HOST = "pokeapi.co"
local API = "https://" .. HOST .. "/api/v2/"

local function is_pt() return (larper.lang() or ""):match("^pt") ~= nil end

-- Os nomes oficiais dos tipos no Brasil (a PokeAPI não tem português para eles).
local TYPES = {
  normal = { "Normal", "Normal" }, fire = { "Fogo", "Fire" }, water = { "Água", "Water" },
  grass = { "Planta", "Grass" }, electric = { "Elétrico", "Electric" }, ice = { "Gelo", "Ice" },
  fighting = { "Lutador", "Fighting" }, poison = { "Venenoso", "Poison" }, ground = { "Terrestre", "Ground" },
  flying = { "Voador", "Flying" }, psychic = { "Psíquico", "Psychic" }, bug = { "Inseto", "Bug" },
  rock = { "Pedra", "Rock" }, ghost = { "Fantasma", "Ghost" }, dragon = { "Dragão", "Dragon" },
  dark = { "Sombrio", "Dark" }, steel = { "Aço", "Steel" }, fairy = { "Fada", "Fairy" },
  stellar = { "Estelar", "Stellar" },
}

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

local function failure(res)
  if res.error == "not_approved" then
    return tr{ pt = "Aprove " .. HOST .. " no cartão do plugin, em Configurações → Plugins", en = "Approve " .. HOST .. " on the plugin's card in Settings → Plugins" }
  elseif res.error == "rate_limited" or res.status == 429 then
    return tr{ pt = "Muitas consultas seguidas. Tente de novo daqui a pouco", en = "Too many lookups in a row. Try again in a moment" }
  elseif res.error == "network" then
    return tr{ pt = "Sem conexão com a PokeAPI agora", en = "Couldn't reach PokeAPI right now" }
  elseif (res.status or 0) >= 500 then
    return tr{ pt = "A PokeAPI está com problemas agora (erro " .. res.status .. "). Tente mais tarde", en = "PokeAPI is having trouble right now (error " .. res.status .. "). Try again later" }
  end
  return tr{ pt = "Não consegui consultar a PokeAPI", en = "Couldn't look that up on PokeAPI" }
end

-- A ficha de um Pokémon passa de 700 KB por causa dos golpes e jogos. Antes de decodificar,
-- troco essas listas por vazias (num gsub só, sem laço em Lua), o que poupa memória.
local HEAVY = { "moves", "game_indices", "held_items", "past_abilities", "past_types", "past_stats", "abilities", "forms",
  "flavor_text_entries", "form_descriptions", "pokedex_numbers", "pal_park_encounters", "egg_groups" }
local function decode(body)
  local slim = body
  for _, k in ipairs(HEAVY) do slim = slim:gsub('"' .. k .. '":%b[]', '"' .. k .. '":[]', 1) end
  slim = slim:gsub('"sprites":%b{}', '"sprites":{}', 1):gsub('"cries":%b{}', '"cries":{}', 1)
  return larper.json.decode(slim) or larper.json.decode(body)
end

-- "Mr. Mime" → "mr-mime", "#025" → "25", "Nidoran♀" → "nidoran-f".
local function normalize(args)
  local q = args:lower():gsub("^%s*#?", ""):gsub("%s+$", "")
  if q:match("^%d+$") then
    local n = tonumber(q)
    if n < 1 or n > 99999 then return nil end
    return tostring(math.tointeger(n))
  end
  q = q:gsub("\xE2\x99\x80", "-f"):gsub("\xE2\x99\x82", "-m")
  q = q:gsub("\xC3[\xA0-\xA5]", "a"):gsub("\xC3[\xA8-\xAB]", "e"):gsub("\xC3[\xAC-\xAF]", "i")
    :gsub("\xC3[\xB2-\xB6]", "o"):gsub("\xC3[\xB9-\xBC]", "u"):gsub("\xC3\xA7", "c")
  q = q:gsub("\xE2\x80\x99", ""):gsub("[%.':]", ""):gsub("%s+", "-"):gsub("%-+", "-")
  if q == "" or #q > 40 or not q:match("^[a-z0-9%-]+$") then return nil end
  return q
end

local function by_lang(list, field, code)
  for _, x in ipairs(type(list) == "table" and list or {}) do
    if type(x) == "table" and type(x.language) == "table" and x.language.name == code and type(x[field]) == "string" then
      return x[field]
    end
  end
end

local function one_decimal(n)
  local s = string.format("%.1f", n)
  if is_pt() then s = s:gsub("%.", ",") end
  return s
end

local function capitalize(s) return (s:gsub("^%l", string.upper):gsub("%-(%l)", function(c) return "-" .. c:upper() end)) end

local function card(p, sp)
  local lang = (larper.lang() or "en"):lower()
  local pt = is_pt()
  local name = sp and (by_lang(sp.names, "name", lang) or (pt and by_lang(sp.names, "name", "pt-br")) or by_lang(sp.names, "name", "en"))
  local base = sp and sp.name or p.name
  name = name or capitalize(tostring(base or "?"))
  -- Uma forma (deoxys-attack) mostra o nome da espécie e a forma entre parênteses.
  local pname = tostring(p.name or "")
  if base and pname ~= base and pname:sub(1, #base + 1) == base .. "-" then
    name = name .. " (" .. capitalize(pname:sub(#base + 2)) .. ")"
  end
  -- O gênero ("Mouse Pokémon") só no idioma da interface; o português não tem.
  local genus
  if sp then
    genus = by_lang(sp.genera, "genus", lang) or (pt and (by_lang(sp.genera, "genus", "pt-br") or by_lang(sp.genera, "genus", "pt")))
    if not genus and not pt then genus = by_lang(sp.genera, "genus", "en") end
  end
  local number = math.tointeger(sp and sp.id or p.id) or 0
  local types = {}
  local slots = type(p.types) == "table" and p.types or {}
  table.sort(slots, function(a, b) return (a.slot or 0) < (b.slot or 0) end)
  for _, t in ipairs(slots) do
    local tn = type(t.type) == "table" and t.type.name or "?"
    local names = TYPES[tn]
    types[#types + 1] = names and (pt and names[1] or names[2]) or capitalize(tn)
  end
  local stats = {}
  for _, s in ipairs(type(p.stats) == "table" and p.stats or {}) do
    if type(s.stat) == "table" then stats[s.stat.name] = s.base_stat end
  end
  local parts = { string.format("#%03d %s", number, name) .. (genus and (" (" .. genus .. ")") or "") }
  if #types > 0 then parts[#parts + 1] = table.concat(types, "/") end
  if p.height then parts[#parts + 1] = one_decimal(p.height / 10) .. " m" end
  if p.weight then parts[#parts + 1] = one_decimal(p.weight / 10) .. " kg" end
  local labels = { { "hp", "HP" }, { "attack", "Atk" }, { "defense", "Def" }, { "speed", pt and "Vel" or "Spd" } }
  for _, l in ipairs(labels) do
    if stats[l[1]] then parts[#parts + 1] = l[2] .. " " .. math.tointeger(stats[l[1]]) end
  end
  return table.concat(parts, " · ")
end

-- --- /pokemon ---------------------------------------------------------------------------

local busy = {}

local function not_found(q)
  larper.notify(tr{ pt = "Não achei nenhum Pokémon chamado \"" .. q .. "\"", en = "Couldn't find a Pokémon called \"" .. q .. "\"" })
end

-- Pede a espécie (nome no idioma e gênero); sem ela, a ficha sai mesmo assim.
local function with_species(q, p, sp)
  local function finish(species)
    busy[q] = nil
    remember(q, { p = p, sp = species })
    if p.name then remember(p.name, { p = p, sp = species }) end
    larper.insert(card(p, species))
  end
  if sp then return finish(sp) end
  local url = type(p.species) == "table" and type(p.species.url) == "string" and p.species.url or nil
  if not url or not url:match("^https://pokeapi%.co/") or not budget() then return finish(nil) end
  larper.http.get(url, function(res)
    finish(res.ok and decode(res.body) or nil)
  end)
end

larper.command("/pokemon", function(args)
  local q = normalize(args)
  if not q then
    larper.notify(tr{ pt = "Use assim: /pokemon pikachu ou /pokemon 25", en = "Use it like this: /pokemon pikachu or /pokemon 25" })
    return
  end
  local hit = cache[q]
  if hit then return larper.insert(card(hit.p, hit.sp)) end
  if busy[q] or not budget() then return end
  busy[q] = true
  larper.http.get(API .. "pokemon/" .. q, function(res)
    local p = res.ok and decode(res.body) or nil
    if type(p) == "table" and p.id then return with_species(q, p) end
    if res.status ~= 404 then
      busy[q] = nil
      return larper.notify(failure(res))
    end
    -- Algumas espécies só existem com a forma no nome (deoxys → deoxys-normal): a espécie diz qual é a padrão.
    if not budget() then busy[q] = nil; return end
    larper.http.get(API .. "pokemon-species/" .. q, function(res2)
      local sp = res2.ok and decode(res2.body) or nil
      local default
      for _, v in ipairs(type(sp) == "table" and type(sp.varieties) == "table" and sp.varieties or {}) do
        if v.is_default and type(v.pokemon) == "table" then default = v.pokemon.name end
      end
      if not default or not tostring(default):match("^[a-z0-9%-]+$") then
        busy[q] = nil
        if res2.status == 404 or res2.ok then return not_found(args) end
        return larper.notify(failure(res2))
      end
      if not budget() then busy[q] = nil; return end
      larper.http.get(API .. "pokemon/" .. default, function(res3)
        local p3 = res3.ok and decode(res3.body) or nil
        if type(p3) ~= "table" or not p3.id then
          busy[q] = nil
          return larper.notify(failure(res3))
        end
        with_species(q, p3, sp)
      end)
    end)
  end)
end)
