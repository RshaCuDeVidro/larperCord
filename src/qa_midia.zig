//! QA da mídia (QA_SUITE=midia): mensagem de voz (tocar, pausar, buscar na
//! barra e chegar ao fim), capa de spoiler e de conteúdo sensível, link de
//! anexo vencido renovado uma vez só e a aba de figurinhas (pacotes buscados
//! só quando ela abre, a de outro servidor trancada sem Nitro, enviar) e o GIF do
//! Klipy, que anda sozinho e chega à tela sem nenhum evento. E os anexos de
//! áudio: o player no lugar do cartão (Ogg Opus, MP3 e WAV sem FFmpeg; FLAC com
//! ele), tocar, o visualizador só tocando (e nunca sem foco ou com "reduzir
//! movimento"), buscar na forma de onda, velocidade, teclado, parar ao trocar de
//! canal, o cartão de arquivo quando não dá para tocar e a CPU tocando e parado.
//! Tudo na demonstração: o #música do primeiro servidor (fake_gateway.zig).
const std = @import("std");
const c = @import("c");
const App = @import("app.zig").App;
const R = @import("qa_runner.zig");
const Op = R.Op;
const qa = @import("ui/qa.zig");
const gw = @import("net/fake_gateway.zig");
const types = @import("core/types.zig");
const voice_msg = @import("ui/voice_msg.zig");
const audio_player = @import("ui/audio_player.zig");
const audio_fonte = @import("ui/audio_fonte.zig");
const ffmpeg = @import("platform/ffmpeg.zig");
const media_cover = @import("ui/media_cover.zig");
const media_refresh = @import("core/media_refresh.zig");
const stickers = @import("core/stickers.zig");
const gif_stream = @import("ui/gif_stream.zig");
const StoredMessage = @import("core/store.zig").StoredMessage;
const Id = types.Id;

const media: Id = gw.media_channel;
const expired_url = "demo:expired:1?ex=1&is=0&hm=qa";

fn s(name: []const u8) Op {
    return .{ .section = name };
}
fn click(k: []const u8) Op {
    return .{ .click = .{ .mark = k } };
}
fn dyn(f: *const fn (*App, []u8) []const u8) Op {
    return .{ .click = .{ .dyn = f } };
}
fn expect(name: []const u8, f: *const fn (*App) bool) Op {
    return .{ .expect = .{ .name = name, .check = f, .timeout_ms = 5000 } };
}

/// A mensagem do #música com um anexo assim (pelo nome do arquivo).
fn msgWith(app: *App, filename: []const u8) ?*StoredMessage {
    const cs = app.store.channel(media) orelse return null;
    var i = cs.messages.items.len;
    while (i > 0) {
        i -= 1;
        const m = &cs.messages.items[i];
        for (m.msg.attachments) |a| if (std.mem.eql(u8, a.filename, filename)) return m;
    }
    return null;
}
fn idOf(app: *App, filename: []const u8) Id {
    return if (msgWith(app, filename)) |m| m.msg.id else 0;
}
fn markOf(buf: []u8, comptime prefix: []const u8, id: Id) []const u8 {
    if (id == 0) return "";
    return std.fmt.bufPrint(buf, prefix ++ "{d}", .{id}) catch "";
}
fn shown(comptime prefix: []const u8, id: Id) bool {
    var b: [64]u8 = undefined;
    return id != 0 and qa.find(markOf(&b, prefix, id)) != null;
}
fn jump(app: *App, filename: []const u8) void {
    const id = idOf(app, filename);
    if (id != 0) app.handle(.{ .jump_to = id });
}
fn imageReady(app: *App, key_part: []const u8) bool {
    var it = app.images.map.iterator();
    while (it.next()) |e| if (std.mem.indexOf(u8, e.key_ptr.*, key_part) != null and e.value_ptr.state == .ready) return true;
    return false;
}

// --- Mensagem de voz ------------------------------------------------------------

const voice_file = "voice-message.ogg";
fn tPlay(app: *App, buf: []u8) []const u8 {
    return markOf(buf, "voice-play:", idOf(app, voice_file));
}
fn tWave(app: *App, buf: []u8) []const u8 {
    return markOf(buf, "voice-wave:", idOf(app, voice_file));
}
fn voiceShown(app: *App) bool {
    const m = msgWith(app, voice_file) orelse return false;
    return m.msg.attachments[0].voice and shown("voice-play:", m.msg.id) and shown("voice-wave:", m.msg.id);
}
fn voicePlaying(_: *App) bool {
    const i = voice_msg.info();
    // A duração vem do Ogg (4 s menos o pre-skip) e a posição anda.
    return i.playing and i.pos_ms >= 500 and i.dur_ms > 3800 and i.dur_ms <= 4000;
}
var paused_at: u32 = 0;
fn voicePaused(_: *App) bool {
    const i = voice_msg.info();
    paused_at = i.pos_ms;
    return !i.playing and i.pos_ms > 0 and i.has_file;
}
fn pauseHolds(_: *App) bool {
    const i = voice_msg.info();
    return !i.playing and i.pos_ms == paused_at;
}
fn seekedWhilePaused(_: *App) bool {
    const i = voice_msg.info();
    return !i.playing and i.pos_ms >= 2800 and i.pos_ms <= 3200;
}
fn resumedFromSeek(_: *App) bool {
    const i = voice_msg.info();
    return i.playing and i.pos_ms >= 2900;
}
fn reachedEnd(_: *App) bool {
    const i = voice_msg.info();
    return !i.playing and i.pos_ms == 0 and i.has_file;
}
fn voiceViz(_: *App) bool {
    const i = audio_player.info();
    return i.tipo == .voz and i.playing and i.viz_frames >= snap.viz + 10 and i.viz_top > 20;
}

