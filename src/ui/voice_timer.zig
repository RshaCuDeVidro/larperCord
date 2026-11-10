//! O tempo da call ao lado de cada canal de voz na lista de canais ("16:42:14";
//! o texto e quando ele muda vêm de core/voice_timer.zig). Pequeno, num verde
//! apagado e em fonte monoespaçada: os algarismos têm a mesma largura, e o nome
//! do canal não treme a cada segundo.
const std = @import("std");
const d = @import("draw.zig");
const vt = @import("../core/voice_timer.zig");
const S = @import("settings_state.zig");

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

pub fn color(ctx: *const d.Ctx) d.Rgba {
    return ctx.col(.online).mix(ctx.col(.muted), 0.3);
}
