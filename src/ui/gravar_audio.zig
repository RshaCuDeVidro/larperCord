//! Gravar áudio na caixa de texto: o botão do microfone ao lado das opções (ou
//! Ctrl+Shift+R, que dá para trocar), a barra que fica no lugar da caixa com o
//! tempo, o nível ao vivo, Cancelar e Enviar (Esc e Enter), e quem grava. O
//! microfone é o da página Voz, com o volume, o passa-altas e a supressão de
//! ruído de lá. A gravação vira Opus mono a 32 kbit/s num Ogg
//! (core/ogg_escrita.zig) e vai como um anexo comum (.ogg), pelo mesmo caminho
//! de qualquer arquivo da bandeja: nada de mensagem de voz do Discord.
//!
//! A thread só existe enquanto grava: abre o microfone (pode levar centenas de
//! milissegundos, longe da interface), lê um quadro de 20 ms por vez, codifica
//! e monta o Ogg na memória. Numa call não grava (o microfone é dela). No QA
//! nenhum dispositivo abre: um sinal sintético faz o papel do microfone.
const std = @import("std");
const c = @import("c");
const d = @import("draw.zig");
const anim = @import("anim.zig");
const qa = @import("qa.zig");
const i18n = @import("i18n.zig");
const icons = @import("icons.zig");
const teclas = @import("teclas.zig");
const types = @import("../core/types.zig");
const voz = @import("../core/voz.zig");
const g = @import("../core/gravacao.zig");
const ogg = @import("../core/ogg_escrita.zig");
const voz_audio = @import("../net/voz_audio.zig");
const sys = @import("../platform/sys.zig");
const nowMs = @import("../net/fake_gateway.zig").nowMs;
const Id = types.Id;

const alloc = std.heap.c_allocator;
const Atomic = std.atomic.Value;

// --- O codificador ---------------------------------------------------------------

/// libopus (mono, 48 kHz, voz, 32 kbit/s, quadros de 20 ms) num Ogg Opus.
pub const Encoder = struct {
    enc: *c.OpusEncoder,
    w: ogg.Writer,
    pre_skip: u16,
    /// Amostras gravadas (sem o silêncio do fim) e as de todos os pacotes.
    samples: u64 = 0,
    coded: u64 = 0,
    in_page: u32 = 0,

    pub fn init(serial: u32) !Encoder {
        var err: c_int = 0;
        const enc = c.opus_encoder_create(@intCast(g.rate), 1, c.OPUS_APPLICATION_VOIP, &err) orelse return error.Opus;
        errdefer c.opus_encoder_destroy(enc);
        _ = c.opus_encoder_ctl(enc, c.OPUS_SET_BITRATE_REQUEST, @as(c_int, g.bitrate));
        _ = c.opus_encoder_ctl(enc, c.OPUS_SET_SIGNAL_REQUEST, @as(c_int, c.OPUS_SIGNAL_VOICE));
        // Gravar não tem pressa: a melhor qualidade custa pouco num canal só.
        _ = c.opus_encoder_ctl(enc, c.OPUS_SET_COMPLEXITY_REQUEST, @as(c_int, 10));
        var look: c.opus_int32 = 0;
        _ = c.opus_encoder_ctl(enc, c.OPUS_GET_LOOKAHEAD_REQUEST, &look);
        var e: Encoder = .{ .enc = enc, .w = .init(alloc, serial), .pre_skip = @intCast(std.math.clamp(look, 0, 65535)) };
        errdefer e.w.deinit();
        // Os dois cabeçalhos, cada um na sua página (RFC 7845).
        var hb: [19]u8 = undefined;
        try e.w.packet(ogg.opusHead(&hb, 1, e.pre_skip, g.rate), 0, false);
        try e.w.flush();
        const tags = try ogg.opusTags(alloc, "larperCord", &.{});
        defer alloc.free(tags);
        try e.w.packet(tags, 0, false);
        try e.w.flush();
        return e;
    }

    pub fn deinit(e: *Encoder) void {
        c.opus_encoder_destroy(e.enc);
        e.w.deinit();
    }

    /// Um quadro de 20 ms.
    pub fn push(e: *Encoder, pcm: *const [g.frame]i16) !void {
        try e.encode(pcm, null);
        e.samples += g.frame;
    }

    /// `end`: o último pacote, com a granule do fim do áudio.
    fn encode(e: *Encoder, pcm: *const [g.frame]i16, end: ?u64) !void {
        var pkt: [1500]u8 = undefined;
        const n = c.opus_encode(e.enc, pcm, @intCast(g.frame), &pkt, pkt.len);
        if (n < 0) return error.Opus;
        e.coded += g.frame;
        try e.w.packet(pkt[0..@intCast(n)], end orelse e.coded, end != null);
        e.in_page += 1;
        if (end == null and e.in_page >= g.packets_per_page) {
            try e.w.flush();
            e.in_page = 0;
        }
    }

    /// Esvazia o atraso do codificador com silêncio e fecha o arquivo (a granule
    /// do fim corta o que passou do gravado). Quem chama fica com os bytes.
    pub fn finish(e: *Encoder) ![]u8 {
        const zero: [g.frame]i16 = @splat(0);
        const tail = g.tailFrames(e.pre_skip);
        for (1..tail) |_| try e.encode(&zero, null);
        try e.encode(&zero, g.endGranule(e.pre_skip, e.samples));
        return e.w.out.toOwnedSlice(alloc);
    }
};

