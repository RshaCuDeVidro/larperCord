//! A tela da call (#19, o "voice menu" do helpik1). Numa call de servidor, a área da
//! conversa vira uma grade com um quadro por pessoa: a foto e o apelido do servidor
//! no meio, sobre a cor da foto, o anel verde de quem fala, o microfone e o fone
//! desligados, a atividade embaixo do nome e o selo AO VIVO de quem transmite.
//! Clicar num quadro abre o menu da pessoa (volume, silenciar para mim). O cabeçalho
//! mostra a call e o botão de voltar para a conversa (Esc também volta), e os botões
//! da faixa de voz ficam no lugar da caixa de mensagem. Numa call de DM ou grupo, a
//! mesma grade fica numa faixa em cima da conversa. Nos temas de terminal, uma lista
//! em texto. Sem câmera nem transmissão: só quem está e como está. Nada aqui anima
//! sozinho: a tela muda quando alguém fala, entra ou sai, como a lista de canais.
const std = @import("std");
const c = @import("c");
const kdl = @import("../theme/kdl.zig");
const d = @import("draw.zig");
const w = @import("widgets.zig");
const qa = @import("qa.zig");
const anim = @import("anim.zig");
const i18n = @import("i18n.zig");
const icons = @import("icons.zig");
const devices = @import("device_menu.zig");
const channels = @import("comp_channels.zig");
const types = @import("../core/types.zig");
const ChannelState = @import("../core/store.zig").ChannelState;
const Id = types.Id;

/// A call de servidor aberta no lugar da conversa (null = a conversa de sempre).
pub fn guildCall(ctx: *const d.Ctx) ?*ChannelState {
    if (!ctx.st.call_view or ctx.st.friends) return null;
    const cs = ctx.store.channel(ctx.st.voice orelse return null) orelse return null;
    // Outro servidor na tela (por qualquer caminho): a conversa dele, não a call.
    return if (cs.info.guild != 0 and cs.info.guild == ctx.st.guild) cs else null;
}

/// Os botões no estilo texto ([mic] [fone]…): o da caixa de mensagem do tema
/// (composer variant=prompt), guardado a cada quadro, vale também para a faixa da DM.
pub var text_buttons = false;

/// O tamanho em que as fotos dos quadros são pedidas, o mesmo para qualquer quadro: o
/// quadro muda de tamanho (gente entrando, a janela) sem pedir e decodificar a foto de
/// novo, e a cor dela é achada pela mesma chave.
const photo_px: f32 = 128;

/// A call da DM ou do grupo `ch_id`, com a gente nela: a faixa em cima da conversa.
pub fn dmCall(ctx: *const d.Ctx, ch_id: Id) ?*ChannelState {
    if (ctx.st.voice != ch_id) return null;
    const cs = ctx.store.channel(ch_id) orelse return null;
    return if (cs.info.guild == 0) cs else null;
}

// --- A grade -------------------------------------------------------------------------

const layout = @import("call_layout.zig").layout;

const tile_min: f32 = 176;
const tile_max: f32 = 560;
const tile_gap: f32 = 10;
const pad: f32 = 16;

/// O microfone ou o fone com o risco de desligado.
fn offIcon(dl: *c.ImDrawList, mic: bool, cx: f32, cy: f32, col: d.Rgba) void {
    if (mic) icons.mic(dl, cx, cy, col.u()) else icons.headset(dl, cx, cy, col.u());
    d.line(dl, cx - 8, cy - 8, cx + 8, cy + 8, col, 1.8);
}

fn openMenu(ctx: *d.Ctx, uid: Id) void {
    ctx.popup(.{ .menu = .{ .kind = .user, .id = uid, .x = ctx.mouse.x, .y = ctx.mouse.y } });
}