// --- Spoiler e sensível -----------------------------------------------------------

const spoiler_file = "SPOILER_final.png";
const sensitive_file = "foto.png";
fn tSpoiler(app: *App, buf: []u8) []const u8 {
    return markOf(buf, "cover:", idOf(app, spoiler_file));
}
fn tSensitive(app: *App, buf: []u8) []const u8 {
    return markOf(buf, "cover:", idOf(app, sensitive_file));
}
fn jumpSpoiler(app: *App) void {
    jump(app, spoiler_file);
}
fn jumpSensitive(app: *App) void {
    jump(app, sensitive_file);
}
fn spoilerCovered(app: *App) bool {
    const id = idOf(app, spoiler_file);
    return shown("cover:", id) and !media_cover.revealed(id);
}
fn spoilerRevealed(app: *App) bool {
    const id = idOf(app, spoiler_file);
    var b: [64]u8 = undefined;
    const att = std.fmt.bufPrint(&b, "att:{d}:0", .{id}) catch return false;
    return media_cover.revealed(id) and !shown("cover:", id) and qa.find(att) != null;
}
fn sensitiveCovered(app: *App) bool {
    const id = idOf(app, sensitive_file);
    return shown("cover:", id) and !media_cover.revealed(id);
}
fn sensitiveRevealed(app: *App) bool {
    const id = idOf(app, sensitive_file);
    return media_cover.revealed(id) and !shown("cover:", id) and imageReady(app, "demo:3");
}

// --- Link vencido ---------------------------------------------------------------

fn jumpExpired(app: *App) void {
    jump(app, "ontem.png");
}
fn refreshedOnce(app: *App) bool {
    return gw.sent.refreshes.load(.monotonic) == 1 and gw.sent.refresh_len.load(.monotonic) == 1 and
        std.mem.startsWith(u8, media_refresh.global.resolve(expired_url), "demo:1?ex=") and imageReady(app, "demo:1?ex=");
}
fn stillOnce(_: *App) bool {
    return gw.sent.refreshes.load(.monotonic) == 1;
}

// --- Figurinhas -------------------------------------------------------------------

fn bottom(app: *App) void {
    const sc = app.st.scrollOf(media);
    sc.stick_bottom = true;
}
fn noPacksYet(app: *App) bool {
    return gw.sent.sticker_packs.load(.monotonic) == 0 and app.store.stickers.packs_state == .none and
        app.store.stickers.guilds.get(gw.guildId(0)) != null;
}
fn packsFetched(app: *App) bool {
    return gw.sent.sticker_packs.load(.monotonic) == 1 and app.store.stickers.packs_state == .ready and
        qa.find("sticker:900501") != null and qa.find("sticker:900401") != null and qa.find("sticker:900403") != null;
}
fn externalLocked(app: *App) bool {
    const list = app.store.stickers.guilds.get(gw.guildId(1)) orelse return false;
    return app.store.premium_type == 0 and stickers.canSend(&list[0], gw.guildId(0), 0, std.math.maxInt(u64)) == .needs_nitro and qa.find("sticker:900411") != null;
}
fn nothingSent(_: *App) bool {
    return gw.sent.stickers_sent.load(.monotonic) == 0;
}
fn filtered(_: *App) bool {
    return qa.find("sticker:900503") != null and qa.find("sticker:900401") == null;
}
fn closed(app: *App) bool {
    return app.st.popup == .none;
}
fn stickerArrived(app: *App) bool {
    if (gw.sent.stickers_sent.load(.monotonic) != 1 or gw.sent.sticker_last.load(.monotonic) != 900401) return false;
    if (app.st.popup != .none) return false;
    const cs = app.store.channel(media) orelse return false;
    const items = cs.messages.items;
    if (items.len == 0) return false;
    const last = &items[items.len - 1].msg;
    return last.author == app.store.me and last.attachments.len == 1 and std.mem.eql(u8, last.attachments[0].url, "demo:sticker:900401:0");
}
fn packsNotRefetched(_: *App) bool {
    return gw.sent.sticker_packs.load(.monotonic) == 1 and qa.find("sticker:900501") != null;
}

// --- GIF do Klipy -----------------------------------------------------------------

fn jumpKlipy(app: *App) void {
    jump(app, gw.klipy_file);
}
fn tKlipy(app: *App, buf: []u8) []const u8 {
    const id = idOf(app, gw.klipy_file);
    if (id == 0) return "";
    return std.fmt.bufPrint(buf, "att:{d}:0", .{id}) catch "";
}
fn klipyBadge(app: *App) bool {
    var b: [64]u8 = undefined;
    const id = idOf(app, gw.klipy_file);
    return id != 0 and qa.find(std.fmt.bufPrint(&b, "gif-badge:{d}:0", .{id}) catch return false) != null;
}
/// A animação que a conversa desenha (o anexo aponta para o GIF longo da demonstração).
fn klipyStream(app: *App) ?*gif_stream.Stream {
    var it = app.images.map.iterator();
    while (it.next()) |e| if (std.mem.endsWith(u8, e.key_ptr.*, " demo:longgif") and e.value_ptr.state == .ready) return e.value_ptr.stream;
    return null;
}
fn klipyStreams(app: *App) bool {
    var b: [64]u8 = undefined;
    return klipyStream(app) != null and qa.find(tKlipy(app, &b)) != null and !klipyBadge(app);
}