/// Para o QA: codifica `pcm` (mono, 48 kHz) inteiro, como a gravação faz.
pub fn encodeAll(pcm: []const i16) ![]u8 {
    var e = try Encoder.init(0x51A7);
    defer e.deinit();
    var i: usize = 0;
    while (i < pcm.len) : (i += g.frame) {
        var f: [g.frame]i16 = @splat(0);
        const n = @min(g.frame, pcm.len - i);
        @memcpy(f[0..n], pcm[i..][0..n]);
        try e.push(&f);
    }
    return e.finish();
}

// --- Quem grava (thread curta) ---------------------------------------------------

const Stop = enum(u8) { none, keep, drop };
const Phase = enum(u8) { starting, recording, full, failed, done };
const Fail = enum(u8) { none, mic, silent, codec };

/// Barras ao vivo guardadas (a barra mais larga não passa disso).
const ring_len = 160;

/// Uma gravação, da interface e da thread (cada uma solta a sua parte).
const Rec = struct {
    refs: Atomic(u32) = .init(2),
    stop: Atomic(Stop) = .init(.none),
    phase: Atomic(Phase) = .init(.starting),
    why: Atomic(Fail) = .init(.none),
    frames: Atomic(u32) = .init(0),
    bars: [ring_len]Atomic(u8) = @splat(.init(0)),
    n_bars: Atomic(u32) = .init(0),
    /// O arquivo pronto, depois de `done` (quem esperou a thread fica com ele).
    file: []u8 = &.{},
    /// O sinal sintético no lugar do microfone (QA).
    fake: bool,
    serial: u32,

    fn release(r: *Rec) void {
        if (r.refs.fetchSub(1, .acq_rel) != 1) return;
        if (r.file.len > 0) alloc.free(r.file);
        alloc.destroy(r);
    }
};

/// Threads vivas (o app espera por elas ao fechar).
var live: Atomic(u32) = .init(0);

fn worker(p: ?*anyopaque) callconv(.c) c_int {
    const r: *Rec = @ptrCast(@alignCast(p.?));
    defer {
        r.release();
        _ = live.fetchSub(1, .release);
    }
    record(r) catch |e| {
        r.why.store(switch (e) {
            error.Mic => .mic,
            error.Silent => .silent,
            else => .codec,
        }, .release);
        r.phase.store(.failed, .release);
    };
    return 0;
}

