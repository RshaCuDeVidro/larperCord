//! QA do perfil de servidor (#19). No primeiro servidor da demonstração a ana tem
//! apelido e foto de lá, o kaique só o apelido e o brunão só a foto. Cada lugar onde a
//! pessoa aparece usa o perfil do servidor: a lista da call, a lista de membros, a
//! mensagem, a resposta, a menção, o "digitando", o @ da caixa (que acha pelos dois
//! nomes), o cartão (com o nome global menor embaixo, a bio, os pronomes e o banner
//! de lá), o perfil grande e o mixer da call. Em outro servidor tudo volta ao global.
//! Sozinho: QA_SUITE=perfil; só a parte de cada tema: QA_SUITE=perfil-tema.
const std = @import("std");
const c = @import("c");
const App = @import("app.zig").App;
const R = @import("qa_runner.zig");
const Op = R.Op;
const qa = @import("ui/qa.zig");
const gw = @import("net/fake_gateway.zig");
const face_json = @import("net/face_json.zig");
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
const g1: Id = gw.guildId(1);
/// #setups: sem não lidas, abre no fim (as mensagens do QA aparecem embaixo).
const setups: Id = gw.channelId(0, 6);
const call0: Id = gw.channelId(0, 13);
const games0: Id = gw.channelId(0, 14);
const call1: Id = gw.channelId(1, 13);
const ana: Id = 1001;
const kaique: Id = 1003;
const bruno: Id = 1002;

fn find(comptime fmt: []const u8, args: anytype) ?Rect {
    var b: [64]u8 = undefined;
    return qa.find(std.fmt.bufPrint(&b, fmt, args) catch return null);
}

/// O nome que apareceu no lugar (widgets.markName), em qualquer ponto da tela.
fn named(comptime place: []const u8, uid: Id, name: []const u8) bool {
    return find("nome:" ++ place ++ ":{d}:{s}", .{ uid, name }) != null;
}

/// O nome, dentro de `r` (o mesmo nome aparece em vários lugares).
fn namedIn(comptime place: []const u8, uid: Id, name: []const u8, r: Rect) bool {
    var b: [64]u8 = undefined;
    return qa.anyIn(std.fmt.bufPrint(&b, "nome:" ++ place ++ ":{d}:{s}", .{ uid, name }) catch return false, r);
}

/// A foto do perfil do servidor dentro de `r`.
fn serverAvatarIn(uid: Id, r: Rect) bool {
    var b: [32]u8 = undefined;
    return qa.anyIn(std.fmt.bufPrint(&b, "avatar-srv:{d}", .{uid}) catch return false, r);
}

fn push(app: *App, e: @import("core/event.zig").Event) void {
    app.events.push(e);
    platform.Window.wake(app.win.wake_type, .gateway);
}

// --- Primeiro servidor -------------------------------------------------------------

fn openSetups(app: *App) void {
    app.handle(.{ .select_guild = g0 });
    app.handle(.{ .select_channel = setups });
}
fn inSetups(app: *App) bool {
    const cs = app.store.channel(setups) orelse return false;
    return app.st.activeChannel() == setups and cs.history == .loaded;
}

fn voiceList0(_: *App) bool {
    const ra = find("voice-member:{d}:{d}", .{ call0, ana }) orelse return false;
    const rd = find("voice-member:{d}:{d}", .{ call0, kaique }) orelse return false;
    const rb = find("voice-member:{d}:{d}", .{ games0, bruno }) orelse return false;
    return namedIn("voice", ana, "Aninha", ra) and namedIn("voice", kaique, "Kaká do Zig", rd) and namedIn("voice", bruno, "brunão", rb) and
        serverAvatarIn(ana, ra) and !serverAvatarIn(kaique, rd) and serverAvatarIn(bruno, rb);
}

fn memberList0(_: *App) bool {
    const ra = find("member:{d}", .{ana}) orelse return false;
    const rd = find("member:{d}", .{kaique}) orelse return false;
    const rb = find("member:{d}", .{bruno}) orelse return false;
    return namedIn("member", ana, "Aninha", ra) and namedIn("member", kaique, "Kaká do Zig", rd) and namedIn("member", bruno, "brunão", rb) and
        serverAvatarIn(ana, ra) and !serverAvatarIn(kaique, rd) and serverAvatarIn(bruno, rb);
}

var first: Id = 0;
var second: Id = 0;

