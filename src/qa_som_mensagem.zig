//! QA do som de mensagem nova (core/aviso.zig decide, net/voz_audio.zig toca):
//! as mensagens chegam pelo gateway da demonstração (`demo_message`, as mesmas
//! frases das que chegam ao vivo) e o QA conta os pedidos em `msg_sound.played`,
//! sem ouvir nada. O som sai no driver mudo do SDL, como os da call: `sounds_played`
//! sobe quando ele chega à saída. Entra na bateria geral e roda sozinho
//! (QA_SUITE=som-mensagem).
const std = @import("std");
const c = @import("c");
const App = @import("app.zig").App;
const R = @import("qa_runner.zig");
const Op = R.Op;
const qa = @import("ui/qa.zig");
const gw = @import("net/fake_gateway.zig");
const types = @import("core/types.zig");
const sons = @import("core/sons.zig");
const voz_audio = @import("net/voz_audio.zig");
const S = @import("ui/settings_state.zig");
const platform = @import("platform/window.zig");
const tray = @import("platform/tray.zig");
const app_conta = @import("app_conta.zig");
const Id = types.Id;

const sh = &voz_audio.sh;
const geral: Id = 500005;
const memes: Id = 500006;
/// A DM com o kaique (1003).
const dm = gw.dmId(2);
const toggle_key = "toggle:Som de mensagem nova";

fn s(name: []const u8) Op {
    return .{ .section = name };
}
fn click(k: []const u8) Op {
    return .{ .click = .{ .mark = k } };
}
fn expect(name: []const u8, f: *const fn (*App) bool) Op {
    return .{ .expect = .{ .name = name, .check = f } };
}
fn run(f: *const fn (*App) void) Op {
    return .{ .run = f };
}

// --- Mensagens chegando pelo gateway da demonstração ------------------------------

var played0: u32 = 0;
var sounds0: u32 = 0;
var notified0: u32 = 0;
var last0: Id = 0;
var target: Id = 0;

fn lastOf(app: *App, ch: Id) Id {
    const cs = app.store.channel(ch) orelse return 0;
    return cs.info.last_message;
}

/// Marca os contadores e pede uma mensagem ao vivo. Cada caso começa sem o
/// intervalo da rajada anterior (a rajada tem o caso dela).
fn send(app: *App, ch: Id, mention: bool) void {
    played0 = app.msg_sound.played;
    sounds0 = sh.sounds_played.load(.monotonic);
    notified0 = app.st.filtros.notified;
    last0 = lastOf(app, ch);
    target = ch;
    app.msg_sound.last_ms = null;
    app.cmd(.{ .demo_message = .{ .channel = ch, .mention = mention } });
}
fn dmOther(app: *App) void {
    send(app, dm, false);
}
fn mentionOther(app: *App) void {
    send(app, memes, true);
}
fn plainOther(app: *App) void {
    send(app, memes, false);
}
/// Duas DMs seguidas, sem esperar.
fn burst(app: *App) void {
    send(app, dm, false);
    app.cmd(.{ .demo_message = .{ .channel = dm } });
}

var own_seq: u64 = 0;
/// Nossa própria mensagem chegando pelo gateway (mandada de outro aparelho).
fn ownDm(app: *App) void {
    played0 = app.msg_sound.played;
    last0 = lastOf(app, dm);
    target = dm;
    app.msg_sound.last_ms = null;
    own_seq += 1;
    const id = types.makeSnowflake(gw.nowMs(), 0x3e000 + own_seq);
    const text = std.heap.c_allocator.dupe(u8, "mandei do celular") catch return;
    app.events.push(.{ .message_create = .{ .id = id, .channel = dm, .author = app.store.me, .timestamp = @divTrunc(gw.nowMs(), 1000), .content = text } });
    platform.Window.wake(app.win.wake_type, .gateway);
}

