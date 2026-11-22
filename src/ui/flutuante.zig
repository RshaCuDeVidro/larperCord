//! A vista compacta da janela flutuante (picture-in-picture, app_flutuante.zig): a
//! conversa, com as últimas mensagens ao vivo e uma caixa para responder, ou a call em
//! que estamos, com os quadros de quem está e os botões de mutar, ensurdecer e sair. O
//! desenho é o de sempre (comp_messages.historyIn, call_grid.compact, a linha do
//! "digitando" e o aviso de quando não dá para mandar) num d.Ctx com `pip`, no contexto
//! do ImGui da janela flutuante; as faixas vêm de core/flutuante.zig.
const std = @import("std");
const c = @import("c");
const kdl = @import("../theme/kdl.zig");
const d = @import("draw.zig");
const qa = @import("qa.zig");
const i18n = @import("i18n.zig");
const icons = @import("icons.zig");
const anim = @import("anim.zig");
const msgs = @import("comp_messages.zig");
const call_grid = @import("call_grid.zig");
const sigil = @import("comp_chat.zig").sigil;
const send_limits = @import("composer_limits.zig");
const ime = @import("ime.zig");
const state = @import("state.zig");
const fl = @import("../core/flutuante.zig");
const ChannelState = @import("../core/store.zig").ChannelState;

/// A janela flutuante está aberta (a paleta pergunta; quem muda é app_flutuante.zig).
pub var aberta = false;

/// Os botões da barra de cima, da direita para a esquerda: fechar e voltar para a
/// principal. O resto da barra arrasta a janela (app_flutuante.zig `hitTest`).
pub const botoes_w: f32 = 72;

/// O que a vista guarda de um quadro para o outro.
pub const Estado = struct {
    /// A caixa de mensagem dela: a da principal continua com o rascunho de lá.
    input: [2000]u8 = @splat(0),
    /// Pôr o foco na caixa no próximo quadro (abriu, ganhou o foco, mandou).
    focus: bool = true,
    /// O texto mudou por fora (mandou): a caixa recarrega quando soltar.
    sync: bool = false,
    scroll: state.Scroll = .{},
    /// O texto em conversão do IME nesta janela (o SDL manda no evento dela, e a caixa
    /// mostra numa caixinha sobre o cursor, como nos outros campos).
    preedit: [256]u8 = undefined,
    preedit_len: usize = 0,
};

/// O primeiro nó do tema com o nome: a conversa e a caixa saem com as propriedades do
/// tema (bolhas, irc, tamanho das fotos, o estilo dos quadros da call).
fn find(n: *const kdl.Node, name: []const u8) ?*const kdl.Node {
    if (std.mem.eql(u8, n.name, name)) return n;
    for (n.children) |*ch| if (find(ch, name)) |f| return f;
    return null;
}

const sem_mensagens: kdl.Node = .{ .name = "messages" };
const sem_caixa: kdl.Node = .{ .name = "composer" };

fn node(ctx: *const d.Ctx, name: []const u8, fallback: *const kdl.Node) *const kdl.Node {
    const root = ctx.th.layout orelse return fallback;
    return find(root, name) orelse fallback;
}

fn offset(r: d.Rect, o: d.Rect) d.Rect {
    return .{ .x = r.x + o.x, .y = r.y + o.y, .w = r.w, .h = r.h };
}

/// Um quadro da janela flutuante, entre o NewFrame e o Render do contexto dela.
pub fn draw(ctx: *d.Ctx, alvo: fl.Alvo, e: *Estado) void {
    const vp = c.ImGui_GetMainViewport();
    c.ImGui_SetNextWindowPos(vp.*.Pos, 0);
    c.ImGui_SetNextWindowSize(vp.*.Size, 0);
    _ = c.ImGui_Begin("##pip", null, c.ImGuiWindowFlags_NoDecoration | c.ImGuiWindowFlags_NoMove |
        c.ImGuiWindowFlags_NoSavedSettings | c.ImGuiWindowFlags_NoBringToFrontOnFocus |
        c.ImGuiWindowFlags_NoBackground | c.ImGuiWindowFlags_NoScrollWithMouse | c.ImGuiWindowFlags_NoNav);
    defer c.ImGui_End();
    ctx.dl = c.ImGui_GetWindowDrawList();
    ctx.fg = c.ImGui_GetForegroundDrawList();
    ctx.win = .{ .x = vp.*.Pos.x, .y = vp.*.Pos.y, .w = vp.*.Size.x, .h = vp.*.Size.y };
    const v = fl.vista(ctx.win.w, ctx.win.h, alvo);
    const topo = offset(v.topo, ctx.win);
    const corpo = offset(v.corpo, ctx.win);
    const base = offset(v.base, ctx.win);
    qa.mark(ctx.win, "window:{s}", .{@tagName(alvo)});
    const cs = ctx.store.channel(alvo.canal()) orelse return;
    barra(ctx, alvo, cs, topo);
    const n = node(ctx, "messages", &sem_mensagens);
    switch (alvo) {
        .conversa => |ch| {
            msgs.historyIn(ctx, n, corpo, ch, "##pip-msgs", &e.scroll);
            caixa(ctx, cs, base, e);
        },
        .call => call_grid.compact(ctx, n, corpo, base, cs),
    }
    // A conversão do IME da caixa, sobre o cursor dela (nenhum campo com o foco: acabou).
    if (e.preedit_len > 0 and !ime.box(ctx, e.preedit[0..e.preedit_len])) e.preedit_len = 0;
}

