//! Quem toca áudio na conversa: as mensagens de voz (ui/voice_msg.zig) e os
//! anexos de áudio (ui/audio_card.zig). Um áudio por vez. Tocar baixa o arquivo
//! pelo mesmo caminho das imagens (só domínios do Discord, com o proxy das
//! configurações), escolhe quem decodifica pelos primeiros bytes
//! (ui/audio_fonte.zig) e põe num stream do SDL no dispositivo de saída escolhido
//! na página Voz, com o volume de saída de lá. A thread e o stream só existem
//! enquanto toca: pausar fecha os dois e guarda onde parou (o arquivo baixado fica,
//! para continuar sem baixar de novo).
//!
//! Enquanto toca, a mesma thread mede as faixas do visualizador
//! (core/audio_bandas.zig) no trecho que está saindo no alto-falante, só quando a
//! interface pediu (na tela, janela em foco, sem "reduzir movimento"). A forma de
//! onda do arquivo inteiro (core/audio_onda.zig) sai uma vez, numa thread de
//! prioridade baixa, e fica guardada para as próximas vezes.
//!
//! Para quando a conversa dele sai da tela (outro canal ou aba), quando a mensagem
//! some (rolou para longe e saiu da memória) e quando a janela vai para a bandeja.
const std = @import("std");
const c = @import("c");
const d = @import("draw.zig");
const anim = @import("anim.zig");
const qa = @import("qa.zig");
const images = @import("images.zig");
const types = @import("../core/types.zig");
const onda = @import("../core/audio_onda.zig");
const bandas = @import("../core/audio_bandas.zig");
const media_refresh = @import("../core/media_refresh.zig");
const voz_audio = @import("../net/voz_audio.zig");
const platform = @import("../platform/window.zig");
const fonte = @import("audio_fonte.zig");
const demo = @import("audio_demo.zig");

const alloc = std.heap.c_allocator;
const Atomic = @import("../platform/sys.zig").Atomic;

/// Teto do download (o Discord sem Nitro aceita até 10 MB; com Nitro, bem mais).
pub const max_bytes: usize = 32 << 20;
/// A forma de onda só para áudios de até 40 min (decodificar o arquivo inteiro).
const max_onda_ms: u64 = 40 * 60 * 1000;
/// Quadros lidos de cada vez.
const chunk = 2048;
/// O que a thread guarda do que já foi para o alto-falante (mono), para as faixas.
const hist_len = 1 << 16;

pub const Tipo = enum(u8) { voz, arquivo };

/// Por que não tocou (o cartão diz).
pub const Falha = enum(u8) { nenhuma, baixar, grande, formato, ffmpeg, som };

const RunState = enum(u8) { loading, playing, done, failed };

/// As velocidades do botão (×100).
pub const velocidades = [_]u16{ 100, 150, 200 };

// --- Quem toca (thread curta) -------------------------------------------------

/// O arquivo baixado, dividido entre a interface (para continuar depois de
/// pausar), a thread que toca e a da forma de onda.
const Blob = struct {
    refs: Atomic(u32),
    data: []u8,

    fn retain(b: *Blob) *Blob {
        _ = b.refs.fetchAdd(1, .monotonic);
        return b;
    }

    fn release(b: *Blob) void {
        if (b.refs.fetchSub(1, .acq_rel) != 1) return;
        alloc.free(b.data);
        alloc.destroy(b);
    }
};

/// Uma vez tocando, da interface e da thread (cada uma solta a sua parte).
const Run = struct {
    refs: Atomic(u32) = .init(2),
    stop: Atomic(bool) = .init(false),
    url: []u8,
    wake_type: u32,
    /// O arquivo que a interface já tinha (null = a thread baixa).
    blob: ?*Blob,
    /// O que a thread baixou, com uma parte para a interface guardar.
    fresh: Atomic(?*Blob) = .init(null),
    start_ms: u32,
    /// Começar nesta fração do arquivo (o clique na barra antes de saber a duração; -1 = não).
    start_frac: f32 = -1,
    pos_ms: Atomic(u32),
    dur_ms: Atomic(u32) = .init(0),
    state: Atomic(RunState) = .init(.loading),
    falha: Atomic(Falha) = .init(.nenhuma),
    /// Pedido de busca (ms; -1 = nenhum).
    seek_ms: Atomic(i64) = .init(-1),
    speed: Atomic(u16) = .init(100),
    /// A interface quer as faixas do visualizador (está na tela, animando).
    viz: Atomic(bool) = .init(false),
    bands: [bandas.n]Atomic(u8) = @splat(.init(0)),

    fn release(r: *Run) void {
        if (r.refs.fetchSub(1, .acq_rel) != 1) return;
        if (r.blob) |b| b.release();
        if (r.fresh.swap(null, .acq_rel)) |b| b.release();
        alloc.free(r.url);
        alloc.destroy(r);
    }

    fn wake(r: *const Run) void {
        platform.Window.wake(r.wake_type, .media);
    }
};

