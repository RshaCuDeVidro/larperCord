-- @name Quote on click
-- @name:pt Citar com clique
-- @description Hold Q and left-click a message, or pick "Quote" on its menu, to put it in the message box as a quote. Nothing is sent: you write the answer and press Enter. Click the conversation first, or the Q goes into the box.
-- @description:pt Segure Q e clique numa mensagem, ou use "Citar" no menu dela, para pôr a mensagem na caixa como citação. Nada é enviado: você escreve a resposta e aperta Enter. Clique na conversa antes, senão o Q vai para a caixa.
-- @version 1.0.0
-- @capabilities messages, composer, menu

local tr = larper.tr
-- A citação inteira (com os "> " e a linha em branco) fica abaixo disso, e sobra
-- espaço para a resposta na mesma mensagem.
local MAX = 1500

-- Corta em n bytes sem partir um caractere no meio.
local function cut(s, n)
  if #s <= n then return s end
  while n > 0 and (s:byte(n + 1) or 0) & 0xC0 == 0x80 do n = n - 1 end
  return s:sub(1, n)
end

local function quote(m)
  local text = (m.content or ""):gsub("\r\n", "\n"):gsub("^%s+", ""):gsub("%s+$", "")
  if text == "" then
    text = m.attachments and m.attachments > 0 and tr{ pt = "[anexo]", en = "[attachment]" } or tr{ pt = "[sem texto]", en = "[no text]" }
  end
  -- Citar não é motivo para chamar todo mundo de novo.
  text = text:gsub("@(everyone)", "@\u{200B}%1"):gsub("@(here)", "@\u{200B}%1")
  local lines = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = "> " .. line
  end
  local body = table.concat(lines, "\n")
  local room = MAX - #"\n\n"
  if #body > room then
    body = cut(body, room - #"…")
    -- Sem um "> " sozinho no fim: as reticências ficam na última linha citada.
    body = body:gsub("\n[> ]*$", "") .. "…"
  end
  return body .. "\n\n"
end

larper.on("click", function(m, info)
  if info.button == "left" and info.keys.q then
    larper.insert(quote(m))
  end
end)

larper.menu("message", { pt = "Citar", en = "Quote" }, function(m)
  larper.insert(quote(m))
end)