/// A ana escreve, e a mari responde mencionando ela.
fn postMessages(app: *App) void {
    const now = gw.nowMs();
    const a = std.heap.c_allocator;
    first = types.makeSnowflake(now, 0x3e001);
    second = types.makeSnowflake(now, 0x3e002);
    push(app, .{ .message_create = .{ .id = first, .channel = setups, .author = ana, .timestamp = @divTrunc(now, 1000), .content = a.dupe(u8, "rice novo, o que acham?") catch return } });
    push(app, .{ .message_create = .{ .id = second, .channel = setups, .author = 1007, .timestamp = @divTrunc(now, 1000), .content = a.dupe(u8, "<@1001> ficou lindo!") catch return, .reply_to = first } });
}
fn authorShown(_: *App) bool {
    const r = find("msg:{d}", .{first}) orelse return false;
    return namedIn("msg", ana, "Aninha", r) and serverAvatarIn(ana, r);
}
fn replyAndMention(_: *App) bool {
    const r = find("msg:{d}", .{second}) orelse return false;
    return namedIn("reply", ana, "Aninha", r) and namedIn("mention", ana, "Aninha", r) and serverAvatarIn(ana, r);
}

fn typingDuda(app: *App) void {
    push(app, .{ .typing_start = .{ .channel = setups, .user = kaique } });
}
fn typingShown(_: *App) bool {
    return named("typing", kaique, "Kaká do Zig");
}

fn autoNick(_: *App) bool {
    return named("auto", ana, "Aninha");
}
fn composerEmpty(_: *App) bool {
    return find("nome:auto:{d}:Aninha", .{ana}) == null;
}

fn openCard(app: *App) void {
    app.st.popup = .{ .profile = .{ .user = ana, .x = 420, .y = 200 } };
}
fn cardShown(_: *App) bool {
    const av = qa.find("profile-avatar") orelse return false;
    return named("card", ana, "Aninha") and named("global", ana, "ana.exe") and serverAvatarIn(ana, av);
}
/// Na tela: a bio e o banner do perfil do servidor (e os pronomes de lá no Store, à
/// parte dos globais).
fn cardServerProfile(app: *App) bool {
    const p = app.store.profiles.get(ana) orelse return false;
    return p.guild == g0 and std.mem.eql(u8, p.guild_pronouns, "ela/elu") and !std.mem.eql(u8, p.pronouns, "ela/elu") and
        qa.find("profile-bio-srv") != null and qa.find("profile-banner-srv") != null;
}

fn openFull(app: *App) void {
    app.handle(.{ .open_full_profile = .{ .user = ana } });
}
fn fullShown(app: *App) bool {
    if (app.st.popup != .profile_full) return false;
    const av = qa.find("profile-avatar") orelse return false;
    return named("full", ana, "Aninha") and named("global", ana, "ana.exe") and serverAvatarIn(ana, av);
}
fn closed(app: *App) bool {
    return app.st.popup == .none;
}

fn inCall(app: *App) bool {
    return app.st.voice == call0;
}
fn mixerShown(app: *App) bool {
    if (app.st.popup != .mixer) return false;
    const r = find("nome:mixer:{d}:Aninha", .{ana}) orelse return false;
    return serverAvatarIn(ana, r) and named("mixer", kaique, "Kaká do Zig");
}
fn outOfCall(app: *App) bool {
    return app.st.voice == null;
}

// --- Outro servidor ----------------------------------------------------------------

fn openGuild1(app: *App) void {
    app.handle(.{ .select_guild = g1 });
}
fn voiceList1(app: *App) bool {
    if (app.st.guild != g1) return false;
    const ra = find("voice-member:{d}:{d}", .{ call1, ana }) orelse return false;
    return namedIn("voice", ana, "ana.exe", ra) and !serverAvatarIn(ana, ra) and find("nome:voice:{d}:Aninha", .{ana}) == null;
}
fn cardGlobal(app: *App) bool {
    const av = qa.find("profile-avatar") orelse return false;
    const p = app.store.profiles.get(ana) orelse return false;
    return named("card", ana, "ana.exe") and find("nome:global:{d}:ana.exe", .{ana}) == null and !serverAvatarIn(ana, av) and
        p.guild == g1 and qa.find("profile-bio-srv") == null and qa.find("profile-banner-srv") == null;
}

/// De volta ao primeiro servidor, o cartão pede o perfil de lá de novo (o Store tinha o
/// do outro servidor).
fn cardServerAgain(app: *App) bool {
    const p = app.store.profiles.get(ana) orelse return false;
    return app.st.guild == g0 and p.guild == g0 and named("card", ana, "Aninha") and qa.find("profile-bio-srv") != null;
}

