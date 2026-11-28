-- @name Dice
-- @name:pt Dados
-- @description /roll 2d20+3 rolls dice and sends the result to the channel: several terms, keep the highest or lowest (4d6k3, 4d6kl1), d% and dF. /pick a b c draws one option and /coin flips a coin.
-- @description:pt /rolar 2d20+3 rola dados e manda o resultado no canal: vários termos, ficar com os maiores ou menores (4d6k3, 4d6kl1), d% e dF. /sortear a b c sorteia uma opção e /moeda joga uma moeda.
-- @version 1.0.0
-- @capabilities send, notify

local tr = larper.tr
local MAX_DICE = 100
local MAX_SIDES = 1000
local MAX_TERMS = 20
local MAX_CONST = 100000
local MAX_EXPR = 200
-- Lista de dados maior que isso aparece cortada.
local SHOW_DICE = 20

local function usage()
  larper.notify(tr{
    pt = "Use assim: /rolar 2d20+3, /rolar 4d6k3, /rolar d% ou /rolar 4dF (até 100 dados de até 1000 lados)",
    en = "Use it like this: /roll 2d20+3, /roll 4d6k3, /roll d% or /roll 4dF (up to 100 dice of up to 1000 sides)",
  })
end

-- 12345 -> "12.345" em português, "12,345" em inglês.
local function num(n)
  local s = tostring(math.abs(n))
  local sep = larper.lang():match("^pt") and "." or ","
  s = s:reverse():gsub("(%d%d%d)", "%1" .. sep):reverse()
  if s:sub(1, 1) == sep then s = s:sub(2) end
  return (n < 0 and "-" or "") .. s
end