/// O QA normalmente desenha todo quadro (lê os pixels). Aqui o portão vale de verdade e a
/// checagem, que roda depois de ele decidir, olha quadro a quadro: `hidden` conta os
/// quadros do GIF que ficaram fora da tela; `same`, os iguais que o portão pulou.
const Watch = struct { shown: u32 = 0, skipped: u64 = 0, frames: u32 = 0, hidden: u32 = 0, same: u32 = 0 };
var watch: Watch = .{};
fn watchStart(app: *App) void {
    const st = klipyStream(app) orelse return;
    watch = .{ .shown = st.shown, .skipped = app.gate.skipped };
    app.qa_real_gate = true;
}
fn watchStop(app: *App) void {
    app.qa_real_gate = false;
}
fn klipyAdvances(app: *App) bool {
    const st = klipyStream(app) orelse return false;
    const skipped = app.gate.skipped != watch.skipped;
    if (st.shown != watch.shown) {
        watch.frames +%= st.shown -% watch.shown;
        if (skipped) watch.hidden += 1;
    } else if (skipped) watch.same += 1;
    watch.shown = st.shown;
    watch.skipped = app.gate.skipped;
    // 30 ms por quadro: uns 30 quadros em pouco menos de 1 s.
    return watch.frames >= 30;
}
fn klipyReachedScreen(_: *App) bool {
    if (c.SDL_getenv("QA_DEBUG") != null) std.debug.print("[klipy] quadros {d}, fora da tela {d}, iguais pulados {d}\n", .{ watch.frames, watch.hidden, watch.same });
    return watch.frames >= 30 and watch.hidden == 0 and watch.same > 0;
}
fn klipyHoverPlays(app: *App) bool {
    return klipyReachedScreen(app) and !klipyBadge(app);
}
fn autoplayOff(app: *App) void {
    app.st.settings.autoplay_gifs = false;
}
fn autoplayOn(app: *App) void {
    app.st.settings.autoplay_gifs = true;
}
fn klipyStill(app: *App) bool {
    const st = klipyStream(app) orelse return false;
    return st.shown == watch.shown and klipyBadge(app);
}
fn blur(app: *App) void {
    app.qa_blur = true;
}
fn unblur(app: *App) void {
    app.qa_blur = false;
}
/// Sem foco, nenhum GIF nem emoji animado marca o próximo quadro: o app não acorda por eles.
fn blurredStill(app: *App) bool {
    return klipyStill(app) and app.images.next_frame_ms == std.math.maxInt(i64);
}


// --- Anexos de áudio --------------------------------------------------------------

fn audioKey(app: *App, filename: []const u8) u64 {
    return audio_player.keyOf(idOf(app, filename), 0);
}
fn markAudio(comptime prefix: []const u8, comptime file: []const u8) fn (*App, []u8) []const u8 {
    return struct {
        fn f(app: *App, buf: []u8) []const u8 {
            return markOf(buf, prefix, idOf(app, file));
        }
    }.f;
}
const tMp3Play = markAudio("audio-play:", gw.audio_mp3);
const tMp3Wave = markAudio("audio-wave:", gw.audio_mp3);
const tOggPlay = markAudio("audio-play:", gw.audio_ogg);
const tOggWave = markAudio("audio-wave:", gw.audio_ogg);
const tOggSpeed = markAudio("audio-speed:", gw.audio_ogg);
const tOggCard = markAudio("audio-card:", gw.audio_ogg);
const tWavPlay = markAudio("audio-play:", gw.audio_wav);
/// Sem o FFmpeg (o CI não tem), o FLAC é cartão de arquivo e não há o que tocar: o
/// alvo vazio pula o clique.
fn tFlacPlay(app: *App, buf: []u8) []const u8 {
    if (ffmpeg.get() == null) return "";
    return markOf(buf, "audio-play:", idOf(app, gw.audio_flac));
}

fn jumpMp3(app: *App) void {
    jump(app, gw.audio_mp3);
}
fn jumpOgg(app: *App) void {
    jump(app, gw.audio_ogg);
}
fn jumpWav(app: *App) void {
    jump(app, gw.audio_wav);
}
fn jumpFlac(app: *App) void {
    jump(app, gw.audio_flac);
}

/// O cartão de player (e não o de arquivo) de um anexo.
fn playerShown(app: *App, file: []const u8) bool {
    const id = idOf(app, file);
    return shown("audio-play:", id) and shown("audio-wave:", id) and shown("audio-speed:", id) and shown("audio-dl:", id) and !shown("audio-fallback:", id);
}
fn mp3Card(app: *App) bool {
    return playerShown(app, gw.audio_mp3);
}
fn wavCard(app: *App) bool {
    return playerShown(app, gw.audio_wav);
}
fn oggCard(app: *App) bool {
    return playerShown(app, gw.audio_ogg);
}