fn record(r: *Rec) !void {
    var enc = try Encoder.init(r.serial);
    defer enc.deinit();
    var cap: voz.Capture = .{};
    defer cap.release();
    const real = !r.fake;
    if (real and !voz_audio.acquire()) return error.Mic;
    defer if (real) voz_audio.release();
    var mic: voz_audio.Mic = .{};
    defer mic.close();
    if (real) {
        mic.open(nowMs());
        if (mic.stream == null) return error.Mic;
    }
    r.phase.store(.recording, .release);
    const t0 = c.SDL_GetTicks();
    var synth: Synth = .{};
    var made: u64 = 0;
    var stereo: [voz.frame_len]i16 = undefined;
    var mono: [g.frame]i16 = undefined;
    var frames: u32 = 0;
    var peak: u8 = 0;
    var in_bar: u32 = 0;
    while (true) {
        switch (r.stop.load(.acquire)) {
            .drop => return,
            .keep => break,
            .none => {},
        }
        while (frames < g.max_frames) {
            if (real) {
                if (!mic.read(&stereo)) break;
            } else {
                // Em tempo real, como um microfone: um quadro a cada 20 ms.
                if (made >= (c.SDL_GetTicks() - t0) / g.frame_ms) break;
                synth.frame(&stereo);
                made += 1;
            }
            // O que a página Voz escolheu, menos a porta (cortaria as pausas).
            var cfg = voz_audio.sh.captureCfg();
            cfg.gate = false;
            _ = cap.process(&stereo, cfg);
            g.toMono(&stereo, &mono);
            try enc.push(&mono);
            frames += 1;
            r.frames.store(frames, .release);
            peak = @max(peak, g.level(&mono));
            in_bar += 1;
            if (in_bar == g.frames_per_bar) {
                const n = r.n_bars.load(.monotonic);
                r.bars[n % ring_len].store(peak, .monotonic);
                r.n_bars.store(n + 1, .release);
                in_bar = 0;
                peak = 0;
            }
        }
        if (frames >= g.max_frames) {
            // No teto: o microfone fecha (nada mais é lido) e o arquivo espera Enviar.
            if (r.phase.load(.acquire) != .full) {
                mic.close();
                r.phase.store(.full, .release);
            }
        } else if (real) {
            mic.check(nowMs());
            // Aberto, mas nada chega: microfone mudo ou sem permissão no sistema.
            if (frames == 0 and c.SDL_GetTicks() - t0 > 3000) return error.Silent;
        }
        c.SDL_Delay(10);
    }
    r.file = try enc.finish();
    r.phase.store(.done, .release);
}

/// O microfone do QA: uma voz sintética com sílabas e pausas (como a mensagem
/// de voz da demonstração), em estéreo como o microfone de verdade chega.
const Synth = struct {
    phase: f32 = 0,
    n: u64 = 0,

    fn frame(s: *Synth, out: *[voz.frame_len]i16) void {
        const fr: f32 = @floatFromInt(g.rate);
        var i: usize = 0;
        while (i < out.len) : (i += 2) {
            const t = @as(f32, @floatFromInt(s.n)) / fr;
            s.n += 1;
            const syl = @abs(@sin(t * std.math.pi * 2.6));
            const f0 = 170 + 60 * @sin(t * 3.1);
            s.phase = @mod(s.phase + 2 * std.math.pi * f0 / fr, 2 * std.math.pi);
            const v = (@sin(s.phase) + 0.4 * @sin(s.phase * 2) + 0.2 * @sin(s.phase * 3)) * syl * syl * 0.35;
            const x: i16 = @intFromFloat(std.math.clamp(v, -1, 1) * 32767);
            out[i] = x;
            out[i + 1] = x;
        }
    }
};

// --- O que a interface lembra ----------------------------------------------------

var rec: ?*Rec = null;
var thread: ?*c.SDL_Thread = null;
var rec_channel: Id = 0;
/// Quando começou (relógio da interface): o Cancelar fica onde estava o
/// microfone, e um clique duplo nele não pode jogar fora o que acabou de começar.
var started_ms: i64 = 0;
const click_guard_ms = 350;
/// O atalho foi apertado neste quadro ou no anterior: o botão (ou a barra) atende.
var key_frame: c_int = -10;

/// O atalho (ui/root.zig): começa a gravar ou, gravando, envia. Quem atende é
/// o botão da caixa no quadro seguinte, com as mesmas regras do clique.
pub fn shortcut() void {
    key_frame = c.ImGui_GetFrameCount();
}

fn takeKey() bool {
    if (c.ImGui_GetFrameCount() - key_frame > 1) return false;
    key_frame = -10;
    return true;
}

/// Gravando nesta conversa?
pub fn recordingIn(ch: Id) bool {
    return rec != null and rec_channel == ch;
}

