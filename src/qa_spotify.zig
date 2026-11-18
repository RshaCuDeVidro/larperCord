//! QA da presença do Spotify: a opção liga a detecção e a atividade "Listening
//! to Spotify" vai para o gateway de mentira. A detecção de verdade não roda
//! aqui: o QA injeta as faixas (platform/spotify.zig qaInject), que é o mesmo
//! caminho que a thread usa — assim o Spotify de quem testa (ou o de nenhum)
//! não entra na conta. Muda de faixa, pausa, some e desliga, e a posição
//! sozinha não manda nada de novo.
const std = @import("std");
const App = @import("app.zig").App;
const R = @import("qa_runner.zig");
const Op = R.Op;
const qa = @import("ui/qa.zig");
const gw = @import("net/fake_gateway.zig");
const spotify = @import("platform/spotify.zig");

fn s(name: []const u8) Op {
    return .{ .section = name };
}
fn click(k: []const u8) Op {
    return .{ .click = .{ .mark = k } };
}
fn expect(name: []const u8, f: *const fn (*App) bool) Op {
    return .{ .expect = .{ .name = name, .check = f, .timeout_ms = 5000 } };
}
fn run(f: *const fn (*App) void) Op {
    return .{ .run = f };
}

const toggle = "toggle:Detectar o Spotify local";

// --- Passos ------------------------------------------------------------------------

fn openPrivacy(app: *App) void {
    app.st.settings.page = .privacidade;
    app.st.settings.open = true;
}

fn closeSettings(app: *App) void {
    app.st.settings.open = false;
}

fn offNothing(app: *App) bool {
    return !app.st.settings.spotify_presence and !spotify.running();
}

fn on(app: *App) bool {
    return app.st.settings.spotify_presence;
}

var presences_before: u64 = 0;
fn notePresences() void {
    presences_before = gw.sent.presences.load(.acquire);
}

fn lastOp3() []const u8 {
    return gw.sent.presence[0..gw.sent.presence_len.load(.acquire)];
}

fn op3Has(needles: []const []const u8) bool {
    if (gw.sent.presences.load(.acquire) <= presences_before) return false;
    for (needles) |n| if (std.mem.indexOf(u8, lastOp3(), n) == null) return false;
    return true;
}

fn op3Lacks(nope: []const u8) bool {
    if (gw.sent.presences.load(.acquire) <= presences_before) return false;
    return std.mem.indexOf(u8, lastOp3(), nope) == null;
}

fn myActivities(app: *App) []const @import("core/types.zig").Activity {
    return app.store.activities.get(app.store.me) orelse &.{};
}

/// Injeta uma faixa no caminho da detecção (o QA não tem thread de verdade).
fn inject(title: []const u8, artist: []const u8, playing: bool, position_ms: i64) void {
    var t: spotify.Track = .{};
    t.title.set(title, 128);
    t.artist.set(artist, 128);
    t.playing = playing;
    t.position_ms = position_ms;
    spotify.qaInject(t);
}

fn inject1(_: *App) void {
    notePresences();
    inject("Musica de Teste", "Artista de Teste", true, 30_000);
}

fn op3Spotify(_: *App) bool {
    // Sem aplicação nenhuma: sem application_id no op 3.
    return op3Has(&.{ "\"type\":2", "\"name\":\"Spotify\"", "\"details\":\"Musica de Teste\"", "\"state\":\"Artista de Teste\"", "\"start\":" }) and op3Lacks("\"application_id\"");
}

fn panelShows(app: *App) bool {
    const acts = myActivities(app);
    const me = app.store.user(app.store.me) orelse return false;
    return acts.len == 1 and std.mem.eql(u8, acts[0].name, "Spotify") and std.mem.eql(u8, acts[0].details, "Musica de Teste") and
        me.activity != null and std.mem.endsWith(u8, me.activity.?, "Spotify") and qa.find("me-activity") != null;
}

fn injectPaused(_: *App) void {
    notePresences();
    inject("Musica de Teste", "Artista de Teste", false, 45_000);
}

fn op3Paused(_: *App) bool {
    // Pausada: sem cronômetro (a posição congelada ia parecer errada).
    return op3Has(&.{ "\"name\":\"Spotify\"", "\"details\":\"Musica de Teste\"" }) and op3Lacks("\"timestamps\"") and op3Lacks("\"application_id\"");
}

fn injectSame(_: *App) void {
    notePresences();
    inject("Musica de Teste", "Artista de Teste", false, 47_000);
}

fn noResend(_: *App) bool {
    return gw.sent.presences.load(.acquire) == presences_before;
}

fn injectGone(_: *App) void {
    notePresences();
    spotify.qaInject(null);
}

fn cleared(app: *App) bool {
    const me = app.store.user(app.store.me) orelse return false;
    return op3Has(&.{"\"activities\":[]"}) and myActivities(app).len == 0 and me.activity == null;
}

fn inject2(_: *App) void {
    notePresences();
    inject("Outra Musica", "Outro Artista", true, 10_000);
}

fn op3Again(_: *App) bool {
    return op3Has(&.{"\"details\":\"Outra Musica\""});
}

fn turnOff(app: *App) void {
    notePresences();
    openPrivacy(app);
}

fn offCleared(app: *App) bool {
    return !app.st.settings.spotify_presence and !spotify.running() and op3Has(&.{"\"activities\":[]"});
}

fn restore(app: *App) void {
    closeSettings(app);
}

pub const ops = [_]Op{
    s("spotify"),
    expect("desligado: nada de detecção nem thread", offNothing),
    run(openPrivacy),
    click(toggle),
    .{ .shot = "spotify-config" },
    expect("ligado: a opção fica salva", on),
    run(closeSettings),
    run(inject1),
    expect("a faixa injetada vira atividade Listening to Spotify", op3Spotify),
    expect("a atividade aparece no nosso painel e no perfil", panelShows),
    .{ .shot = "spotify-painel" },
    run(injectPaused),
    expect("a pausa tira o cronômetro (e é ela que reenvia)", op3Paused),
    run(injectSame),
    expect("a mesma faixa com a posição andada não reenvia", noResend),
    run(injectGone),
    expect("sem Spotify, a atividade limpa", cleared),
    run(inject2),
    expect("faixa nova manda de novo", op3Again),
    run(turnOff),
    click(toggle),
    expect("desligar para a detecção e limpa a atividade", offCleared),
    run(restore),
};
