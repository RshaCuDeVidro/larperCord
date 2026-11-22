//! Os áudios da demonstração (o #música do primeiro servidor,
//! net/fake_gateway.zig): feitos aqui mesmo na hora do play e entregues pelo
//! mesmo caminho dos de verdade (ui/audio_player.zig), sem rede. A mensagem de
//! voz e um Ogg Opus codificados agora com a libopus, o MP3 embutido
//! (core/audio_pcm.zig), um WAV e um FLAC simples (sem compressão), que só o
//! FFmpeg toca.
const std = @import("std");
const c = @import("c");
const ogg = @import("../core/ogg_opus.zig");
const pcm = @import("../core/audio_pcm.zig");

const alloc = std.heap.c_allocator;

pub const prefixo = "demo:audio:";

/// Os bytes de `demo:voice` ou de `demo:audio:<tipo>`.
pub fn bytes(url: []const u8) ![]u8 {
    if (std.mem.eql(u8, url, "demo:voice")) return voz();
    if (!std.mem.startsWith(u8, url, prefixo)) return error.Demo;
    const kind = url[prefixo.len..];
    if (std.mem.eql(u8, kind, "mp3")) return alloc.dupe(u8, pcm.demo_mp3);
    if (std.mem.eql(u8, kind, "wav")) return wav();
    if (std.mem.eql(u8, kind, "ogg")) return opus();
    if (std.mem.eql(u8, kind, "flac")) return flac();
    return error.Demo;
}

// --- O que toca ------------------------------------------------------------------

fn nota(semitons: f32) f32 {
    return 440 * std.math.pow(f32, 2, semitons / 12);
}

/// Uma corda dedilhada (seno com dois harmônicos e um ataque curto).
fn pluck(t: f32, f: f32) f32 {
    if (t < 0) return 0;
    const env = @exp(-t * 3) * @min(1, t * 300);
    const w = 2 * std.math.pi * f * t;
    return env * (@sin(w) + 0.3 * @sin(2 * w) + 0.1 * @sin(3 * w));
}

fn kick(t: f32) f32 {
    if (t < 0 or t > 0.3) return 0;
    const ph = 2 * std.math.pi * (50 * t + 70.0 / 30.0 * (1 - @exp(-t * 30)));
    return @exp(-t * 14) * @sin(ph);
}

/// Ruído branco simples (para a caixa e o chimbal), sempre igual.
fn ruido(i: usize) f32 {
    var x: u32 = @truncate(i *% 2654435761);
    x ^= x >> 13;
    x *%= 0x5bd1e995;
    x ^= x >> 15;
    return @as(f32, @floatFromInt(x & 0xffff)) / 32768.0 - 1;
}

/// Lá menor, Fá, Dó e Sol num arpejo (o Ogg Opus, em estéreo: o baixo no meio,
/// as notas abrindo para os lados).
fn arpejo(t: f32, lado: f32) f32 {
    const acordes = [4][3]f32{ .{ 0, 3, 7 }, .{ -4, 0, 3 }, .{ 3, 7, 10 }, .{ -2, 2, 5 } };
    const passo: f32 = 0.2;
    const k: usize = @intFromFloat(@floor(t / passo));
    const ac = acordes[(k / 8) % 4];
    const quando = t - @as(f32, @floatFromInt(k)) * passo;
    const n = ac[k % 3] + (if (k % 6 >= 3) @as(f32, 12) else 0);
    const pan = if (k % 2 == 0) 0.5 + 0.4 * lado else 0.5 - 0.4 * lado;
    const baixo_t = t - @as(f32, @floatFromInt(k / 8 * 8)) * passo;
    return 0.32 * pan * pluck(quando, nota(n)) + 0.3 * pluck(baixo_t, nota(ac[0] - 24)) + 0.35 * kick(@mod(t, 0.8));
}

/// Bateria e baixo (o WAV).
fn batida(t: f32, i: usize) f32 {
    const beat = @mod(t, 0.5);
    const caixa = if (@mod(t, 1.0) >= 0.5) @exp(-beat * 22) * ruido(i) * 0.5 else 0;
    const chimbal = @exp(-@mod(t, 0.25) * 60) * ruido(i *% 7 + 3) * 0.18;
    const baixo = 0.35 * pluck(@mod(t, 1.0), nota(if (@mod(t, 2.0) < 1) -29 else -26));
    return 0.6 * kick(beat) + caixa + chimbal + baixo;
}