fn start(ctx: *d.Ctx, ch: Id) void {
    if (rec != null) return;
    // No QA, nem o driver de áudio de verdade: o sinal sintético não abre nada.
    if (qa.on()) voz_audio.force_dummy = true;
    const r = alloc.create(Rec) catch return;
    r.* = .{ .fake = qa.on(), .serial = c.SDL_rand_bits() };
    _ = live.fetchAdd(1, .acq_rel);
    const t = c.SDL_CreateThread(worker, "gravar-audio", r) orelse {
        _ = live.fetchSub(1, .release);
        alloc.destroy(r);
        return ctx.st.showToast(ctx.now_ms, true, "não deu para começar a gravar", "couldn't start recording", .{});
    };
    rec = r;
    thread = t;
    rec_channel = ch;
    started_ms = ctx.now_ms;
    _ = qa_stats.starts.fetchAdd(1, .monotonic);
}

/// Joga fora: a thread para sozinha e solta a parte dela.
fn discard() void {
    const r = rec orelse return;
    rec = null;
    r.stop.store(.drop, .release);
    if (thread) |t| c.SDL_DetachThread(t);
    thread = null;
    r.release();
    _ = qa_stats.discards.fetchAdd(1, .monotonic);
}

/// Para e espera a thread fechar o arquivo (uma volta dela, uns 10 ms).
fn finish() ?[]u8 {
    const r = rec orelse return null;
    rec = null;
    r.stop.store(.keep, .release);
    if (thread) |t| c.SDL_WaitThread(t, null);
    thread = null;
    defer r.release();
    if (r.phase.load(.acquire) != .done) return null;
    const f = r.file;
    r.file = &.{};
    return f;
}

/// A cada quadro, no começo da caixa: trocou de conversa, entrou numa call ou o
/// microfone falhou, a gravação acaba (com o motivo).
pub fn watch(ctx: *d.Ctx) void {
    const r = rec orelse return;
    const st = ctx.st;
    if ((st.activeChannel() orelse 0) != rec_channel or st.friends) {
        discard();
        return st.showToast(ctx.now_ms, false, "gravação descartada: você saiu da conversa", "recording discarded: you left the conversation", .{});
    }
    if (st.voice != null) {
        discard();
        return st.showToast(ctx.now_ms, true, "gravação descartada: você entrou numa call", "recording discarded: you joined a call", .{});
    }
    if (r.phase.load(.acquire) == .failed) {
        const why = r.why.load(.acquire);
        discard();
        switch (why) {
            .silent => st.showToast(ctx.now_ms, true, "o microfone não está mandando som (veja Configurações → Voz)", "the microphone isn't sending any sound (see Settings → Voice)", .{}),
            .codec => st.showToast(ctx.now_ms, true, "não deu para gravar o áudio", "couldn't record the audio", .{}),
            else => st.showToast(ctx.now_ms, true, "o microfone não abriu (veja Configurações → Voz)", "the microphone didn't open (see Settings → Voice)", .{}),
        }
        return;
    }
    // O relógio e as barras andam uns 20 quadros por segundo, só enquanto grava.
    anim.every(50);
}

/// Fecha tudo ao sair do app (antes do SDL).
pub fn shutdown() void {
    discard();
    var waited: u32 = 0;
    while (live.load(.acquire) > 0 and waited < 3000) : (waited += 5) c.SDL_Delay(5);
    var b: [512]u8 = undefined;
    // Só sai se estiver vazia (um áudio ainda na bandeja fica).
    if (dirPath(&b)) |dir| _ = c.SDL_RemovePath(dir.ptr);
}

/// Para o QA: o que a gravação está fazendo agora e quantas começaram e foram
/// jogadas fora.
pub const qa_stats = struct {
    pub var starts: Atomic(u32) = .init(0);
    pub var discards: Atomic(u32) = .init(0);
    pub var sent: Atomic(u32) = .init(0);
};
pub const Info = struct { active: bool, recording: bool, ms: u32, bars: u32, full: bool };
pub fn info() Info {
    const r = rec orelse return .{ .active = false, .recording = false, .ms = 0, .bars = 0, .full = false };
    const ph = r.phase.load(.acquire);
    return .{ .active = true, .recording = ph == .recording or ph == .full, .ms = r.frames.load(.acquire) * g.frame_ms, .bars = r.n_bars.load(.acquire), .full = ph == .full };
}