/// O que o player contava num instante (para comparar depois).
const Snap = struct { viz: u32 = 0, wakes: u32 = 0, pos: u32 = 0, t: i64 = 0, cpu_ns: i64 = 0, frames: u64 = 0 };
var snap: Snap = .{};
fn snapNow(app: *App) void {
    const i = audio_player.info();
    snap = .{ .viz = i.viz_frames, .wakes = i.wakes, .pos = i.pos_ms, .t = @intCast(c.SDL_GetTicks()), .cpu_ns = cpuNs(), .frames = framesNow(app) };
}
fn framesNow(app: *App) u64 {
    return app.gate.built;
}
fn playingFile(app: *App, file: []const u8, dur_lo: u32, dur_hi: u32) bool {
    const i = audio_player.info();
    return i.active == audioKey(app, file) and i.tipo == .arquivo and i.playing and !i.loading and i.pos_ms >= 300 and i.dur_ms >= dur_lo and i.dur_ms <= dur_hi;
}
fn mp3Playing(app: *App) bool {
    // O MP3 da demonstração tem 4 s (dr_mp3, sem FFmpeg).
    return playingFile(app, gw.audio_mp3, 3900, 4100) and audio_player.info().wakes > snap.wakes;
}
fn vizMoves(_: *App) bool {
    const i = audio_player.info();
    return i.playing and i.viz_frames >= snap.viz + 15 and i.viz_top > 20 and i.wakes >= snap.wakes + 15;
}
fn ondaReady(_: *App) bool {
    return audio_player.info().onda;
}
fn mp3Seeked(app: *App) bool {
    // Um quarto da barra = 1 s (e continua tocando dali).
    const i = audio_player.info();
    return i.active == audioKey(app, gw.audio_mp3) and i.playing and i.pos_ms >= 950 and i.pos_ms <= 1700;
}
fn hoverTime(app: *App) bool {
    return shown("audio-hover-time:", idOf(app, gw.audio_mp3));
}
fn audioPaused(_: *App) bool {
    const i = audio_player.info();
    return !i.playing and i.pos_ms > 0 and i.has_file;
}
/// Pausado (e as barras já no chão): nada do player pede quadro, nada anda.
fn pausedStill(_: *App) bool {
    const i = audio_player.info();
    return !i.playing and i.viz_top == 0 and i.wakes == snap.wakes and i.viz_frames == snap.viz and i.pos_ms == snap.pos;
}
fn oggPlaying(app: *App) bool {
    // 16 s de Ogg Opus em estéreo, menos o pre-skip.
    return playingFile(app, gw.audio_ogg, 15900, 16000);
}
fn speed150(_: *App) bool {
    const i = audio_player.info();
    return i.playing and i.speed == 150;
}
fn speed200(_: *App) bool {
    const i = audio_player.info();
    return i.playing and i.speed == 200;
}
/// Em 2x, a posição anda o dobro do relógio.
fn twiceAsFast(_: *App) bool {
    const i = audio_player.info();
    const wall: i64 = @as(i64, @intCast(c.SDL_GetTicks())) - snap.t;
    if (wall < 700) return false;
    const moved: i64 = @as(i64, i.pos_ms) - snap.pos;
    if (c.SDL_getenv("QA_DEBUG") != null) std.debug.print("[audio 2x] relógio {d} ms, posição {d} ms\n", .{ wall, moved });
    return i.playing and moved >= @divTrunc(wall * 16, 10);
}
fn oggNearStart(app: *App) bool {
    const i = audio_player.info();
    return i.active == audioKey(app, gw.audio_ogg) and i.playing and i.pos_ms < 2000;
}
fn speed100(_: *App) bool {
    const i = audio_player.info();
    return i.speed == 100;
}
fn wavPlaying(app: *App) bool {
    return playingFile(app, gw.audio_wav, 2950, 3050);
}
fn reduceOn(app: *App) void {
    app.st.settings.reduce_motion = true;
}
fn reduceOff(app: *App) void {
    app.st.settings.reduce_motion = false;
}
/// Tocando sem animar: o visualizador não anda, a barra sim.
fn noVizButPlays(_: *App) bool {
    const i = audio_player.info();
    return i.playing and i.viz_frames == snap.viz and i.viz_top == 0 and i.pos_ms > snap.pos + 200;
}
fn blurOn(app: *App) void {
    app.qa_blur = true;
}
fn blurOff(app: *App) void {
    app.qa_blur = false;
}
fn vizBack(_: *App) bool {
    const i = audio_player.info();
    return i.playing and i.viz_frames >= snap.viz + 5 and i.viz_top > 20;
}
fn pausedByChannel(_: *App) bool {
    return !audio_player.info().playing;
}
fn backToMusic(app: *App) void {
    jump(app, gw.audio_ogg);
}
fn atStart(app: *App) bool {
    const i = audio_player.info();
    return i.active == audioKey(app, gw.audio_ogg) and !i.playing and i.pos_ms <= 150;
}
fn plusFive(app: *App) bool {
    const i = audio_player.info();
    return i.active == audioKey(app, gw.audio_ogg) and !i.playing and i.pos_ms >= 4800 and i.pos_ms <= 5200;
}
fn spacePlays(app: *App) bool {
    const i = audio_player.info();
    return i.active == audioKey(app, gw.audio_ogg) and i.playing;
}
fn spacePauses(_: *App) bool {
    return !audio_player.info().playing;
}
fn minusFive(app: *App) bool {
    const i = audio_player.info();
    return i.active == audioKey(app, gw.audio_ogg) and i.pos_ms <= 400;
}