/// Um acorde longo que vai e volta (o FLAC).
fn pad(t: f32) f32 {
    const notas = [_]f32{ -12, -5, 0, 4 };
    var v: f32 = 0;
    for (notas, 0..) |n, i| {
        const f = nota(n);
        const trem = 0.7 + 0.3 * @sin(2 * std.math.pi * (0.5 + 0.13 * @as(f32, @floatFromInt(i))) * t);
        v += trem * @sin(2 * std.math.pi * f * t);
    }
    const env = @min(1, t * 4) * @min(1, (3.0 - t) * 4);
    return 0.18 * v * @max(env, 0);
}

fn toI16(v: f32) i16 {
    return @intFromFloat(std.math.clamp(v, -1, 1) * 32767);
}

// --- Os arquivos -----------------------------------------------------------------

/// A mensagem de voz: uma voz sintética de 4 s, codificada em Opus aqui mesmo e
/// posta num Ogg (passa pelo mesmo caminho da de verdade).
fn voz() ![]u8 {
    var err: c_int = 0;
    const enc = c.opus_encoder_create(@intCast(ogg.rate), 1, c.OPUS_APPLICATION_VOIP, &err) orelse return error.Opus;
    defer c.opus_encoder_destroy(enc);
    var w: ogg.Writer = .{ .gpa = alloc };
    errdefer w.out.deinit(alloc);
    var hb: [19]u8 = undefined;
    const pre_skip: u16 = 312;
    try w.packets(ogg.flag_bos, 0, &.{ogg.opusHead(&hb, 1, pre_skip)});
    try w.packets(0, 0, &.{"OpusTags\x0a\x00\x00\x00larperCord\x00\x00\x00\x00"});
    const frame = 960;
    const frames = 200;
    var buf: [frame]i16 = undefined;
    var pkts: [10][400]u8 = undefined;
    var lens: [10]usize = undefined;
    var phase: f32 = 0;
    var granule: u64 = 0;
    var k: usize = 0;
    while (k < frames) : (k += 10) {
        for (0..10) |j| {
            const fi = k + j;
            for (&buf, 0..) |*s, i| {
                // Sílabas: um tom que sobe e desce, com pausas entre elas.
                const t = @as(f32, @floatFromInt(fi * frame + i)) / @as(f32, @floatFromInt(ogg.rate));
                const syl = @abs(@sin(t * std.math.pi * 2.6));
                const f0 = 170 + 60 * @sin(t * 3.1);
                phase += 2 * std.math.pi * f0 / @as(f32, @floatFromInt(ogg.rate));
                const v = (@sin(phase) + 0.4 * @sin(phase * 2) + 0.2 * @sin(phase * 3)) * syl * syl * 0.35;
                s.* = toI16(v);
            }
            const n = c.opus_encode(enc, &buf, frame, &pkts[j], pkts[j].len);
            if (n <= 0) return error.Opus;
            lens[j] = @intCast(n);
            granule += frame;
        }
        var list: [10][]const u8 = undefined;
        for (0..10) |j| list[j] = pkts[j][0..lens[j]];
        try w.packets(if (k + 10 >= frames) ogg.flag_eos else 0, granule, &list);
    }
    return w.out.toOwnedSlice(alloc);
}

fn wav() ![]u8 {
    const rate = 22050;
    const frames = rate * 3;
    const s = try alloc.alloc(i16, frames);
    defer alloc.free(s);
    for (s, 0..) |*x, i| x.* = toI16(batida(@as(f32, @floatFromInt(i)) / rate, i));
    return pcm.wav16(alloc, rate, 1, s);
}

