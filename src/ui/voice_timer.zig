//! O tempo da call ao lado de cada canal de voz na lista de canais ("16:42:14";
//! o texto e quando ele muda vêm de core/voice_timer.zig). Pequeno, num verde
//! apagado e em fonte monoespaçada: os algarismos têm a mesma largura, e o nome
//! do canal não treme a cada segundo.
//!
//! Custo: o app só acorda por ele com a linha do canal na tela de verdade (nem
//! rolada para fora, nem coberta pelas Configurações; com a janela escondida nem
//! há quadro), na virada da menor unidade que o formato mostra (anim.atClock).
const std = @import("std");
const c = @import("c");
const d = @import("draw.zig");
const qa = @import("qa.zig");
const anim = @import("anim.zig");
const vt = @import("../core/voice_timer.zig");
const S = @import("settings_state.zig");
const Id = @import("../core/types.zig").Id;

/// O formato das configurações, montado de novo só quando a escolha muda.
var cache: struct { ok: bool = false, index: u8 = 0, pattern: S.Text = .{}, fmt: vt.Format = undefined } = .{};

pub fn format(s: *const S.Settings) *const vt.Format {
    if (!cache.ok or cache.index != s.voice_timer_format or !std.mem.eql(u8, cache.pattern.slice(), s.voice_timer_pattern.slice())) {
        cache.index = s.voice_timer_format;
        cache.pattern = s.voice_timer_pattern;
        cache.fmt = vt.resolve(s.voice_timer_format, s.voice_timer_pattern.slice());
        cache.ok = true;
    }
    return &cache.fmt;
}

pub const Timer = struct {
    text: []const u8,
    w: f32,
    font: *c.ImFont,
    size: f32,
    start_s: i64,
};

/// O tempo deste canal agora, já medido, ou null: opção desligada, canal sem call
/// ou sem ninguém nela (uma call cujo fim não chegou não fica contando à toa).
pub fn measure(ctx: *d.Ctx, cs: anytype, buf: []u8, size: f32) ?Timer {
    if (!ctx.st.settings.voice_timer or cs.info.kind != .voice or cs.voice_members.items.len == 0) return null;
    const e = vt.elapsed(ctx.now_ms, cs.voice_start_s) orelse return null;
    const t = format(&ctx.st.settings).text(buf, e);
    if (t.len == 0) return null;
    const font = ctx.mono.get(.regular);
    return .{ .text = t, .w = d.width(font, size, t), .font = font, .size = size, .start_s = cs.voice_start_s };
}

pub fn color(ctx: *const d.Ctx) d.Rgba {
    return ctx.col(.online).mix(ctx.col(.muted), 0.3);
}

/// Desenha encostado em `right`, centrado na altura de `row`, e marca a próxima
/// virada se a linha aparece de verdade: `list` é a parte da lista que está na
/// tela (a linha desenhada na folga de cima ou de baixo não conta).
pub fn draw(ctx: *d.Ctx, dl: *c.ImDrawList, t: Timer, right: f32, row: d.Rect, list: d.Rect, id: Id) void {
    const x = right - t.w;
    d.text(dl, t.font, t.size, x, d.centerY(row, t.size), color(ctx), t.text);
    qa.mark(.{ .x = x, .y = row.y + 2, .w = t.w, .h = row.h - 4 }, "voice-timer:{d}", .{id});
    if (qa.on()) remember(id, t.text);
    const seen = row.bottom() > list.y and row.y < list.bottom() and !ctx.st.settings.open;
    if (!seen) return;
    if (vt.nextChange(format(&ctx.st.settings), ctx.now_ms, t.start_s)) |n| {
        anim.atClock(n);
        scheduled_at_ms = ctx.now_ms;
    }
}

// --- QA ---------------------------------------------------------------------------

/// O relógio do último quadro em que algum tempo marcou a próxima virada.
pub var scheduled_at_ms: i64 = 0;

/// O texto que cada canal mostrou por último (o QA confere com a marcação
/// `voice-timer:<canal>`, que só existe se ele apareceu no último quadro).
var shown: [8]struct { id: Id = 0, len: u8 = 0, buf: [64]u8 = undefined } = @splat(.{});
var shown_next: usize = 0;

fn remember(id: Id, text: []const u8) void {
    const slot = for (&shown) |*e| {
        if (e.id == id) break e;
    } else blk: {
        const e = &shown[shown_next % shown.len];
        shown_next += 1;
        break :blk e;
    };
    slot.id = id;
    slot.len = @intCast(@min(text.len, slot.buf.len));
    @memcpy(slot.buf[0..slot.len], text[0..slot.len]);
}

pub fn shownText(id: Id) ?[]const u8 {
    for (&shown) |*e| if (e.id == id) return e.buf[0..e.len];
    return null;
}