/// Threads vivas (o app espera por elas ao fechar).
var live: Atomic(u32) = .init(0);

fn worker(p: ?*anyopaque) callconv(.c) c_int {
    const r: *Run = @ptrCast(@alignCast(p.?));
    defer {
        r.wake();
        r.release();
        _ = live.fetchSub(1, .release);
    }
    play(r) catch {
        if (r.falha.load(.acquire) == .nenhuma) r.falha.store(.som, .release);
        r.state.store(.failed, .release);
        return 0;
    };
    r.state.store(.done, .release);
    return 0;
}

const ListSink = struct {
    list: std.ArrayList(u8) = .empty,
    too_big: bool = false,

    fn write(ud: *anyopaque, piece: []const u8, total: i64) bool {
        const s: *ListSink = @ptrCast(@alignCast(ud));
        if (s.list.items.len + piece.len > max_bytes or total > @as(i64, @intCast(max_bytes))) {
            s.too_big = true;
            return false;
        }
        s.list.appendSlice(alloc, piece) catch return false;
        return true;
    }
};

fn download(r: *Run) !*Blob {
    var data: []u8 = undefined;
    if (std.mem.startsWith(u8, r.url, "demo:")) {
        data = demo.bytes(r.url) catch {
            r.falha.store(.baixar, .release);
            return error.Download;
        };
    } else {
        var sink: ListSink = .{};
        errdefer sink.list.deinit(alloc);
        var ubuf: [2100]u8 = undefined;
        const z = std.fmt.bufPrintSentinel(&ubuf, "{s}", .{r.url}, 0) catch return error.Url;
        var curl: ?*c.CURL = null;
        defer if (curl) |h| c.curl_easy_cleanup(h);
        if (!images.fetch(&curl, z, .{ .ctx = &sink, .write = ListSink.write }, &r.stop, 60) or sink.list.items.len == 0) {
            r.falha.store(if (sink.too_big) .grande else .baixar, .release);
            return error.Download;
        }
        data = try sink.list.toOwnedSlice(alloc);
    }
    errdefer alloc.free(data);
    const b = try alloc.create(Blob);
    b.* = .{ .refs = .init(1), .data = data };
    return b;
}

fn msOf(frames: u64, rate: u32) u32 {
    return @intCast(@min(frames * 1000 / @max(rate, 1), std.math.maxInt(u32)));
}

