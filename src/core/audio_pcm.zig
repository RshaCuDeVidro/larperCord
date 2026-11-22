//! MP3 e WAV (e AIFF) decodificados da memória, em float intercalado, pelo
//! dr_mp3 e pelo dr_wav (third_party/dr_libs). Aqui só a casca em Zig: o que o
//! player de áudio (ui/audio_fonte.zig) e os testes chamam. Os dados precisam
//! continuar vivos até o `close` (nada é copiado). Também o WAV que a
//! demonstração e os testes montam.
const std = @import("std");

const Mp3H = opaque {};
const WavH = opaque {};
extern fn larper_mp3_open(data: [*]const u8, len: usize, channels: *c_uint, rate: *c_uint) ?*Mp3H;
extern fn larper_mp3_frames(h: *Mp3H) c_ulonglong;
extern fn larper_mp3_read(h: *Mp3H, frames: c_ulonglong, out: [*]f32) c_ulonglong;
extern fn larper_mp3_seek(h: *Mp3H, frame: c_ulonglong) c_int;
extern fn larper_mp3_close(h: *Mp3H) void;
extern fn larper_wav_open(data: [*]const u8, len: usize, channels: *c_uint, rate: *c_uint) ?*WavH;
extern fn larper_wav_frames(h: *WavH) c_ulonglong;
extern fn larper_wav_read(h: *WavH, frames: c_ulonglong, out: [*]f32) c_ulonglong;
extern fn larper_wav_seek(h: *WavH, frame: c_ulonglong) c_int;
extern fn larper_wav_close(h: *WavH) void;

/// Até 8 canais (o que o SDL toca); mais que isso o arquivo é recusado.
pub const max_channels = 8;

fn sane(channels: c_uint, rate: c_uint) bool {
    return channels >= 1 and channels <= max_channels and rate >= 4000 and rate <= 384_000;
}

pub const Mp3 = struct {
    h: *Mp3H,
    channels: u32,
    rate: u32,

    pub fn open(data: []const u8) ?Mp3 {
        var ch: c_uint = 0;
        var rate: c_uint = 0;
        const h = larper_mp3_open(data.ptr, data.len, &ch, &rate) orelse return null;
        if (!sane(ch, rate)) {
            larper_mp3_close(h);
            return null;
        }
        return .{ .h = h, .channels = ch, .rate = rate };
    }

    /// Quadros de áudio (amostras por canal) no arquivo inteiro.
    pub fn frames(m: *const Mp3) u64 {
        return larper_mp3_frames(m.h);
    }

    /// Lê até `out.len / channels` quadros; 0 = acabou.
    pub fn read(m: *Mp3, out: []f32) usize {
        const want = out.len / m.channels;
        if (want == 0) return 0;
        return @intCast(larper_mp3_read(m.h, want, out.ptr));
    }

    pub fn seek(m: *Mp3, frame: u64) bool {
        return larper_mp3_seek(m.h, frame) != 0;
    }

    pub fn close(m: *Mp3) void {
        larper_mp3_close(m.h);
    }
};

pub const Wav = struct {
    h: *WavH,
    channels: u32,
    rate: u32,

    pub fn open(data: []const u8) ?Wav {
        var ch: c_uint = 0;
        var rate: c_uint = 0;
        const h = larper_wav_open(data.ptr, data.len, &ch, &rate) orelse return null;
        if (!sane(ch, rate)) {
            larper_wav_close(h);
            return null;
        }
        return .{ .h = h, .channels = ch, .rate = rate };
    }

    pub fn frames(w: *const Wav) u64 {
        return larper_wav_frames(w.h);
    }

    pub fn read(w: *Wav, out: []f32) usize {
        const want = out.len / w.channels;
        if (want == 0) return 0;
        return @intCast(larper_wav_read(w.h, want, out.ptr));
    }

    pub fn seek(w: *Wav, frame: u64) bool {
        return larper_wav_seek(w.h, frame) != 0;
    }

    pub fn close(w: *Wav) void {
        larper_wav_close(w.h);
    }
};

/// Um WAV PCM de 16 bits com estas amostras (intercaladas).
pub fn wav16(gpa: std.mem.Allocator, rate: u32, channels: u16, samples: []const i16) ![]u8 {
    const data_len: u32 = @intCast(samples.len * 2);
    const out = try gpa.alloc(u8, 44 + data_len);
    @memcpy(out[0..4], "RIFF");
    std.mem.writeInt(u32, out[4..8], 36 + data_len, .little);
    @memcpy(out[8..16], "WAVEfmt ");
    std.mem.writeInt(u32, out[16..20], 16, .little);
    std.mem.writeInt(u16, out[20..22], 1, .little);
    std.mem.writeInt(u16, out[22..24], channels, .little);
    std.mem.writeInt(u32, out[24..28], rate, .little);
    std.mem.writeInt(u32, out[28..32], rate * channels * 2, .little);
    std.mem.writeInt(u16, out[32..34], channels * 2, .little);
    std.mem.writeInt(u16, out[34..36], 16, .little);
    @memcpy(out[36..40], "data");
    std.mem.writeInt(u32, out[40..44], data_len, .little);
    for (samples, 0..) |s, i| std.mem.writeInt(i16, out[44 + i * 2 ..][0..2], s, .little);
    return out;
}

