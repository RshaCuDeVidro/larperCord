//! Que áudio é um anexo. Antes de baixar, pelo tipo que o Discord manda
//! (`content_type` audio/*, guardado em `Attachment.audio`) ou pela extensão do
//! nome; depois de baixar, pelos primeiros bytes, que mandam em quem decodifica.
//! Ogg Opus, MP3 e WAV/AIFF o app toca sozinho; o resto (FLAC, Vorbis, AAC/M4A…)
//! só com o FFmpeg do sistema.
const std = @import("std");

pub const Formato = enum {
    opus,
    /// Ogg de que só os bytes dizem o codec (Opus ou Vorbis).
    ogg,
    vorbis,
    mp3,
    wav,
    flac,
    m4a,
    aac,
    /// Áudio pelo tipo, sem extensão conhecida: os bytes decidem.
    outro,

    /// Toca sem o FFmpeg (o Ogg sem saber o codec conta: quase sempre é Opus).
    pub fn nativo(f: Formato) bool {
        return switch (f) {
            .opus, .ogg, .mp3, .wav, .outro => true,
            else => false,
        };
    }

    /// O nome que aparece no cartão.
    pub fn nome(f: Formato) []const u8 {
        return switch (f) {
            .opus => "Opus",
            .ogg => "Ogg",
            .vorbis => "Vorbis",
            .mp3 => "MP3",
            .wav => "WAV",
            .flac => "FLAC",
            .m4a => "M4A",
            .aac => "AAC",
            .outro => "",
        };
    }
};

const extensoes = [_]struct { ext: []const u8, f: Formato }{
    .{ .ext = "mp3", .f = .mp3 },
    .{ .ext = "wav", .f = .wav },
    .{ .ext = "wave", .f = .wav },
    .{ .ext = "aif", .f = .wav },
    .{ .ext = "aiff", .f = .wav },
    .{ .ext = "aifc", .f = .wav },
    .{ .ext = "ogg", .f = .ogg },
    .{ .ext = "oga", .f = .ogg },
    .{ .ext = "opus", .f = .opus },
    .{ .ext = "flac", .f = .flac },
    .{ .ext = "m4a", .f = .m4a },
    .{ .ext = "m4b", .f = .m4a },
    .{ .ext = "aac", .f = .aac },
    .{ .ext = "mka", .f = .outro },
    .{ .ext = "weba", .f = .outro },
};

/// Pela extensão do nome (sem diferenciar maiúsculas). null = não é de áudio.
pub fn pelaExtensao(name: []const u8) ?Formato {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return null;
    const ext = name[dot + 1 ..];
    for (extensoes) |e| if (std.ascii.eqlIgnoreCase(ext, e.ext)) return e.f;
    return null;
}

/// O tipo que o Discord manda (`content_type`): é áudio?
pub fn tipoDeAudio(content_type: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(content_type, "audio/");
}

/// O anexo é um áudio para o player? `audio` = o tipo disse audio/*. A extensão
/// diz qual; sem ela, os bytes decidem depois (`.outro`).
pub fn doAnexo(audio: bool, name: []const u8) ?Formato {
    if (pelaExtensao(name)) |f| return f;
    return if (audio) .outro else null;
}

/// Pelos primeiros bytes do arquivo baixado. null = não reconhecido.
pub fn pelosBytes(data: []const u8) ?Formato {
    var d = data;
    // ID3v2 na frente (MP3 quase sempre, às vezes AAC ou FLAC): pula a tag.
    if (d.len >= 10 and std.mem.eql(u8, d[0..3], "ID3")) {
        const size = (@as(usize, d[6] & 0x7f) << 21) | (@as(usize, d[7] & 0x7f) << 14) | (@as(usize, d[8] & 0x7f) << 7) | (d[9] & 0x7f);
        const footer: usize = if (d[5] & 0x10 != 0) 10 else 0;
        const skip = 10 + size + footer;
        if (skip >= d.len) return .mp3;
        d = d[skip..];
    }
    if (d.len < 4) return null;
    if (std.mem.eql(u8, d[0..4], "OggS")) {
        // O primeiro pacote diz o codec (a página tem 27 bytes + a tabela de segmentos).
        if (d.len >= 28) {
            const body = 27 + @as(usize, d[26]);
            if (d.len >= body + 8) {
                const p = d[body..];
                if (std.mem.eql(u8, p[0..8], "OpusHead")) return .opus;
                if (std.mem.eql(u8, p[1..7], "vorbis")) return .vorbis;
                if (std.mem.eql(u8, p[1..5], "FLAC")) return .flac;
            }
        }
        return .ogg;
    }
    if (std.mem.eql(u8, d[0..4], "fLaC")) return .flac;
    if (d.len >= 12 and (std.mem.eql(u8, d[0..4], "RIFF") or std.mem.eql(u8, d[0..4], "RF64")) and std.mem.eql(u8, d[8..12], "WAVE")) return .wav;
    if (d.len >= 12 and std.mem.eql(u8, d[0..4], "FORM") and (std.mem.eql(u8, d[8..12], "AIFF") or std.mem.eql(u8, d[8..12], "AIFC"))) return .wav;
    if (d.len >= 8 and std.mem.eql(u8, d[4..8], "ftyp")) return .m4a;
    if (d[0] == 0xff) {
        // ADTS (AAC) tem a camada 00; MP3, 01/10/11.
        if (d[1] & 0xf6 == 0xf0) return .aac;
        if (d[1] & 0xe0 == 0xe0 and (d[1] >> 1) & 3 != 0) return .mp3;
    }
    return null;
}