// --- O arquivo -------------------------------------------------------------------

fn dirPath(buf: []u8) ?[:0]const u8 {
    return std.fmt.bufPrintSentinel(buf, "{s}/{s}{d}", .{ sys.tempDir(), types.recorded_dir_prefix, c.getpid() }, 0) catch null;
}

/// Grava o Ogg na pasta temporária nossa, com o nome que vai para o Discord.
/// O caminho volta alocado (c_allocator); quem manda apaga depois de enviado.
fn save(bytes: []const u8) ?[:0]u8 {
    var db: [512]u8 = undefined;
    const dir = dirPath(&db) orelse return null;
    sys.mkdirPrivate(dir.ptr);
    var t: c.SDL_Time = 0;
    _ = c.SDL_GetCurrentTime(&t);
    var dt: c.SDL_DateTime = undefined;
    if (!c.SDL_TimeToDateTime(t, &dt, true)) return null;
    const when: g.When = .{ .year = @intCast(dt.year), .month = @intCast(dt.month), .day = @intCast(dt.day), .hour = @intCast(dt.hour), .minute = @intCast(dt.minute) };
    var n: u8 = 1;
    while (n < 100) : (n += 1) {
        var nb: [64]u8 = undefined;
        var pb: [600]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&pb, "{s}/{s}", .{ dir, g.fileName(&nb, when, n) }, 0) catch return null;
        // Outro no mesmo minuto ainda na bandeja: este ganha "-2".
        if (sys.fileSize(path.ptr) != null) continue;
        if (!c.SDL_SaveFile(path.ptr, bytes.ptr, bytes.len)) return null;
        return alloc.dupeSentinel(u8, path, 0) catch null;
    }
    return null;
}

/// Enviar: fecha o arquivo, grava e manda (core: App.sendRecording).
fn send(ctx: *d.Ctx) void {
    const r = rec orelse return;
    const ms = r.frames.load(.acquire) * g.frame_ms;
    const ph = r.phase.load(.acquire);
    if ((ph != .recording and ph != .full) or ms < g.min_ms) {
        discard();
        return ctx.st.showToast(ctx.now_ms, false, "gravação curta demais: nada foi enviado", "recording too short: nothing was sent", .{});
    }
    const bytes = finish() orelse return ctx.st.showToast(ctx.now_ms, true, "não deu para gravar o áudio", "couldn't record the audio", .{});
    defer alloc.free(bytes);
    const path = save(bytes) orelse return ctx.st.showToast(ctx.now_ms, true, "não consegui salvar o áudio para enviar", "couldn't save the audio to send", .{});
    _ = qa_stats.sent.fetchAdd(1, .monotonic);
    ctx.act(.{ .send_recording = path });
    ctx.st.focus_input = true;
}

// --- Na caixa de texto -----------------------------------------------------------

/// O botão aparece (Configurações → Chat): nunca no navegador (sem codificador) nem
/// editando uma mensagem.
pub fn showsButton(ctx: *const d.Ctx) bool {
    return ctx.st.settings.record_audio and !sys.web and ctx.st.editing == 0;
}

/// Por que não dá para gravar aqui agora (null = dá). O que impede de mandar
/// qualquer mensagem já tirou a caixa da tela (ui/composer_limits.zig).
fn blocked(ctx: *const d.Ctx, ch: *const types.Channel) ?[]const u8 {
    if (ctx.st.voice != null) return i18n.tr("Numa call o microfone é dela: saia da call para gravar áudio.", "In a call the microphone is in use: leave the call to record audio.");
    if (ch.guild != 0 and ctx.store.channelPermissions(ch) & types.perm.attach_files == 0)
        return i18n.tr("Você não tem permissão para enviar arquivos neste canal.", "You don't have permission to attach files in this channel.");
    return null;
}

