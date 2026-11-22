//! As barrinhas do visualizador de áudio: uma FFT pequena (1024 pontos, raiz 2,
//! com janela de Hann) sobre o que está saindo no alto-falante agora, e a energia
//! em `n` faixas espaçadas como o ouvido ouve (logarítmicas, de 50 Hz a 16 kHz ou
//! até a metade da taxa). Cada faixa vira 0–255 numa escala de -60 dB a 0 dB.
//! Quem chama é a thread que toca (ui/audio_player.zig), ~50 vezes por segundo,
//! e só com o visualizador na tela: parado, não custa nada.
const std = @import("std");

pub const n = 24;
pub const janela = 1024;
const f_min: f32 = 50;
const f_max: f32 = 16_000;
const db_min: f32 = -60;

/// FFT complexa no lugar (Cooley-Tukey iterativa). `re.len` = `im.len` = potência de 2.
pub fn fft(re: []f32, im: []f32) void {
    const len = re.len;
    std.debug.assert(len == im.len and std.math.isPowerOfTwo(len));
    // Ordem dos índices com os bits invertidos.
    var j: usize = 0;
    for (1..len) |i| {
        var bit = len >> 1;
        while (j & bit != 0) : (bit >>= 1) j ^= bit;
        j |= bit;
        if (i < j) {
            std.mem.swap(f32, &re[i], &re[j]);
            std.mem.swap(f32, &im[i], &im[j]);
        }
    }
    var size: usize = 2;
    while (size <= len) : (size <<= 1) {
        const ang = -2.0 * std.math.pi / @as(f32, @floatFromInt(size));
        const wr = @cos(ang);
        const wi = @sin(ang);
        var start: usize = 0;
        while (start < len) : (start += size) {
            var cr: f32 = 1;
            var ci: f32 = 0;
            for (0..size / 2) |k| {
                const a = start + k;
                const b = a + size / 2;
                const tr = re[b] * cr - im[b] * ci;
                const ti = re[b] * ci + im[b] * cr;
                re[b] = re[a] - tr;
                im[b] = im[a] - ti;
                re[a] += tr;
                im[a] += ti;
                const nr = cr * wr - ci * wi;
                ci = cr * wi + ci * wr;
                cr = nr;
            }
        }
    }
}

/// Onde cada faixa começa (em bins da FFT); a última posição é o fim da última.
/// Toda faixa tem pelo menos um bin, mesmo nas graves com taxa alta.
pub fn limites(rate: u32) [n + 1]usize {
    const bin_hz = @as(f32, @floatFromInt(rate)) / janela;
    const top = @min(f_max, @as(f32, @floatFromInt(rate)) / 2 - bin_hz);
    const ratio = std.math.pow(f32, top / f_min, 1.0 / @as(f32, n));
    var out: [n + 1]usize = undefined;
    var f = f_min;
    for (&out, 0..) |*b, i| {
        var bin: usize = @intFromFloat(@round(f / bin_hz));
        if (i > 0) bin = @max(bin, out[i - 1] + 1);
        b.* = @min(bin, janela / 2 - (n - i));
        f *= ratio;
    }
    // O fim de baixo também não passa da metade.
    for (1..n + 1) |i| out[i] = @max(out[i], out[i - 1] + 1);
    return out;
}

/// A faixa onde cai a frequência `hz` (para os testes e para a legenda).
pub fn daFrequencia(hz: f32, rate: u32) usize {
    const lim = limites(rate);
    const bin: usize = @intFromFloat(@round(hz * janela / @as(f32, @floatFromInt(rate))));
    for (0..n) |i| if (bin < lim[i + 1]) return i;
    return n - 1;
}