fn play(r: *Run) !void {
    const file = if (r.blob) |b| b.retain() else blk: {
        const b = try download(r);
        // Uma parte fica para a interface (continuar sem baixar de novo).
        r.fresh.store(b.retain(), .release);
        r.wake();
        break :blk b;
    };
    defer file.release();
    if (r.stop.load(.acquire)) return;
    var src = fonte.Fonte.abrir(file.data) catch |e| {
        r.falha.store(if (e == error.PrecisaFfmpeg) .ffmpeg else .formato, .release);
        return error.Format;
    };
    defer src.close();
    const rate = src.rate();
    const ch = src.channels();
    const total = src.frames();
    if (total > 0) r.dur_ms.store(msOf(total, rate), .release);

    if (!voz_audio.acquire()) return error.Audio;
    defer voz_audio.release();
    const spec: c.SDL_AudioSpec = .{ .format = c.SDL_AUDIO_F32, .channels = @intCast(ch), .freq = @intCast(rate) };
    const out = c.SDL_OpenAudioDeviceStream(voz_audio.outputDevice(), &spec, null, null) orelse
        c.SDL_OpenAudioDeviceStream(c.SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, &spec, null, null) orelse return error.Audio;
    defer c.SDL_DestroyAudioStream(out);
    var gain = voz_audio.sh.out_gain.load(.monotonic);
    _ = c.SDL_SetAudioStreamGain(out, gain);
    var speed = r.speed.load(.acquire);
    _ = c.SDL_SetAudioStreamFrequencyRatio(out, @as(f32, @floatFromInt(speed)) / 100);

    const buf = try alloc.alloc(f32, chunk * ch);
    defer alloc.free(buf);
    const hist = try alloc.alloc(f32, hist_len);
    defer alloc.free(hist);
    @memset(hist, 0);

    var start: u64 = if (r.start_frac >= 0 and total > 0)
        @intFromFloat(@as(f64, r.start_frac) * @as(f64, @floatFromInt(total)))
    else
        @as(u64, r.start_ms) * rate / 1000;
    if (total > 0) start = @min(start, total -| 1);
    if (start > 0) src.seek(start);
    // Fim do que já foi para a fila (em quadros do arquivo).
    var pushed_end: u64 = start;
    var eof = false;
    var flushed = false;
    var resumed = false;
    const bytes_per_frame: usize = ch * @sizeOf(f32);
    r.pos_ms.store(msOf(start, rate), .release);
    r.state.store(.playing, .release);
    r.wake();

    while (!r.stop.load(.acquire)) {
        const want = r.seek_ms.swap(-1, .acq_rel);
        if (want >= 0) {
            // Busca: esvazia a fila e o decodificador recomeça do ponto novo.
            _ = c.SDL_ClearAudioStream(out);
            var f: u64 = @as(u64, @intCast(want)) * rate / 1000;
            if (total > 0) f = @min(f, total -| 1);
            src.seek(f);
            pushed_end = f;
            eof = false;
            flushed = false;
        }
        const sp = r.speed.load(.acquire);
        if (sp != speed) {
            speed = sp;
            _ = c.SDL_SetAudioStreamFrequencyRatio(out, @as(f32, @floatFromInt(speed)) / 100);
        }
        const g = voz_audio.sh.out_gain.load(.monotonic);
        if (g != gain) {
            gain = g;
            _ = c.SDL_SetAudioStreamGain(out, gain);
        }
        var queued: usize = @intCast(@max(c.SDL_GetAudioStreamQueued(out), 0));
        queued /= bytes_per_frame;
        // Uns 300 ms na fila (na velocidade pedida).
        const ahead: usize = @as(usize, rate) * 3 / 10 * speed / 100;
        while (!eof and queued < ahead) {
            const n = src.read(buf);
            if (n == 0) {
                eof = true;
                break;
            }
            if (!c.SDL_PutAudioStreamData(out, buf.ptr, @intCast(n * bytes_per_frame))) return error.Audio;
            // O mesmo trecho, em mono, para as faixas.
            for (0..n) |i| {
                var m: f32 = 0;
                for (buf[i * ch ..][0..ch]) |s| m += s;
                hist[@intCast((pushed_end + i) % hist_len)] = m / @as(f32, @floatFromInt(ch));
            }
            pushed_end += n;
            queued += n;
        }
        if (eof and !flushed) {
            // Sem mais nada: o que sobrou no conversor de taxa sai também.
            flushed = true;
            _ = c.SDL_FlushAudioStream(out);
        }
        if (!resumed) {
            resumed = true;
            _ = c.SDL_ResumeAudioStreamDevice(out);
        }
        const now_pos = pushed_end -| queued;
        r.pos_ms.store(msOf(now_pos, rate), .release);
        if (r.viz.load(.acquire)) {
            // As faixas do trecho que está saindo agora (o fim da janela no que toca).
            var win: [bandas.janela]f32 = undefined;
            const from = now_pos -| bandas.janela;
            for (&win, 0..) |*w, i| w.* = if (from + i < now_pos) hist[@intCast((from + i) % hist_len)] else 0;
            var out_b: [bandas.n]u8 = undefined;
            bandas.calcular(&win, rate, &out_b);
            for (&r.bands, out_b) |*a, v| a.store(v, .monotonic);
        }
        if (eof and queued == 0) {
            const end_ms = msOf(pushed_end, rate);
            if (r.dur_ms.load(.acquire) == 0) r.dur_ms.store(end_ms, .release);
            r.pos_ms.store(r.dur_ms.load(.acquire), .release);
            return;
        }
        c.SDL_Delay(15);
    }
}

// --- A forma de onda (thread de prioridade baixa) ---------------------------------

const Job = struct {
    refs: Atomic(u32) = .init(2),
    stop: Atomic(bool) = .init(false),
    /// 0 = medindo, 1 = pronto, 2 = não deu.
    done: Atomic(u8) = .init(0),
    blob: *Blob,
    key: u64,
    wake_type: u32,
    out: [onda.fina]u8 = undefined,
    dur_ms: u32 = 0,

    fn release(j: *Job) void {
        if (j.refs.fetchSub(1, .acq_rel) != 1) return;
        j.blob.release();
        alloc.destroy(j);
    }
};