/// O quadro de uma pessoa.
fn tile(ctx: *d.Ctx, dl: *c.ImDrawList, guild: Id, uid: Id, r: d.Rect, idx: usize) void {
    const u = ctx.store.user(uid);
    const speaking = ctx.store.isSpeaking(uid, ctx.now_ms);
    const vf = ctx.store.voiceFlags(uid);
    const radius = @max(ctx.th.radius + 2, 8);
    const av = std.math.clamp(@min(r.h * 0.42, r.w * 0.34), 28, 120);
    const scale = ctx.io.*.DisplayFramebufferScale.x;
    var ub: [192]u8 = undefined;
    const url = w.avatarUrl(ctx, &ub, guild, uid);
    // O fundo: a cor da foto (quando ela já carregou) ou a do cargo, escura o
    // bastante para o nome em branco.
    const photo: ?d.Rgba = if (url.len == 0) null else if (ctx.images.tint(url, av * scale, av * scale)) |t| d.Rgba.hex(t) else null;
    const fill = (photo orelse ctx.th.role(if (u) |x| x.role else 0)).mix(d.Rgba.black, 0.5);
    d.rect(dl, r, fill, radius);
    const hb = d.hit(ctx, 8900 + idx, r);
    if (hb.hovered) d.rect(dl, r, d.Rgba.white.alpha(0.06), radius);
    qa.mark(r, "grid-tile:{d}", .{uid});
    if (hb.clicked or hb.right) openMenu(ctx, uid);

    const cx = r.x + r.w / 2;
    const cy = r.y + r.h * 0.42;
    if (speaking) {
        d.border(dl, r.inset(1, 1), ctx.col(.online), radius, 3);
        c.ImDrawList_AddCircleEx(dl, d.v(cx, cy), av / 2 + 4, ctx.col(.online).u(), 0, 3, 0);
        qa.mark(r, "grid-speaking:{d}", .{uid});
    }
    w.avatarAt(ctx, dl, guild, cx, cy, av, uid, .circle, null, 1, false);

    // O nome e, embaixo, a atividade, centrados.
    const name = ctx.store.nameIn(guild, uid) orelse "?";
    const fs = std.math.clamp(r.h * 0.13, 13, 18);
    const nf = ctx.ui.get(.semibold);
    const room = r.w - 24;
    const nw = @min(d.width(nf, fs, name), room);
    const ny = cy + av / 2 + @max(6, r.h * 0.05);
    _ = d.textClipped(dl, nf, fs, cx - nw / 2, ny, d.Rgba.white.alpha(0.95), name, room);
    w.markName(.{ .x = cx - nw / 2, .y = ny, .w = nw, .h = fs + 4 }, "tile", uid, name);
    if (u) |x| if (x.activity) |act| if (act.len > 0) {
        const afs = fs - 2.5;
        const ay = ny + fs + 4;
        if (ay + afs + 4 <= r.bottom()) {
            const af = ctx.ui.get(.regular);
            const aw = @min(d.width(af, afs, act), room);
            _ = d.textClipped(dl, af, afs, cx - aw / 2, ay, d.Rgba.white.alpha(0.7), act, room);
            qa.mark(.{ .x = cx - aw / 2, .y = ay, .w = aw, .h = afs + 4 }, "grid-activity:{d}", .{uid});
        }
    };

    // Microfone e fone desligados, no canto de baixo (vermelho: foi o servidor).
    const mic_off = vf.self_mute or vf.serverMuted();
    const deaf = vf.deafened();
    if (mic_off or deaf) {
        const iw: f32 = (if (deaf) @as(f32, 22) else 0) + (if (mic_off) @as(f32, 22) else 0);
        const pr: d.Rect = .{ .x = r.right() - 10 - iw - 8, .y = r.bottom() - 36, .w = iw + 8, .h = 26 };
        d.rect(dl, pr, d.Rgba.black.alpha(0.45), 13);
        var x = pr.right() - 4;
        const my = pr.y + pr.h / 2;
        if (deaf) {
            x -= 11;
            offIcon(dl, false, x, my, if (vf.deaf) ctx.col(.danger) else d.Rgba.white.alpha(0.85));
            qa.mark(.{ .x = x - 10, .y = pr.y, .w = 20, .h = pr.h }, "grid-deaf:{d}", .{uid});
            x -= 11;
        }
        if (mic_off) {
            x -= 11;
            offIcon(dl, true, x, my, if (vf.serverMuted()) ctx.col(.danger) else d.Rgba.white.alpha(0.85));
            qa.mark(.{ .x = x - 10, .y = pr.y, .w = 20, .h = pr.h }, "grid-muted:{d}", .{uid});
        }
    }

    // Transmitindo: só o selo (assistir fica de fora).
    if (vf.self_stream) {
        const lt = i18n.tr("AO VIVO", "LIVE");
        const lf = ctx.ui.get(.bold);
        const lr: d.Rect = .{ .x = r.x + 10, .y = r.y + 10, .w = d.width(lf, 11, lt) + 12, .h = 20 };
        d.rect(dl, lr, ctx.col(.danger), 5);
        d.text(dl, lf, 11, lr.x + 6, d.centerY(lr, 11), d.Rgba.white, lt);
        qa.mark(lr, "grid-live:{d}", .{uid});
    }
}

