//! O que é puro na gravação de áudio da caixa de texto (ui/gravar_audio.zig):
//! os parâmetros do Opus, o teto e o aviso de tempo, o estéreo do microfone
//! virando mono, o nível de cada quadro para as barras ao vivo, o relógio e o
//! nome do arquivo. O arquivo vai como um anexo comum (.ogg), igual a qualquer
//! outro da bandeja: nada de mensagem de voz do Discord.
const std = @import("std");
const voz = @import("voz.zig");

/// Ogg Opus é sempre a 48 kHz; mono, quadros de 20 ms.
pub const rate: u32 = 48_000;
pub const frame: usize = rate / 50;
pub const frame_ms: u32 = 20;
/// 32 kbit/s com VBR: voz limpa, uns 240 KB por minuto.
pub const bitrate: i32 = 32_000;
/// Pacotes por página do Ogg (1 s): a busca do player e o custo do cabeçalho.
pub const packets_per_page: u32 = 50;

/// Até 10 minutos (uns 2,4 MB, longe dos 10 MB de anexo sem Nitro). Nos últimos
/// 30 s o relógio avisa; no teto a gravação para e espera Enviar ou Cancelar.
pub const max_ms: u32 = 10 * 60 * 1000;
pub const max_frames: u32 = max_ms / frame_ms;
pub const warn_ms: u32 = 30 * 1000;
/// Menos que isso é um clique sem querer: não vira anexo.
pub const min_ms: u32 = 300;

/// Quadros de 20 ms por barra ao vivo (o pico deles).
pub const frames_per_bar: u32 = 4;

/// O microfone vem em estéreo (core/voz.zig): a média dos dois lados.
pub fn toMono(stereo: []const i16, out: []i16) void {
    std.debug.assert(stereo.len == out.len * 2);
    for (out, 0..) |*m, i| m.* = @intCast(@divTrunc(@as(i32, stereo[i * 2]) + stereo[i * 2 + 1], 2));
}

/// Abaixo disto a barra fica no chão.
pub const level_floor_db: f32 = -60;

/// O nível de um quadro numa barra de 0 a 255: linear em dB, de -60 dB ao
/// fundo de escala.
pub fn level(pcm: []const i16) u8 {
    const db = voz.dbOf(voz.rmsOf(pcm));
    if (db <= level_floor_db) return 0;
    const k = std.math.clamp((db - level_floor_db) / -level_floor_db, 0, 1);
    return @intFromFloat(@round(k * 255));
}

/// "m:ss" de um tempo em ms.
pub fn clock(buf: []u8, ms: u32) []const u8 {
    const s = ms / 1000;
    return std.fmt.bufPrint(buf, "{d}:{d:0>2}", .{ s / 60, s % 60 }) catch "";
}

/// Quanto falta para o teto, quando já é hora de avisar (null = ainda não).
pub fn warnLeft(ms: u32) ?u32 {
    if (ms + warn_ms < max_ms) return null;
    return max_ms -| ms;
}

/// A data e a hora locais do nome do arquivo.
pub const When = struct { year: u16, month: u8, day: u8, hour: u8, minute: u8 };

/// "audio-2026-11-17-1432.ogg": o nome com que o anexo aparece no Discord. Um
/// segundo no mesmo minuto ganha "-2" (`n`), e assim por diante.
pub fn fileName(buf: []u8, w: When, n: u8) []const u8 {
    if (n > 1) return std.fmt.bufPrint(buf, "audio-{d:0>4}-{d:0>2}-{d:0>2}-{d:0>2}{d:0>2}-{d}.ogg", .{ w.year, w.month, w.day, w.hour, w.minute, n }) catch "audio.ogg";
    return std.fmt.bufPrint(buf, "audio-{d:0>4}-{d:0>2}-{d:0>2}-{d:0>2}{d:0>2}.ogg", .{ w.year, w.month, w.day, w.hour, w.minute }) catch "audio.ogg";
}