/// Configurações → Minha conta: os pronomes e a bio são os globais, mesmo com um
/// servidor com perfil próprio selecionado (senão salvar gravaria os de lá como globais).
fn openAccount(app: *App) void {
    app.st.settings.page = .conta;
    app.st.settings.open = true;
}
fn accountGlobal(app: *App) bool {
    const f = @import("ui/settings_conta.zig").qaFields();
    // (A bio do servidor fala do larperCord; a global, não.)
    return app.st.guild == g0 and std.mem.eql(u8, f[0], "ele/dele") and f[1].len > 0 and std.mem.indexOf(u8, f[1], "larperCord") == null;
}
fn closeSettings(app: *App) void {
    app.st.settings.open = false;
}

/// Um GUILD_MEMBER_UPDATE parcial (ganhou um cargo, sem `nick`) chega pelo mesmo
/// leitor do gateway (net/face_json.zig): o apelido fica.
fn partialUpdate(app: *App) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), "{\"guild_id\":\"500000\",\"user\":{\"id\":\"1001\"},\"roles\":[\"7\"],\"avatar\":\"demo\"}", .{}) catch return;
    var pb: [128]u8 = undefined;
    const ch = face_json.read(&pb, g0, ana, v) orelse return;
    var o = face_json.owned(std.heap.c_allocator, ch);
    // A foto da demonstração não é um caminho do CDN: fica a de antes.
    if (o.face.avatar) |t| std.heap.c_allocator.free(t);
    o.face.avatar = null;
    o.keep_avatar = true;
    push(app, .{ .member_face = .{ .guild = g0, .user = ana, .face = o.face, .keep_nick = o.keep_nick, .keep_avatar = o.keep_avatar } });
}
fn nickKept(_: *App) bool {
    const r = find("member:{d}", .{ana}) orelse return false;
    return namedIn("member", ana, "Aninha", r) and serverAvatarIn(ana, r);
}

/// O apelido muda com a conversa já medida: a menção na resposta muda junto, e a
/// mensagem é medida de novo (a menção continua dentro dela).
const long_nick = "Aninha Comprida";
fn renameAna(app: *App) void {
    push(app, .{ .member_face = .{ .guild = g0, .user = ana, .face = .{ .nick = std.heap.c_allocator.dupe(u8, long_nick) catch return }, .keep_avatar = true } });
}
fn renamed(_: *App) bool {
    const r = find("msg:{d}", .{second}) orelse return false;
    const m = find("nome:mention:{d}:" ++ long_nick, .{ana}) orelse return false;
    return m.bottom() <= r.bottom() + 1 and namedIn("reply", ana, long_nick, r);
}
fn renameBack(app: *App) void {
    push(app, .{ .member_face = .{ .guild = g0, .user = ana, .face = .{ .nick = std.heap.c_allocator.dupe(u8, "Aninha") catch return }, .keep_avatar = true } });
}
fn nameBack(_: *App) bool {
    return named("mention", ana, "Aninha");
}

/// "Respondendo a" na barra da caixa: o apelido.
fn replyToFirst(app: *App) void {
    app.st.reply_to = first;
}
fn replyingShown(_: *App) bool {
    return named("replying", ana, "Aninha");
}
fn cancelReply(app: *App) void {
    app.st.reply_to = 0;
}

/// Na DM com a ana: o nome global.
fn openDm(app: *App) void {
    app.handle(.{ .select_channel = gw.dmId(0) });
}
fn dmOpen(app: *App) bool {
    const cs = app.store.channel(gw.dmId(0)) orelse return false;
    return app.st.activeChannel() == gw.dmId(0) and cs.history == .loaded;
}
var dm_msg: Id = 0;
fn dmMessage(app: *App) void {
    const now = gw.nowMs();
    dm_msg = types.makeSnowflake(now, 0x3e003);
    push(app, .{ .message_create = .{ .id = dm_msg, .channel = gw.dmId(0), .author = ana, .timestamp = @divTrunc(now, 1000), .content = std.heap.c_allocator.dupe(u8, "e aí <@1001>?") catch return } });
}
fn dmGlobal(_: *App) bool {
    const r = find("msg:{d}", .{dm_msg}) orelse return false;
    return namedIn("msg", ana, "ana.exe", r) and namedIn("mention", ana, "ana.exe", r) and !serverAvatarIn(ana, r);
}

