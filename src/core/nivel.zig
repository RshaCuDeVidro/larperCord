//! "Igualar volume" de uma pessoa na call (mixer da call, por pessoa, desligado de
//! começo): quem fala baixo sobe e quem fala alto desce, até perto do mesmo volume.
//!
//! Recebe os 20 ms já decodificados (estéreo, i16) e mede a força da fala (RMS). Só
//! aprende com o que é fala: silêncio e chiado de fundo ficam abaixo do `gate` e não
//! mexem no ganho (senão a pausa subiria o chiado). O ganho desce rápido (um grito
//! não estoura) e sobe devagar (sem bombear entre as palavras), vai de rampa ao longo
//! do quadro (sem degrau audível) e um limitador no fim segura o pico abaixo do teto.
//!
//! Nada aloca e o estado é um punhado de números por pessoa. Desligado, o chamador
//! nem chega aqui (net/voice.zig).
const std = @import("std");
const voz = @import("voz.zig");

/// RMS de fala que ele persegue (escala de i16; ~ -21 dBFS, uma conversa confortável).
pub const target: f32 = 2900;
/// Abaixo disto (~ -42 dBFS) é silêncio ou fundo: não aprende.
pub const gate: f32 = 260;
/// Quanto pode subir e descer (×4 = +12 dB; ×0,25 = -12 dB).
pub const max_gain: f32 = 4;
pub const min_gain: f32 = 0.25;
/// Teto do pico depois do ganho (um pouco abaixo do máximo do i16).
pub const ceiling: f32 = 31000;

pub const Nivelador = struct {
    /// O ganho de agora (o do fim do último quadro).
    gain: f32 = 1,
    /// A força da fala, suavizada (~200 ms).
    env: f32 = 0,

    pub fn process(n: *Nivelador, pcm: []i16) void {
        const rms = rmsOf(pcm);
        var want = n.gain;
        if (rms >= gate) {
            n.env = if (n.env == 0) rms else n.env * 0.9 + rms * 0.1;
            want = std.math.clamp(target / n.env, min_gain, max_gain);
        }
        // Desce rápido, sobe devagar.
        const rate: f32 = if (want < n.gain) 0.35 else 0.06;
        var next = n.gain + (want - n.gain) * rate;
        // O limitador: o pico deste quadro não passa do teto. Se nem o ganho do começo
        // do quadro cabe, ele vale desde a primeira amostra (sem rampa, sem estourar).
        const peak = peakOf(pcm);
        if (peak * next > ceiling) next = ceiling / peak;
        const from = if (peak * n.gain > ceiling) next else n.gain;
        apply(pcm, from, next);
        n.gain = next;
    }
};

fn rmsOf(pcm: []const i16) f32 {
    if (pcm.len == 0) return 0;
    var sum: f64 = 0;
    for (pcm) |s| {
        const v: f64 = @floatFromInt(s);
        sum += v * v;
    }
    return @floatCast(@sqrt(sum / @as(f64, @floatFromInt(pcm.len))));
}

fn peakOf(pcm: []const i16) f32 {
    var p: i32 = 0;
    for (pcm) |s| p = @max(p, @as(i32, @intCast(@abs(@as(i32, s)))));
    return @floatFromInt(p);
}

/// Multiplica o quadro pelo ganho, indo de `from` a `to` ao longo dele (os dois canais
/// de cada amostra com o mesmo ganho).
fn apply(pcm: []i16, from: f32, to: f32) void {
    if (from == 1 and to == 1) return;
    const frames = pcm.len / voz.channels;
    if (frames == 0) return;
    const nf: f32 = @floatFromInt(frames);
    for (0..frames) |i| {
        const g = from + (to - from) * (@as(f32, @floatFromInt(i)) + 1) / nf;
        for (pcm[i * voz.channels ..][0..voz.channels]) |*s| {
            const v = @as(f32, @floatFromInt(s.*)) * g;
            s.* = @intFromFloat(@round(std.math.clamp(v, -32768, 32767)));
        }
    }
}

// --- Testes -----------------------------------------------------------------

fn sine(pcm: []i16, amp: f32, phase: *f32) void {
    var i: usize = 0;
    while (i < pcm.len) : (i += voz.channels) {
        const v: i16 = @intFromFloat(@sin(phase.*) * amp);
        pcm[i] = v;
        pcm[i + 1] = v;
        phase.* += 2 * std.math.pi * 220.0 / 48000.0;
    }
}

/// RMS de saída depois de `frames` quadros de um seno de amplitude `amp`.
fn settle(amp: f32, frames: usize) f32 {
    var n: Nivelador = .{};
    var pcm: [voz.frame_len]i16 = undefined;
    var ph: f32 = 0;
    var out: f32 = 0;
    for (0..frames) |_| {
        sine(&pcm, amp, &ph);
        n.process(&pcm);
        out = rmsOf(&pcm);
    }
    return out;
}

test "quem fala baixo sobe e quem fala alto desce, para perto do mesmo volume" {
    // Em 4 s de fala (200 quadros), os dois chegam a ±2 dB do alvo.
    const quiet = settle(1400, 200); // RMS ~990: pede ganho ~2,9
    const loud = settle(16000, 200); // RMS ~11300: pede ganho ~0,26
    const lo = target * 0.79; // -2 dB
    const hi = target * 1.26; // +2 dB
    try std.testing.expect(quiet > lo and quiet < hi);
    try std.testing.expect(loud > lo and loud < hi);
}

test "silêncio continua silêncio e o chiado de fundo não sobe" {
    var n: Nivelador = .{};
    var pcm: [voz.frame_len]i16 = @splat(0);
    for (0..100) |_| n.process(&pcm);
    for (pcm) |s| try std.testing.expectEqual(@as(i16, 0), s);
    try std.testing.expectEqual(@as(f32, 1), n.gain);
    // Um fundo bem baixo (abaixo do gate) não ensina nada: o ganho fica em 1.
    var ph: f32 = 0;
    for (0..100) |_| {
        sine(&pcm, 200, &ph);
        n.process(&pcm);
    }
    try std.testing.expectEqual(@as(f32, 1), n.gain);
}

test "o ganho fica entre os limites e o pico não passa do teto" {
    // Fala muito baixa (logo acima do gate): sobe no máximo ×4.
    var n: Nivelador = .{};
    var pcm: [voz.frame_len]i16 = undefined;
    var ph: f32 = 0;
    for (0..400) |_| {
        sine(&pcm, 400, &ph);
        n.process(&pcm);
    }
    try std.testing.expect(n.gain <= max_gain + 0.001);
    try std.testing.expect(n.gain > 3.5);
    // Depois disso, um grito de repente: o limitador segura o pico no mesmo quadro.
    sine(&pcm, 30000, &ph);
    n.process(&pcm);
    for (pcm) |s| try std.testing.expect(@abs(@as(i32, s)) <= @as(i32, @intFromFloat(ceiling)) + 1);
}
