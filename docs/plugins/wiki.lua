-- @name Wikipedia
-- @name:pt Wikipédia
-- @description /wiki term puts the title, a short summary and the link of the Wikipedia article in the message box, in the app's language (Portuguese or English). With no exact article it searches, and a page with several meanings lists them. Only the term goes out, after you approve the host below.
-- @description:pt /wiki termo põe na caixa de mensagem o título, um resumo e o link do artigo da Wikipédia, no idioma do app (português ou inglês). Sem artigo com esse nome ele procura, e páginas com vários significados viram lista. Só o termo sai do app.
-- @version 1.0.0
-- @capabilities composer, http, notify
-- @hosts *.wikipedia.org

local tr = larper.tr
local MAX = 600
local OPTIONS = 5

local function host()
  return (larper.lang() or ""):match("^pt") and "pt.wikipedia.org" or "en.wikipedia.org"
end

-- --- Pedidos ----------------------------------------------------------------------------

local cache, cache_order = {}, {}
local function remember(key, value)
  if not cache[key] then cache_order[#cache_order + 1] = key end
  cache[key] = { value = value, at = os.time() }
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
    return tr{ pt = "Aprove *.wikipedia.org no cartão do plugin, em Configurações → Plugins", en = "Approve *.wikipedia.org on the plugin's card in Settings → Plugins" }
  elseif res.status == 429 then
    return tr{ pt = "A Wikipédia pediu para esperar um pouco. Tente de novo daqui a alguns minutos", en = "Wikipedia asked to slow down. Try again in a few minutes" }
  elseif res.error == "rate_limited" then
    return tr{ pt = "Muitas consultas seguidas. Tente de novo daqui a pouco", en = "Too many lookups in a row. Try again in a moment" }
  elseif res.error == "network" then
    return tr{ pt = "Sem conexão com a Wikipédia agora", en = "Couldn't reach Wikipedia right now" }
  elseif (res.status or 0) >= 500 then
    return tr{ pt = "A Wikipédia está com problemas agora (erro " .. res.status .. "). Tente mais tarde", en = "Wikipedia is having trouble right now (error " .. res.status .. "). Try again later" }
  end
  return tr{ pt = "Não consegui consultar a Wikipédia", en = "Couldn't look that up on Wikipedia" }
end

-- --- Texto ----------------------------------------------------------------------------

local ENTITIES = { ["&lt;"] = "<", ["&gt;"] = ">", ["&amp;"] = "&", ["&quot;"] = '"', ["&#39;"] = "'", ["&nbsp;"] = " " }

local function tidy(s)
  s = s:gsub("<[^>]*>", ""):gsub("&#?%w+;", ENTITIES)
  -- As marcas de referência ("[1]", "[carece de fontes]?") não fazem sentido fora da página.
  s = s:gsub("%[[^%]\n]*%]%??", ""):gsub("[ \t]+", " "):gsub(" ([,%.;:])", "%1")
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Corta perto de MAX caracteres, no fim de uma frase: pode passar um pouco (até SLACK) para
-- não perder uma frase inteira, e só corta no meio de uma se a primeira já for longa demais.
local SLACK = 80
local function cut(text, max)
  local n = utf8.len(text) or #text
  if n <= max then return text end
  local function bytes(chars) return (utf8.offset(text, chars + 1) or (chars + 1)) - 1 end
  local head = text:sub(1, bytes(math.min(n, max + SLACK)))
  local best
  for pos in head:gmatch("()[%.!?]%s") do best = pos end
  if head:match("[%.!?]$") then best = #head end
  if best and (utf8.len(head:sub(1, best)) or best) >= max * 0.4 then return head:sub(1, best) end
  head = text:sub(1, bytes(max))
  local space = head:match(".*()%s")
  return (space and head:sub(1, space - 1) or head) .. "…"
end

local function title_path(t)
  return larper.urlencode((t:gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", "_")))
end

local function page_url(d, h)
  local urls = type(d.content_urls) == "table" and type(d.content_urls.desktop) == "table" and d.content_urls.desktop
  if urls and type(urls.page) == "string" then return urls.page end
  return "https://" .. h .. "/wiki/" .. title_path(tostring(d.title or ""))
end

-- Monta o texto que vai para a caixa. nil = não serve (página sem conteúdo).
local function render(d, h)
  local name = tidy(tostring(d.title or ""))
  if name == "" then return nil end
  local url = page_url(d, h)
  if d.type == "disambiguation" then
    local items = {}
    for li in tostring(d.extract_html or ""):gmatch("<li[^>]*>(.-)</li>") do
      local item = tidy(li)
      if item ~= "" then items[#items + 1] = "• " .. cut(item, 110) end
      if #items == OPTIONS then break end
    end
    if #items > 0 then
      local head = h:match("^pt") and ("**" .. name .. "** pode se referir a:") or ("**" .. name .. "** may refer to:")
      return head .. "\n" .. table.concat(items, "\n") .. "\n" .. url
    end
  end
  local summary = tidy(tostring(d.extract or ""))
  if summary == "" then summary = tidy(tostring(d.description or "")) end
  if summary == "" then return "**" .. name .. "** " .. url end
  return "**" .. name .. "** — " .. cut(summary, MAX) .. " " .. url
end

-- --- /wiki ------------------------------------------------------------------------------

local busy = {}

-- done(dados, resposta); resposta false = nem pediu (passou do teto, já avisado).
local function summary(h, title, done)
  if not budget() then return done(nil, false) end
  larper.http.get("https://" .. h .. "/api/rest_v1/page/summary/" .. title_path(title), { headers = { Accept = "application/json" } }, function(res)
    local d = res.ok and larper.json.decode(res.body) or nil
    done(type(d) == "table" and d or nil, res)
  end)
end

local function search(h, term, done)
  if not budget() then return done(nil, false) end
  local url = "https://" .. h .. "/w/api.php?action=opensearch&namespace=0&limit=" .. OPTIONS .. "&format=json&search=" .. larper.urlencode(term)
  larper.http.get(url, function(res)
    local d = res.ok and larper.json.decode(res.body) or nil
    local titles = type(d) == "table" and type(d[2]) == "table" and d[2] or nil
    done(titles, res)
  end)
end

larper.command("/wiki", function(args)
  local term = args:gsub("%s+", " ")
  if term == "" or #term > 200 then
    larper.notify(tr{ pt = "Use assim: /wiki Recife", en = "Use it like this: /wiki Recife" })
    return
  end
  local h = host()
  local key = h .. ":" .. term:lower()
  local hit = cache[key]
  if hit and os.time() - hit.at < 6 * 3600 then return larper.insert(hit.value) end
  if busy[key] then return end
  busy[key] = true
  local function finish(d, res)
    busy[key] = nil
    if res == false then return end
    local text = d and render(d, h)
    if text then
      remember(key, text)
      return larper.insert(text)
    end
    if res and not res.ok and res.status ~= 404 then return larper.notify(failure(res)) end
    larper.notify(tr{ pt = "Não achei nada na Wikipédia sobre \"" .. term .. "\"", en = "Couldn't find anything on Wikipedia about \"" .. term .. "\"" })
  end
  summary(h, term, function(d, res)
    if res == false then return finish(nil, false) end
    if d and d.type ~= "no-extract" then return finish(d, res) end
    if not res.ok and res.status ~= 404 then return finish(nil, res) end
    -- Sem artigo com esse nome exato: a busca acha o mais parecido.
    search(h, term, function(titles, res2)
      if res2 == false then return finish(nil, false) end
      if not titles then return finish(nil, res2) end
      local first = titles[1]
      if type(first) ~= "string" then return finish(nil, nil) end
      if d and first:lower() == tostring(d.title or ""):lower() then return finish(d, res) end
      summary(h, first, finish)
    end)
  end)
end)
