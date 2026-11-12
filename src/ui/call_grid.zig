//! A tela da call (#19, o "voice menu" do helpik1). Numa call de servidor, a área da
//! conversa vira uma grade com um quadro por pessoa: a foto e o apelido do servidor
//! no meio, sobre o fundo do tema com um toque da cor da foto, o anel verde de quem
//! fala, o microfone e o fone desligados, a atividade embaixo do nome e o selo AO
//! VIVO de quem transmite. O tema escolhe o estilo dos quadros (`call-style`), o
//! quanto da foto entra no fundo (`call-tint`) e o formato das fotos (`avatar`), no
//! componente `messages`. Clicar num quadro abre o menu da pessoa (volume, silenciar
//! para mim); com o mouse no seu, aparece o nível do seu microfone. Sozinho na call,
//! o quadro encolhe e embaixo vem o convite. O cabeçalho mostra a call e o botão de
//! voltar para a conversa (Esc também volta), e os botões da faixa de voz, numa barra
//! com o tempo da call, ficam no lugar da caixa de mensagem. Numa call de DM ou grupo,
//! a mesma grade fica numa faixa em cima da conversa. Nos temas de terminal, uma
//! lista em texto. Sem câmera nem transmissão: só quem está e como está. Nada aqui
//! anima sozinho: a tela muda quando alguém fala, entra ou sai, como a lista de canais.
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
const forum = @import("forum.zig");
const invites = @import("invites.zig");
const mascote = @import("mascote.zig");
const voice_timer = @import("voice_timer.zig");
const theme_mod = @import("../theme/theme.zig");
const voz = @import("../core/voz.zig");
const vt = @import("../core/voice_timer.zig");
const voz_audio = @import("../net/voz_audio.zig");
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
/// Sozinho na call: um quadro menor, e embaixo a linha do convite.
const tile_alone_max: f32 = 380;
const alone_row_h: f32 = 64;

/// Como o tema pinta os quadros, das propriedades do componente `messages`:
/// `call-style` (um estilo nomeado: fundo, borda, sombra, brilho…), `call-tint`
/// (quanto da cor da foto entra no fundo, de 0 a 1) e `avatar` (o formato da foto;
/// `none` vira círculo, porque aqui a foto é a pessoa).
const Look = struct {
    style: ?theme_mod.Style = null,
    tint: f32 = 0.22,
    shape: w.Shape = .circle,
};

fn lookOf(ctx: *const d.Ctx, n: *const kdl.Node) Look {
    return .{
        .style = ctx.th.style(n.str("call-style")),
        .tint = std.math.clamp(d.pnum(n, "call-tint", 0.22), 0, 1),
        .shape = w.shapeOf(d.pstr(n, "avatar", "circle")),
    };
}

/// O texto do tema sobre o fundo do quadro; se ele some ali (uma foto escura num
/// tema claro, ou o contrário), branco ou quase preto, o que se ler melhor.
fn inkOn(ctx: *const d.Ctx, fill: d.Rgba) d.Rgba {
    const opaque_fill: d.Rgba = .{ .r = fill.r, .g = fill.g, .b = fill.b, .a = 1 };
    const t = ctx.col(.text);
    if (t.contrast(opaque_fill) >= 4) return t;
    const dark = d.Rgba.hex(0x101014);
    return if (d.Rgba.white.contrast(opaque_fill) >= dark.contrast(opaque_fill)) d.Rgba.white else dark;
}

/// O anel de quem fala em volta da foto, no formato dela.
fn ring(dl: *c.ImDrawList, shape: w.Shape, cx: f32, cy: f32, av: f32, col: d.Rgba) void {
    if (shape == .circle) return c.ImDrawList_AddCircleEx(dl, d.v(cx, cy), av / 2 + 4, col.u(), 0, 3, 0);
    const half = av / 2 + 4;
    d.border(dl, .{ .x = cx - half, .y = cy - half, .w = half * 2, .h = half * 2 }, col, w.shapeRadius(shape, av) + 4, 3);
}