test "extensão: maiúsculas, as de áudio e as que não são" {
    try std.testing.expectEqual(Formato.mp3, pelaExtensao("Música.MP3").?);
    try std.testing.expectEqual(Formato.wav, pelaExtensao("gravação.wav").?);
    try std.testing.expectEqual(Formato.wav, pelaExtensao("loop.aiff").?);
    try std.testing.expectEqual(Formato.ogg, pelaExtensao("x.ogg").?);
    try std.testing.expectEqual(Formato.opus, pelaExtensao("nota.opus").?);
    try std.testing.expectEqual(Formato.flac, pelaExtensao("disco.flac").?);
    try std.testing.expectEqual(Formato.m4a, pelaExtensao("voz.m4a").?);
    try std.testing.expect(pelaExtensao("foto.png") == null);
    try std.testing.expect(pelaExtensao("mp3") == null);
    try std.testing.expect(pelaExtensao("arquivo.") == null);
    try std.testing.expect(pelaExtensao("video.mp4") == null);
}

test "anexo: o tipo audio/* sem extensão deixa os bytes decidirem" {
    try std.testing.expect(tipoDeAudio("audio/mpeg"));
    try std.testing.expect(tipoDeAudio("Audio/Ogg"));
    try std.testing.expect(!tipoDeAudio("video/mp4"));
    try std.testing.expect(!tipoDeAudio(""));
    try std.testing.expectEqual(Formato.outro, doAnexo(true, "gravacao").?);
    try std.testing.expectEqual(Formato.flac, doAnexo(true, "a.flac").?);
    try std.testing.expectEqual(Formato.mp3, doAnexo(false, "a.mp3").?);
    try std.testing.expect(doAnexo(false, "notas.txt") == null);
}

test "nativo: Opus, MP3 e WAV sem FFmpeg; FLAC, Vorbis e AAC precisam dele" {
    try std.testing.expect(Formato.mp3.nativo() and Formato.wav.nativo() and Formato.opus.nativo() and Formato.ogg.nativo());
    try std.testing.expect(!Formato.flac.nativo() and !Formato.vorbis.nativo() and !Formato.m4a.nativo() and !Formato.aac.nativo());
}

test "bytes: cada formato pelo começo do arquivo" {
    try std.testing.expectEqual(Formato.wav, pelosBytes("RIFF\x24\x00\x00\x00WAVEfmt ").?);
    try std.testing.expectEqual(Formato.wav, pelosBytes("FORM\x00\x00\x00\x10AIFFCOMM").?);
    try std.testing.expectEqual(Formato.flac, pelosBytes("fLaC\x00\x00\x00\x22").?);
    try std.testing.expectEqual(Formato.m4a, pelosBytes("\x00\x00\x00\x20ftypM4A ").?);
    try std.testing.expectEqual(Formato.mp3, pelosBytes("\xff\xfb\x90\x64\x00").?);
    try std.testing.expectEqual(Formato.aac, pelosBytes("\xff\xf1\x50\x80\x00").?);
    // ID3 na frente de um MP3: a tag é pulada.
    try std.testing.expectEqual(Formato.mp3, pelosBytes("ID3\x04\x00\x00\x00\x00\x00\x02\x00\x00\xff\xfb\x90\x64").?);
    try std.testing.expectEqual(Formato.mp3, pelosBytes(@import("audio_pcm.zig").demo_mp3).?);
    // Ogg: o primeiro pacote diz o codec.
    const ogg = @import("ogg_opus.zig");
    var w: ogg.Writer = .{ .gpa = std.testing.allocator };
    defer w.out.deinit(std.testing.allocator);
    var hb: [19]u8 = undefined;
    try w.packets(ogg.flag_bos, 0, &.{ogg.opusHead(&hb, 1, 312)});
    try std.testing.expectEqual(Formato.opus, pelosBytes(w.out.items).?);
    var v: ogg.Writer = .{ .gpa = std.testing.allocator };
    defer v.out.deinit(std.testing.allocator);
    try v.packets(ogg.flag_bos, 0, &.{"\x01vorbis\x00\x00\x00\x00\x02\x44\xac\x00\x00"});
    try std.testing.expectEqual(Formato.vorbis, pelosBytes(v.out.items).?);
    try std.testing.expect(pelosBytes("%PDF-1.7") == null);
    try std.testing.expect(pelosBytes("ab") == null);
}