// FLAC: só com o FFmpeg. Com ele, toca; sem ele (ou com o QA fingindo que não tem),
// fica o cartão de arquivo com o aviso.
fn flacByFfmpeg(app: *App) bool {
    if (ffmpeg.get() == null) return fallbackShown(app);
    return playerShown(app, gw.audio_flac);
}
fn flacPlays(app: *App) bool {
    if (ffmpeg.get() == null) return true;
    return playingFile(app, gw.audio_flac, 2950, 3050);
}
fn pauseNow(_: *App) void {
    audio_player.pausar();
}
fn noFfmpeg(_: *App) void {
    audio_fonte.qa_sem_ffmpeg = true;
}
fn ffmpegBack(_: *App) void {
    audio_fonte.qa_sem_ffmpeg = false;
}
fn fallbackShown(app: *App) bool {
    const id = idOf(app, gw.audio_flac);
    var b: [64]u8 = undefined;
    const att = std.fmt.bufPrint(&b, "att:{d}:0", .{id}) catch return false;
    return shown("audio-fallback:", id) and !shown("audio-play:", id) and qa.find(att) != null;
}
fn flacCardBack(app: *App) bool {
    if (ffmpeg.get() == null) return fallbackShown(app);
    return playerShown(app, gw.audio_flac);
}
/// Os nativos continuam player sem o FFmpeg.
fn nativeWithoutFfmpeg(app: *App) bool {
    return playerShown(app, gw.audio_ogg) or playerShown(app, gw.audio_wav);
}

// --- CPU ----------------------------------------------------------------------------

/// CPU do processo inteiro (todas as threads), em ns. Só no Linux; no Windows, 0.
fn cpuNs() i64 {
    if (@import("builtin").os.tag != .linux) {
        return 0;
    } else {
        var ts: std.c.timespec = undefined;
        if (std.c.clock_gettime(.PROCESS_CPUTIME_ID, &ts) != 0) return 0;
        return @as(i64, @intCast(ts.sec)) * 1_000_000_000 + @as(i64, @intCast(ts.nsec));
    }
}
/// Daqui em diante o laço dorme como no uso normal (e o portão vale). Sem o
/// mascote do canto, que tem animação própria (como no tools/qa_parado.sh): só o
/// player conta.
var pet_was = false;
fn sleepLikeReal(app: *App) void {
    app.qa_sleep = true;
    app.qa_real_gate = true;
    pet_was = app.st.settings.mascot_pet;
    app.st.settings.mascot_pet = false;
}
fn sleepOff(app: *App) void {
    app.qa_sleep = false;
    app.qa_real_gate = false;
    app.st.settings.mascot_pet = pet_was;
}
var cpu_playing: f64 = -1;
var cpu_noviz: f64 = -1;
var cpu_paused: f64 = -1;
var fps_playing: f64 = -1;
var fps_noviz: f64 = -1;
var fps_paused: f64 = -1;
fn cpuShare() f64 {
    const wall_ms: f64 = @floatFromInt(@as(i64, @intCast(c.SDL_GetTicks())) - snap.t);
    const cpu_ms: f64 = @as(f64, @floatFromInt(cpuNs() - snap.cpu_ns)) / 1e6;
    return if (wall_ms > 0) cpu_ms / wall_ms * 100 else 0;
}
/// Quadros montados por segundo desde o `snapNow` (os iguais, que o portão não manda à tela, contam).
fn framesPerS(app: *App) f64 {
    const wall_ms: f64 = @floatFromInt(@as(i64, @intCast(c.SDL_GetTicks())) - snap.t);
    const f: f64 = @floatFromInt(framesNow(app) -% snap.frames);
    return if (wall_ms > 0) f * 1000 / wall_ms else 0;
}
/// QA_DEBUG: quadro a quadro, quanto passou e quem pediu o próximo (o player pede
/// daqui a 40 ms; menos que isso é outra coisa).
var trace_n: u32 = 0;
var trace_last: u64 = 0;
fn traceFrames(app: *App) bool {
    const anim = @import("ui/anim.zig");
    const t = c.SDL_GetTicksNS();
    if (c.SDL_getenv("QA_DEBUG") != null and trace_last != 0) {
        const far = std.math.maxInt(i64);
        std.debug.print("[audio quadro] +{d:.1} ms  anim {d}  imagens {d}  relógio {d}  ativo {}\n", .{
            @as(f64, @floatFromInt(t - trace_last)) / 1e6,
            if (anim.next_wake_ms == far) -1 else anim.next_wake_ms - anim.now_ms,
            if (app.images.next_frame_ms == far) -1 else app.images.next_frame_ms - anim.now_ms,
            if (anim.clock_wake_ms == far) -1 else anim.clock_wake_ms - anim.now_ms,
            anim.active,
        });
    }
    trace_last = t;
    trace_n += 1;
    return trace_n >= 30;
}