/// O nome da conversa (ou da call) e os botões de voltar para a principal e de fechar.
fn barra(ctx: *d.Ctx, alvo: fl.Alvo, cs: *ChannelState, r: d.Rect) void {
    const dl = ctx.dl;
    const fam = ctx.ui;
    d.rect(dl, r, ctx.col(.rail).mix(ctx.col(.bg), 0.4), 0);
    d.line(dl, r.x, r.bottom() - 0.5, r.right(), r.bottom() - 0.5, ctx.col(.border), 1);
    const cy = r.y + r.h / 2;
    var x = r.x + 12;
    switch (alvo) {
        .call => {
            icons.speaker(dl, x + 8, cy, ctx.col(.faint).u());
            x += 22;
        },
        .conversa => {
            // Os tamanhos do cabeçalho da principal: as letras já estão no atlas.
            const sg = sigil(&cs.info);
            d.text(dl, fam.get(.medium), 22, x, d.centerY(r, 22), ctx.col(.faint), sg);
            x += d.width(fam.get(.medium), 22, sg) + 4;
        },
    }
    const room = r.right() - botoes_w - 8 - x;
    const nw = d.textClipped(dl, fam.get(.semibold), 16, x, d.centerY(r, 16), ctx.col(.text), cs.info.name, room);
    qa.mark(.{ .x = x, .y = r.y, .w = nw, .h = r.h }, "title", .{});
    if (ctx.store.guild(cs.info.guild)) |g| if (room - nw > 40) {
        var gb: [160]u8 = undefined;
        const sub = std.fmt.bufPrint(&gb, "·  {s}", .{g.name}) catch "";
        _ = d.textClipped(dl, fam.get(.regular), 14, x + nw + 8, d.centerY(r, 14), ctx.col(.faint), sub, room - nw - 8);
    };
    // Fechar, na ponta.
    const xr: d.Rect = .{ .x = r.right() - 34, .y = cy - 14, .w = 28, .h = 28 };
    const xh = d.hit(ctx, 1, xr);
    qa.mark(xr, "close", .{});
    const xk = anim.to(anim.id("pip-close", 0), if (xh.hovered) 1 else 0, 24);
    d.rect(dl, xr, ctx.col(.danger).alpha(0.85 * xk), @max(ctx.th.radius, 6));
    const xc = ctx.col(.muted).mix(d.Rgba.white, xk);
    d.line(dl, xr.x + 9, xr.y + 9, xr.x + 19, xr.y + 19, xc, 1.6);
    d.line(dl, xr.x + 19, xr.y + 9, xr.x + 9, xr.y + 19, xc, 1.6);
    d.tip(ctx, xr, i18n.tr("Fechar a janela flutuante", "Close the floating window"), xh.hovered);
    if (xh.clicked) ctx.act(.{ .flutuante = .fechar });
    // Voltar para a janela principal, na conversa (ou na call) que ela segue.
    const br: d.Rect = .{ .x = xr.x - 34, .y = xr.y, .w = 28, .h = 28 };
    const bh = d.hit(ctx, 2, br);
    qa.mark(br, "back", .{});
    const bk = anim.to(anim.id("pip-back", 0), if (bh.hovered) 1 else 0, 24);
    d.rect(dl, br, ctx.col(.hover).alpha(bk * 1.5), @max(ctx.th.radius, 6));
    icons.expand(dl, br.x + 14, br.y + 14, ctx.col(.muted).mix(ctx.col(.text), bk).u());
    d.tip(ctx, br, i18n.tr("Voltar para a janela principal", "Back to the main window"), bh.hovered);
    if (bh.clicked) ctx.act(.{ .flutuante = .voltar });
}

