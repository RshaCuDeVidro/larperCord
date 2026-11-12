//! QA da tela da call (ui/call_grid.zig), na call da madrugada da demonstração: a
//! ana (apelido e foto do servidor, mutada, ouvindo Spotify), a duda (mutada e
//! surda), o kaique (mutado pelo servidor e transmitindo) e a gente. Clicar no canal
//! de voz entra e abre a grade; cada quadro mostra o que deve; quem fala ganha o
//! anel; clicar num quadro abre o menu da pessoa; os botões da faixa de voz ficam no
//! lugar da caixa; Esc, o botão do cabeçalho e "ver a call" vão e voltam; com muita
//! gente, os quadros encolhem até o mínimo e a grade rola; e numa call de DM a grade
//! fica numa faixa em cima da conversa. Sozinho: QA_SUITE=call; só a parte de cada
//! tema: QA_SUITE=call-tema.
const std = @import("std");
const c = @import("c");
const App = @import("app.zig").App;
const R = @import("qa_runner.zig");
const Op = R.Op;
const qa = @import("ui/qa.zig");
const gw = @import("net/fake_gateway.zig");
const types = @import("core/types.zig");
const platform = @import("platform/window.zig");
const Rect = @import("theme/layout.zig").Rect;
const Id = types.Id;

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
fn key(k: c_int) Op {
    return .{ .key = .{ .key = k } };
}
fn shot(name: []const u8) Op {
    return .{ .shot = name };
}

const g0: Id = gw.guildId(0);
const call0: Id = gw.channelId(0, 13);
const dm0: Id = 900_000;
const me: Id = 1000;
const ana: Id = 1001;
const kaique: Id = 1003;
const duda: Id = 1005;
/// Quem entra na call para encher a grade.
const crowd = [_]Id{ 1004, 1006, 1007, 1008, 1009, 1010, 1011, 1012, 1013 };

fn find(comptime fmt: []const u8, args: anytype) ?Rect {
    var b: [64]u8 = undefined;
    return qa.find(std.fmt.bufPrint(&b, fmt, args) catch return null);
}

/// Uma marca com o nome dentro do quadro de `uid`.
fn inTile(comptime fmt: []const u8, uid: Id) bool {
    const r = find("grid-tile:{d}", .{uid}) orelse return false;
    var b: [64]u8 = undefined;
    return qa.anyIn(std.fmt.bufPrint(&b, fmt, .{uid}) catch return false, r);
}

fn push(app: *App, e: @import("core/event.zig").Event) void {
    app.events.push(e);
    platform.Window.wake(app.win.wake_type, .gateway);
}

fn openGuild0(app: *App) void {
    app.handle(.{ .select_guild = g0 });
}
fn inGuild0(app: *App) bool {
    const ch = app.st.activeChannel() orelse return false;
    const cs = app.store.channel(ch) orelse return false;
    return app.st.guild == g0 and cs.history == .loaded and qa.find("channel:500014") != null;
}

fn viewOpen(app: *App) bool {
    return app.st.voice == call0 and app.st.call_view and qa.find("grid-view") != null;
}
fn tilesShown(_: *App) bool {
    for ([_]Id{ me, ana, kaique, duda }) |uid| if (find("grid-tile:{d}", .{uid}) == null) return false;
    const r = find("grid-tile:{d}", .{ana}).?;
    return qa.anyIn("nome:tile:1001:Aninha", r) and qa.anyIn("avatar-srv:1001", r) and
        inTile("nome:tile:{d}:Kaká do Zig", kaique) and inTile("nome:tile:{d}:duda", duda) and
        qa.overlapping(&.{"grid-tile:"}) == null;
}
fn flagsShown(_: *App) bool {
    return inTile("grid-muted:{d}", ana) and !inTile("grid-deaf:{d}", ana) and
        inTile("grid-muted:{d}", duda) and inTile("grid-deaf:{d}", duda) and
        inTile("grid-muted:{d}", kaique) and inTile("grid-live:{d}", kaique) and !inTile("grid-live:{d}", ana) and
        inTile("grid-activity:{d}", ana) and !inTile("grid-muted:{d}", me);
}
fn speakDuda(app: *App) void {
    push(app, .{ .voice_speaking = .{ .user = duda, .speaking = true } });
}
fn speaking(_: *App) bool {
    return inTile("grid-speaking:{d}", duda) and !inTile("grid-speaking:{d}", ana);
}
fn controlsShown(_: *App) bool {
    for ([_][]const u8{ "grid-mic", "grid-deaf", "grid-mixer", "grid-leave", "grid-back" }) |k| if (qa.find(k) == null) return false;
    // A caixa de mensagem dá lugar aos botões.
    return qa.find("composer") == null;
}
fn menuForAna(app: *App) bool {
    return switch (app.st.popup) {
        .menu => |m| m.kind == .user and m.id == ana,
        else => false,
    };
}
fn menuClosedStillView(app: *App) bool {
    return app.st.popup == .none and app.st.call_view;
}
fn mixerOpen(app: *App) bool {
    return app.st.popup == .mixer;
}
fn closedMixer(app: *App) bool {
    return app.st.popup == .none;
}
fn muted(app: *App) bool {
    return app.st.muted;
}
fn unmuted(app: *App) bool {
    return !app.st.muted;
}
fn backToText(app: *App) bool {
    return !app.st.call_view and app.st.voice == call0 and qa.find("grid-view") == null and qa.find("composer") != null;
}