test "WAV de 16 bits: canais, taxa, amostras e busca" {
    const gpa = std.testing.allocator;
    // Estéreo a 8 kHz: o canal esquerdo conta para cima, o direito para baixo.
    var pcm: [2 * 1000]i16 = undefined;
    for (0..1000) |i| {
        pcm[i * 2] = @intCast(@as(i32, @intCast(i)) * 16);
        pcm[i * 2 + 1] = @intCast(-@as(i32, @intCast(i)) * 16);
    }
    const file = try wav16(gpa, 8000, 2, &pcm);
    defer gpa.free(file);
    var w = Wav.open(file) orelse return error.TestUnexpectedResult;
    defer w.close();
    try std.testing.expectEqual(@as(u32, 2), w.channels);
    try std.testing.expectEqual(@as(u32, 8000), w.rate);
    try std.testing.expectEqual(@as(u64, 1000), w.frames());
    var out: [2 * 64]f32 = undefined;
    try std.testing.expectEqual(@as(usize, 64), w.read(&out));
    try std.testing.expectApproxEqAbs(@as(f32, 10 * 16) / 32768.0, out[20], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -10 * 16) / 32768.0, out[21], 1e-6);
    // Buscar e ler de lá; no fim, 0.
    try std.testing.expect(w.seek(900));
    try std.testing.expectEqual(@as(usize, 64), w.read(&out));
    try std.testing.expectApproxEqAbs(@as(f32, 900 * 16) / 32768.0, out[0], 1e-6);
    try std.testing.expectEqual(@as(usize, 36), w.read(&out));
    try std.testing.expectEqual(@as(usize, 0), w.read(&out));
}

test "WAV estragado ou de outra coisa é recusado" {
    const gpa = std.testing.allocator;
    var pcm: [16]i16 = @splat(0);
    const file = try wav16(gpa, 8000, 1, &pcm);
    defer gpa.free(file);
    try std.testing.expect(Wav.open(file[0..30]) == null);
    try std.testing.expect(Wav.open("RIFF\x10\x00\x00\x00AVI LIST nada de som") == null);
    // Canais demais (o SDL toca até 8).
    const many = try gpa.dupe(u8, file);
    defer gpa.free(many);
    std.mem.writeInt(u16, many[22..24], 12, .little);
    try std.testing.expect(Wav.open(many) == null);
}

/// O MP3 da demonstração (ui/audio_demo.zig): 4 s, mono, 22 050 Hz, 24 kbps, um
/// arpejo que começa num lá de 440 Hz aos 0,1 s.
pub const demo_mp3 = @embedFile("../ui/demo_audio.mp3");

test "MP3: decodifica o da demonstração, com a nota certa no começo" {
    var m = Mp3.open(demo_mp3) orelse return error.TestUnexpectedResult;
    defer m.close();
    try std.testing.expectEqual(@as(u32, 1), m.channels);
    try std.testing.expectEqual(@as(u32, 22050), m.rate);
    const total = m.frames();
    // 4 s (o codificador deixa uns quadros de folga no começo e no fim).
    try std.testing.expect(total > 22050 * 39 / 10 and total < 22050 * 41 / 10);
    const bandas = @import("audio_bandas.zig");
    // Logo depois de o lá começar: a faixa mais forte é a dos 440 Hz.
    try std.testing.expect(m.seek(2646));
    var win: [bandas.janela]f32 = undefined;
    try std.testing.expectEqual(@as(usize, bandas.janela), m.read(&win));
    var out: [bandas.n]u8 = undefined;
    bandas.calcular(&win, m.rate, &out);
    const strongest = std.mem.indexOfMax(u8, &out);
    try std.testing.expectEqual(bandas.daFrequencia(440, m.rate), strongest);
    // Ler o resto inteiro dá o total que ele disse.
    try std.testing.expect(m.seek(0));
    var buf: [4096]f32 = undefined;
    var n: u64 = 0;
    while (true) {
        const got = m.read(&buf);
        if (got == 0) break;
        n += got;
    }
    try std.testing.expectEqual(total, n);
}

test "MP3 estragado é recusado" {
    try std.testing.expect(Mp3.open("isto não é um mp3, nem perto disso, só texto") == null);
    try std.testing.expect(Mp3.open(&.{}) == null);
}