fn arrived(app: *App) bool {
    return lastOf(app, target) > last0;
}
fn played(app: *App) bool {
    return arrived(app) and app.msg_sound.played == played0 + 1;
}
/// Pedido e posto na saída (a mesma dos sons da call, no driver mudo).
fn playedOut(app: *App) bool {
    return played(app) and sh.sounds_played.load(.monotonic) > sounds0;
}
/// Chegou (a decisão sai antes de o Store guardar a mensagem) e não pediu o som.
fn silent(app: *App) bool {
    return arrived(app) and app.msg_sound.played == played0;
}
/// As duas chegaram e avisaram, e o som tocou uma vez só.
fn burstOnce(app: *App) bool {
    return app.st.filtros.notified == notified0 + 2 and app.msg_sound.played == played0 + 1;
}

// --- Onde a pessoa está -----------------------------------------------------------

fn toGeral(app: *App) void {
    app.handle(.{ .select_channel = geral });
}
fn onGeral(app: *App) bool {
    return app.st.activeChannel() == geral;
}
fn openDm(app: *App) void {
    app.handle(.{ .select_channel = dm });
}
fn onDm(app: *App) bool {
    return app.st.activeChannel() == dm;
}
fn blur(app: *App) void {
    app.qa_blur = true;
}
fn unblur(app: *App) void {
    app.qa_blur = false;
}
fn muteDm(app: *App) void {
    app.st.muted_channels.put(app.gpa, dm, {}) catch {};
}
fn unmuteDm(app: *App) void {
    _ = app.st.muted_channels.remove(dm);
}
fn dnd(app: *App) void {
    app_conta.setStatus(app, .dnd, 0, false);
}
fn isDnd(app: *App) bool {
    return app_conta.dndNow(app);
}
fn online(app: *App) void {
    app_conta.setStatus(app, .online, 0, false);
}
fn isOnline(app: *App) bool {
    return !app_conta.dndNow(app);
}

// --- Bandeja ----------------------------------------------------------------------

var tray_was: ?bool = null;
fn hideToTray(app: *App) void {
    tray_was = tray.fake;
    tray.fake = true;
    var e = std.mem.zeroes(c.SDL_Event);
    e.type = c.SDL_EVENT_WINDOW_CLOSE_REQUESTED;
    e.window.windowID = c.SDL_GetWindowID(app.win.window);
    _ = c.SDL_PushEvent(&e);
}
fn inTray(app: *App) bool {
    return app.in_tray and c.SDL_GetWindowFlags(app.win.window) & c.SDL_WINDOW_HIDDEN != 0;
}
fn showAgain(app: *App) void {
    platform.Window.wake(app.win.wake_type, .show);
}
fn shown(app: *App) bool {
    return !app.in_tray and c.SDL_GetWindowFlags(app.win.window) & c.SDL_WINDOW_HIDDEN == 0;
}
fn trayBack(_: *App) void {
    tray.hide();
    tray.fake = tray_was;
}

// --- Configurações ----------------------------------------------------------------

fn settingsOpen(app: *App) bool {
    return app.st.settings.open;
}
fn notifPage(app: *App) bool {
    return app.st.settings.page == .notificacoes and qa.find(toggle_key) != null and
        qa.find("som-var:message") != null and qa.find("som-play:message") != null and qa.find("som-vol:message") != null;
}
fn voicePageRow(app: *App) bool {
    const msg = qa.find("som-var:message") orelse return false;
    const ring = qa.find("som-var:ring") orelse return false;
    return app.st.settings.page == .voz and msg.y > ring.y;
}
fn switchOff(app: *App) bool {
    return !app.st.settings.message_sound;
}
fn switchOn(app: *App) bool {
    return app.st.settings.message_sound;
}
fn markOut(_: *App) void {
    sounds0 = sh.sounds_played.load(.monotonic);
}
fn previewPlayed(_: *App) bool {
    return sh.sounds_played.load(.monotonic) > sounds0;
}
fn callSoundsOff(app: *App) void {
    app.st.settings.voice_sounds = false;
}
fn callSoundsAreOff(_: *App) bool {
    return !sh.sounds.load(.monotonic);
}
fn callSoundsOn(app: *App) void {
    app.st.settings.voice_sounds = true;
}
fn variantOff(app: *App) void {
    S.soundVariant(&app.st.settings, .message).* = @backingInt(sons.Variant.off);
}
fn variantIsOff(_: *App) bool {
    return sh.variant[@backingInt(sons.Event.message)].load(.monotonic) == @backingInt(sons.Variant.off);
}
fn variantClassic(app: *App) void {
    S.soundVariant(&app.st.settings, .message).* = @backingInt(sons.Variant.classic);
}
fn variantIsClassic(_: *App) bool {
    return sh.variant[@backingInt(sons.Event.message)].load(.monotonic) == @backingInt(sons.Variant.classic);
}
/// Ligado de começo, no clássico.
fn defaults(app: *App) bool {
    return app.st.settings.message_sound and S.soundVariantC(&app.st.settings, .message) == @backingInt(sons.Variant.classic);
}

