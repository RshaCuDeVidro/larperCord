//! De onde sai o som de um áudio baixado: quem decodifica, escolhido pelos
//! primeiros bytes (core/audio_formato.zig). Ogg Opus pelo índice de
//! core/ogg_opus.zig e a libopus; MP3 e WAV/AIFF pelo dr_libs
//! (core/audio_pcm.zig); FLAC, Vorbis, AAC/M4A e o resto pelo FFmpeg do sistema,
//! quando tem. Tudo sai em float intercalado, na taxa e nos canais do arquivo (o
//! SDL converte para o dispositivo). Os dados precisam durar até o `close`.
const std = @import("std");
const c = @import("c");
const ogg = @import("../core/ogg_opus.zig");
const pcm = @import("../core/audio_pcm.zig");
const formato = @import("../core/audio_formato.zig");
const ffmpeg = @import("../platform/ffmpeg.zig");

const alloc = std.heap.c_allocator;

pub const Erro = error{ Formato, PrecisaFfmpeg, SemMemoria };

/// O QA finge que não tem FFmpeg (o cartão volta a ser o de arquivo com o aviso).
pub var qa_sem_ffmpeg = false;

/// Dá para tocar `f` aqui? (Antes de saber se tem FFmpeg, promete: o play tenta.)
pub fn podeTocar(f: formato.Formato) bool {
    if (f.nativo()) return true;
    if (qa_sem_ffmpeg) return false;
    return ffmpeg.known() != false;
}

fn temFfmpeg() ?*const ffmpeg.Api {
    if (qa_sem_ffmpeg) return null;
    return ffmpeg.get();
}

pub const Fonte = union(enum) {
    opus: Opus,
    mp3: pcm.Mp3,
    wav: pcm.Wav,
    ff: *Ff,

    /// Abre `data` com quem sabe lê-lo.
    pub fn abrir(data: []const u8) Erro!Fonte {
        const f = formato.pelosBytes(data) orelse return error.Formato;
        switch (f) {
            .opus => return .{ .opus = Opus.open(data) catch return error.Formato },
            .mp3 => if (pcm.Mp3.open(data)) |m| return .{ .mp3 = m },
            .wav => if (pcm.Wav.open(data)) |w| return .{ .wav = w },
            else => {},
        }
        // O resto (e o que os de cima recusaram) só pelo FFmpeg.
        const api = temFfmpeg() orelse return if (f.nativo()) error.Formato else error.PrecisaFfmpeg;
        return .{ .ff = Ff.open(api, data) catch return error.Formato };
    }

    pub fn close(s: *Fonte) void {
        switch (s.*) {
            .opus => |*o| o.close(),
            .mp3 => |*m| m.close(),
            .wav => |*w| w.close(),
            .ff => |f| f.close(),
        }
    }

    pub fn rate(s: *const Fonte) u32 {
        return switch (s.*) {
            .opus => ogg.rate,
            .mp3 => |m| m.rate,
            .wav => |w| w.rate,
            .ff => |f| f.m.rate,
        };
    }

    pub fn channels(s: *const Fonte) u32 {
        return switch (s.*) {
            .opus => |*o| o.stream.channels,
            .mp3 => |m| m.channels,
            .wav => |w| w.channels,
            .ff => |f| f.m.channels,
        };
    }

    /// Quadros no arquivo inteiro (0 = não se sabe ainda).
    pub fn frames(s: *const Fonte) u64 {
        return switch (s.*) {
            .opus => |*o| o.stream.end -| o.stream.pre_skip,
            .mp3 => |m| m.frames(),
            .wav => |w| w.frames(),
            .ff => |f| if (f.m.duration_ms > 0) @as(u64, @intCast(f.m.duration_ms)) * f.m.rate / 1000 else 0,
        };
    }

    /// Lê até `out.len / channels` quadros; 0 = acabou.
    pub fn read(s: *Fonte, out: []f32) usize {
        return switch (s.*) {
            .opus => |*o| o.read(out),
            .mp3 => |*m| m.read(out),
            .wav => |*w| w.read(out),
            .ff => |f| f.read(out),
        };
    }

    /// Vai para o quadro `frame` (o próximo `read` começa dali).
    pub fn seek(s: *Fonte, frame: u64) void {
        switch (s.*) {
            .opus => |*o| o.seek(frame),
            .mp3 => |*m| _ = m.seek(frame),
            .wav => |*w| _ = w.seek(frame),
            .ff => |f| f.seek(frame),
        }
    }
};

// --- Ogg Opus ------------------------------------------------------------------

