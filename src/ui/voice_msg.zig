//! Mensagens de voz: o player na conversa (tocar/pausar, barra com busca,
//! duração e a forma de onda que o Discord manda). Quem baixa, decodifica e toca
//! é ui/audio_player.zig (o mesmo dos anexos de áudio): o Ogg Opus pelo caminho
//! das imagens, a libopus e um stream do SDL no dispositivo de saída escolhido na
//! página Voz, com o volume de saída de lá. Um áudio por vez. Enquanto toca, as
//! barras do visualizador giram em volta do botão. Gravar fica em ui/gravar_audio.zig,
//! e o que se grava lá vai como um arquivo .ogg comum, não como mensagem de voz.
const std = @import("std");
const c = @import("c");
const d = @import("draw.zig");
const anim = @import("anim.zig");
const qa = @import("qa.zig");
const i18n = @import("i18n.zig");
const types = @import("../core/types.zig");
const onda = @import("../core/audio_onda.zig");
const player = @import("audio_player.zig");

/// Fecha tudo ao sair do app (antes do libcurl e do SDL).
pub fn shutdown() void {
    player.shutdown();
}

/// Para o QA: tocando agora, a posição e a duração (ms).
pub const Info = struct { active: u64, playing: bool, pos_ms: u32, dur_ms: u32, has_file: bool };
pub fn info() Info {
    const i = player.info();
    return .{ .active = i.active, .playing = i.playing, .pos_ms = i.pos_ms, .dur_ms = i.dur_ms, .has_file = i.has_file };
}

pub fn draw(ctx: *d.Ctx, dl: *c.ImDrawList, a: *const types.Attachment, r: d.Rect, msg_id: types.Id, channel: types.Id, index: usize, alpha: f32) void {
    const alvo: player.Alvo = .{ .key = player.keyOf(msg_id, index), .url = a.url, .tipo = .voz, .msg_id = msg_id, .canal = channel };
    const key = alvo.key;
    const v = player.ver(ctx, alvo, a.voice_ms);
    const total = v.dur_ms;
    const at = v.pos_ms;

    const radius = @max(ctx.th.radius, 6);
    d.rect(dl, r, ctx.col(.elevated).alpha(alpha), radius);
    d.border(dl, r, ctx.col(.border).alpha(alpha), radius, 1);

    // Tocar / pausar.
    const br: d.Rect = .{ .x = r.x + 12, .y = r.y + (r.h - 34) / 2, .w = 34, .h = 34 };
    const bh = d.hit(ctx, @truncate(key ^ 0x701CE), br);
    qa.mark(br, "voice-play:{d}", .{msg_id});
    const bk = anim.to(anim.id("voice-btn", @truncate(key)), if (bh.hovered) 1 else 0, 20);
    const cx = br.x + 17;
    const cy = br.y + 17;
    // O visualizador: barrinhas em volta do botão enquanto toca (descem ao pausar).
    _ = player.animar(ctx, v, ctx.st.settings.audio_visualizer, types.wave_bars);
    if (v.mine) player.desenharAnel(dl, cx, cy, 18, 6, ctx.col(.accent).alpha(alpha));
    d.circle(dl, cx, cy, 17, ctx.col(.accent).mix(d.Rgba.white, 0.1 * bk).alpha(alpha));
    const ink = ctx.col(.accent_text).alpha(alpha);
    if (v.loading) {
        const t = if (anim.instant) 0 else @as(f32, @floatFromInt(@mod(ctx.now_ms, 100_000))) / 1000.0;
        c.ImDrawList_PathArcTo(dl, d.v(cx, cy), 8, t * 6, t * 6 + 4.2, 20);
        c.ImDrawList_PathStroke(dl, ink.u(), 2, 0);
    } else if (v.playing) {
        d.rect(dl, .{ .x = cx - 6, .y = cy - 7, .w = 4, .h = 14 }, ink, 1);
        d.rect(dl, .{ .x = cx + 2, .y = cy - 7, .w = 4, .h = 14 }, ink, 1);
    } else {
        c.ImDrawList_AddTriangleFilled(dl, d.v(cx - 4.5, cy - 7.5), d.v(cx - 4.5, cy + 7.5), d.v(cx + 8, cy), ink.u());
    }
    d.tip(ctx, br, if (v.playing) i18n.tr("Pausar", "Pause") else i18n.tr("Ouvir a mensagem de voz", "Play voice message"), bh.hovered);
    if (bh.clicked) {
        if (!player.alternar(ctx, alvo, v)) ctx.st.showToast(ctx.now_ms, true, "não deu para tocar a mensagem de voz", "couldn't play the voice message", .{});
    }

    // Tempo à direita: o que já tocou enquanto toca; senão a duração.
    var tb: [24]u8 = undefined;
    const f = ctx.ui.get(.medium);
    const shown_ms = if (v.playing or (v.mine and at > 0)) at else total;
    const tlabel = if (v.falha != .nenhuma) i18n.tr("indisponível", "unavailable") else onda.tempo(&tb, shown_ms);
    const tw = d.width(f, 12.5, tlabel);
    d.text(dl, f, 12.5, r.right() - 14 - tw, d.centerY(r, 12.5), ctx.col(.muted).alpha(alpha), tlabel);

    // A forma de onda é a barra: clicar ou arrastar leva até ali.
    const wr: d.Rect = .{ .x = br.right() + 12, .y = r.y + 10, .w = @max(r.right() - 14 - tw - 12 - (br.right() + 12), 20), .h = r.h - 20 };
    const wh = d.hit(ctx, @truncate(key ^ 0x3A7E), wr);
    qa.mark(wr, "voice-wave:{d}", .{msg_id});
    const frac = onda.fracao(at, total);
    const n: usize = types.wave_bars;
    const step = wr.w / @as(f32, @floatFromInt(n));
    const bw = @max(step * 0.55, 1.5);
    const has_wave = std.mem.max(u8, &a.wave) > 0;
    for (0..n) |i| {
        const val: f32 = if (has_wave) @as(f32, @floatFromInt(a.wave[i])) / 255 else 0.25;
        const bh_px = @max(3, val * wr.h);
        const bx = wr.x + step * @as(f32, @floatFromInt(i)) + (step - bw) / 2;
        const played = (@as(f32, @floatFromInt(i)) + 0.5) / @as(f32, @floatFromInt(n)) <= frac;
        const col = if (played) ctx.col(.accent) else ctx.col(.faint).mix(ctx.col(.muted), if (wh.hovered) 0.4 else 0);
        d.rect(dl, .{ .x = bx, .y = wr.y + (wr.h - bh_px) / 2, .w = bw, .h = bh_px }, col.alpha(alpha), bw / 2);
    }
    if (wh.hovered) c.ImGui_SetMouseCursor(c.ImGuiMouseCursor_Hand);
    if ((wh.held or wh.clicked) and total > 0) {
        const target = onda.msNoPonto(ctx.mouse.x, wr.x, wr.w, total);
        player.buscar(ctx, alvo, target, total, 0, wh.clicked or !wh.held);
    } else if (v.mine) player.soltar(key);
    player.teclas(ctx, alvo, v, ctx.hovering(r));
    if (bh.right or wh.right) if (msg_id != 0) @import("attachments.zig").mediaMenu(ctx, msg_id, a);
}
