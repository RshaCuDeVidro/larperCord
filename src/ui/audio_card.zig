//! Anexos de áudio (.mp3, .ogg, .wav, .flac, .m4a…) na conversa: um player no
//! lugar do cartão de arquivo. Tocar/pausar, a forma de onda do arquivo inteiro
//! como barra (o que já tocou na cor de destaque; clicar ou arrastar leva até
//! ali, e o mouse em cima mostra o tempo do ponto), o tempo, a velocidade (1x,
//! 1,5x, 2x), o nome, o tamanho, baixar e, enquanto toca, o visualizador. Quem
//! toca é ui/audio_player.zig. O que o app não sabe tocar (FLAC e cia. sem o
//! FFmpeg, grande demais) continua o cartão de arquivo, com o porquê.
const std = @import("std");
const c = @import("c");
const d = @import("draw.zig");
const anim = @import("anim.zig");
const qa = @import("qa.zig");
const i18n = @import("i18n.zig");
const types = @import("../core/types.zig");
const onda = @import("../core/audio_onda.zig");
const formato = @import("../core/audio_formato.zig");
const media_refresh = @import("../core/media_refresh.zig");
const player = @import("audio_player.zig");
const fonte = @import("audio_fonte.zig");

/// Altura do cartão na conversa.
pub const altura: f32 = 92;
const largura_max: f32 = 440;

pub fn largura(avail: f32) f32 {
    return @min(avail, largura_max);
}

fn formatoDe(a: *const types.Attachment) ?formato.Formato {
    if (a.voice or a.isImage() or a.video) return null;
    return formato.doAnexo(a.audio, a.filename);
}

/// O anexo vira player (senão, o cartão de arquivo de sempre).
pub fn mostra(a: *const types.Attachment, msg_id: types.Id, index: usize) bool {
    const f = formatoDe(a) orelse return false;
    return motivo(a, f, msg_id, index) == null;
}

/// Por que um anexo de áudio fica como arquivo (null = toca).
fn motivo(a: *const types.Attachment, f: formato.Formato, msg_id: types.Id, index: usize) ?[]const u8 {
    if (a.size > player.max_bytes) return i18n.tr("grande demais para tocar aqui", "too large to play here");
    // Tentou e o arquivo precisava do FFmpeg (um .ogg que era Vorbis): também.
    if (!fonte.podeTocar(f) or (player.precisaFfmpeg(player.keyOf(msg_id, index)) and !fonte.podeTocar(.flac)))
        return i18n.tr("tocar aqui precisa do FFmpeg", "playing here needs FFmpeg");
    return null;
}

/// O aviso do cartão de arquivo de um áudio que não toca aqui (null = não é áudio).
pub fn aviso(a: *const types.Attachment, msg_id: types.Id, index: usize) ?[]const u8 {
    const f = formatoDe(a) orelse return null;
    return motivo(a, f, msg_id, index);
}

/// O que decide se um áudio vira player muda raramente (o FFmpeg carregou ou não,
/// um arquivo que precisava dele): quando muda, a altura do cartão muda junto, e
/// as mensagens são medidas de novo.
var sinal_visto: u64 = 0;

pub fn vigiar(ctx: *d.Ctx) void {
    const known: u64 = if (@import("../platform/ffmpeg.zig").known()) |k| (if (k) 1 else 2) else 0;
    const s = known | (@as(u64, @intFromBool(fonte.qa_sem_ffmpeg)) << 2) | (@as(u64, player.geracao()) << 3);
    if (s == sinal_visto) return;
    sinal_visto = s;
    ctx.st.theme_gen +%= 1;
}

/// O pedido de link novo para baixar (o mesmo link do tocar: cada um sabe o seu).
var refresh_dl: u64 = 0;

fn baixar(ctx: *d.Ctx, a: *const types.Attachment, key: u64) void {
    const res = &media_refresh.global;
    const link = res.resolve(a.url);
    if (!std.mem.startsWith(u8, link, "https://")) {
        ctx.st.showToast(ctx.now_ms, false, "arquivo de demonstração", "demo file", .{});
        return;
    }
    // Link vencido: pede o novo e abre quando ele chegar.
    const ro = res.requestOpen(link, @divTrunc(ctx.now_ms, 1000));
    if (ro.pending) {
        if (ro.notify) ctx.act(.refresh_media);
        refresh_dl = key;
    } else @import("attachments.zig").openUrl(link);
}