/// A caixa de mensagem: Enter manda na conversa que a janela segue, Shift+Enter abre
/// uma linha. Em cima, quem está digitando; sem poder mandar, o motivo no lugar dela.
fn caixa(ctx: *d.Ctx, cs: *ChannelState, base: d.Rect, e: *Estado) void {
    const n = node(ctx, "composer", &sem_caixa);
    const fam = ctx.familyFor(n);
    const dl = ctx.dl;
    const r = fl.caixa(base);
    if (r.h < 20 or r.w < 60) return;
    msgs.typingLine(ctx, dl, fam, cs, r.x + 6, r.y - 19);
    const limit = send_limits.blockFor(ctx.store, &cs.info, ctx.now_ms);
    if (limit.reason.blocksInput()) return send_limits.band(ctx, n, r, limit);
    const radius = ctx.th.radius + 4;
    d.rect(dl, r, ctx.col(.elevated), radius);
    // Mandar: o mesmo botão redondo da caixa "pill".
    const sr: d.Rect = .{ .x = r.right() - r.h + 6, .y = r.y + 6, .w = r.h - 12, .h = r.h - 12 };
    const sh = d.hit(ctx, 3, sr);
    qa.mark(sr, "send", .{});
    const sk = anim.to(anim.id("pip-send", 0), if (sh.hovered) 1 else 0, 20);
    d.circle(dl, sr.x + sr.w / 2, sr.y + sr.h / 2, sr.w / 2, ctx.col(.accent).mix(d.Rgba.white, sk * 0.12));
    const ink = ctx.col(.accent_text).u();
    const tx = sr.x + sr.w / 2;
    const ty = sr.y + sr.h / 2;
    c.ImDrawList_AddTriangleFilled(dl, d.v(tx - 5, ty - 6), d.v(tx + 7, ty), d.v(tx - 5, ty + 6), ink);
    d.tip(ctx, sr, i18n.tr("Enviar  (Enter)", "Send  (Enter)"), sh.hovered);

    const fs = ctx.th.font_size;
    const font_px = d.fontPx(fs);
    const input_x = r.x + 12;
    const input_w = @max(40, sr.x - 6 - input_x);
    const frame_h = @min(font_px + 8, r.h);
    const input_y = r.y + (r.h - frame_h) / 2;
    var hint_buf: [96]u8 = undefined;
    const hint = if (limit.reason.cooling())
        send_limits.cooldownHint(&hint_buf, limit, ctx.now_ms)
    else if (limit.reason == .connecting)
        i18n.fmtZ(&hint_buf, "Conectando… dá para enviar quando conectar", "Connecting… you can send once connected", .{})
    else if (cs.info.guild == 0)
        i18n.fmtZ(&hint_buf, "Conversar com @{s}", "Message @{s}", .{cs.info.name})
    else
        i18n.fmtZ(&hint_buf, "Conversar em {s}{s}", "Message {s}{s}", .{ sigil(&cs.info), cs.info.name });
    if (e.input[0] == 0 and e.preedit_len == 0) _ = d.textClipped(dl, fam.get(.regular), fs, input_x + c.ImGui_GetStyle().*.FramePadding.x, input_y + 4, ctx.col(.faint), hint, input_w - 8);
    c.ImGui_PushFontFloat(fam.get(.regular), font_px);
    c.ImGui_SetCursorScreenPos(d.v(input_x, input_y));
    qa.mark(.{ .x = input_x, .y = r.y, .w = input_w, .h = r.h }, "composer", .{});
    if (e.focus and !@import("popup.zig").openHere(ctx)) {
        c.ImGui_SetKeyboardFocusHere();
        e.focus = false;
    }
    const flags = c.ImGuiInputTextFlags_EnterReturnsTrue | c.ImGuiInputTextFlags_CtrlEnterForNewLine | c.ImGuiInputTextFlags_WordWrap;
    const enter = c.ImGui_InputTextMultilineEx("##pip-input", &e.input, e.input.len, d.v(input_w, frame_h), flags, null, null);
    if (e.sync and !c.ImGui_IsItemActive()) {
        @memset(&e.input, 0);
        e.sync = false;
    }
    // Avisa o Discord quando o texto muda (o app limita a um a cada 8 s).
    if (c.ImGui_IsItemEdited() and e.input[0] != 0) ctx.act(.{ .typing = cs.info.id });
    c.ImGui_PopFont();
    // O Enter que fecha a conversão do IME escolhe o candidato, não manda.
    if ((enter and e.preedit_len == 0 and !ctx.io.*.KeyAlt) or sh.clicked) submit(ctx, cs, e);
}

fn submit(ctx: *d.Ctx, cs: *ChannelState, e: *Estado) void {
    const len = std.mem.indexOfScalar(u8, &e.input, 0) orelse e.input.len;
    const s = std.mem.trim(u8, e.input[0..len], " \t\r\n");
    if (s.len > 0) {
        if (ctx.st.gpa.dupe(u8, s)) |owned| ctx.act(.{ .send_to = .{ .channel = cs.info.id, .text = owned } }) else |_| return;
    }
    @memset(&e.input, 0);
    e.sync = true;
    e.focus = true;
}

/// A conversão do IME que chegou pela janela flutuante (texto vazio: acabou).
pub fn preedit(e: *Estado, text: [*c]const u8) void {
    const s = if (text == null) "" else std.mem.span(@as([*:0]const u8, @ptrCast(text)));
    e.preedit_len = ime.fit(s, e.preedit.len);
    @memcpy(e.preedit[0..e.preedit_len], s[0..e.preedit_len]);
}