fn ondaMain(p: ?*anyopaque) callconv(.c) c_int {
    const j: *Job = @ptrCast(@alignCast(p.?));
    defer {
        platform.Window.wake(j.wake_type, .media);
        j.release();
        _ = live.fetchSub(1, .release);
    }
    _ = c.SDL_SetCurrentThreadPriority(c.SDL_THREAD_PRIORITY_LOW);
    j.done.store(if (medir(j)) 1 else 2, .release);
    return 0;
}

fn medir(j: *Job) bool {
    var src = fonte.Fonte.abrir(j.blob.data) catch return false;
    defer src.close();
    const ch = src.channels();
    const rate = src.rate();
    const buf = alloc.alloc(f32, chunk * ch) catch return false;
    defer alloc.free(buf);
    var acc: onda.Acumulador = .{};
    defer acc.deinit(alloc);
    var frames: u64 = 0;
    const limit = max_onda_ms * rate / 1000;
    while (!j.stop.load(.acquire)) {
        const n = src.read(buf);
        if (n == 0) break;
        acc.add(alloc, buf[0 .. n * ch], ch) catch return false;
        frames += n;
        if (frames > limit) return false;
    }
    if (j.stop.load(.acquire)) return false;
    j.dur_ms = msOf(frames, rate);
    return acc.terminar(alloc, &j.out) catch false;
}

/// O que já se sabe de cada áudio tocado nesta sessão: a duração e a forma de onda.
const Memo = struct { key: u64 = 0, dur_ms: u32 = 0, pronta: bool = false, pts: [onda.fina]u8 = undefined };
var memos: [32]Memo = @splat(.{});
var memo_next: usize = 0;
var job: ?*Job = null;
/// Formas de onda que não deu para medir (não tenta de novo).
var sem_onda: u64 = 0;

fn memo(key: u64) ?*Memo {
    for (&memos) |*m| if (m.key == key and key != 0) return m;
    return null;
}

fn memoNovo(key: u64) *Memo {
    if (memo(key)) |m| return m;
    const m = &memos[memo_next];
    memo_next = (memo_next + 1) % memos.len;
    m.* = .{ .key = key };
    return m;
}

/// A forma de onda já medida de `key` (`fina` pontos).
pub fn formaDeOnda(key: u64) ?*const [onda.fina]u8 {
    const m = memo(key) orelse return null;
    return if (m.pronta) &m.pts else null;
}

/// Muda quando um áudio descobre que precisava do FFmpeg (o cartão muda de altura).
var gen: u32 = 0;
/// Os que tentaram tocar e precisavam do FFmpeg (um .ogg que era Vorbis).
var sem_ffmpeg: [16]u64 = @splat(0);
var sem_ffmpeg_next: usize = 0;

pub fn precisaFfmpeg(key: u64) bool {
    return key != 0 and std.mem.indexOfScalar(u64, &sem_ffmpeg, key) != null;
}

pub fn geracao() u32 {
    return gen;
}

/// Por que `key` não tocou da última vez (`.nenhuma` = tocou ou nem tentou).
pub fn falhou(key: u64) Falha {
    return if (failed_key == key and key != 0) falha else .nenhuma;
}

/// A duração que já se sabe de `key` (0 = não tocou ainda).
pub fn duracao(key: u64) u32 {
    return if (memo(key)) |m| m.dur_ms else 0;
}

fn colherJob() void {
    const j = job orelse return;
    const st = j.done.load(.acquire);
    if (st == 0) return;
    job = null;
    if (st == 1) {
        const m = memoNovo(j.key);
        m.pts = j.out;
        m.pronta = true;
        if (m.dur_ms == 0) m.dur_ms = j.dur_ms;
    } else sem_onda = j.key;
    j.release();
}

fn medirOnda(wake_type: u32) void {
    if (kind != .arquivo or active == 0 or job != null or sem_onda == active) return;
    if (formaDeOnda(active) != null) return;
    const b = blob orelse return;
    const j = alloc.create(Job) catch return;
    j.* = .{ .blob = b.retain(), .key = active, .wake_type = wake_type };
    _ = live.fetchAdd(1, .acq_rel);
    const t = c.SDL_CreateThread(ondaMain, "audio-onda", j) orelse {
        _ = live.fetchSub(1, .release);
        j.refs.store(1, .monotonic);
        j.release();
        return;
    };
    c.SDL_DetachThread(t);
    job = j;
}

