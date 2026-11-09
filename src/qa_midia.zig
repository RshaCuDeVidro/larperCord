//! QA da mídia (QA_SUITE=midia): mensagem de voz (tocar, pausar, buscar na
//! barra e chegar ao fim), capa de spoiler e de conteúdo sensível, link de
//! anexo vencido renovado uma vez só e a aba de figurinhas (pacotes buscados
//! só quando ela abre, a de outro servidor trancada sem Nitro, enviar) e o GIF do
//! Klipy, que anda sozinho e chega à tela sem nenhum evento.
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

pub const ops = [_]Op{
    s("mensagem de voz"),
    click("guild:500000"),
    click("channel:500008"),
    .{ .run = bottom },
    expect("a mensagem de voz vira um player (tocar, forma de onda, duração)", voiceShown),
    .{ .shot = "midia-voz" },
    dyn(tPlay),
    expect("tocar baixa, decodifica o Ogg Opus e a posição anda", voicePlaying),
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
};