fn measurePlaying(app: *App) bool {
    cpu_playing = cpuShare();
    fps_playing = framesPerS(app);
    std.debug.print("[audio cpu] tocando com o visualizador: {d:.1}% de um núcleo, {d:.0} quadros/s\n", .{ cpu_playing, fps_playing });
    return audio_player.info().playing;
}
fn vizOff(app: *App) void {
    app.st.settings.audio_visualizer = false;
}
fn vizOn(app: *App) void {
    app.st.settings.audio_visualizer = true;
}
fn measureNoViz(app: *App) bool {
    cpu_noviz = cpuShare();
    fps_noviz = framesPerS(app);
    std.debug.print("[audio cpu] tocando sem o visualizador: {d:.1}% de um núcleo, {d:.0} quadros/s\n", .{ cpu_noviz, fps_noviz });
    return audio_player.info().playing;
}
fn measurePaused(app: *App) bool {
    cpu_paused = cpuShare();
    fps_paused = framesPerS(app);
    std.debug.print("[audio cpu] parado (o robô ainda acorda 4x/s): {d:.1}% de um núcleo, {d:.0} quadros/s\n", .{ cpu_paused, fps_paused });
    // Parado, o player não pede nenhum quadro.
    return !audio_player.info().playing and audio_player.info().wakes == snap.wakes;
}
/// Os quadros dizem se algo ficou pedindo redesenho: uns 25 por segundo com o
/// visualizador, bem menos sem ele, e parado só os 4 do robô. A CPU, bem folgada (a
/// máquina do QA é dividida), só pega um laço esquecido. Ela é a do processo inteiro,
/// somando a thread do áudio e as do renderizador de software: no CI, com o
/// visualizador a 25 quadros/s, chega a passar de um núcleo (114,7% numa medida, 85,7%
/// noutra), então o teto acompanha o QA_SLOW sem parar em 90% — quem foge é um laço
/// esquecido, que gasta um núcleo inteiro a mais. Parado (os 4 quadros do robô), a
/// mesma conta é pequena, e é ali que um laço que não desenha aparece.
fn cpuSane(_: *App) bool {
    const slow: f64 = if (c.SDL_getenv("QA_SLOW")) |v| std.fmt.parseFloat(f64, std.mem.span(v)) catch 1 else 1;
    // As medidas também vão para qa-out: o CI guarda a pasta, e não a saída de erro.
    var b: [320]u8 = undefined;
    if (std.fmt.bufPrint(&b, "tocando: {d:.1}% de um núcleo, {d:.1} quadros/s\nsem o visualizador: {d:.1}% de um núcleo, {d:.1} quadros/s\nparado: {d:.1}% de um núcleo, {d:.1} quadros/s\n", .{ cpu_playing, fps_playing, cpu_noviz, fps_noviz, cpu_paused, fps_paused })) |t| {
        _ = c.SDL_SaveFile("qa-out/audio-cpu.txt", t.ptr, t.len);
    } else |_| {}
    // Parado, a thread do áudio e as do desenho ficam quietas: um laço esquecido que
    // não desenha (o que os quadros não pegam) aparece aqui como um núcleo inteiro.
    return fps_playing > 15 and fps_playing < 36 and fps_noviz < fps_playing and fps_paused < 7 and
        cpu_playing >= 0 and cpu_playing < @min(50 * slow, 200) and cpu_paused < 30 * slow;
}