// --- O que a interface lembra -------------------------------------------------

/// O áudio escolhido (mensagem + índice do anexo) e onde está.
var active: u64 = 0;
var kind: Tipo = .arquivo;
var run: ?*Run = null;
var blob: ?*Blob = null;
var pos_ms: u32 = 0;
var dur_ms: u32 = 0;
/// Arrastando na barra: a posição que o dedo mostra.
var scrubbing = false;
/// O último que falhou, e por quê (o cartão mostra o aviso).
var failed_key: u64 = 0;
var falha: Falha = .nenhuma;
/// O áudio que esperava o link renovado para tocar (0 = nenhum).
var refresh_play: u64 = 0;
/// Onde está a mensagem dele (para parar quando a conversa sai da tela).
var canal: types.Id = 0;
var mensagem: types.Id = 0;
var drawn = false;
var last_drawn_ms: i64 = 0;
/// A velocidade dos anexos de áudio (as mensagens de voz tocam em 1x).
var vel_idx: usize = 0;
/// As barras do visualizador na tela (sobem e descem suavizadas).
var viz: [bandas.n]f32 = @splat(0);

/// Para o QA: quadros em que o visualizador andou e redesenhos pedidos pelo player.
var qa_viz_frames: u32 = 0;
var qa_wakes: u32 = 0;

pub fn keyOf(msg_id: types.Id, index: usize) u64 {
    return std.hash.Wyhash.hash(msg_id, std.mem.asBytes(&index));
}

/// O áudio que um cartão desenha.
pub const Alvo = struct {
    key: u64,
    /// O link como veio na mensagem (o renovado sai de media_refresh).
    url: []const u8,
    tipo: Tipo,
    msg_id: types.Id,
    canal: types.Id,
};

/// O estado do áudio de um cartão neste quadro.
pub const Vista = struct {
    mine: bool,
    playing: bool,
    loading: bool,
    pos_ms: u32,
    /// 0 = ainda não se sabe.
    dur_ms: u32,
    falha: Falha,
};

/// Começa (ou continua de `from_ms`) a tocar o áudio de `alvo`. `frac` ≥ 0: começa
/// nessa fração do arquivo (quando a duração ainda não é conhecida).
pub fn tocar(ctx: *d.Ctx, alvo: Alvo, from_ms: u32, frac: f32) bool {
    stopRun();
    if (alvo.key != active) {
        if (blob) |b| b.release();
        blob = null;
        active = alvo.key;
        dur_ms = duracao(alvo.key);
    }
    kind = alvo.tipo;
    canal = alvo.canal;
    mensagem = alvo.msg_id;
    failed_key = 0;
    falha = .nenhuma;
    // No QA o som vai para o driver mudo, como o vídeo.
    if (qa.on()) voz_audio.force_dummy = true;
    // Um som por vez: o vídeo tocando pausa.
    @import("video.zig").pause();
    const url = media_refresh.global.resolve(alvo.url);
    const r = alloc.create(Run) catch return false;
    r.* = .{
        .url = alloc.dupe(u8, url) catch {
            alloc.destroy(r);
            return false;
        },
        .wake_type = ctx.images.wake_type,
        .blob = if (blob) |b| b.retain() else null,
        .start_ms = from_ms,
        .start_frac = frac,
        .pos_ms = .init(from_ms),
        .speed = .init(if (alvo.tipo == .arquivo) velocidades[vel_idx] else 100),
    };
    _ = live.fetchAdd(1, .acq_rel);
    const t = c.SDL_CreateThread(worker, "audio", r) orelse {
        _ = live.fetchSub(1, .release);
        r.refs.store(1, .monotonic);
        r.release();
        return false;
    };
    c.SDL_DetachThread(t);
    run = r;
    pos_ms = from_ms;
    drawn = true;
    last_drawn_ms = ctx.now_ms;
    return true;
}

/// Para a thread (pausa): ela fecha o stream e solta o que é dela.
fn stopRun() void {
    const r = run orelse return;
    run = null;
    r.stop.store(true, .release);
    if (r.fresh.swap(null, .acq_rel)) |b| {
        if (blob == null) blob = b else b.release();
    }
    r.release();
}

/// Pausa o que está tocando (o botão, a bandeja, a conversa que saiu da tela).
pub fn pausar() void {
    stopRun();
}

/// A janela foi para a bandeja: pausa, sem esquecer onde estava.
pub fn pause() void {
    stopRun();
}

