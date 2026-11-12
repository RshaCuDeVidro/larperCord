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
const call_grid = @import("ui/call_grid.zig");
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
fn wheelGrid(app: *App) void {
    c.ImGuiIO_AddMouseWheelEvent(app.io, 0, -60);
}
/// Rolando a grade, o último quadro aparece.
fn lastVisible(_: *App) bool {
    return qa.visiblePart("grid-tile:1013") != null;
}
/// Em quadros pequenos, o mudo e o surdo não cobrem o nome nem a atividade.
fn pillClear(_: *App) bool {
    return qa.overlapping(&.{ "grid-muted:", "nome:tile:" }) == null and qa.overlapping(&.{ "grid-deaf:", "nome:tile:" }) == null and
        qa.overlapping(&.{ "grid-muted:", "grid-activity:" }) == null;
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
/// Saiu pelo vermelho da tela: fora da call, e de volta ao segundo servidor, de onde a
/// tela foi aberta (lista e conversa dele).
fn leftCall(app: *App) bool {
    const ch = app.st.activeChannel() orelse return false;
    return app.st.voice == null and !app.st.call_view and qa.find("composer") != null and
        app.st.guild == g1 and app.store.guildOfChannel(ch) == g1;
}
const games0: Id = gw.channelId(0, 14);
/// O que o clique num canal de voz faz (comp_channels): entra e abre a tela. (O
/// "Jogando" fica embaixo da faixa de voz com quatro pessoas na call de cima.)
fn switchCall(app: *App) void {
    app.handle(.{ .toggle_voice = games0 });
    app.handle(.{ .show_call = games0 });
}
/// Na tela, clicar em outro canal de voz troca de call e continua na tela.
fn onGames(app: *App) bool {
    return app.st.voice == games0 and app.st.call_view and qa.find("grid-view") != null;
}
/// Esc depois de trocar de call ainda volta para o segundo servidor.
fn backToGuild1Again(app: *App) bool {
    const ch = app.st.activeChannel() orelse return false;
    return app.st.voice == games0 and !app.st.call_view and app.st.guild == g1 and app.store.guildOfChannel(ch) == g1;
}
/// A foto aberta grande por cima da tela: Esc fecha só ela.
fn viewerOpen(app: *App) bool {
    return app.st.viewer != null;
}
fn viewerClosedStillView(app: *App) bool {
    return app.st.viewer == null and app.st.call_view;
}
/// A tela da call de um servidor que ainda não foi aberto nesta sessão: a lista de
/// membros dele chega (o pedido sai ao abrir a tela).
const call3: Id = gw.channelId(3, 13);
fn callFreshGuild(app: *App) void {
    app.handle(.{ .toggle_voice = call3 });
    app.handle(.{ .show_call = call3 });
}
fn freshMembers(app: *App) bool {
    var keys: [4][56]u8 = undefined;
    var lens: [4]u8 = undefined;
    return app.st.call_view and app.st.voice == call3 and qa.keysWith(&.{"member:"}, &keys, &lens) > 0;
}
fn leaveFresh(app: *App) void {
    app.handle(.leave_voice);
}
fn backInDm(app: *App) bool {
    return app.st.voice == null and !app.st.call_view and app.st.activeChannel() == dm0 and app.st.guild == 0;
}

const g1: Id = gw.guildId(1);
fn fromGuild1(app: *App) void {
    app.handle(.{ .select_guild = g1 });
}
fn onGuild1(app: *App) bool {
    const ch = app.st.activeChannel() orelse return false;
    return app.st.guild == g1 and app.store.guildOfChannel(ch) == g1 and !app.st.call_view;
}
fn backToGuild1(app: *App) bool {
    const ch = app.st.activeChannel() orelse return false;
    return !app.st.call_view and app.st.guild == g1 and app.store.guildOfChannel(ch) == g1 and qa.find("composer") != null and qa.find("grid-view") == null;
}
fn otherTab(app: *App) void {
    app.st.tabs.append(app.gpa, gw.channelId(1, 5)) catch return;
    app.handle(.{ .focus_tab = app.st.tabs.items.len - 1 });
}
fn tabLeft(app: *App) bool {
    return !app.st.call_view and app.st.activeChannel() == gw.channelId(1, 5) and qa.find("grid-view") == null;
}
fn openSettings(app: *App) void {
    app.st.settings.open = true;
}
fn settingsClosedStillView(app: *App) bool {
    return !app.st.settings.open and app.st.call_view;
}
fn paletteOpen(app: *App) bool {
    return app.st.palette.open;
}
fn paletteClosedStillView(app: *App) bool {
    return !app.st.palette.open and app.st.call_view;
}
fn twoLeave(app: *App) void {
    push(app, .{ .voice_state = .{ .channel = null, .user = kaique } });
    push(app, .{ .voice_state = .{ .channel = null, .user = duda } });
}
fn sideBySide(_: *App) bool {
    const a = find("grid-tile:{d}", .{me}) orelse return false;
    const b = find("grid-tile:{d}", .{ana}) orelse return false;
    return find("grid-tile:{d}", .{kaique}) == null and @abs(a.y - b.y) < 1 and a.w > 300;
}
fn twoBack(app: *App) void {
    push(app, .{ .voice_state = .{ .channel = call0, .user = kaique } });
    push(app, .{ .voice_state = .{ .channel = call0, .user = duda } });
}
/// No primeiro quadro com o novo tamanho, a foto da ana já está lá (não a letra): o
/// veredito desse quadro vale, mesmo que a foto chegue depois.
var photo_w: f32 = 0;
var photo_verdict: ?bool = null;
fn notePhotoWidth(_: *App) void {
    photo_w = if (find("grid-tile:{d}", .{ana})) |r| r.w else 0;
    photo_verdict = null;
}
fn photoStays(_: *App) bool {
    if (photo_verdict) |v| return v;
    const r = find("grid-tile:{d}", .{ana}) orelse return false;
    if (@abs(r.w - photo_w) < 1) return false;
    photo_verdict = !qa.anyIn("avatar-letter:1001", r) and qa.anyIn("avatar-srv:1001", r);
    return photo_verdict.?;
}
/// (O que importa é não ter quebrado: sem quadro que caiba, a grade não desenha nada.)
fn stillAlive(app: *App) bool {
    return app.st.call_view and app.st.voice == call0;
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

// --- A barra, o medidor, sozinho e as cores do tema ---------------------------------

/// Microfone, fone, mixer, sair e o tempo da call, todos dentro da barra, sem sobrepor.
fn barShown(_: *App) bool {
    const bar = qa.find("grid-bar") orelse return false;
    for ([_][]const u8{ "grid-mic", "grid-deaf", "grid-mixer", "grid-leave", "grid-timer" }) |k| {
        const r = qa.find(k) orelse return false;
        if (r.x < bar.x - 0.5 or r.right() > bar.right() + 0.5 or r.y < bar.y - 0.5 or r.bottom() > bar.bottom() + 0.5) return false;
    }
    // (O `overlapping` junta as marcas de todos os prefixos, e a setinha do microfone,
    // "grid-mic-menu", fica dentro do botão dele.)
    const t = qa.find("grid-timer").?;
    return t.right() <= qa.find("grid-mic").?.x;
}
/// O fundo do quadro é o do tema, com no máximo o toque da cor da foto.
fn themeFill(_: *App) bool {
    const t = call_grid.qa_tile;
    if (!t.set or t.tint > 0.5) return false;
    const diff = @max(@max(@abs(t.fill.r - t.base.r), @abs(t.fill.g - t.base.g)), @abs(t.fill.b - t.base.b));
    return diff <= t.tint + 0.01;
}
fn meterShown(_: *App) bool {
    const m = qa.find("grid-meter") orelse return false;
    const t = find("grid-tile:{d}", .{me}) orelse return false;
    return m.x >= t.x and m.right() <= t.right() and m.bottom() <= t.bottom() and qa.overlapping(&.{ "grid-meter", "nome:tile:" }) == null;
}
fn meterGone(_: *App) bool {
    return qa.find("grid-meter") == null and qa.find("grid-tile:1000") != null;
}
fn othersLeave(app: *App) void {
    for ([_]Id{ ana, kaique, duda }) |uid| push(app, .{ .voice_state = .{ .channel = null, .user = uid } });
}
fn othersBack(app: *App) void {
    for ([_]Id{ ana, kaique, duda }) |uid| push(app, .{ .voice_state = .{ .channel = call0, .user = uid } });
}
fn aloneShown(_: *App) bool {
    const t = find("grid-tile:{d}", .{me}) orelse return false;
    const a = qa.find("grid-alone") orelse return false;
    const i = qa.find("grid-invite") orelse return false;
    return t.w <= 381 and a.y >= t.bottom() and i.y >= t.bottom() and find("grid-tile:{d}", .{ana}) == null and
        qa.overlapping(&.{ "grid-alone", "grid-invite" }) == null;
}
fn inviteOpen(app: *App) bool {
    return switch (app.st.popup) {
        .create_invite => |ci| ci.channel == call0,
        else => false,
    };
}
fn inviteClosedStillView(app: *App) bool {
    return app.st.popup == .none and app.st.call_view;
}
fn aloneGone(_: *App) bool {
    return qa.find("grid-alone") == null and qa.find("grid-invite") == null and find("grid-tile:{d}", .{ana}) != null;
}
/// Em cada tema: sozinho, a linha do convite embaixo do quadro (ou da linha, no
/// terminal), sem sobrepor nada.
fn aloneThemeOk(_: *App) bool {
    const a = qa.find("grid-alone") orelse return false;
    const t = find("grid-tile:{d}", .{me}) orelse return false;
    return a.y >= t.bottom() - 0.5 and qa.overlapping(&.{ "grid-alone", "grid-tile:" }) == null and
        qa.overlapping(&.{ "grid-invite", "grid-tile:" }) == null and qa.overlapping(&.{ "grid-alone", "grid-invite" }) == null;
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
    expect("numa barra, com o tempo da call, sem sobrepor", barShown),
    expect("o fundo do quadro é o do tema, com só um toque da cor da foto", themeFill),
    expect("sem o mouse em cima, o seu quadro não mostra o medidor (nem pede quadros)", meterGone),
    .{ .hover = .{ .mark = "grid-tile:1000" } },
    expect("com o mouse no seu quadro, o nível do microfone aparece embaixo, sem cobrir o nome", meterShown),
    .{ .hover = .{ .mark = "grid-back" } },
    expect("e some quando o mouse sai", meterGone),
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

    s("tela da call: voltar, abas e Esc"),
    run(fromGuild1),
    expect("numa aba do segundo servidor", onGuild1),
    click("voice-view"),
    expect("\"ver a call\" de outro servidor abre a call do primeiro", viewOpen),
    key(c.ImGuiKey_Escape),
    expect("Esc volta para o segundo servidor, com a lista e a conversa dele", backToGuild1),
    click("voice-view"),
    run(otherTab),
    expect("trocar de aba sai da tela da call", tabLeft),
    click("voice-view"),
    run(openSettings),
    key(c.ImGuiKey_Escape),
    expect("Esc com as Configurações abertas fecha só elas", settingsClosedStillView),
    .{ .key = .{ .key = c.ImGuiKey_K, .ctrl = true } },
    expect("a paleta abre", paletteOpen),
    key(c.ImGuiKey_Escape),
    expect("Esc com a paleta aberta fecha só ela", paletteClosedStillView),
    .{ .key = .{ .key = c.ImGuiKey_K, .ctrl = true } },
    .{ .text = "Call da madrugada" },
    key(c.ImGuiKey_Enter),
    expect("a paleta no canal da call em que já estamos abre a tela, sem sair", viewOpen),
    click("grid-tile:1001"),
    click("menu:Ver foto de perfil"),
    expect("a foto da ana aberta grande por cima da tela", viewerOpen),
    key(c.ImGuiKey_Escape),
    expect("Esc com a foto aberta fecha só ela", viewerClosedStillView),

    s("tela da call: sozinho"),
    run(othersLeave),
    expect("sozinho, o quadro encolhe e embaixo vêm o mascote, \"Só você por aqui\" e o convite", aloneShown),
    shot("call-sozinho"),
    click("grid-invite"),
    expect("o botão abre o convite do servidor", inviteOpen),
    key(c.ImGuiKey_Escape),
    expect("Esc fecha o convite e a tela da call continua", inviteClosedStillView),
    run(othersBack),
    expect("com gente de volta, sem a linha do convite", aloneGone),

    s("tela da call: tamanhos"),
    .{ .resize = .{ 1920, 1080 } },
    run(twoLeave),
    expect("duas pessoas numa janela maximizada ficam lado a lado, não empilhadas", sideBySide),
    run(twoBack),
    .{ .resize = .{ 1280, 800 } },
    .{ .wait = 300 },
    run(notePhotoWidth),
    .{ .resize = .{ 1100, 800 } },
    expect("o quadro muda de tamanho sem a foto sumir (a foto é pedida num tamanho só)", photoStays),
    .{ .resize = .{ 330, 600 } },
    .{ .wait = 200 },
    expect("janela estreita demais para um quadro: nada quebra", stillAlive),
    .{ .resize = .{ 1280, 800 } },

    s("tela da call: muita gente"),
    .{ .resize = .{ 860, 600 } },
    run(addCrowd),
    .{ .wait = 300 },
    expect("com 13 na call numa janela pequena, os quadros ficam no mínimo e a grade rola", crowdScrolls),
    expect("o mudo e o surdo, em cima, não cobrem o nome nem a atividade", pillClear),
    shot("call-muita-gente"),
    .{ .hover = .{ .mark = "grid-view" } },
    run(wheelGrid),
    run(wheelGrid),
    expect("rolando a grade, o último quadro aparece", lastVisible),
    run(removeCrowd),
    .{ .resize = .{ 1280, 800 } },
    expect("quem saiu some da grade", crowdGone),
    run(switchCall),
    expect("na tela, ir para outro canal de voz troca de call e continua na tela", onGames),
    key(c.ImGuiKey_Escape),
    expect("Esc depois de trocar de call ainda volta para o segundo servidor", backToGuild1Again),
    click("voice-view"),
    click("grid-leave"),
    expect("sair pelo vermelho da tela sai da call e volta para o segundo servidor, de onde ela abriu", leftCall),

    s("tela da call: DM"),
    run(openDm0),
    expect("abre a DM", dmReady),
    click("call-start"),
    expect("na call da DM, a grade numa faixa em cima da conversa", dmBand),
    shot("call-dm"),
    click("grid-leave"),
    expect("sair pela faixa", dmLeft),

    s("tela da call: servidor ainda não aberto"),
    run(callFreshGuild),
    expect("a tela da call de um servidor nunca aberto traz a lista de membros dele", freshMembers),
    run(leaveFresh),
    expect("sair volta para a DM", backInDm),
};

// --- Cada tema -----------------------------------------------------------------------

/// Entra na call pelo clique, como uma pessoa: no canal de voz (na lista de canais do
/// tema) ou, sem ela, pela ação.
/// O que veio antes na bateria pode ter tirado alguém da call (a chamada no grupo leva a
/// ana): a ana, a duda e o kaique voltam para a Call da madrugada antes de conferir.
fn joinCall(app: *App) void {
    app.handle(.{ .select_guild = g0 });
    const cs = app.store.channel(call0) orelse return;
    for ([_]Id{ ana, duda, kaique }) |uid| if (std.mem.indexOfScalar(Id, cs.voice_members.items, uid) == null)
        push(app, .{ .voice_state = .{ .channel = call0, .user = uid } });
}
/// O canal de voz à vista (nos temas de linha alta ele fica abaixo da dobra): o
/// clique; senão, a ação.
fn joinedOrList(app: *App, _: []u8) []const u8 {
    if (app.st.voice != null) return "";
    if (qa.visiblePart("channel:500014") != null) return "channel:500014";
    app.handle(.{ .toggle_voice = call0 });
    return "";
}
/// "Ver a call" na faixa de voz (no terminal, o [ver]); sem a faixa, pela ação.
fn viewMark(app: *App, _: []u8) []const u8 {
    if (qa.visiblePart("voice-view") == null) {
        app.handle(.{ .show_call = call0 });
        return "";
    }
    return "voice-view";
}
fn inViewNow(app: *App) bool {
    return app.st.voice == call0 and app.st.call_view;
}
fn micMuted(app: *App) bool {
    return app.st.muted and qa.find("grid-mic") != null;
}
fn micBack(app: *App) bool {
    return !app.st.muted;
}
fn statusFits(_: *App) bool {
    return qa.find("voice-status-cut") == null;
}
fn lang(comptime l: @import("ui/i18n.zig").Lang) *const fn (*App) void {
    return struct {
        fn f(_: *App) void {
            @import("ui/i18n.zig").set(l);
        }
    }.f;
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
    run(joinCall),
    .{ .wait = 300 },
    .{ .click = .{ .dyn = joinedOrList } },
    .{ .click = .{ .dyn = viewMark } },
    expect("entra e abre a tela pela faixa de voz", inViewNow),
    expect("a grade com cada um, sem sobrepor", themeOk),
    click("grid-mic"),
    expect("o botão do microfone da tela (texto nos temas de terminal) muta", micMuted),
    click("grid-mic"),
    expect("e desmuta", micBack),
    run(lang(.en)),
    .{ .wait = 100 },
    expect("\"Voice Connected\" cabe na faixa de voz", statusFits),
    run(lang(.ru)),
    .{ .wait = 100 },
    expect("em russo também", statusFits),
    run(lang(.pt)),
    .{ .wait = 100 },
    expect("\"Voz conectada\" também", statusFits),
    shot("call-grade"),
    run(othersLeave),
    .{ .wait = 100 },
    expect("sozinho: o quadro, o mascote e o convite sem sobrepor", aloneThemeOk),
    shot("call-sozinho"),
    run(othersBack),
    run(leave),
    expect("sai da call", left),
};