-- "2d6+1d4-1" -> lista de termos, ou nil se não entender.
local function parse(expr)
  local s = expr:lower():gsub("%s+", "")
  if s == "" or #s > MAX_EXPR then return nil end
  local terms, pos, dice = {}, 1, 0
  while pos <= #s do
    local sign = 1
    local c = s:sub(pos, pos)
    if c == "+" or c == "-" then
      if c == "-" then sign = -1 end
      pos = pos + 1
    elseif #terms > 0 then
      return nil
    end
    local t
    local n, m, stop = s:match("^(%d*)d(%d+)()", pos)
    if n then
      t = { n = tonumber(n) or 1, sides = tonumber(m) }
    else
      n, stop = s:match("^(%d*)d%%()", pos)
      if n then
        t = { n = tonumber(n) or 1, sides = 100, pct = true }
      else
        n, stop = s:match("^(%d*)df()", pos)
        if n then
          t = { n = tonumber(n) or 1, fudge = true }
        else
          local k
          k, stop = s:match("^(%d+)()", pos)
          if not k then return nil end
          t = { const = tonumber(k) }
          if t.const > MAX_CONST then return nil end
        end
      end
    end
    pos = stop
    if not t.const then
      if t.n < 1 or t.n > MAX_DICE then return nil end
      if not t.fudge and (t.sides < 2 or t.sides > MAX_SIDES) then return nil end
      -- k3 / kh3: os 3 maiores; kl1: o menor.
      local hl, keep, after = s:match("^k([hl]?)(%d+)()", pos)
      if keep then
        t.keep = tonumber(keep)
        t.low = hl == "l"
        if t.keep < 1 or t.keep > t.n then return nil end
        pos = after
      end
      dice = dice + t.n
      if dice > MAX_DICE then return nil end
    end
    t.sign = sign
    terms[#terms + 1] = t
    if #terms > MAX_TERMS then return nil end
  end
  if #terms == 0 then return nil end
  return terms, (s:gsub("df", "dF"))
end

local function roll(terms)
  local total = 0
  for _, t in ipairs(terms) do
    if t.const then
      total = total + t.sign * t.const
    else
      local rolls, kept = {}, {}
      for i = 1, t.n do
        rolls[i] = t.fudge and math.random(-1, 1) or math.random(1, t.sides)
        kept[i] = true
      end
      if t.keep then
        local order = {}
        for i = 1, t.n do order[i] = i end
        table.sort(order, function(a, b)
          if rolls[a] == rolls[b] then return a < b end
          if t.low then return rolls[a] < rolls[b] end
          return rolls[a] > rolls[b]
        end)
        for i = 1, t.n do kept[i] = false end
        for i = 1, t.keep do kept[order[i]] = true end
      end
      local sum = 0
      for i = 1, t.n do
        if kept[i] then sum = sum + rolls[i] end
      end
      t.rolls, t.kept, t.sum = rolls, kept, sum
      total = total + t.sign * sum
    end
  end
  return total
end

local FUDGE = { [-1] = "-", [0] = "0", [1] = "+" }

local function show_term(t)
  if t.const then return num(t.const) end
  local parts = {}
  for i, r in ipairs(t.rolls) do
    if i > SHOW_DICE and #t.rolls > SHOW_DICE + 5 then
      parts[#parts + 1] = "… +" .. (#t.rolls - SHOW_DICE)
      break
    end
    local v = t.fudge and FUDGE[r] or num(r)
    -- O que ficou de fora do "k" aparece riscado.
    parts[#parts + 1] = t.kept[i] and v or "~~" .. v .. "~~"
  end
  return "[" .. table.concat(parts, ", ") .. "]"
end

local function describe(terms, expr, total)
  local only = terms[1]
  if #terms == 1 and not only.const and not only.fudge and only.n == 1 and not only.keep and only.sign > 0 then
    return "🎲 " .. expr .. " → **" .. num(only.rolls[1]) .. "**"
  end
  local out = {}
  for i, t in ipairs(terms) do
    local piece = show_term(t)
    if i == 1 then
      out[1] = (t.sign < 0 and "-" or "") .. piece
    else
      out[#out + 1] = (t.sign < 0 and " - " or " + ") .. piece
    end
  end
  local text = "🎲 " .. expr .. " → " .. table.concat(out) .. " = **" .. num(total) .. "**"
  if #text > 1990 then text = "🎲 " .. expr .. " → **" .. num(total) .. "**" end
  return text
end

local function need_channel()
  if larper.channel() then return true end
  larper.notify(tr{ pt = "Abra um canal primeiro", en = "Open a channel first" })
  return false
end

local function cmd_roll(args)
  local terms, expr = parse(args)
  if not terms then return usage() end
  if not need_channel() then return end
  local total = roll(terms)
  larper.send(nil, describe(terms, expr, total))
end

-- Corta sem partir um caractere no meio.
local function cut(s, n)
  if #s <= n then return s end
  while n > 0 and (s:byte(n + 1) or 0) & 0xC0 == 0x80 do n = n - 1 end
  return s:sub(1, n) .. "…"
end

local function cmd_pick(args)
  local options = {}
  if args:find(",", 1, true) then
    for piece in (args .. ","):gmatch("([^,]*),") do
      piece = piece:match("^%s*(.-)%s*$")
      if piece ~= "" then options[#options + 1] = piece end
    end
  else
    for word in args:gmatch("%S+") do options[#options + 1] = word end
  end
  if #options < 2 then
    larper.notify(tr{
      pt = "Use assim: /sortear pizza sushi lasanha, ou /sortear ver filme, jogar, dormir",
      en = "Use it like this: /pick pizza sushi lasagna, or /pick watch a movie, play, sleep",
    })
    return
  end
  if not need_channel() then return end
  -- Um * solto quebraria o negrito.
  local choice = cut(options[math.random(1, #options)], 1900):gsub("%*", "\\*")
  larper.send(nil, "🎲 " .. tr{ pt = "Sorteado", en = "Picked" } .. ": **" .. choice .. "**")
end

local function cmd_coin()
  if not need_channel() then return end
  local heads = math.random(1, 2) == 1
  local side = heads and tr{ pt = "Cara", en = "Heads" } or tr{ pt = "Coroa", en = "Tails" }
  larper.send(nil, "🪙 **" .. side .. "**")
end

larper.command("/rolar", cmd_roll)
larper.command("/roll", cmd_roll)
larper.command("/sortear", cmd_pick)
larper.command("/pick", cmd_pick)
larper.command("/moeda", cmd_coin)
larper.command("/coin", cmd_coin)