/// O estado da thread chega na interface (só para o áudio ativo, desenhado).
fn sync(ctx: *d.Ctx, alvo: Alvo) void {
    colherJob();
    const r = run orelse return;
    if (r.fresh.swap(null, .acq_rel)) |b| {
        if (blob == null) blob = b else b.release();
    }
    const dm = r.dur_ms.load(.acquire);
    if (dm > 0) {
        dur_ms = dm;
        memoNovo(active).dur_ms = dm;
    }
    switch (r.state.load(.acquire)) {
        .loading, .playing => {
            if (!scrubbing) pos_ms = r.pos_ms.load(.acquire);
        },
        .done => {
            run = null;
            r.release();
            pos_ms = 0;
        },
        .failed => {
            run = null;
            const why = r.falha.load(.acquire);
            r.release();
            pos_ms = 0;
            const res = &media_refresh.global;
            // Link vencido: pede o novo e toca de novo quando chegar (uma vez).
            if (why == .baixar) {
                const ro = res.requestOpen(alvo.url, @divTrunc(ctx.now_ms, 1000));
                if (ro.pending) {
                    if (ro.notify) ctx.act(.refresh_media);
                    refresh_play = active;
                    return;
                }
            }
            failed_key = active;
            falha = why;
            // Sem FFmpeg o cartão volta a ser de arquivo e explica; o resto ganha um aviso.
            if (why == .ffmpeg) {
                sem_ffmpeg[sem_ffmpeg_next] = active;
                sem_ffmpeg_next = (sem_ffmpeg_next + 1) % sem_ffmpeg.len;
                gen +%= 1;
                return;
            }
            if (alvo.tipo == .voz) {
                ctx.st.showToast(ctx.now_ms, true, "não deu para tocar a mensagem de voz", "couldn't play the voice message", .{});
            } else switch (why) {
                .grande => ctx.st.showToast(ctx.now_ms, true, "áudio grande demais para tocar aqui", "audio too large to play here", .{}),
                .formato => ctx.st.showToast(ctx.now_ms, true, "não deu para ler este áudio", "couldn't read this audio", .{}),
                .baixar => ctx.st.showToast(ctx.now_ms, true, "não deu para baixar o áudio", "couldn't download the audio", .{}),
                else => ctx.st.showToast(ctx.now_ms, true, "não deu para tocar o áudio", "couldn't play the audio", .{}),
            }
        },
    }
}

/// Uma vez por quadro, de quem desenha o áudio `alvo`: o estado da thread chega
/// aqui e o cartão fica sabendo o que mostrar.
pub fn ver(ctx: *d.Ctx, alvo: Alvo, dur_hint: u32) Vista {
    const mine = alvo.key == active;
    if (mine) {
        drawn = true;
        last_drawn_ms = ctx.now_ms;
        sync(ctx, alvo);
        if (blob != null) medirOnda(ctx.images.wake_type);
    }
    const res = &media_refresh.global;
    // O link novo chegou depois de uma falha: toca de novo, do começo.
    if (mine and refresh_play == alvo.key and res.open_ready and res.takeOpen(alvo.url)) {
        refresh_play = 0;
        _ = tocar(ctx, alvo, 0, -1);
    }
    const playing = mine and run != null;
    const total: u32 = if (mine and dur_ms > 0) dur_ms else if (duracao(alvo.key) > 0) duracao(alvo.key) else dur_hint;
    return .{
        .mine = mine,
        .playing = playing,
        .loading = playing and run.?.state.load(.acquire) == .loading,
        .pos_ms = if (mine) (if (total > 0) @min(pos_ms, total) else pos_ms) else 0,
        .dur_ms = total,
        .falha = if (failed_key == alvo.key) falha else .nenhuma,
    };
}

/// O play/pause de um cartão.
pub fn alternar(ctx: *d.Ctx, alvo: Alvo, v: Vista) bool {
    if (v.playing) {
        stopRun();
        return true;
    }
    const from = if (v.mine and v.pos_ms < v.dur_ms -| 250) v.pos_ms else 0;
    return tocar(ctx, alvo, from, -1);
}