pub const ops = [_]Op{
    s("perfil do servidor (#19)"),
    run(openSetups),
    expect("abre o #setups do primeiro servidor", inSetups),
    expect("lista da call: apelido e foto do servidor (ana), só o apelido (kaique), só a foto (brunão)", voiceList0),
    expect("lista de membros: os mesmos apelidos e fotos", memberList0),
    shot("perfil-servidor-listas"),
    run(postMessages),
    expect("mensagem: o autor com o apelido e a foto do servidor", authorShown),
    expect("resposta e menção: o apelido também", replyAndMention),
    run(renameAna),
    expect("o apelido muda com a conversa já na tela: a menção e a resposta mudam, e a mensagem é medida de novo", renamed),
    run(renameBack),
    expect("e volta", nameBack),
    run(partialUpdate),
    expect("um GUILD_MEMBER_UPDATE sem \"nick\" (ganhou um cargo) não apaga o apelido", nickKept),
    run(replyToFirst),
    expect("\"Respondendo a\": o apelido", replyingShown),
    run(cancelReply),
    run(typingDuda),
    expect("digitando: o apelido", typingShown),
    shot("perfil-servidor-mensagens"),
    click("composer"),
    .{ .text = "@Anin" },
    expect("@ na caixa, pelo apelido: aparece o apelido", autoNick),
    .{ .key = .{ .key = c.ImGuiKey_A, .ctrl = true } },
    key(c.ImGuiKey_Backspace),
    .{ .text = "@ana" },
    expect("@ pelo nome global também acha, e mostra o apelido", autoNick),
    shot("perfil-servidor-arroba"),
    .{ .key = .{ .key = c.ImGuiKey_A, .ctrl = true } },
    key(c.ImGuiKey_Backspace),
    key(c.ImGuiKey_Escape),
    expect("caixa vazia de novo", composerEmpty),
    run(openCard),
    expect("cartão: o apelido em cima, o nome global menor embaixo, a foto do servidor", cardShown),
    expect("cartão: bio, pronomes e banner do perfil do servidor", cardServerProfile),
    shot("perfil-servidor-cartao"),
    run(openFull),
    expect("perfil grande: o apelido, o nome global e a foto do servidor", fullShown),
    shot("perfil-servidor-perfil"),
    key(c.ImGuiKey_Escape),
    expect("Esc fecha o perfil", closed),
    click("channel:500014"),
    expect("entra na call", inCall),
    click("voice-mixer"),
    expect("mixer da call: o apelido e a foto do servidor", mixerShown),
    shot("perfil-servidor-mixer"),
    click("voice-mixer-close"),
    click("hangup"),
    expect("sai da call", outOfCall),

    s("perfil do servidor: outro servidor"),
    run(openGuild1),
    expect("em outro servidor, a lista da call com o nome e a foto globais", voiceList1),
    run(openCard),
    expect("o cartão com o nome global, sem a linha de baixo, sem a foto e sem o perfil do primeiro servidor", cardGlobal),
    shot("perfil-servidor-outro"),
    key(c.ImGuiKey_Escape),
    expect("Esc fecha o cartão", closed),
    run(openSetups),
    run(openCard),
    expect("de volta ao primeiro servidor, o cartão traz o perfil de lá de novo", cardServerAgain),
    key(c.ImGuiKey_Escape),
    run(openAccount),
    expect("Configurações → Minha conta mostra os pronomes e a bio globais, não os do servidor", accountGlobal),
    run(closeSettings),
    run(openDm),
    expect("abre a DM com a ana", dmOpen),
    run(dmMessage),
    expect("na DM, o nome, a menção e a foto globais", dmGlobal),
};

// --- Cada tema -----------------------------------------------------------------------

fn openGuild0(app: *App) void {
    app.handle(.{ .select_guild = g0 });
}
/// Nos temas de linha alta os canais de voz ficam abaixo da dobra: rola até eles.
fn listMark(_: *App, _: []u8) []const u8 {
    return if (qa.find("channel:500014") != null or qa.find("channel:500005") != null) "channel:500005" else "";
}
fn wheelDown(app: *App) void {
    c.ImGuiIO_AddMouseWheelEvent(app.io, 0, -40);
}
fn themeOk(_: *App) bool {
    // Tema sem lista de canais à vista (zen esconde a navegação): nada a conferir. Com
    // ela, a call precisa ter rolado para a tela.
    if (qa.find("channel:500005") == null and qa.find("channel:500014") == null) return true;
    const ra = find("voice-member:{d}:{d}", .{ call0, ana }) orelse return false;
    const rd = find("voice-member:{d}:{d}", .{ call0, kaique }) orelse return false;
    return namedIn("voice", ana, "Aninha", ra) and namedIn("voice", kaique, "Kaká do Zig", rd);
}

pub const ops_theme = [_]Op{
    s("perfil do servidor no tema"),
    run(openGuild0),
    .{ .wait = 300 },
    .{ .hover = .{ .dyn = listMark } },
    run(wheelDown),
    .{ .wait = 300 },
    expect("na lista da call, o apelido do perfil do servidor", themeOk),
    shot("perfil-servidor-call"),
};