/// A linha de uma pessoa na versão em texto.
fn line(ctx: *d.Ctx, dl: *c.ImDrawList, font: *c.ImFont, fs: f32, guild: Id, uid: Id, r: d.Rect, idx: usize) void {
    const u = ctx.store.user(uid);
    const speaking = ctx.store.isSpeaking(uid, ctx.now_ms);
    const vf = ctx.store.voiceFlags(uid);
    const name = ctx.store.nameIn(guild, uid) orelse "?";
    const act = if (u) |x| x.activity orelse "" else "";
    var buf: [256]u8 = undefined;
    const t = std.fmt.bufPrint(&buf, "{s} {s}{s}{s}{s}{s}", .{
        if (speaking) "◉" else "○",
        name,
        channels.voiceFlagsTty(vf),
        if (act.len > 0) "  · " else "",
        act,
        if (vf.self_stream) i18n.tr("  [AO VIVO]", "  [LIVE]") else "",
    }) catch name;
    const hb = d.hit(ctx, 8900 + idx, r);
    if (hb.hovered) d.rect(dl, r, ctx.col(.hover), 0);
    if (hb.clicked or hb.right) openMenu(ctx, uid);
    _ = d.textClipped(dl, font, fs, r.x + 4, d.centerY(r, fs), if (speaking) ctx.col(.online) else ctx.col(.text), t, r.w - 8);
    qa.mark(r, "grid-tile:{d}", .{uid});
    w.markName(r, "tile", uid, name);
    if (speaking) qa.mark(r, "grid-speaking:{d}", .{uid});
    if (vf.self_mute or vf.serverMuted()) qa.mark(r, "grid-muted:{d}", .{uid});
    if (vf.deafened()) qa.mark(r, "grid-deaf:{d}", .{uid});
    if (act.len > 0) qa.mark(r, "grid-activity:{d}", .{uid});
    if (vf.self_stream) qa.mark(r, "grid-live:{d}", .{uid});
}

/// Quem está na call, em quadros ou (nos temas de terminal) em linhas, numa região
/// que rola quando não cabe.
fn people(ctx: *d.Ctx, n: *const kdl.Node, r: d.Rect, cs: *ChannelState, tty: bool, region: [*:0]const u8) void {
    const list = cs.voice_members.items;
    const guild = cs.info.guild;
    const dl = d.beginRegion(ctx, region, r, 0);
    const top = c.ImGui_GetCursorScreenPos().y;
    if (list.len == 0) {
        const t = i18n.tr("Conectando à call…", "Connecting to the call…");
        const f = ctx.ui.get(.regular);
        d.text(dl, f, 14, r.x + (r.w - d.width(f, 14, t)) / 2, top + r.h / 2 - 8, ctx.col(.muted), t);
        return d.endRegion(ctx, top + r.h, r.x);
    }
    if (tty) {
        const fam = ctx.familyFor(n);
        const fs = ctx.th.font_size;
        var y = top + 8;
        for (list, 0..) |uid, i| {
            line(ctx, dl, fam.get(.regular), fs, guild, uid, .{ .x = r.x + 8, .y = y, .w = r.w - 16, .h = fs + 8 }, i);
            y += fs + 10;
        }
        return d.endRegion(ctx, y + 8, r.x);
    }
    const g = layout(list.len, r.w - pad * 2, r.h - pad * 2, tile_gap, tile_min, tile_max);
    const rows_f: f32 = @floatFromInt(g.rows);
    const block_h = rows_f * g.tile_h + (rows_f - 1) * tile_gap;
    const y0 = top + @max(pad, (r.h - block_h) / 2);
    for (list, 0..) |uid, i| {
        const row = i / g.cols;
        const col = i % g.cols;
        // A última linha, se incompleta, fica centrada.
        const in_row: f32 = @floatFromInt(if (row == g.rows - 1) list.len - row * g.cols else g.cols);
        const row_w = in_row * g.tile_w + (in_row - 1) * tile_gap;
        const x = r.x + (r.w - row_w) / 2 + @as(f32, @floatFromInt(col)) * (g.tile_w + tile_gap);
        const y = y0 + @as(f32, @floatFromInt(row)) * (g.tile_h + tile_gap);
        tile(ctx, dl, guild, uid, .{ .x = @round(x), .y = @round(y), .w = @round(g.tile_w), .h = @round(g.tile_h) }, i);
    }
    d.endRegion(ctx, y0 + block_h + pad, r.x);
}