/// A granule da última página: o pre-skip mais as amostras gravadas (o resto do
/// último pacote, que só existe para esvaziar o atraso do codificador, sai
/// cortado no fim).
pub fn endGranule(pre_skip: u16, samples: u64) u64 {
    return @as(u64, pre_skip) + samples;
}

/// Quadros de silêncio a codificar no fim para a última amostra gravada sair do
/// codificador (o atraso dele é o pre-skip): sempre pelo menos um, e o último
/// pacote fecha o arquivo.
pub fn tailFrames(pre_skip: u16) u32 {
    return @intCast(@max(1, (@as(usize, pre_skip) + frame - 1) / frame));
}

test "estéreo vira mono pela média" {
    var out: [3]i16 = undefined;
    toMono(&.{ 100, 300, -32768, -32768, 32767, -32768 }, &out);
    try std.testing.expectEqualSlices(i16, &.{ 200, -32768, 0 }, &out);
}

test "nível: silêncio no chão, fundo de escala no topo, -30 dB no meio" {
    const zero: [960]i16 = @splat(0);
    try std.testing.expectEqual(@as(u8, 0), level(&zero));
    // Onda quadrada no máximo: RMS = fundo de escala.
    var full: [960]i16 = undefined;
    for (&full, 0..) |*s, i| s.* = if (i % 2 == 0) 32767 else -32767;
    try std.testing.expectEqual(@as(u8, 255), level(&full));
    // -30 dB (RMS 1036): metade da escala de -60 a 0.
    var mid: [960]i16 = undefined;
    for (&mid, 0..) |*s, i| s.* = if (i % 2 == 0) 1036 else -1036;
    const v = level(&mid);
    try std.testing.expect(v >= 126 and v <= 129);
    // -70 dB fica no chão.
    var low: [960]i16 = undefined;
    for (&low, 0..) |*s, i| s.* = if (i % 2 == 0) 10 else -10;
    try std.testing.expectEqual(@as(u8, 0), level(&low));
}

test "relógio, aviso perto do teto e nome do arquivo" {
    var b: [16]u8 = undefined;
    try std.testing.expectEqualStrings("0:00", clock(&b, 0));
    try std.testing.expectEqualStrings("0:07", clock(&b, 7999));
    try std.testing.expectEqualStrings("10:00", clock(&b, max_ms));
    try std.testing.expect(warnLeft(0) == null);
    try std.testing.expect(warnLeft(max_ms - warn_ms - 1) == null);
    try std.testing.expectEqual(@as(?u32, warn_ms), warnLeft(max_ms - warn_ms));
    try std.testing.expectEqual(@as(?u32, 0), warnLeft(max_ms + 5));
    var nb: [40]u8 = undefined;
    const when: When = .{ .year = 2026, .month = 11, .day = 17, .hour = 9, .minute = 5 };
    try std.testing.expectEqualStrings("audio-2026-11-17-0905.ogg", fileName(&nb, when, 1));
    try std.testing.expectEqualStrings("audio-2026-11-17-0905-3.ogg", fileName(&nb, when, 3));
    try std.testing.expectEqual(@as(u32, 30_000), max_frames);
}

test "fim do arquivo: o atraso do codificador sai e o resto é cortado" {
    // O pre-skip da libopus a 48 kHz (312) cabe num quadro de silêncio.
    try std.testing.expectEqual(@as(u32, 1), tailFrames(312));
    try std.testing.expectEqual(@as(u32, 1), tailFrames(0));
    try std.testing.expectEqual(@as(u32, 2), tailFrames(961));
    // 2 s gravados: a granule final é 312 + 96000, e o último pacote (o de
    // silêncio) passa disso, então o leitor corta o resto.
    try std.testing.expectEqual(@as(u64, 312 + 96_000), endGranule(312, 96_000));
    try std.testing.expect(endGranule(312, 96_000) <= 96_000 + frame * tailFrames(312));
}