/// Clique ou arrasto na barra, em `target` ms (ou na fração `frac` sem duração
/// conhecida). `solto`: o dedo saiu (a busca vale); senão só mostra o ponto.
pub fn buscar(ctx: *d.Ctx, alvo: Alvo, target: u32, total: u32, frac: f32, solto: bool) void {
    if (total == 0) {
        // Sem duração ainda (nunca tocou): começa a tocar já no ponto.
        if (solto) _ = tocar(ctx, alvo, 0, frac);
        return;
    }
    if (alvo.key != active) {
        // Outro áudio: este passa a ser o escolhido, parado no ponto.
        stopRun();
        if (blob) |b| b.release();
        blob = null;
        active = alvo.key;
        kind = alvo.tipo;
        canal = alvo.canal;
        mensagem = alvo.msg_id;
        dur_ms = total;
        failed_key = 0;
    }
    pos_ms = target;
    scrubbing = !solto;
    if (run) |rr| {
        if (solto) rr.seek_ms.store(target, .release);
    }
}

/// O dedo saiu da barra sem clique (arrasto que terminou fora dela).
pub fn soltar(key: u64) void {
    if (key == active) scrubbing = false;
}

/// Pula `delta` ms a partir de onde está (as setas do teclado).
pub fn pular(ctx: *d.Ctx, alvo: Alvo, v: Vista, delta: i64) void {
    if (v.dur_ms == 0) return;
    const at: i64 = @as(i64, v.pos_ms) + delta;
    const target: u32 = @intCast(std.math.clamp(at, 0, @as(i64, v.dur_ms)));
    buscar(ctx, alvo, target, v.dur_ms, 0, true);
}

/// Teclado com o mouse em cima do cartão e nenhum campo de texto com o foco
/// (como a navegação vim): espaço toca ou pausa, ← e → voltam ou avançam 5 s.
pub fn teclas(ctx: *d.Ctx, alvo: Alvo, v: Vista, hovered: bool) void {
    if (!hovered or ctx.io.*.WantTextInput or ctx.io.*.KeyCtrl or ctx.io.*.KeyAlt) return;
    if (c.ImGui_IsKeyPressedEx(c.ImGuiKey_Space, false)) {
        _ = alternar(ctx, alvo, v);
    } else if (c.ImGui_IsKeyPressed(c.ImGuiKey_LeftArrow)) {
        pular(ctx, alvo, v, -5000);
    } else if (c.ImGui_IsKeyPressed(c.ImGuiKey_RightArrow)) {
        pular(ctx, alvo, v, 5000);
    }
}

pub fn velocidade() u16 {
    return velocidades[vel_idx];
}

/// A próxima velocidade (1x → 1,5x → 2x → 1x), valendo na hora se estiver tocando.
pub fn trocarVelocidade() void {
    vel_idx = (vel_idx + 1) % velocidades.len;
    if (run) |r| if (kind == .arquivo) r.speed.store(velocidades[vel_idx], .release);
}

/// As barras do visualizador (0–1), já suavizadas neste quadro.
pub fn barras() *const [bandas.n]f32 {
    return &viz;
}

/// O visualizador deste cartão anda neste quadro? Quem desenha chama depois de
/// `ver`; as faixas vêm da thread só enquanto isso for verdade. Também pede o
/// próximo redesenho: 25 por segundo com o visualizador, senão só quando o tempo
/// ou a próxima barra mudam (`n_barras` da forma de onda).
pub fn animar(ctx: *d.Ctx, v: Vista, quer_viz: bool, n_barras: usize) bool {
    if (!v.mine) return false;
    const on = v.playing and !v.loading and quer_viz and ctx.st.window_focused and !anim.instant;
    if (run) |r| r.viz.store(on, .release);
    const dt = anim.dt;
    var moved = false;
    for (&viz, 0..) |*b, i| {
        const alvo: f32 = if (on) @as(f32, @floatFromInt(run.?.bands[i].load(.monotonic))) / 255 else 0;
        const next = if (anim.instant) alvo else bandas.suavizar(b.*, alvo, dt);
        if (next != b.*) moved = true;
        b.* = next;
    }
    if (on) {
        qa_viz_frames +%= 1;
        anim.at(ctx.now_ms + 40);
        qa_wakes +%= 1;
    } else if (v.playing) {
        if (v.loading) {
            // Baixando: a thread acorda o app quando começa a tocar; a rodinha anda devagar.
            if (!anim.instant) anim.every(50);
        } else {
            const vel = @as(f32, @floatFromInt(if (kind == .arquivo) velocidade() else 100)) / 100;
            anim.at(ctx.now_ms + onda.proximaMudanca(v.pos_ms, v.dur_ms, n_barras, vel));
        }
        qa_wakes +%= 1;
    } else if (moved) {
        // Pausou: as barras descem até zerar e param.
        anim.at(ctx.now_ms + 40);
        qa_wakes +%= 1;
    }
    return on;
}