/// A tela da call no lugar da conversa.
pub fn page(ctx: *d.Ctx, n: *const kdl.Node, r: d.Rect, cs: *ChannelState) void {
    // Esc volta para a conversa, se não for para fechar outra coisa (menu, paleta,
    // Configurações, a imagem aberta, a busca) nem estiver digitando.
    if (c.ImGui_IsKeyPressed(c.ImGuiKey_Escape) and escFree(ctx)) ctx.act(.{ .show_call = 0 });
    qa.mark(r, "grid-view", .{});
    people(ctx, n, r, cs, d.is(n, "variant", "irc", ""), "##call-grid");
}

/// O Esc é da tela da call? (Nada aberto por cima que ele deva fechar antes.)
pub fn escFree(ctx: *const d.Ctx) bool {
    const st = ctx.st;
    return st.popup == .none and !st.palette.open and st.viewer == null and !st.settings.open and
        !@import("search.zig").open and !ctx.io.*.WantTextInput;
}

/// A call da DM ou do grupo aberto: uma faixa em cima da conversa, com a grade e os
/// botões. Devolve a altura que ocupou (0: a conversa é baixa demais para dividir).
pub fn dmBand(ctx: *d.Ctx, n: *const kdl.Node, r: d.Rect, cs: *ChannelState) f32 {
    const tty = d.is(n, "variant", "irc", "");
    const ctl_h: f32 = if (tty) 28 else 60;
    const rows: f32 = @floatFromInt(@max(cs.voice_members.items.len, 1));
    const want = if (tty) rows * (ctx.th.font_size + 10) + 16 + ctl_h else r.h * 0.42;
    const h = @min(@max(want, if (tty) @as(f32, 70) else 210), @max(r.h * 0.6, 100));
    const band: d.Rect = .{ .x = r.x, .y = r.y, .w = r.w, .h = h };
    d.rect(ctx.dl, band, ctx.col(.rail).alpha(0.55), 0);
    d.line(ctx.dl, band.x, band.bottom() - 0.5, band.right(), band.bottom() - 0.5, ctx.col(.border), 1);
    qa.mark(band, "grid-band", .{});
    people(ctx, n, .{ .x = band.x, .y = band.y, .w = band.w, .h = band.h - ctl_h }, cs, tty, "##call-band");
    buttons(ctx, ctx.dl, ctx.familyFor(n), .{ .x = band.x, .y = band.bottom() - ctl_h, .w = band.w, .h = ctl_h }, tty);
    return h;
}

// --- Botões --------------------------------------------------------------------------

/// Os botões da faixa de voz (microfone, fone, mixer, sair), no lugar da caixa de
/// mensagem.
pub fn controls(ctx: *d.Ctx, n: *const kdl.Node, r: d.Rect) void {
    buttons(ctx, ctx.dl, ctx.familyFor(n), r, d.is(n, "variant", "prompt", ""));
}

fn openMixer(ctx: *d.Ctx, r: d.Rect) void {
    ctx.popup(.{ .mixer = .{ .x = r.x + r.w / 2 - 160, .y = r.y - 330 } });
}

/// Um botão de texto (`[mixer]`, `[sair]`) dos temas de terminal; devolve a largura.
fn textButton(ctx: *d.Ctx, dl: *c.ImDrawList, font: *c.ImFont, fs: f32, x: f32, y: f32, h: f32, label: []const u8, mark: []const u8, ink: d.Rgba, id: usize) struct { w: f32, clicked: bool } {
    const bw = d.width(font, fs, label) + 8;
    const br: d.Rect = .{ .x = x, .y = y, .w = bw, .h = h };
    const hb = d.hit(ctx, id, br);
    qa.mark(br, "{s}", .{mark});
    if (hb.hovered) d.rect(dl, br, ctx.col(.hover), 0);
    d.text(dl, font, fs, x + 4, d.centerY(br, fs), if (hb.hovered) ctx.col(.text) else ink, label);
    return .{ .w = bw, .clicked = hb.clicked };
}