/// O microfone ou o fone com o risco de desligado.
fn offIcon(dl: *c.ImDrawList, mic: bool, cx: f32, cy: f32, col: d.Rgba) void {
    if (mic) icons.mic(dl, cx, cy, col.u()) else icons.headset(dl, cx, cy, col.u());
    d.line(dl, cx - 8, cy - 8, cx + 8, cy + 8, col, 1.8);
}

fn openMenu(ctx: *d.Ctx, uid: Id) void {
    ctx.popup(.{ .menu = .{ .kind = .user, .id = uid, .x = ctx.mouse.x, .y = ctx.mouse.y } });
}

/// O quadro de uma pessoa.
fn tile(ctx: *d.Ctx, dl: *c.ImDrawList, look: Look, guild: Id, uid: Id, r: d.Rect, idx: usize) void {
    const u = ctx.store.user(uid);
    const speaking = ctx.store.isSpeaking(uid, ctx.now_ms);
    const vf = ctx.store.voiceFlags(uid);
    const mine = uid == ctx.store.me;
    const radius = if (look.style) |st| st.radius else @max(ctx.th.radius + 2, 8);
    const av = std.math.clamp(@min(r.h * 0.42, r.w * 0.34), 28, 120);
    const scale = ctx.io.*.DisplayFramebufferScale.x;
    var ub: [192]u8 = undefined;
    const url = w.avatarUrl(ctx, &ub, guild, uid);
    // O fundo é o do tema (o estilo `call-style` ou o `elevated`), com um toque da
    // cor da foto (quando ela já carregou) ou, sem foto, da do cargo.
    const photo: ?d.Rgba = if (url.len == 0) null else if (ctx.images.tint(url, photo_px * scale, photo_px * scale)) |t| d.Rgba.hex(t) else null;
    const tint = photo orelse ctx.th.role(if (u) |x| x.role else 0);
    const base = if (look.style) |st| st.bg orelse ctx.col(.surface) else ctx.col(.elevated);
    const fill = base.mix(tint, look.tint);
    if (look.style) |st| {
        d.drawStyle(ctx, dl, st, r, 8900 + idx);
        d.rect(dl, r, tint.alpha(look.tint), radius);
    } else {
        d.rect(dl, r, fill, radius);
        d.border(dl, r, ctx.col(.border).alpha(0.6), radius, 1);
    }
    const ink = inkOn(ctx, fill);
    if (qa.compiled and mine) qa_tile = .{ .set = true, .fill = fill, .base = base, .tint = look.tint };
    const hb = d.hit(ctx, 8900 + idx, r);
    if (hb.hovered) d.rect(dl, r, ink.alpha(0.06), radius);
    qa.mark(r, "grid-tile:{d}", .{uid});
    if (hb.clicked or hb.right) openMenu(ctx, uid);

    const cx = r.x + r.w / 2;
    const cy = r.y + r.h * 0.42;
    if (speaking) {
        d.border(dl, r.inset(1, 1), ctx.col(.online), radius, 3);
        ring(dl, look.shape, cx, cy, av, ctx.col(.online));
        qa.mark(r, "grid-speaking:{d}", .{uid});
    }
    w.avatarAt(ctx, dl, guild, cx, cy, av, uid, look.shape, null, 1, .{ .animate = false, .request = photo_px });

    // O nome e, embaixo, a atividade, centrados (no seu quadro, acima do medidor).
    const name = ctx.store.nameIn(guild, uid) orelse "?";
    const fs = std.math.clamp(r.h * 0.13, 13, 18);
    const nf = ctx.ui.get(.semibold);
    const room = r.w - 24;
    const nw = @min(d.width(nf, fs, name), room);
    const ny = cy + av / 2 + @max(6, r.h * 0.05);
    _ = d.textClipped(dl, nf, fs, cx - nw / 2, ny, ink.alpha(0.95), name, room);
    w.markName(.{ .x = cx - nw / 2, .y = ny, .w = nw, .h = fs + 4 }, "tile", uid, name);
    if (u) |x| if (x.activity) |act| if (act.len > 0) {
        const afs = fs - 2.5;
        const ay = ny + fs + 4;
        if (ay + afs + (if (mine) @as(f32, 14) else 4) <= r.bottom()) {
            const af = ctx.ui.get(.regular);
            const aw = @min(d.width(af, afs, act), room);
            _ = d.textClipped(dl, af, afs, cx - aw / 2, ay, ink.alpha(0.7), act, room);
            qa.mark(.{ .x = cx - aw / 2, .y = ay, .w = aw, .h = afs + 4 }, "grid-activity:{d}", .{uid});
        }
    };

    // Microfone e fone desligados, no canto de cima (longe do nome e da atividade;
    // vermelho: foi o servidor), numa pílula com o fundo do tema.
    const mic_off = vf.self_mute or vf.serverMuted();
    const deaf = vf.deafened();
    if (mic_off or deaf) {
        const iw: f32 = (if (deaf) @as(f32, 22) else 0) + (if (mic_off) @as(f32, 22) else 0);
        const pr: d.Rect = .{ .x = r.right() - 10 - iw - 8, .y = r.y + 10, .w = iw + 8, .h = 26 };
        d.rect(dl, pr, ctx.col(.bg).alpha(0.72), 13);
        const icon = ctx.col(.text).alpha(0.85);
        var x = pr.right() - 4;
        const my = pr.y + pr.h / 2;
        if (deaf) {
            x -= 11;
            offIcon(dl, false, x, my, if (vf.deaf) ctx.col(.danger) else icon);
            qa.mark(.{ .x = x - 10, .y = pr.y, .w = 20, .h = pr.h }, "grid-deaf:{d}", .{uid});
            x -= 11;
        }
        if (mic_off) {
            x -= 11;
            offIcon(dl, true, x, my, if (vf.serverMuted()) ctx.col(.danger) else icon);
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

    if (mine) meter(ctx, dl, r, ink, hb.hovered);
}

/// O fundo do seu quadro no último quadro desenhado (o QA confere que é o do tema).
pub var qa_tile: struct { set: bool = false, fill: d.Rgba = d.Rgba.black, base: d.Rgba = d.Rgba.black, tint: f32 = 0 } = .{};

/// O nível do seu microfone na call, com a marca do limiar da detecção de voz (no
/// aperte para falar, só o nível): dá para ver se o microfone pega e se a
/// sensibilidade está boa sem abrir as Configurações. Só aparece com o mouse no seu
/// quadro, e só então pede quadros (30 por segundo, com a janela em foco): parada, a
/// tela da call não gasta nada com ele.
fn meter(ctx: *d.Ctx, dl: *c.ImDrawList, r: d.Rect, ink: d.Rgba, hovered: bool) void {
    const tr: d.Rect = .{ .x = r.x + 16, .y = r.bottom() - 11, .w = r.w - 32, .h = 5 };
    const s = &ctx.st.settings;
    // (Sem um `hit` próprio: por cima do quadro ele tiraria o mouse dele.)
    const on_bar = hovered and ctx.hovering(.{ .x = tr.x, .y = tr.y - 8, .w = tr.w, .h = tr.h + 16 });
    // (A dica é chamada em todo quadro: ela mesma desenha o sumiço.)
    d.tip(ctx, tr, if (s.voice_ptt)
        i18n.tr("Seu microfone (aperte para falar). Ajuste em Configurações → Voz.", "Your mic (push to talk). Adjust it in Settings → Voice.")
    else
        i18n.tr("Seu microfone: a barra é o nível, a marca é o limiar da detecção de voz. Ajuste em Configurações → Voz.", "Your mic: the bar is the level, the mark is the voice detection threshold. Adjust it in Settings → Voice."), on_bar);
    if (!hovered or tr.w < 40) return;
    const sh = &voz_audio.sh;
    d.rect(dl, tr, ink.alpha(0.18), tr.h / 2);
    const level = if (ctx.st.muted or ctx.st.deafened) 0 else voz.dbToPos(sh.call_level_db.load(.monotonic));
    const th = voz.dbToPos(if (s.voice_auto) sh.call_threshold_db.load(.monotonic) else voz.sensToDb(s.voice_sens));
    if (level > 0) {
        if (s.voice_ptt) {
            d.rect(dl, .{ .x = tr.x, .y = tr.y, .w = tr.w * level, .h = tr.h }, ctx.col(.online), tr.h / 2);
        } else {
            // Abaixo do limiar, apagado (não abre o microfone); acima, verde.
            d.rect(dl, .{ .x = tr.x, .y = tr.y, .w = tr.w * @min(level, th), .h = tr.h }, ink.alpha(0.45), tr.h / 2);
            if (level > th) d.rect(dl, .{ .x = tr.x + tr.w * th, .y = tr.y, .w = tr.w * (level - th), .h = tr.h }, ctx.col(.online), tr.h / 2);
        }
    }
    if (!s.voice_ptt) {
        const mx = @round(tr.x + tr.w * th);
        d.line(dl, mx, tr.y - 4, mx, tr.bottom() + 4, ink.alpha(0.9), 2);
    }
    qa.mark(tr, "grid-meter", .{});
    if (ctx.st.window_focused) anim.at(ctx.now_ms + 33);
}

/// Sozinho na call de um servidor: o mascote cochilando, "Só você por aqui" e, se dá
/// para convidar neste servidor, o botão que abre o convite (o mesmo do menu do
/// servidor: o link só é pedido ao clicar).
fn aloneRow(ctx: *d.Ctx, dl: *c.ImDrawList, cs: *ChannelState, cx: f32, y: f32) void {
    const f = ctx.ui.get(.regular);
    const fs: f32 = 14;
    const t = i18n.tr("Só você por aqui", "Just you here");
    const ch: ?Id = if (invites.canInvite(ctx, &cs.info)) cs.info.id else invites.channelFor(ctx, cs.info.guild);
    const bl = i18n.tr("Convidar pessoas", "Invite people");
    const bw = if (ch != null) d.width(ctx.ui.get(.semibold), 13.5, bl) + 28 else 0;
    const mw: f32 = 58;
    const tw = d.width(f, fs, t);
    const row: d.Rect = .{ .x = cx, .y = y, .w = 0, .h = alone_row_h };
    var x = cx - (mw + 10 + tw + (if (ch != null) 18 + bw else 0)) / 2;
    mascote.inApp(ctx, dl, x + mw / 2, y + alone_row_h / 2, mw, .sleep, .call, 8);
    x += mw + 10;
    d.text(dl, f, fs, x, d.centerY(row, fs), ctx.col(.muted), t);
    qa.mark(.{ .x = x, .y = y, .w = tw, .h = alone_row_h }, "grid-alone", .{});
    x += tw + 18;
    if (ch) |id| {
        const br: d.Rect = .{ .x = x, .y = y + (alone_row_h - 34) / 2, .w = bw, .h = 34 };
        qa.mark(br, "grid-invite", .{});
        if (forum.primary(ctx, dl, ctx.ui, 8970, br, bl, true)) invites.openCreate(ctx, id);
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
        if (alone(ctx, cs)) {
            y += 4;
            aloneLine(ctx, dl, fam, fs, cs, r.x + 8, y, fs + 8);
            y += fs + 10;
        }
        return d.endRegion(ctx, y + 8, r.x);
    }
    const look = lookOf(ctx, n);
    const by_self = alone(ctx, cs);
    const row_h: f32 = if (by_self) alone_row_h + 12 else 0;
    const g = layout(list.len, r.w - pad * 2, r.h - pad * 2 - row_h, tile_gap, tile_min, if (by_self) tile_alone_max else tile_max);
    // Área estreita demais para um quadro (a janela sendo arrastada bem pequena).
    if (g.cols == 0 or g.rows == 0) return d.endRegion(ctx, top + r.h, r.x);
    const rows_f: f32 = @floatFromInt(g.rows);
    const block_h = rows_f * g.tile_h + (rows_f - 1) * tile_gap + row_h;
    const y0 = top + @max(pad, (r.h - block_h) / 2);
    for (list, 0..) |uid, i| {
        const row = i / g.cols;
        const col = i % g.cols;
        // A última linha, se incompleta, fica centrada.
        const in_row: f32 = @floatFromInt(if (row == g.rows - 1) list.len - row * g.cols else g.cols);
        const row_w = in_row * g.tile_w + (in_row - 1) * tile_gap;
        const x = r.x + (r.w - row_w) / 2 + @as(f32, @floatFromInt(col)) * (g.tile_w + tile_gap);
        const y = y0 + @as(f32, @floatFromInt(row)) * (g.tile_h + tile_gap);
        tile(ctx, dl, look, guild, uid, .{ .x = @round(x), .y = @round(y), .w = @round(g.tile_w), .h = @round(g.tile_h) }, i);
    }
    if (by_self) aloneRow(ctx, dl, cs, r.x + r.w / 2, @round(y0 + g.tile_h + 12));
    d.endRegion(ctx, y0 + block_h + pad, r.x);
}

/// Só a gente na call de um servidor (na DM ou no grupo, sozinho é esperando atender).
fn alone(ctx: *const d.Ctx, cs: *const ChannelState) bool {
    const list = cs.voice_members.items;
    return cs.info.guild != 0 and list.len == 1 and list[0] == ctx.store.me;
}

/// A versão em texto da linha do convite: "só você por aqui  [convidar]".
fn aloneLine(ctx: *d.Ctx, dl: *c.ImDrawList, fam: *d.Family, fs: f32, cs: *ChannelState, x0: f32, y: f32, h: f32) void {
    const font = fam.get(.regular);
    const t = i18n.tr("só você por aqui", "just you here");
    const tw = d.width(font, fs, t) + fs;
    d.text(dl, font, fs, x0 + 4 + fs, y + (h - fs) / 2, ctx.col(.faint), t);
    qa.mark(.{ .x = x0, .y = y, .w = tw + 8, .h = h }, "grid-alone", .{});
    const ch: ?Id = if (invites.canInvite(ctx, &cs.info)) cs.info.id else invites.channelFor(ctx, cs.info.guild);
    if (ch) |id| {
        const b = textButton(ctx, dl, fam.get(.bold), fs, x0 + tw + 16, y, h, i18n.tr("[convidar]", "[invite]"), "grid-invite", ctx.col(.accent), 8970);
        if (b.clicked) invites.openCreate(ctx, id);
    }
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
        !@import("search.zig").open and !@import("interact.zig").anyOpen() and !@import("dropdown.zig").ownsEsc() and
        !ctx.io.*.WantTextInput;
}

/// A call da DM ou do grupo aberto: uma faixa em cima da conversa, com a grade e os
/// botões. Devolve a altura que ocupou (0: a conversa é baixa demais para dividir).
pub fn dmBand(ctx: *d.Ctx, n: *const kdl.Node, r: d.Rect, cs: *ChannelState) f32 {
    const tty = d.is(n, "variant", "irc", "");
    const ctl_h: f32 = if (tty) 28 else 60;
    // Sobra pelo menos isto para a conversa embaixo.
    const room = r.h - 80;
    const min_h: f32 = if (tty) 70 else 160;
    if (room < min_h) return 0;
    const rows: f32 = @floatFromInt(@max(cs.voice_members.items.len, 1));
    const want = if (tty) rows * (ctx.th.font_size + 10) + 16 + ctl_h else r.h * 0.42;
    const h = std.math.clamp(want, min_h, room);
    const band: d.Rect = .{ .x = r.x, .y = r.y, .w = r.w, .h = h };
    d.rect(ctx.dl, band, ctx.col(.rail).alpha(0.55), 0);
    d.line(ctx.dl, band.x, band.bottom() - 0.5, band.right(), band.bottom() - 0.5, ctx.col(.border), 1);
    qa.mark(band, "grid-band", .{});
    people(ctx, n, .{ .x = band.x, .y = band.y, .w = band.w, .h = band.h - ctl_h }, cs, tty, "##call-band");
    buttons(ctx, ctx.dl, ctx.familyFor(n), .{ .x = band.x, .y = band.bottom() - ctl_h, .w = band.w, .h = ctl_h }, text_buttons, cs);
    return h;
}

// --- Botões --------------------------------------------------------------------------

/// Os botões da faixa de voz (microfone, fone, mixer, sair) e o tempo da call, no
/// lugar da caixa de mensagem.
pub fn controls(ctx: *d.Ctx, n: *const kdl.Node, r: d.Rect) void {
    buttons(ctx, ctx.dl, ctx.familyFor(n), r, text_buttons, guildCall(ctx));
}

/// O tempo da call (a mesma opção e o mesmo formato da lista de canais), já medido,
/// ou null: opção desligada, call de DM ou ainda sem começo.
fn callTime(ctx: *d.Ctx, cs: ?*ChannelState, buf: []u8, size: f32) ?voice_timer.Timer {
    return voice_timer.measure(ctx, cs orelse return null, buf, size);
}

/// Desenha o tempo e marca o próximo redesenho na virada que o formato mostra (o app
/// dorme direto até lá, como na lista de canais).
fn drawTime(ctx: *d.Ctx, dl: *c.ImDrawList, t: voice_timer.Timer, x: f32, row: d.Rect, col: d.Rgba) void {
    d.text(dl, t.font, t.size, x, d.centerY(row, t.size), col, t.text);
    qa.mark(.{ .x = x, .y = row.y, .w = t.w, .h = row.h }, "grid-timer", .{});
    if (ctx.st.settings.open) return;
    if (vt.nextChange(voice_timer.format(&ctx.st.settings), ctx.now_ms, t.start_s)) |next| anim.atClock(next);
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

fn buttons(ctx: *d.Ctx, dl: *c.ImDrawList, fam: *d.Family, r: d.Rect, tty: bool, cs: ?*ChannelState) void {
    var tb: [48]u8 = undefined;
    if (tty) {
        const fs = ctx.th.font_size - 1;
        const font = fam.get(.bold);
        const h = @min(r.h, 26);
        const y = r.y + (r.h - h) / 2;
        var x = r.x + 10;
        if (callTime(ctx, cs, &tb, fs)) |t| {
            drawTime(ctx, dl, t, x + 4, .{ .x = x, .y = y, .w = t.w, .h = h }, voice_timer.color(ctx));
            x += t.w + 16;
        }
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
    // Tudo numa barra com o fundo e os cantos do tema, centrada: o tempo da call (com
    // o ponto verde de "no ar"), microfone, fone, mixer e sair.
    const b = std.math.clamp(r.h - 24, 28, 40);
    const gap: f32 = 10;
    const inset: f32 = 8;
    const dev_w = b + devices.chev_w;
    const leave_w = b * 1.5;
    const fs = ctx.th.font_size;
    const timer = callTime(ctx, cs, &tb, fs - 1);
    const timer_w = if (timer) |t| t.w + 14 + gap + 4 else 0;
    const total = timer_w + dev_w * 2 + b + leave_w + gap * 3;
    const bar: d.Rect = .{ .x = @round(r.x + (r.w - total) / 2 - inset), .y = @round(r.y + (r.h - b) / 2 - inset), .w = total + inset * 2, .h = b + inset * 2 };
    const bar_r = std.math.clamp(ctx.th.radius * 2, 4, bar.h / 2);
    d.rect(dl, bar, ctx.col(.bg).mix(ctx.col(.elevated), 0.45), bar_r);
    d.border(dl, bar, ctx.col(.border), bar_r, 1);
    qa.mark(bar, "grid-bar", .{});
    var x = bar.x + inset;
    const y = bar.y + inset;
    const btn_r = std.math.clamp(bar_r - inset, 3, b / 2);
    if (timer) |t| {
        x += 4;
        d.circle(dl, x + 3, y + b / 2, 3, ctx.col(.online));
        drawTime(ctx, dl, t, x + 14, .{ .x = x, .y = y, .w = t.w, .h = b }, ctx.col(.muted));
        x += t.w + 14 + gap;
    }
    const font = fam.get(.medium);
    for ([_]devices.Kind{ .mic, .deaf }, [_][]const u8{ "grid-mic", "grid-deaf" }, 0..) |k, tag, i| {
        const br: d.Rect = .{ .x = x, .y = y, .w = dev_w, .h = b };
        d.rect(dl, br, ctx.col(.elevated), btn_r);
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
        d.rect(dl, mr, ctx.col(.elevated).mix(ctx.col(.hover), k), btn_r);
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
        d.rect(dl, lr, ctx.col(.danger).mix(d.Rgba.black, 0.15 * k), btn_r);
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