/// 16 s em estéreo, como uma música mandada no chat.
fn opus() ![]u8 {
    var err: c_int = 0;
    const enc = c.opus_encoder_create(@intCast(ogg.rate), 2, c.OPUS_APPLICATION_AUDIO, &err) orelse return error.Opus;
    defer c.opus_encoder_destroy(enc);
    var w: ogg.Writer = .{ .gpa = alloc };
    errdefer w.out.deinit(alloc);
    var hb: [19]u8 = undefined;
    const pre_skip: u16 = 312;
    try w.packets(ogg.flag_bos, 0, &.{ogg.opusHead(&hb, 2, pre_skip)});
    try w.packets(0, 0, &.{"OpusTags\x0a\x00\x00\x00larperCord\x00\x00\x00\x00"});
    const frame = 960;
    const frames = 800;
    var buf: [frame * 2]i16 = undefined;
    var pkts: [10][1500]u8 = undefined;
    var lens: [10]usize = undefined;
    var granule: u64 = 0;
    var k: usize = 0;
    while (k < frames) : (k += 10) {
        for (0..10) |j| {
            for (0..frame) |i| {
                const t = @as(f32, @floatFromInt((k + j) * frame + i)) / @as(f32, @floatFromInt(ogg.rate));
                buf[i * 2] = toI16(arpejo(t, -1));
                buf[i * 2 + 1] = toI16(arpejo(t, 1));
            }
            const n = c.opus_encode(enc, &buf, frame, &pkts[j], pkts[j].len);
            if (n <= 0) return error.Opus;
            lens[j] = @intCast(n);
            granule += frame;
        }
        var list: [10][]const u8 = undefined;
        for (0..10) |j| list[j] = pkts[j][0..lens[j]];
        try w.packets(if (k + 10 >= frames) ogg.flag_eos else 0, granule, &list);
    }
    return w.out.toOwnedSlice(alloc);
}

// FLAC sem compressão (subquadros VERBATIM): o cabeçalho, o STREAMINFO e um quadro
// por bloco, cada um com o CRC-8 do cabeçalho e o CRC-16 do quadro.

fn crc8(data: []const u8) u8 {
    var crc: u8 = 0;
    for (data) |b| {
        crc ^= b;
        for (0..8) |_| crc = if (crc & 0x80 != 0) (crc << 1) ^ 0x07 else crc << 1;
    }
    return crc;
}

fn crc16(data: []const u8) u16 {
    var crc: u16 = 0;
    for (data) |b| {
        crc ^= @as(u16, b) << 8;
        for (0..8) |_| crc = if (crc & 0x8000 != 0) (crc << 1) ^ 0x8005 else crc << 1;
    }
    return crc;
}

fn flac() ![]u8 {
    const rate: u32 = 16000;
    const total: u32 = rate * 3;
    const block: u32 = 4096;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "fLaC");
    // STREAMINFO (o último bloco de metadados): blocos de 4096, mono, 16 bits.
    try out.appendSlice(alloc, &.{ 0x80, 0, 0, 34 });
    var si: [34]u8 = @splat(0);
    std.mem.writeInt(u16, si[0..2], block, .big);
    std.mem.writeInt(u16, si[2..4], block, .big);
    // Taxa (20 bits), canais - 1 (3), bits - 1 (5) e total de amostras (36).
    const packed_: u64 = (@as(u64, rate) << 44) | (@as(u64, 0) << 41) | (@as(u64, 15) << 36) | total;
    std.mem.writeInt(u64, si[10..18], packed_, .big);
    try out.appendSlice(alloc, &si);
    var start: u32 = 0;
    var num: u32 = 0;
    while (start < total) : ({
        start += block;
        num += 1;
    }) {
        const n = @min(block, total - start);
        const at = out.items.len;
        // Sincronismo, blocos fixos; tamanho no fim do cabeçalho (16 bits), taxa do
        // STREAMINFO; mono; 16 bits. O número do quadro em "UTF-8" (aqui, < 128).
        try out.appendSlice(alloc, &.{ 0xff, 0xf8, 0x70, 0x08, @intCast(num) });
        var bs: [2]u8 = undefined;
        std.mem.writeInt(u16, &bs, @intCast(n - 1), .big);
        try out.appendSlice(alloc, &bs);
        try out.append(alloc, crc8(out.items[at..]));
        // Subquadro VERBATIM, sem bits desperdiçados.
        try out.append(alloc, 0x02);
        for (0..n) |i| {
            const t = @as(f32, @floatFromInt(start + i)) / @as(f32, @floatFromInt(rate));
            var sb: [2]u8 = undefined;
            std.mem.writeInt(i16, &sb, toI16(pad(t)), .big);
            try out.appendSlice(alloc, &sb);
        }
        var cb: [2]u8 = undefined;
        std.mem.writeInt(u16, &cb, crc16(out.items[at..]), .big);
        try out.appendSlice(alloc, &cb);
    }
    return out.toOwnedSlice(alloc);
}