fn buttons(ctx: *d.Ctx, dl: *c.ImDrawList, fam: *d.Family, r: d.Rect, tty: bool) void {
    if (tty) {
        const fs = ctx.th.font_size - 1;
        const font = fam.get(.bold);
        const h = @min(r.h, 26);
        const y = r.y + (r.h - h) / 2;
        var x = r.x + 10;
        for ([_]devices.Kind{ .mic, .deaf }, [_][]const u8{ "grid-mic", "grid-deaf" }, 0..) |k, tag, i| {
            const br: d.Rect = .{ .x = x, .y = y, .w = devices.ttyWidth(font, fs, k, .tty), .h = h };
            qa.mark(br, "{s}", .{tag});
            _ = devices.toggle(ctx, dl, font, fs, k, br, .tty, 8950 + i * 2, tag);
            x += br.w + 8;
        }
        const mix = textButton(ctx, dl, font, fs, x, y, h, i18n.tr("[mixer]", "[mixer]"), "grid-mixer", ctx.col(.muted), 8960);
        if (mix.clicked) openMixer(ctx, r);
        x += mix.w + 8;
        const leave = textButton(ctx, dl, font, fs, x, y, h, i18n.tr("[sair]", "[leave]"), "grid-leave", ctx.col(.danger), 8961);
        if (leave.clicked) ctx.act(.leave_voice);
        return;
    }
    const b = std.math.clamp(r.h - 16, 30, 44);
    const gap: f32 = 12;
    const dev_w = b + devices.chev_w;
    const leave_w = b * 1.5;
    const total = dev_w * 2 + b + leave_w + gap * 3;
    var x = r.x + (r.w - total) / 2;
    const y = r.y + (r.h - b) / 2;
    const fs = ctx.th.font_size;
    const font = fam.get(.medium);
    for ([_]devices.Kind{ .mic, .deaf }, [_][]const u8{ "grid-mic", "grid-deaf" }, 0..) |k, tag, i| {
        const br: d.Rect = .{ .x = x, .y = y, .w = dev_w, .h = b };
        d.rect(dl, br, ctx.col(.elevated), b / 2);
        qa.mark(br, "{s}", .{tag});
        _ = devices.toggle(ctx, dl, font, fs, k, br, .icon, 8950 + i * 2, tag);
        x += dev_w + gap;
    }
    // Mixer: os três faders da faixa de voz.
    {
        const mr: d.Rect = .{ .x = x, .y = y, .w = b, .h = b };
        const mh = d.hit(ctx, 8960, mr);
        qa.mark(mr, "grid-mixer", .{});
        const k = anim.to(anim.id("grid-mixer", 0), if (mh.hovered) 1 else 0, 24);
        d.rect(dl, mr, ctx.col(.elevated).mix(ctx.col(.hover), k), b / 2);
        const mx = mr.x + b / 2;
        const my = mr.y + b / 2;
        const ink = ctx.col(.muted).mix(ctx.col(.text), k);
        for (0..3) |i| {
            const yy = my - 7 + @as(f32, @floatFromInt(i)) * 7;
            d.line(dl, mx - 7, yy, mx + 7, yy, ink.alpha(0.6), 1.3);
            const kx = mx - 7 + @as(f32, @floatFromInt((i * 5) % 14));
            c.ImDrawList_AddCircleEx(dl, d.v(kx, yy), 2.2, ink.u(), 0, 1.2, 0);
        }
        d.tip(ctx, mr, i18n.tr("Mixer da call", "Call mixer"), mh.hovered);
        if (mh.clicked) openMixer(ctx, r);
        x += b + gap;
    }
    // Sair: o botão vermelho.
    {
        const lr: d.Rect = .{ .x = x, .y = y, .w = leave_w, .h = b };
        const lh = d.hit(ctx, 8961, lr);
        qa.mark(lr, "grid-leave", .{});
        const k = anim.to(anim.id("grid-leave", 0), if (lh.hovered) 1 else 0, 24);
        d.rect(dl, lr, ctx.col(.danger).mix(d.Rgba.black, 0.15 * k), b / 2);
        const lx = lr.x + lr.w / 2;
        const ly = lr.y + b / 2;
        d.line(dl, lx - 5, ly - 5, lx + 5, ly + 5, d.Rgba.white, 2.2);
        d.line(dl, lx + 5, ly - 5, lx - 5, ly + 5, d.Rgba.white, 2.2);
        d.tip(ctx, lr, i18n.tr("Sair da call", "Leave call"), lh.hovered);
        if (lh.clicked) ctx.act(.leave_voice);
    }
}