/// O botão do microfone na caixa (`prompt`: o estilo de texto dos temas de terminal).
pub fn button(ctx: *d.Ctx, dl: *c.ImDrawList, fam: anytype, r: d.Rect, prompt: bool, ch: *const types.Channel) void {
    const why = blocked(ctx, ch);
    const hb = d.hit(ctx, 41, r);
    qa.mark(r, "composer-record", .{});
    const ink = if (why != null) ctx.col(.faint).alpha(0.6) else if (hb.hovered) ctx.col(.text) else ctx.col(.muted);
    if (prompt) {
        const fs = ctx.th.font_size;
        d.text(dl, fam.get(.bold), fs, r.x + 4, d.centerY(r, fs), if (why == null and hb.hovered) ctx.col(.accent) else ink, "[rec]");
    } else icons.mic(dl, r.x + r.w / 2, r.y + r.h / 2, ink.u());
    var kb: [48]u8 = undefined;
    var tb: [96]u8 = undefined;
    const tip = why orelse i18n.fmt(&tb, "Gravar áudio  ({s})", "Record audio  ({s})", .{teclas.first(&ctx.st.teclas, .gravar_audio, &kb)});
    d.tip(ctx, r, tip, hb.hovered);
    if (hb.clicked or takeKey()) {
        if (why) |w| return ctx.st.showToast(ctx.now_ms, true, "{s}", "{s}", .{w});
        start(ctx, ch.id);
    }
}