pub const ops = [_]Op{
    s("som de mensagem nova: quando toca"),
    expect("ligado de começo, no som clássico", defaults),
    run(unblur),
    run(toGeral),
    expect("no #geral, com a janela em foco", onGeral),
    run(dmOther),
    expect("DM da demonstração, fora da conversa aberta: pede o som, e ele chega à saída (driver mudo)", playedOut),
    run(mentionOther),
    expect("menção num canal de servidor que não está aberto: toca", played),
    run(plainOther),
    expect("mensagem comum, sem menção: não toca", silent),
    run(ownDm),
    expect("a nossa própria mensagem (de outro aparelho): não toca", silent),
    run(openDm),
    expect("abre a DM", onDm),
    run(dmOther),
    expect("DM na conversa aberta, com a janela em foco: não toca", silent),
    run(blur),
    run(dmOther),
    expect("a mesma conversa com a janela fora de foco: toca", played),
    run(unblur),
    run(hideToTray),
    expect("fechar esconde na bandeja", inTray),
    run(dmOther),
    expect("escondida na bandeja, até a conversa aberta toca", played),
    run(showAgain),
    expect("Abrir volta a janela", shown),
    run(trayBack),
    run(toGeral),
    expect("de volta ao #geral", onGeral),

    s("som de mensagem nova: quando não toca"),
    run(muteDm),
    run(dmOther),
    expect("DM silenciada: não toca", silent),
    run(unmuteDm),
    run(dnd),
    expect("status Não perturbe", isDnd),
    run(dmOther),
    expect("em Não perturbe: não toca", silent),
    run(online),
    expect("status online de novo", isOnline),
    run(burst),
    expect("duas DMs seguidas: as duas avisam e o som toca uma vez", burstOnce),
    run(variantOff),
    expect("o som de mensagem desligado na lista (Voz → Sons)", variantIsOff),
    run(dmOther),
    expect("som desligado na lista: não toca", silent),
    run(variantClassic),
    expect("o clássico de volta", variantIsClassic),
    run(callSoundsOff),
    expect("sons da call desligados", callSoundsAreOff),
    run(dmOther),
    expect("os sons da call desligados não calam a mensagem nova", playedOut),
    run(callSoundsOn),

    s("som de mensagem nova: a chave em Notificações"),
    click("user-btn:2"),
    expect("abrir as configurações", settingsOpen),
    click("settings:Notificações"),
    expect("Notificações mostra a chave e o som (escolha, Ouvir e volume)", notifPage),
    .{ .shot = "notificacoes-som" },
    run(markOut),
    click("som-play:message"),
    expect("Ouvir toca o som de mensagem", previewPlayed),
    click(toggle_key),
    expect("a chave desliga", switchOff),
    click("settings-close"),
    run(dmOther),
    expect("com a chave desligada: não toca", silent),
    click("user-btn:2"),
    click("settings:Notificações"),
    click(toggle_key),
    expect("a chave liga de novo", switchOn),
    click("settings:Voz"),
    .{ .hover = .{ .mark = "som-play:message" } },
    expect("Voz → Sons também tem o som de mensagem, por último", voicePageRow),
    .{ .shot = "voz-som-mensagem" },
    click("settings-close"),
    run(dmOther),
    expect("ligada de novo: toca", played),
};