pub fn draw(ctx: *d.Ctx, dl: *c.ImDrawList, a: *const types.Attachment, r: d.Rect, msg_id: types.Id, channel: types.Id, index: usize, alpha: f32) void {
    const alvo: player.Alvo = .{ .key = player.keyOf(msg_id, index), .url = a.url, .tipo = .arquivo, .msg_id = msg_id, .canal = channel };
    const key = alvo.key;
    const ids: usize = @truncate(key);
    const v = player.ver(ctx, alvo, 0);
    const res = &media_refresh.global;
    if (refresh_dl == key and res.open_ready and res.takeOpen(a.url)) {
        refresh_dl = 0;
        @import("attachments.zig").openUrl(res.resolve(a.url));
    }
    const total = v.dur_ms;
    const at = v.pos_ms;
    const radius = @max(ctx.th.radius, 6);
    const hovered = ctx.hovering(r);
    d.rect(dl, r, ctx.col(.elevated).alpha(alpha), radius);
    d.border(dl, r, ctx.col(.border).alpha(alpha), radius, 1);
    qa.mark(r, "audio-card:{d}", .{msg_id});

    // A forma de onda: a barra de baixo, à esquerda do tempo.
    const fam = ctx.ui;
    const x0 = r.x + 66;
    const right = r.right() - 12;
    var tb1: [16]u8 = undefined;
    var tb2: [16]u8 = undefined;
    var tbuf: [40]u8 = undefined;
    // A duração arredondada (5,99 s é "0:06"); a posição, só o que já passou.
    const total_txt = (total + 500) / 1000 * 1000;
    const tlabel = if (total == 0)
        (if (v.mine and at > 0) onda.tempo(&tb1, at) else "-:--")
    else if (v.playing or (v.mine and at > 0))
        std.fmt.bufPrint(&tbuf, "{s} / {s}", .{ onda.tempo(&tb1, @min(at, total_txt)), onda.tempo(&tb2, total_txt) }) catch ""
    else
        onda.tempo(&tb2, total_txt);
    const tf = fam.get(.medium);
    const tw = d.width(tf, 12, tlabel);
    const wr: d.Rect = .{ .x = x0, .y = r.y + 50, .w = @max(right - tw - 12 - x0, 40), .h = 30 };
    const step: f32 = 4;
    const n_bars: usize = @intFromFloat(@max(8, @floor(wr.w / step)));

    // O visualizador anda (e o próximo quadro é pedido) antes de desenhar.
    const viz_on = player.animar(ctx, v, ctx.st.settings.audio_visualizer, n_bars);

    // Tocar / pausar.
    const br: d.Rect = .{ .x = r.x + 12, .y = r.y + (r.h - 42) / 2, .w = 42, .h = 42 };
    const bh = d.hit(ctx, ids ^ 0xA0D1_0001, br);
    qa.mark(br, "audio-play:{d}", .{msg_id});
    const bk = anim.to(anim.id("audio-btn", key), if (bh.hovered) 1 else 0, 20);
    const cx = br.x + 21;
    const cy = br.y + 21;
    d.circle(dl, cx, cy, 21, ctx.col(.accent).mix(d.Rgba.white, 0.1 * bk).alpha(alpha));
    const ink = ctx.col(.accent_text).alpha(alpha);
    if (v.loading) {
        const t = if (anim.instant) 0 else @as(f32, @floatFromInt(@mod(ctx.now_ms, 100_000))) / 1000.0;
        c.ImDrawList_PathArcTo(dl, d.v(cx, cy), 9, t * 6, t * 6 + 4.2, 20);
        c.ImDrawList_PathStroke(dl, ink.u(), 2.2, 0);
    } else if (v.playing) {
        d.rect(dl, .{ .x = cx - 7, .y = cy - 8, .w = 4.5, .h = 16 }, ink, 1);
        d.rect(dl, .{ .x = cx + 2.5, .y = cy - 8, .w = 4.5, .h = 16 }, ink, 1);
    } else {
        c.ImDrawList_AddTriangleFilled(dl, d.v(cx - 5, cy - 9), d.v(cx - 5, cy + 9), d.v(cx + 9.5, cy), ink.u());
    }
    d.tip(ctx, br, if (v.playing) i18n.tr("Pausar", "Pause") else i18n.tr("Tocar o áudio", "Play audio"), bh.hovered);
    if (bh.clicked and !player.alternar(ctx, alvo, v)) ctx.st.showToast(ctx.now_ms, true, "não deu para tocar o áudio", "couldn't play the audio", .{});

    // Baixar (no canto) e a velocidade.
    const dr: d.Rect = .{ .x = right - 28, .y = r.y + 9, .w = 28, .h = 24 };
    const dh = d.hit(ctx, ids ^ 0xA0D1_0002, dr);
    qa.mark(dr, "audio-dl:{d}", .{msg_id});
    if (dh.hovered) d.rect(dl, dr, ctx.col(.text).alpha(0.08 * alpha), 6);
    downloadIcon(dl, dr.x + 14, dr.y + 12, ctx.col(if (dh.hovered) .text else .muted).alpha(alpha));
    d.tip(ctx, dr, i18n.tr("Baixar (abre no navegador)", "Download (opens in the browser)"), dh.hovered);
    if (dh.clicked) baixar(ctx, a, key);

    const vel = player.velocidade();
    const vlabel = switch (vel) {
        150 => i18n.tr("1,5×", "1.5×"),
        200 => "2×",
        else => "1×",
    };
    const vf = fam.get(.semibold);
    const vw = @max(d.width(vf, 12, vlabel) + 14, 32);
    const sr: d.Rect = .{ .x = dr.x - 6 - vw, .y = r.y + 10, .w = vw, .h = 22 };
    const sh = d.hit(ctx, ids ^ 0xA0D1_0003, sr);
    qa.mark(sr, "audio-speed:{d}", .{msg_id});
    const fast = vel != 100;
    d.rect(dl, sr, (if (fast) ctx.col(.accent).alpha(0.18) else ctx.col(.text).alpha(if (sh.hovered) 0.1 else 0.05)).alpha(alpha), 11);
    d.text(dl, vf, 12, sr.x + (sr.w - d.width(vf, 12, vlabel)) / 2, d.centerY(sr, 12), ctx.col(if (fast) .accent else .muted).alpha(alpha), vlabel);
    d.tip(ctx, sr, i18n.tr("Velocidade", "Speed"), sh.hovered);
    if (sh.clicked) player.trocarVelocidade();

    // O nome e, embaixo, o tamanho e o formato (ou por que não tocou).
    _ = d.textClipped(dl, fam.get(.semibold), 14, x0, r.y + 11, ctx.col(.text).alpha(alpha), a.filename, sr.x - 10 - x0);
    var mb: [96]u8 = undefined;
    var sb: [32]u8 = undefined;
    const size_txt = if (a.size > 0) @import("attachments.zig").formatSize(&sb, a.size) else i18n.tr("áudio", "audio");
    const fname = if (formatoDe(a)) |f| f.nome() else "";
    const meta = if (v.falha != .nenhuma)
        i18n.tr("indisponível", "unavailable")
    else if (fname.len > 0)
        std.fmt.bufPrint(&mb, "{s} · {s}", .{ size_txt, fname }) catch size_txt
    else
        size_txt;
    d.text(dl, fam.get(.regular), 12, x0, r.y + 31, ctx.col(if (v.falha != .nenhuma) .danger else .faint).alpha(alpha), meta);

    // O visualizador: à direita da linha do tamanho, enquanto toca.
    if (v.mine and r.w >= 300) {
        const vr: d.Rect = .{ .x = right - 104, .y = r.y + 34, .w = 104, .h = 12 };
        if (viz_on or std.mem.max(f32, player.barras()) > 0.01) player.desenharFila(dl, vr, ctx.col(.accent).alpha(alpha));
        qa.mark(vr, "audio-viz:{d}", .{msg_id});
    }

    // A forma de onda é a barra: clicar ou arrastar leva até ali.
    const wh = d.hit(ctx, ids ^ 0xA0D1_0004, wr);
    qa.mark(wr, "audio-wave:{d}", .{msg_id});
    const frac = onda.fracao(at, total);
    var vals: [256]u8 = undefined;
    const nb = @min(n_bars, vals.len);
    const pronta = player.formaDeOnda(key);
    if (pronta) |pts| onda.reduzir(pts, vals[0..nb]) else @memset(vals[0..nb], 40);
    // A forma de onda nova cresce de uma vez (com "reduzir movimento", aparece).
    const grow = anim.to(anim.id("audio-onda", key), if (pronta != null) 1 else 0, 9);
    const bw: f32 = 2.5;
    const mouse_frac = std.math.clamp((ctx.mouse.x - wr.x) / wr.w, 0, 1);
    for (0..nb) |i| {
        const flat: f32 = 40.0 / 255.0;
        const real = @as(f32, @floatFromInt(vals[i])) / 255;
        const k = if (pronta != null) flat + (real - flat) * grow else flat;
        const h = @max(3, k * wr.h);
        const bx = wr.x + step * @as(f32, @floatFromInt(i)) + (step - bw) / 2;
        const mid = (@as(f32, @floatFromInt(i)) + 0.5) / @as(f32, @floatFromInt(nb));
        const played = total > 0 and mid <= frac;
        var col = if (played) ctx.col(.accent) else ctx.col(.faint).mix(ctx.col(.muted), if (wh.hovered) 0.35 else 0);
        // Com o mouse em cima: até o ponto do mouse fica um pouco mais claro.
        if (wh.hovered and total > 0 and mid <= mouse_frac and !played) col = col.mix(ctx.col(.accent), 0.35);
        d.rect(dl, .{ .x = bx, .y = wr.y + (wr.h - h) / 2, .w = bw, .h = h }, col.alpha(alpha), bw / 2);
    }
    if (wh.hovered) c.ImGui_SetMouseCursor(c.ImGuiMouseCursor_Hand);
    if (wh.held or wh.clicked) {
        const target = onda.msNoPonto(ctx.mouse.x, wr.x, wr.w, total);
        player.buscar(ctx, alvo, target, total, mouse_frac, wh.clicked or !wh.held);
    } else if (v.mine) player.soltar(key);
    // O tempo do ponto sob o mouse, numa etiqueta em cima da barra.
    if ((wh.hovered or wh.held) and total > 0) {
        var hb: [16]u8 = undefined;
        const ht = onda.tempo(&hb, onda.msNoPonto(ctx.mouse.x, wr.x, wr.w, total));
        const hf = fam.get(.medium);
        const hw = d.width(hf, 11.5, ht) + 12;
        const mx = std.math.clamp(ctx.mouse.x, wr.x, wr.right());
        d.line(dl, mx, wr.y - 1, mx, wr.bottom() + 1, ctx.col(.text).alpha(0.5 * alpha), 1);
        const pr: d.Rect = .{ .x = std.math.clamp(mx - hw / 2, r.x + 4, r.right() - 4 - hw), .y = wr.y - 20, .w = hw, .h = 18 };
        d.rect(dl, pr, ctx.col(.text).alpha(0.9 * alpha), 5);
        d.text(dl, hf, 11.5, pr.x + 6, d.centerY(pr, 11.5), ctx.col(.elevated).alpha(alpha), ht);
        qa.mark(pr, "audio-hover-time:{d}", .{msg_id});
    }
    d.text(dl, tf, 12, right - tw, d.centerY(wr, 12), ctx.col(.muted).alpha(alpha), tlabel);

    player.teclas(ctx, alvo, v, hovered);
    if (bh.right or wh.right or sh.right or dh.right) if (msg_id != 0) @import("attachments.zig").mediaMenu(ctx, msg_id, a);
}

fn downloadIcon(dl: *c.ImDrawList, cx: f32, cy: f32, col: d.Rgba) void {
    d.line(dl, cx, cy - 7, cx, cy + 3, col, 1.7);
    c.ImDrawList_AddTriangleFilled(dl, d.v(cx - 4.5, cy - 0.5), d.v(cx + 4.5, cy - 0.5), d.v(cx, cy + 4.5), col.u());
    d.line(dl, cx - 7, cy + 7, cx + 7, cy + 7, col, 1.7);
}