// --- Cabeçalho -----------------------------------------------------------------------

/// O cabeçalho na tela da call: o canal e o servidor, e o botão de voltar para a
/// conversa.
pub fn header(ctx: *d.Ctx, n: *const kdl.Node, r: d.Rect, cs: *ChannelState) void {
    const fam = ctx.familyFor(n);
    const dl = ctx.dl;
    const g = ctx.store.guild(cs.info.guild);
    if (d.is(n, "variant", "tty", "discord")) {
        const fs = ctx.th.font_size - 1;
        const font = fam.get(.bold);
        const back_t = i18n.tr("[conversa]", "[chat]");
        const bw = d.width(font, fs, back_t);
        const br: d.Rect = .{ .x = r.right() - bw - 12, .y = r.y, .w = bw + 4, .h = r.h };
        var buf: [192]u8 = undefined;
        const t = std.fmt.bufPrint(&buf, "─ ♪ {s} ─ {s} ", .{ cs.info.name, if (g) |x| x.name else "" }) catch cs.info.name;
        const tw = d.textClipped(dl, font, fs, r.x + 6, d.centerY(r, fs), ctx.col(.accent), t, br.x - r.x - 14);
        const ly = r.y + r.h / 2;
        d.line(dl, r.x + 6 + tw + 4, ly, br.x - 4, ly, ctx.col(.border), 1);
        const hb = d.hit(ctx, 8990, br);
        qa.mark(br, "grid-back", .{});
        d.text(dl, font, fs, br.x + 2, d.centerY(r, fs), if (hb.hovered) ctx.col(.text) else ctx.col(.muted), back_t);
        d.tip(ctx, br, i18n.tr("Voltar à conversa (Esc)", "Back to chat (Esc)"), hb.hovered);
        if (hb.clicked) ctx.act(.{ .show_call = 0 });
        return;
    }
    icons.speaker(dl, r.x + 22, r.y + r.h / 2, ctx.col(.faint).u());
    const back_t = i18n.tr("Voltar à conversa", "Back to chat");
    const bf = fam.get(.medium);
    const bw = d.width(bf, 13, back_t) + 40;
    const br: d.Rect = .{ .x = r.right() - bw - 12, .y = r.y + (r.h - 30) / 2, .w = bw, .h = 30 };
    const name_room = br.x - (r.x + 42) - 12;
    const nw = d.textClipped(dl, fam.get(.semibold), 16, r.x + 42, d.centerY(r, 16), ctx.col(.text), cs.info.name, name_room);
    if (g) |x| {
        var gb: [160]u8 = undefined;
        const sub = std.fmt.bufPrint(&gb, "·  {s}", .{x.name}) catch "";
        _ = d.textClipped(dl, fam.get(.regular), 14, r.x + 42 + nw + 10, d.centerY(r, 14), ctx.col(.faint), sub, @max(name_room - nw - 10, 0));
    }
    const hb = d.hit(ctx, 8990, br);
    qa.mark(br, "grid-back", .{});
    const k = anim.to(anim.id("grid-back", 0), if (hb.hovered) 1 else 0, 24);
    d.rect(dl, br, ctx.col(.elevated).mix(ctx.col(.hover), k), @max(ctx.th.radius, 6));
    const ink = ctx.col(.muted).mix(ctx.col(.text), k);
    icons.message(dl, br.x + 16, br.y + 15, ink.u());
    d.text(dl, bf, 13, br.x + 30, d.centerY(br, 13), ink, back_t);
    d.tip(ctx, br, "Esc", hb.hovered);
    if (hb.clicked) ctx.act(.{ .show_call = 0 });
}