/// Decodifica pacote a pacote, puxado por quem lê (o mesmo corte do começo e do
/// fim das mensagens de voz: o pre-skip e a granule da última página).
pub const Opus = struct {
    data: []const u8,
    stream: ogg.Stream,
    dec: *c.OpusDecoder,
    idx: usize = 0,
    /// Instante (amostras decodificadas, com o pre-skip) de onde começa o que se ouve.
    skip_to: u64,
    /// O pacote decodificado (120 ms em estéreo, no máximo) e o que ainda não foi
    /// lido dele. Fora da struct: um buffer de 46 KB dentro dela viraria uma cópia
    /// inteira no executável a cada lugar que monta uma `Fonte`.
    buf: []f32,
    buf_at: usize = 0,
    buf_len: usize = 0,

    fn open(data: []const u8) !Opus {
        var stream = try ogg.index(alloc, data);
        errdefer stream.deinit(alloc);
        const buf = try alloc.alloc(f32, 5760 * 2);
        errdefer alloc.free(buf);
        var err: c_int = 0;
        const dec = c.opus_decoder_create(@intCast(ogg.rate), stream.channels, &err) orelse return error.Opus;
        return .{ .data = data, .stream = stream, .dec = dec, .skip_to = stream.pre_skip, .buf = buf };
    }

    fn close(o: *Opus) void {
        c.opus_decoder_destroy(o.dec);
        o.stream.deinit(alloc);
        alloc.free(o.buf);
    }

    fn seek(o: *Opus, frame: u64) void {
        // Recomeça o decodificador do ponto novo (como as mensagens de voz faziam).
        var err: c_int = 0;
        if (c.opus_decoder_create(@intCast(ogg.rate), o.stream.channels, &err)) |fresh| {
            c.opus_decoder_destroy(o.dec);
            o.dec = fresh;
        }
        const ms: u32 = @intCast(@min(frame / (ogg.rate / 1000), std.math.maxInt(u32)));
        o.idx = o.stream.seekIndex(ms);
        o.skip_to = o.stream.pre_skip + frame;
        o.buf_at = 0;
        o.buf_len = 0;
    }

    fn read(o: *Opus, out: []f32) usize {
        const ch: usize = o.stream.channels;
        const want = out.len / ch;
        var got: usize = 0;
        while (got < want) {
            if (o.buf_at >= o.buf_len and !o.next()) break;
            const n = @min(want - got, (o.buf_len - o.buf_at) / ch);
            @memcpy(out[got * ch ..][0 .. n * ch], o.buf[o.buf_at..][0 .. n * ch]);
            o.buf_at += n * ch;
            got += n;
        }
        return got;
    }

    /// O próximo pacote com algo para ouvir (false = acabou).
    fn next(o: *Opus) bool {
        const s = &o.stream;
        const ch: usize = s.channels;
        while (o.idx < s.packets.len) {
            const pk = s.packets[o.idx];
            const next_start = if (o.idx + 1 < s.packets.len) s.packets[o.idx + 1].start else s.end;
            o.idx += 1;
            const n = c.opus_decode_float(o.dec, s.data(o.data, pk).ptr, @intCast(pk.len), o.buf.ptr, 5760, 0);
            if (n <= 0) continue;
            // Só o que está entre o ponto de começo e o fim do áudio.
            const p0 = pk.start;
            const p1 = @min(p0 + @as(u64, @intCast(n)), s.end, @max(next_start, p0 + 1));
            const from = @max(p0, o.skip_to);
            if (p1 <= from) continue;
            o.buf_at = @intCast((from - p0) * ch);
            o.buf_len = @intCast((p1 - p0) * ch);
            o.skip_to = p1;
            return true;
        }
        return false;
    }
};

// --- FFmpeg --------------------------------------------------------------------

/// FLAC, Vorbis, AAC/M4A…: o FFmpeg lendo da memória. Os quadros decodificados
/// esperam em `pend` até alguém ler.
const Ff = struct {
    m: ffmpeg.Media,
    rd: ffmpeg.MemReader,
    pend: std.ArrayList(f32) = .empty,
    pend_at: usize = 0,
    eof: bool = false,
    /// Depois de buscar: o que vem antes deste ponto (ms) é jogado fora.
    skip_ms: i64 = 0,

    fn open(api: *const ffmpeg.Api, data: []const u8) !*Ff {
        const f = try alloc.create(Ff);
        errdefer alloc.destroy(f);
        f.* = .{ .m = undefined, .rd = .{ .data = data } };
        f.m = try ffmpeg.Media.openAudioOnly(api, f.rd.io());
        if (f.m.channels < 1 or f.m.channels > pcm.max_channels) {
            f.m.close();
            return error.Formato;
        }
        return f;
    }

    fn close(f: *Ff) void {
        f.m.close();
        f.pend.deinit(alloc);
        alloc.destroy(f);
    }

    fn seek(f: *Ff, frame: u64) void {
        const ms: i64 = @intCast(frame * 1000 / @max(f.m.rate, 1));
        f.m.seekAudio(ms);
        f.pend.clearRetainingCapacity();
        f.pend_at = 0;
        f.eof = false;
        f.skip_ms = ms;
    }

    /// Quadro de áudio decodificado (chamado pelo Media.decodeAudio).
    pub fn audio(f: *Ff, samples: []const f32, pts: ?i64) void {
        const ch: usize = f.m.channels;
        var s = samples;
        if (pts) |t| if (t < f.skip_ms) {
            // Antes do ponto pedido: corta a frente (ou tudo).
            const cut: usize = @intCast(@divTrunc((f.skip_ms - t) * f.m.rate, 1000));
            if (cut * ch >= s.len) return;
            s = s[cut * ch ..];
        };
        f.pend.appendSlice(alloc, s) catch return;
    }

    fn read(f: *Ff, out: []f32) usize {
        const ch: usize = f.m.channels;
        const want = out.len / ch * ch;
        var got: usize = 0;
        while (got < want) {
            if (f.pend_at >= f.pend.items.len) {
                f.pend.clearRetainingCapacity();
                f.pend_at = 0;
                if (f.eof) break;
                switch (f.m.read()) {
                    .audio => {
                        f.m.decodeAudio(f.m.pkt.?, f);
                        f.m.unref(f.m.pkt.?);
                    },
                    .video => f.m.unref(f.m.pkt.?),
                    .skip => {},
                    .eof => {
                        f.m.drainAudio(f);
                        f.eof = true;
                    },
                }
                continue;
            }
            const n = @min(want - got, f.pend.items.len - f.pend_at);
            @memcpy(out[got..][0..n], f.pend.items[f.pend_at..][0..n]);
            f.pend_at += n;
            got += n;
        }
        // Depois do primeiro trecho, nada mais é cortado.
        if (got > 0) f.skip_ms = std.math.minInt(i64);
        return got / ch;
    }
};