fn addCrowd(app: *App) void {
    for (crowd) |uid| push(app, .{ .voice_state = .{ .channel = call0, .user = uid } });
}
fn removeCrowd(app: *App) void {
    for (crowd) |uid| push(app, .{ .voice_state = .{ .channel = null, .user = uid } });
}
fn crowdScrolls(_: *App) bool {
    const view = qa.find("grid-view") orelse return false;
    var lowest: f32 = 0;
    for (crowd ++ [_]Id{ me, ana, kaique, duda }) |uid| {
        const r = find("grid-tile:{d}", .{uid}) orelse return false;
        if (r.w < 175) return false;
        lowest = @max(lowest, r.bottom());
    }
    return lowest > view.bottom() and qa.overlapping(&.{"grid-tile:"}) == null;
}
fn crowdGone(_: *App) bool {
    return find("grid-tile:{d}", .{crowd[0]}) == null and find("grid-tile:{d}", .{ana}) != null;
}
fn leftCall(app: *App) bool {
    return app.st.voice == null and !app.st.call_view and qa.find("composer") != null;
}

fn openDm0(app: *App) void {
    app.actions.append(app.gpa, .{ .select_channel = dm0 }) catch {};
}
fn dmReady(app: *App) bool {
    return app.st.activeChannel() == dm0 and qa.find("call-start") != null;
}
fn dmBand(app: *App) bool {
    const band = qa.find("grid-band") orelse return false;
    const tile = find("grid-tile:{d}", .{me}) orelse return false;
    const comp = qa.find("composer") orelse return false;
    // A grade em cima, a conversa e a caixa embaixo dela.
    return app.st.voice == dm0 and tile.y >= band.y and tile.bottom() <= band.bottom() + 1 and comp.y > band.bottom() and qa.find("grid-leave") != null;
}
fn dmLeft(app: *App) bool {
    return app.st.voice == null and qa.find("grid-band") == null;
}

pub const ops = [_]Op{
    s("tela da call"),
    run(openGuild0),
    expect("abre o primeiro servidor", inGuild0),
    click("channel:500014"),
    expect("clicar no canal de voz entra na call e abre a tela dela", viewOpen),
    expect("um quadro para cada um, com o apelido e a foto do servidor, sem sobrepor", tilesShown),
    expect("mudo, surdo, a atividade e o AO VIVO de quem transmite", flagsShown),
    run(speakDuda),
    expect("quem fala ganha o anel verde", speaking),
    expect("os botões da faixa de voz no lugar da caixa, e o de voltar no cabeçalho", controlsShown),
    shot("call-grade"),
    click("grid-tile:1001"),
    expect("clicar num quadro abre o menu da pessoa", menuForAna),
    key(c.ImGuiKey_Escape),
    expect("Esc fecha o menu e a tela da call continua", menuClosedStillView),
    click("grid-mixer"),
    expect("o mixer abre pelo botão da tela", mixerOpen),
    click("voice-mixer-close"),
    expect("fecha o mixer", closedMixer),
    click("grid-mic"),
    expect("o botão do microfone muta", muted),
    click("grid-mic"),
    expect("e desmuta", unmuted),
    key(c.ImGuiKey_Escape),
    expect("Esc volta para a conversa, ainda na call", backToText),
    click("voice-view"),
    expect("\"ver a call\" na faixa de voz abre a tela de novo", viewOpen),
    click("grid-back"),
    expect("o botão do cabeçalho volta para a conversa", backToText),
    click("channel:500014"),
    expect("clicar no canal da call em que já estamos abre a tela, sem sair", viewOpen),

    s("tela da call: muita gente"),
    .{ .resize = .{ 860, 600 } },
    run(addCrowd),
    .{ .wait = 300 },
    expect("com 13 na call numa janela pequena, os quadros ficam no mínimo e a grade rola", crowdScrolls),
    shot("call-muita-gente"),
    run(removeCrowd),
    .{ .resize = .{ 1280, 800 } },
    expect("quem saiu some da grade", crowdGone),
    click("grid-leave"),
    expect("sair pelo botão da tela sai da call e volta para a conversa", leftCall),

    s("tela da call: DM"),
    run(openDm0),
    expect("abre a DM", dmReady),
    click("call-start"),
    expect("na call da DM, a grade numa faixa em cima da conversa", dmBand),
    shot("call-dm"),
    click("grid-leave"),
    expect("sair pela faixa", dmLeft),
};

// --- Cada tema -----------------------------------------------------------------------

fn joinView(app: *App) void {
    app.handle(.{ .select_guild = g0 });
    if (app.st.voice != call0) app.handle(.{ .toggle_voice = call0 });
    app.handle(.{ .show_call = call0 });
}
fn themeOk(_: *App) bool {
    if (qa.find("grid-view") == null) return false;
    for ([_]Id{ me, ana, kaique, duda }) |uid| if (find("grid-tile:{d}", .{uid}) == null) return false;
    return inTile("nome:tile:{d}:Aninha", ana) and qa.overlapping(&.{"grid-tile:"}) == null;
}
fn leave(app: *App) void {
    app.handle(.leave_voice);
}
fn left(app: *App) bool {
    return app.st.voice == null and !app.st.call_view;
}

pub const ops_theme = [_]Op{
    s("tela da call no tema"),
    run(joinView),
    .{ .wait = 300 },
    expect("a grade com cada um, sem sobrepor", themeOk),
    shot("call-grade"),
    run(leave),
    expect("sai da call", left),
};