pub const ops = [_]Op{
    s("mensagem de voz"),
    click("guild:500000"),
    click("channel:500008"),
    .{ .run = bottom },
    expect("a mensagem de voz vira um player (tocar, forma de onda, duração)", voiceShown),
    .{ .shot = "midia-voz" },
    dyn(tPlay),
    .{ .run = snapNow },
    expect("tocar baixa, decodifica o Ogg Opus e a posição anda", voicePlaying),
    expect("a mensagem de voz também ganha o visualizador (em volta do botão)", voiceViz),
    .{ .shot = "midia-voz-tocando" },
    dyn(tPlay),
    expect("pausar para a thread e guarda onde parou", voicePaused),
    .{ .wait = 400 },
    expect("pausado, a posição não anda", pauseHolds),
    .{ .click = .{ .dyn_at = .{ .f = tWave, .fx = 0.75, .fy = 0.5 } } },
    expect("clicar na forma de onda leva até ali", seekedWhilePaused),
    dyn(tPlay),
    expect("continua do ponto escolhido (sem baixar de novo)", resumedFromSeek),
    .{ .expect = .{ .name = "no fim, para e volta ao começo", .check = reachedEnd, .timeout_ms = 4000 } },

    s("spoiler e conteúdo sensível"),
    .{ .run = jumpSpoiler },
    expect("anexo SPOILER_ fica coberto", spoilerCovered),
    .{ .shot = "midia-spoiler" },
    dyn(tSpoiler),
    expect("o clique mostra (e a imagem chega)", spoilerRevealed),
    .{ .run = jumpSensitive },
    expect("anexo marcado como sensível fica coberto", sensitiveCovered),
    .{ .shot = "midia-sensivel" },
    dyn(tSensitive),
    expect("o clique mostra o conteúdo sensível", sensitiveRevealed),

    s("link de anexo vencido"),
    .{ .run = jumpExpired },
    expect("a imagem com o link vencido pede um link novo e carrega com ele", refreshedOnce),
    .{ .wait = 600 },
    expect("cada link é renovado uma vez só", stillOnce),
    .{ .shot = "midia-link-renovado" },

    s("figurinhas"),
    .{ .run = bottom },
    expect("os pacotes padrão não são buscados antes de abrir a aba", noPacksYet),
    click("composer-gif"),
    click("gif-tab:2"),
    expect("abrir a aba busca os pacotes e mostra as do servidor, a Lottie e as do pacote", packsFetched),
    expect("a figurinha de outro servidor fica trancada sem Nitro", externalLocked),
    .{ .shot = "midia-figurinhas" },
    click("sticker:900411"),
    .{ .wait = 300 },
    expect("clicar na trancada não manda nada", nothingSent),
    click("gif-search"),
    .{ .text = "tchau" },
    expect("a busca filtra as figurinhas pelo nome", filtered),
    .{ .key = .{ .key = c.ImGuiKey_Escape } },
    expect("Esc fecha o seletor", closed),
    click("composer-gif"),
    click("gif-tab:2"),
    expect("os pacotes não são buscados de novo", packsNotRefetched),
    click("sticker:900401"),
    expect("um clique manda a figurinha (sticker_ids) e ela chega na conversa", stickerArrived),
    .{ .shot = "midia-figurinha-enviada" },

    s("GIF do Klipy (embed gifv)"),
    .{ .run = jumpKlipy },
    expect("o GIF do Klipy aparece tocando aos poucos, sem o selo de GIF", klipyStreams),
    .{ .shot = "midia-klipy" },
    // Sem o mouse em cima e sem nenhum evento: o desenho fica igual, só a textura muda.
    .{ .hover = .{ .mark = "guild:500000" } },
    .{ .wait = 250 },
    .{ .run = watchStart },
    .{ .expect = .{ .name = "sem mexer em nada, o GIF anda sozinho", .check = klipyAdvances, .timeout_ms = 4000 } },
    .{ .run = watchStop },
    expect("cada quadro novo do GIF chega à tela, mesmo com o desenho igual", klipyReachedScreen),
    .{ .run = autoplayOff },
    .{ .wait = 100 },
    .{ .run = watchStart },
    .{ .wait = 500 },
    .{ .run = watchStop },
    expect("com \"tocar GIFs sozinhos\" desligado, fica parado e com o selo", klipyStill),
    .{ .hover = .{ .dyn = tKlipy } },
    .{ .wait = 100 },
    .{ .run = watchStart },
    .{ .expect = .{ .name = "com o mouse em cima, anda", .check = klipyAdvances, .timeout_ms = 4000 } },
    .{ .run = watchStop },
    expect("e cada quadro chega à tela, sem o selo", klipyHoverPlays),
    .{ .run = autoplayOn },
    .{ .hover = .{ .mark = "guild:500000" } },
    // Como no Discord: tocar sozinho vale com a janela em foco.
    .{ .run = blur },
    .{ .wait = 100 },
    .{ .run = watchStart },
    .{ .wait = 500 },
    .{ .run = watchStop },
    expect("com a janela sem foco, o GIF para e nada marca o próximo quadro", blurredStill),
    .{ .run = unblur },
    .{ .wait = 100 },
    .{ .run = watchStart },
    .{ .expect = .{ .name = "com o foco de volta, o GIF volta a andar sozinho", .check = klipyAdvances, .timeout_ms = 4000 } },
    .{ .run = watchStop },

    s("anexos de áudio"),
    .{ .run = autoplayOff },
    .{ .run = jumpMp3 },
    expect("o .mp3 (só pela extensão) vira player: tocar, forma de onda, velocidade e baixar", mp3Card),
    .{ .run = jumpWav },
    expect("o .wav (tipo audio/*) vira player", wavCard),
    .{ .run = jumpOgg },
    expect("o .ogg (Opus) vira player", oggCard),
    .{ .run = jumpMp3 },
    .{ .wait = 200 },
    .{ .shot = "midia-audio" },
    .{ .run = snapNow },
    dyn(tMp3Play),
    expect("tocar o MP3 decodifica pelo dr_mp3, a posição anda e pede quadros", mp3Playing),
    .{ .run = snapNow },
    expect("o visualizador anda enquanto toca (25 quadros por segundo)", vizMoves),
    expect("a forma de onda do arquivo inteiro é medida uma vez, numa thread", ondaReady),
    .{ .hover = .{ .dyn_at = .{ .f = tMp3Wave, .fx = 0.6, .fy = 0.5 } } },
    expect("o mouse em cima da forma de onda mostra o tempo do ponto", hoverTime),
    .{ .shot = "midia-audio-tocando" },
    .{ .click = .{ .dyn_at = .{ .f = tMp3Wave, .fx = 0.25, .fy = 0.5 } } },
    expect("clicar na forma de onda leva até ali (um quarto = 1 s)", mp3Seeked),
    dyn(tMp3Play),
    expect("pausar para a thread e guarda onde parou", audioPaused),
    .{ .wait = 700 },
    .{ .run = snapNow },
    .{ .wait = 500 },
    expect("pausado, nada do player pede quadro e as barras ficam no chão", pausedStill),

    .{ .run = jumpOgg },
    .{ .wait = 150 },
    dyn(tOggPlay),
    expect("o Ogg Opus em estéreo toca pela libopus", oggPlaying),
    dyn(tOggSpeed),
    expect("a velocidade vai para 1,5x tocando", speed150),
    dyn(tOggSpeed),
    expect("e para 2x", speed200),
    .{ .run = snapNow },
    .{ .wait = 800 },
    expect("em 2x, a posição anda o dobro do relógio", twiceAsFast),
    .{ .shot = "midia-audio-2x" },
    dyn(tOggSpeed),
    expect("mais um clique volta a 1x", speed100),
    // De volta ao começo (em 2x o fim chega logo).
    .{ .click = .{ .dyn_at = .{ .f = tOggWave, .fx = 0.02, .fy = 0.5 } } },
    expect("o Ogg continua tocando do começo", oggNearStart),
    .{ .run = blurOn },
    .{ .wait = 150 },
    .{ .run = snapNow },
    .{ .wait = 500 },
    expect("com a janela sem foco, o visualizador para (a barra continua)", noVizButPlays),
    .{ .run = blurOff },
    .{ .run = snapNow },
    expect("com o foco de volta, o visualizador volta", vizBack),
    click("channel:500006"),
    expect("trocar de canal para o áudio", pausedByChannel),
    click("channel:500008"),
    .{ .run = backToMusic },
    .{ .wait = 200 },
    .{ .click = .{ .dyn_at = .{ .f = tOggWave, .fx = 0.0, .fy = 0.5 } } },
    expect("parado, clicar no começo da barra volta ao começo", atStart),
    .{ .hover = .{ .dyn = tOggCard } },
    .{ .key = .{ .key = c.ImGuiKey_RightArrow } },
    expect("com o mouse em cima, → avança 5 s", plusFive),
    .{ .key = .{ .key = c.ImGuiKey_Space } },
    expect("espaço toca", spacePlays),
    .{ .key = .{ .key = c.ImGuiKey_Space } },
    expect("espaço de novo pausa", spacePauses),
    .{ .key = .{ .key = c.ImGuiKey_LeftArrow } },
    expect("← volta 5 s", minusFive),

    .{ .run = jumpWav },
    .{ .wait = 150 },
    .{ .run = reduceOn },
    dyn(tWavPlay),
    expect("o WAV toca pelo dr_wav", wavPlaying),
    .{ .run = snapNow },
    .{ .wait = 500 },
    expect("com \"reduzir movimento\", o visualizador não anda (só a barra)", noVizButPlays),
    .{ .run = reduceOff },
    .{ .run = pauseNow },

    .{ .run = jumpFlac },
    .{ .wait = 200 },
    expect("o FLAC vira player quando o FFmpeg carrega (senão, cartão de arquivo)", flacByFfmpeg),
    dyn(tFlacPlay),
    expect("e toca pelo FFmpeg", flacPlays),
    .{ .run = pauseNow },
    .{ .run = noFfmpeg },
    .{ .wait = 200 },
    expect("sem FFmpeg, o FLAC volta a ser cartão de arquivo, com o aviso", fallbackShown),
    .{ .shot = "midia-audio-sem-ffmpeg" },
    .{ .run = jumpOgg },
    expect("sem FFmpeg, os que o app toca sozinho continuam player", nativeWithoutFfmpeg),
    .{ .run = ffmpegBack },
    .{ .run = jumpFlac },
    expect("com o FFmpeg de volta, o FLAC volta a ser player", flacCardBack),

    s("anexos de áudio: CPU"),
    .{ .run = jumpOgg },
    .{ .wait = 200 },
    .{ .click = .{ .dyn_at = .{ .f = tOggWave, .fx = 0.0, .fy = 0.5 } } },
    dyn(tOggPlay),
    expect("o Ogg toca de novo", oggPlaying),
    .{ .hover = .{ .mark = "guild:500000" } },
    .{ .run = sleepLikeReal },
    // A rolagem até a mensagem e o hover que saiu ainda animam um pouco (fora da tela
    // não há vsync: animando, o laço desenha sem parar). Mede depois de assentar.
    .{ .wait = 1500 },
    .{ .expect = .{ .name = "quadros tocando (com QA_DEBUG, um por linha)", .check = traceFrames, .timeout_ms = 5000 } },
    .{ .run = snapNow },
    .{ .wait = 2500 },
    .{ .expect = .{ .name = "medido: tocando com o visualizador", .check = measurePlaying, .timeout_ms = 1000 } },
    .{ .run = vizOff },
    .{ .run = snapNow },
    .{ .wait = 2000 },
    .{ .expect = .{ .name = "medido: tocando sem o visualizador", .check = measureNoViz, .timeout_ms = 1000 } },
    .{ .run = vizOn },
    .{ .run = pauseNow },
    .{ .wait = 600 },
    .{ .run = snapNow },
    .{ .wait = 2000 },
    .{ .expect = .{ .name = "medido: parado (o player não pede quadro)", .check = measurePaused, .timeout_ms = 1000 } },
    .{ .run = sleepOff },
    expect("tocando, ~25 quadros/s com o visualizador e menos sem ele; parado, nenhum a mais", cpuSane),
    .{ .run = autoplayOn },
};