/// Uma vez por quadro, depois de desenhar. O áudio que não apareceu: o
/// visualizador para; se a conversa dele não está mais na tela (`perto` falso:
/// outro canal ou aba, ou a mensagem saiu da memória), pausa. Parado e fora da tela
/// por 1 min, o arquivo baixado é solto (a posição fica).
pub fn endFrame(now_ms: i64, perto: bool) void {
    if (active == 0) return;
    if (!drawn) {
        if (run) |r| {
            r.viz.store(false, .release);
            if (!perto) stopRun();
        }
        if (run == null and blob != null and job == null) {
            if (now_ms - last_drawn_ms > 60_000) {
                blob.?.release();
                blob = null;
            } else anim.at(last_drawn_ms + 60_001);
        }
    }
    drawn = false;
}

/// Onde está a mensagem do áudio tocando agora (null = nada tocando).
pub fn tocandoEm() ?struct { canal: types.Id, msg: types.Id } {
    if (run == null) return null;
    return .{ .canal = canal, .msg = mensagem };
}

/// Fecha tudo ao sair do app (antes do libcurl e do SDL).
pub fn shutdown() void {
    stopRun();
    if (job) |j| {
        j.stop.store(true, .release);
        j.release();
        job = null;
    }
    if (blob) |b| b.release();
    blob = null;
    var waited: u32 = 0;
    while (live.load(.acquire) > 0 and waited < 3000) : (waited += 5) c.SDL_Delay(5);
}

/// Para o QA: tocando agora, a posição, a duração (ms) e o visualizador.
pub const Info = struct {
    active: u64,
    tipo: Tipo,
    playing: bool,
    loading: bool,
    pos_ms: u32,
    dur_ms: u32,
    has_file: bool,
    speed: u16,
    falha: Falha,
    failed_key: u64,
    viz_frames: u32,
    wakes: u32,
    /// A barra mais alta do visualizador agora (0–255).
    viz_top: u8,
    onda: bool,
};

pub fn info() Info {
    var top: f32 = 0;
    for (viz) |b| top = @max(top, b);
    return .{
        .active = active,
        .tipo = kind,
        .playing = run != null,
        .loading = if (run) |r| r.state.load(.acquire) == .loading else false,
        .pos_ms = pos_ms,
        .dur_ms = dur_ms,
        .has_file = blob != null,
        .speed = if (run) |r| r.speed.load(.acquire) else velocidade(),
        .falha = falha,
        .failed_key = failed_key,
        .viz_frames = qa_viz_frames,
        .wakes = qa_wakes,
        .viz_top = @intFromFloat(@round(top * 255)),
        .onda = formaDeOnda(active) != null,
    };
}

// --- Desenho do visualizador ------------------------------------------------------

/// As barras em fila, de baixo para cima, dentro de `r`.
pub fn desenharFila(dl: *c.ImDrawList, r: d.Rect, col: d.Rgba) void {
    const n: f32 = @floatFromInt(bandas.n);
    const step = r.w / n;
    const bw = @max(step * 0.62, 1.5);
    for (viz, 0..) |v, i| {
        const h = @max(2, v * r.h);
        const x = r.x + step * @as(f32, @floatFromInt(i)) + (step - bw) / 2;
        d.rect(dl, .{ .x = x, .y = r.bottom() - h, .w = bw, .h = h }, col.alpha(0.55 + 0.45 * v), bw / 2);
    }
}

/// As barras em volta de um círculo (o botão de tocar das mensagens de voz):
/// começam em `r0` e crescem até `len` para fora.
pub fn desenharAnel(dl: *c.ImDrawList, cx: f32, cy: f32, r0: f32, len: f32, col: d.Rgba) void {
    const n: usize = bandas.n;
    for (0..n) |i| {
        // As graves embaixo, subindo pelos dois lados (espelhado).
        const v = viz[if (i < n / 2) i * 2 else (n - 1 - i) * 2 + 1];
        if (v < 0.02) continue;
        const ang = std.math.pi / 2.0 + 2 * std.math.pi * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
        const ux = @cos(ang);
        const uy = @sin(ang);
        const a = r0;
        const b = r0 + 1 + v * len;
        d.line(dl, cx + ux * a, cy + uy * a, cx + ux * b, cy + uy * b, col.alpha(0.4 + 0.6 * v), 2);
    }
}