/// A barra da gravação no lugar da caixa: tempo, nível ao vivo, Cancelar e Enviar.
pub fn bar(ctx: *d.Ctx, dl: *c.ImDrawList, fam: anytype, r: d.Rect, prompt: bool, pill: bool, round_bottom: bool) void {
    const rc = rec orelse return;
    const ph = rc.phase.load(.acquire);
    const ms = rc.frames.load(.acquire) * g.frame_ms;
    const fs = ctx.th.font_size;
    qa.mark(r, "record-bar", .{});
    if (prompt) {
        d.line(dl, r.x, r.y + 0.5, r.right(), r.y + 0.5, ctx.col(.border), 1);
    } else {
        const radius = if (pill) r.h / 2 else ctx.th.radius + 4;
        d.rectFlags(dl, r, ctx.col(.elevated), radius, if (round_bottom) c.ImDrawFlags_RoundBottom else 0);
    }
    const cy = r.y + r.h / 2;
    var x = r.x + (if (pill) @as(f32, 24) else if (prompt) @as(f32, 10) else 18);

    // O ponto vermelho pulsando (parado no teto).
    const danger = ctx.col(.danger);
    const pulse: f32 = if (ph == .recording) 0.55 + 0.45 * @abs(@sin(@as(f32, @floatFromInt(@mod(ctx.now_ms, 100_000))) / 400)) else 1;
    d.circle(dl, x + 5, cy, 5, danger.alpha(pulse));
    x += 18;

    // O tempo (vermelho perto do teto).
    var cb: [16]u8 = undefined;
    const left = g.warnLeft(ms);
    const clock = g.clock(&cb, ms);
    const cw = d.width(fam.get(.semibold), fs, clock);
    d.text(dl, fam.get(.semibold), fs, x, d.centerY(r, fs), if (left != null) danger else ctx.col(.text), clock);
    qa.mark(.{ .x = x, .y = r.y, .w = cw, .h = r.h }, "record-timer", .{});
    x += cw + 14;

    // Da direita para a esquerda: Enviar, Cancelar e o aviso.
    const f = fam.get(.semibold);
    const send_t = i18n.tr("Enviar", "Send");
    const cancel_t = i18n.tr("Cancelar", "Cancel");
    const sw = d.width(f, 13, send_t) + 26;
    const send_r: d.Rect = .{ .x = r.right() - sw - (if (pill) @as(f32, 12) else 8), .y = cy - 14, .w = sw, .h = 28 };
    const cw2 = d.width(f, 13, cancel_t) + 20;
    const cancel_r: d.Rect = .{ .x = send_r.x - cw2 - 6, .y = cy - 14, .w = cw2, .h = 28 };
    const send_h = d.hit(ctx, 43, send_r);
    const cancel_h = d.hit(ctx, 42, cancel_r);
    qa.mark(send_r, "record-send", .{});
    qa.mark(cancel_r, "record-cancel", .{});
    if (prompt) {
        d.text(dl, f, 13, send_r.x + 4, d.centerY(send_r, 13), if (send_h.hovered) ctx.col(.accent) else ctx.col(.text), send_t);
        d.text(dl, f, 13, cancel_r.x + 4, d.centerY(cancel_r, 13), if (cancel_h.hovered) ctx.col(.accent) else ctx.col(.muted), cancel_t);
    } else {
        d.rect(dl, send_r, ctx.col(.accent).mix(d.Rgba.white, if (send_h.hovered) 0.12 else 0), send_r.h / 2);
        d.text(dl, f, 13, send_r.x + 13, d.centerY(send_r, 13), ctx.col(.accent_text), send_t);
        if (cancel_h.hovered) d.rect(dl, cancel_r, ctx.col(.hover), cancel_r.h / 2);
        d.text(dl, f, 13, cancel_r.x + 10, d.centerY(cancel_r, 13), if (cancel_h.hovered) ctx.col(.text) else ctx.col(.muted), cancel_t);
    }
    d.tip(ctx, send_r, i18n.tr("Enviar como arquivo .ogg  (Enter)", "Send as an .ogg file  (Enter)"), send_h.hovered);
    d.tip(ctx, cancel_r, i18n.tr("Jogar fora a gravação  (Esc)", "Throw the recording away  (Esc)"), cancel_h.hovered);

    var note_buf: [64]u8 = undefined;
    var lb: [16]u8 = undefined;
    const note: []const u8 = if (ph == .full)
        i18n.tr("Limite de 10 min", "10 min limit")
    else if (left) |l|
        i18n.fmt(&note_buf, "faltam {s}", "{s} left", .{g.clock(&lb, l + 999)})
    else
        "";
    var wave_end = cancel_r.x - 12;
    if (note.len > 0) {
        const nw = d.width(fam.get(.regular), 12.5, note);
        wave_end -= nw;
        d.text(dl, fam.get(.regular), 12.5, wave_end, d.centerY(r, 12.5), danger, note);
        wave_end -= 12;
    }

    // O nível ao vivo: a barra mais nova à direita.
    const wr: d.Rect = .{ .x = x, .y = r.y + 9, .w = @max(wave_end - x, 0), .h = r.h - 18 };
    qa.mark(wr, "record-wave", .{});
    if (ph == .starting) {
        _ = d.textClipped(dl, fam.get(.regular), 13, wr.x, d.centerY(r, 13), ctx.col(.faint), i18n.tr("Abrindo o microfone…", "Opening the microphone…"), wr.w);
    } else {
        const step: f32 = 5;
        const fit: u32 = @intFromFloat(@max(@floor(wr.w / step), 0));
        const total = rc.n_bars.load(.acquire);
        const shown = @min(@min(fit, total), ring_len);
        const col = if (ph == .full) ctx.col(.muted) else ctx.col(.accent);
        var k: u32 = 0;
        while (k < shown) : (k += 1) {
            const v = rc.bars[(total - 1 - k) % ring_len].load(.monotonic);
            const h = @max(2, @as(f32, @floatFromInt(v)) / 255 * wr.h);
            const bx = wr.right() - step * @as(f32, @floatFromInt(k + 1)) + 1;
            d.rect(dl, .{ .x = bx, .y = cy - h / 2, .w = 3, .h = h }, col, 1.5);
        }
        // Antes da primeira barra: a linha de base, para não parecer vazio.
        if (wr.w > step * @as(f32, @floatFromInt(shown))) d.line(dl, wr.x, cy, wr.right() - step * @as(f32, @floatFromInt(shown)), cy, ctx.col(.faint).alpha(0.5), 1);
    }

    // Enter envia e Esc joga fora, a não ser que algo por cima pegue a tecla.
    const st = ctx.st;
    const over = st.popup != .none or st.palette.open or st.settings.open or ctx.io.*.WantTextInput;
    const enter = !over and (c.ImGui_IsKeyPressedEx(c.ImGuiKey_Enter, false) or c.ImGui_IsKeyPressedEx(c.ImGuiKey_KeypadEnter, false));
    const esc = !over and c.ImGui_IsKeyPressedEx(c.ImGuiKey_Escape, false);
    const armed = ctx.now_ms - started_ms >= click_guard_ms;
    if ((cancel_h.clicked and armed) or esc) return discard();
    if ((send_h.clicked and armed) or enter or takeKey()) send(ctx);
}