/// As faixas das últimas `janela` amostras (mono, -1…1).
pub fn calcular(samples: *const [janela]f32, rate: u32, out: *[n]u8) void {
    var re: [janela]f32 = undefined;
    var im: [janela]f32 = @splat(0);
    for (samples, 0..) |s, i| {
        const w = 0.5 - 0.5 * @cos(2 * std.math.pi * @as(f32, @floatFromInt(i)) / (janela - 1));
        re[i] = s * w;
    }
    fft(&re, &im);
    const lim = limites(rate);
    // Uma senoide de amplitude 1 com a janela de Hann dá janela/4 no pico.
    const full: f32 = janela / 4;
    for (0..n) |b| {
        var peak: f32 = 0;
        for (lim[b]..lim[b + 1]) |k| peak = @max(peak, re[k] * re[k] + im[k] * im[k]);
        const mag = @sqrt(peak) / full;
        const db = if (mag > 1e-9) 20 * std.math.log10(mag) else db_min;
        const k01 = std.math.clamp((db - db_min) / -db_min, 0, 1);
        out[b] = @intFromFloat(@round(k01 * 255));
    }
}

/// Uma barra na tela indo até o valor novo: sobe rápido, desce devagar (como os
/// medidores de verdade). `dt` em segundos.
pub fn suavizar(atual: f32, alvo: f32, dt: f32) f32 {
    if (alvo >= atual) return atual + (alvo - atual) * @min(1, dt * 30);
    return @max(alvo, atual - dt * 2.2);
}

test "FFT: uma senoide cai no bin dela" {
    var re: [64]f32 = undefined;
    var im: [64]f32 = @splat(0);
    for (&re, 0..) |*x, i| x.* = @sin(2 * std.math.pi * 5 * @as(f32, @floatFromInt(i)) / 64);
    fft(&re, &im);
    // Pico no bin 5 (e no espelho, 59), com amplitude n/2; o resto quase nada.
    try std.testing.expectApproxEqAbs(@as(f32, 32), @sqrt(re[5] * re[5] + im[5] * im[5]), 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 0), @sqrt(re[6] * re[6] + im[6] * im[6]), 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 0), re[0], 1e-3);
}

test "faixas: crescentes, com pelo menos um bin cada, dentro da FFT" {
    for ([_]u32{ 8000, 16000, 22050, 44100, 48000, 96000 }) |rate| {
        const lim = limites(rate);
        for (0..n) |i| try std.testing.expect(lim[i + 1] > lim[i]);
        try std.testing.expect(lim[0] >= 1);
        try std.testing.expect(lim[n] <= janela / 2);
    }
    // Graves à esquerda, agudos à direita.
    try std.testing.expect(daFrequencia(100, 48000) < daFrequencia(1000, 48000));
    try std.testing.expect(daFrequencia(1000, 48000) < daFrequencia(8000, 48000));
}

test "faixas: silêncio é zero e um tom acende só a faixa dele" {
    var buf: [janela]f32 = @splat(0);
    var out: [n]u8 = undefined;
    calcular(&buf, 48000, &out);
    for (out) |v| try std.testing.expectEqual(@as(u8, 0), v);
    for (&buf, 0..) |*x, i| x.* = 0.5 * @sin(2 * std.math.pi * 2000 * @as(f32, @floatFromInt(i)) / 48000);
    calcular(&buf, 48000, &out);
    const at = daFrequencia(2000, 48000);
    try std.testing.expectEqual(at, std.mem.indexOfMax(u8, &out));
    // -6 dB (meia amplitude) fica perto de 90% da escala; longe do tom, bem menos.
    try std.testing.expect(out[at] > 210 and out[at] < 245);
    try std.testing.expect(out[0] < 80 and out[n - 1] < 80);
}

test "barras sobem rápido e descem devagar" {
    const up = suavizar(0, 1, 1.0 / 30.0);
    try std.testing.expect(up == 1);
    const down = suavizar(1, 0, 1.0 / 30.0);
    try std.testing.expect(down > 0.9 and down < 1);
    try std.testing.expectEqual(@as(f32, 0), suavizar(0.01, 0, 1));
}
