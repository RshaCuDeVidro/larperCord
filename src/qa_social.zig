//! QA dos pedidos de mensagem e do grupo de DM: pedido e spam fora das conversas, sem
//! notificar; aceitar e recusar um de cada vez; pôr e tirar gente do grupo, renomear e sair.
//! O servidor de mentira anota o pedido que iria para o Discord.
const std = @import("std");
const c = @import("c");
const App = @import("app.zig").App;
const R = @import("qa_runner.zig");
const Op = R.Op;
const qa = @import("ui/qa.zig");
const types = @import("core/types.zig");
const dm_requests = @import("ui/dm_requests.zig");
const gw = @import("net/fake_gateway.zig");
const platform = @import("platform/window.zig");
const Id = types.Id;

const req_dm = gw.request_dm;
const spam_dm = gw.spam_dm;
const group: Id = 900_006;

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

/// O último pedido que iria para o Discord ("PUT /channels/…").
fn sentReq(want: []const u8) bool {
    const n = gw.sent.social_len.load(.monotonic);
    return std.mem.eql(u8, gw.sent.social_req[0..@min(n, gw.sent.social_req.len)], want);
}
fn markFor(comptime fmt: []const u8, id: Id) bool {
    var b: [64]u8 = undefined;
    return qa.find(std.fmt.bufPrint(&b, fmt, .{id}) catch return false) != null;
}

fn openFirstDm(app: *App) void {
    app.actions.append(app.gpa, .{ .select_channel = gw.dmId(0) }) catch {};
}
fn hiddenFromList(app: *App) bool {
    const r = app.store.channel(req_dm) orelse return false;
    const sp = app.store.channel(spam_dm) orelse return false;
    return r.info.request == .pending and sp.info.request == .spam and dm_requests.view == .none and
        qa.find("dm-requests") != null and !markFor("channel:{d}", req_dm) and !markFor("channel:{d}", spam_dm) and markFor("channel:{d}", group);
}

var notified0: u32 = 0;
var seq: u64 = 0;
fn injectRequestMsg(app: *App) void {
    notified0 = app.st.filtros.notified;
    seq += 1;
    const content = std.heap.c_allocator.dupe(u8, "oi! posso te mandar uma coisa?") catch return;
    app.events.push(.{ .message_create = .{ .id = types.makeSnowflake(gw.nowMs(), 0x3b000 + seq), .channel = req_dm, .author = 1009, .timestamp = @divTrunc(gw.nowMs(), 1000), .content = content } });
    platform.Window.wake(app.win.wake_type, .gateway);
}
fn notNotified(app: *App) bool {
    const cs = app.store.channel(req_dm) orelse return false;
    return cs.info.unread and app.st.filtros.notified == notified0 and app.st.filtros.count(req_dm) == 0;
}
fn requestsOpen(_: *App) bool {
    return dm_requests.view == .requests and markFor("request:{d}", req_dm) and markFor("request-accept:{d}", req_dm) and
        !markFor("request:{d}", spam_dm) and !markFor("channel:{d}", group);
}
fn spamOpen(_: *App) bool {
    return dm_requests.view == .spam and markFor("request:{d}", spam_dm) and !markFor("request:{d}", req_dm);
}
var socials0: u64 = 0;
fn noteSocials(_: *App) void {
    socials0 = gw.sent.socials.load(.monotonic);
}
fn declined(app: *App) bool {
    var b: [64]u8 = undefined;
    return gw.sent.socials.load(.monotonic) == socials0 + 1 and sentReq(std.fmt.bufPrint(&b, "DELETE /channels/{d}/recipients/@me", .{spam_dm}) catch return false) and
        app.store.channel(spam_dm) == null;
}
fn accepted(app: *App) bool {
    var b: [64]u8 = undefined;
    const cs = app.store.channel(req_dm) orelse return false;
    return gw.sent.socials.load(.monotonic) == socials0 + 2 and sentReq(std.fmt.bufPrint(&b, "PUT /channels/{d}/recipients/@me", .{req_dm}) catch return false) and
        cs.info.request == .none;
}
fn emptyShown(_: *App) bool {
    return dm_requests.view == .requests and qa.find("dm-requests-empty") != null;
}
fn acceptedInList(_: *App) bool {
    return dm_requests.view == .none and markFor("channel:{d}", req_dm) and qa.find("dm-requests") == null;
}

fn membersOpen(app: *App) bool {
    return app.st.popup == .group_members and markFor("group-member:{d}", 1001) and markFor("group-remove:{d}", 1003) and
        !markFor("group-remove:{d}", app.store.me);
}
fn filterFinds(_: *App) bool {
    return markFor("group-add:{d}", 1007) and !markFor("group-add:{d}", 1002) and !markFor("group-friend:{d}", 1001);
}
fn hasMember(app: *App, uid: Id) bool {
    const cs = app.store.channel(group) orelse return false;
    return std.mem.indexOfScalar(Id, cs.info.recipients, uid) != null;
}
fn added(app: *App) bool {
    var b: [64]u8 = undefined;
    return sentReq(std.fmt.bufPrint(&b, "PUT /channels/{d}/recipients/1007", .{group}) catch return false) and hasMember(app, 1007) and
        markFor("group-member:{d}", 1007);
}
fn removed(app: *App) bool {
    var b: [64]u8 = undefined;
    return sentReq(std.fmt.bufPrint(&b, "DELETE /channels/{d}/recipients/1003", .{group}) catch return false) and !hasMember(app, 1003) and
        hasMember(app, 1007) and !markFor("group-member:{d}", 1003);
}
fn closed(app: *App) bool {
    return app.st.popup == .none;
}
fn renamed(app: *App) bool {
    const cs = app.store.channel(group) orelse return false;
    // Renomear não desfaz quem entrou e saiu.
    return app.st.popup == .none and std.mem.eql(u8, cs.info.name, "rolê novo") and hasMember(app, 1007) and !hasMember(app, 1003);
}
fn leaveAsks(app: *App) bool {
    return app.st.popup == .menu and app.st.popup.menu.kind == .group_leave and app.store.channel(group) != null;
}
fn tLeaveConfirm(app: *App, b: []u8) []const u8 {
    const cs = app.store.channel(group) orelse return "";
    return std.fmt.bufPrint(b, "menu:Sair de «{s}»", .{cs.info.name}) catch "";
}
fn left(app: *App) bool {
    var b: [64]u8 = undefined;
    return sentReq(std.fmt.bufPrint(&b, "DELETE /channels/{d}", .{group}) catch return false) and app.store.channel(group) == null and
        !markFor("channel:{d}", group);
}

// --- Lista de DMs: a mais recente em cima, ao vivo ---------------------------

/// A primeira conversa da lista (fora pedidos e spam).
fn topDm(app: *App) Id {
    for (app.store.channelsOf(0)) |id| if (app.store.channel(id)) |cs| if (cs.info.request == .none) return id;
    return 0;
}
fn rowY(id: Id) ?f32 {
    var b: [64]u8 = undefined;
    const r = qa.find(std.fmt.bufPrint(&b, "channel:{d}", .{id}) catch return null) orelse return null;
    return r.y;
}
/// Primeira da lista e desenhada acima de todas as outras linhas.
fn onTop(app: *App, id: Id) bool {
    if (topDm(app) != id) return false;
    const y = rowY(id) orelse return false;
    for (app.store.channelsOf(0)) |other| if (other != id) if (rowY(other)) |oy| if (oy <= y) return false;
    return true;
}
fn push(app: *App, e: @import("core/event.zig").Event) void {
    app.events.push(e);
    platform.Window.wake(app.win.wake_type, .gateway);
}
var dm_seq: u64 = 0;
/// Uma mensagem chegando numa DM (`dm` = o que o gateway de verdade manda antes,
/// para MESSAGE_CREATE sem servidor). Retorna o ID dela.
fn incomingDm(app: *App, ch: Id, author: Id, dm: bool, is_group: bool) Id {
    dm_seq += 1;
    const id = types.makeSnowflake(gw.nowMs(), 0x3c000 + dm_seq);
    const content = std.heap.c_allocator.dupe(u8, "e aí, sumido") catch return 0;
    if (dm) push(app, .{ .dm_message = .{ .channel = ch, .author = author, .group = is_group } });
    push(app, .{ .message_create = .{ .id = id, .channel = ch, .author = author, .timestamp = @divTrunc(gw.nowMs(), 1000), .content = content } });
    return id;
}

const received_dm = gw.dmId(4);
fn injectReceived(app: *App) void {
    _ = incomingDm(app, received_dm, 1005, true, false);
}
fn receivedOnTop(app: *App) bool {
    return onTop(app, received_dm);
}

const sent_dm = gw.dmId(2);
var sends0: u64 = 0;
fn noteSends(_: *App) void {
    sends0 = gw.sent.messages.load(.monotonic);
}
fn sentOnTop(app: *App) bool {
    const cs = app.store.channel(sent_dm) orelse return false;
    var confirmed = false;
    for (cs.messages.items) |*m| if (!m.pending and m.msg.author == app.store.me and std.mem.eql(u8, m.msg.content, "subindo a conversa")) {
        confirmed = true;
    };
    return gw.sent.messages.load(.monotonic) > sends0 and confirmed and onTop(app, sent_dm);
}

var new_dm: Id = 0;
fn injectNewDm(app: *App) void {
    new_dm = types.makeSnowflake(gw.nowMs(), 0x3d001);
    const name = std.heap.c_allocator.dupe(u8, "gustavo") catch return;
    push(app, .{ .channel_upsert = .{ .id = new_dm, .guild = 0, .name = name, .topic = "", .recipient = 1008 } });
}
fn newDmOnTop(app: *App) bool {
    return new_dm != 0 and onTop(app, new_dm);
}

var fetches0: u64 = 0;
var unknown_dm: Id = 0;
fn injectUnknownDm(app: *App) void {
    // Uma DM antiga, fechada há um mês: só a mensagem chega.
    unknown_dm = types.makeSnowflake(gw.nowMs() - 30 * 86_400_000, 0x3d002);
    gw.qa_dm.group.store(0, .release);
    gw.qa_dm.user.store(1010, .release);
    gw.qa_dm.channel.store(unknown_dm, .release);
    fetches0 = gw.sent.fetch_channels.load(.monotonic);
    _ = incomingDm(app, unknown_dm, 1010, true, false);
}
fn fetchedOnce(id: Id) bool {
    return gw.sent.fetch_channels.load(.monotonic) == fetches0 + 1 and gw.sent.fetch_channel.load(.acquire) == id;
}
fn unknownOnTop(app: *App) bool {
    const cs = app.store.channel(unknown_dm) orelse return false;
    return cs.info.recipient == 1010 and cs.info.unread and cs.messages.items.len == 1 and fetchedOnce(unknown_dm) and onTop(app, unknown_dm);
}

var unknown_group: Id = 0;
fn injectUnknownGroup(app: *App) void {
    unknown_group = types.makeSnowflake(gw.nowMs() - 86_400_000, 0x3d003);
    gw.qa_dm.group.store(1, .release);
    gw.qa_dm.group_with.store(1008, .release);
    gw.qa_dm.user.store(1007, .release);
    gw.qa_dm.channel.store(unknown_group, .release);
    fetches0 = gw.sent.fetch_channels.load(.monotonic);
    _ = incomingDm(app, unknown_group, 1007, true, true);
}
fn groupFetched(app: *App) bool {
    const cs = app.store.channel(unknown_group) orelse return false;
    return cs.info.group and std.mem.eql(u8, cs.info.name, gw.qa_group_name) and cs.info.recipients.len == 2 and
        fetchedOnce(unknown_group) and onTop(app, unknown_group);
}

const closed_dm = gw.dmId(1);
fn closeDm(app: *App) void {
    push(app, .{ .channel_delete = closed_dm });
}
fn dmClosed(app: *App) bool {
    return app.store.channel(closed_dm) == null and rowY(closed_dm) == null;
}
var reopen_msg: Id = 0;
fn reopenDm(app: *App) void {
    fetches0 = gw.sent.fetch_channels.load(.monotonic);
    reopen_msg = incomingDm(app, closed_dm, 1002, true, false);
}
fn reopened(app: *App) bool {
    const cs = app.store.channel(closed_dm) orelse return false;
    return cs.info.recipient == 1002 and fetchedOnce(closed_dm) and onTop(app, closed_dm);
}
fn deleteLast(app: *App) void {
    push(app, .{ .message_delete = .{ .channel = closed_dm, .id = reopen_msg } });
}
fn stillOnTop(app: *App) bool {
    const cs = app.store.channel(closed_dm) orelse return false;
    for (cs.messages.items) |*m| if (m.msg.id == reopen_msg and !m.deleted) return false;
    return onTop(app, closed_dm);
}

pub const ops = [_]Op{
    s("pedidos de mensagem: fora das conversas e sem notificar"),
    run(openFirstDm),
    .{ .wait = 300 },
    expect("pedido e spam ficam fora das conversas, numa linha só deles", hiddenFromList),
    run(injectRequestMsg),
    expect("mensagem de um pedido não notifica nem conta como DM", notNotified),
    click("dm-requests"),
    expect("a linha abre a aba de pedidos", requestsOpen),
    .{ .wait = 150 },
    .{ .shot = "pedidos-mensagem" },
    click("dm-tab:spam"),
    expect("a aba de spam mostra só o spam", spamOpen),
    .{ .shot = "pedidos-spam" },
    run(noteSocials),
    click("request-decline:900013"),
    expect("recusar manda DELETE .../recipients/@me e tira da lista", declined),
    click("dm-tab:requests"),
    click("request-accept:900012"),
    expect("aceitar manda PUT .../recipients/@me e o pedido vira conversa", accepted),
    expect("sem pedidos, a aba diz que não há nada", emptyShown),
    click("dm-requests"),
    expect("a conversa aceita aparece entre as DMs e a linha some", acceptedInList),

    s("grupo de DM: pessoas, nome e sair"),
    .{ .rclick = .{ .mark = "channel:900006" } },
    click("menu:Pessoas do grupo…"),
    expect("o menu do grupo abre as pessoas (o dono pode tirar)", membersOpen),
    .{ .text = "mari" },
    expect("o filtro procura entre os amigos que não estão no grupo", filterFinds),
    .{ .wait = 150 },
    .{ .shot = "grupo-pessoas" },
    click("group-add:1007"),
    expect("adicionar manda PUT .../recipients/{id} e a pessoa entra", added),
    click("group-remove:1003"),
    expect("o dono tira alguém com DELETE .../recipients/{id}", removed),
    click("group-close"),
    expect("fechar", closed),
    .{ .rclick = .{ .mark = "channel:900006" } },
    click("menu:Editar grupo…"),
    .{ .key = .{ .key = c.ImGuiKey_A, .ctrl = true } },
    .{ .text = "rolê novo" },
    click("edit-save"),
    expect("renomear o grupo troca o nome (e mantém quem está nele)", renamed),
    .{ .rclick = .{ .mark = "channel:900006" } },
    click("menu:Sair do grupo"),
    expect("sair do grupo pede confirmação", leaveAsks),
    .{ .shot = "grupo-sair" },
    .{ .click = .{ .dyn = tLeaveConfirm } },
    expect("confirmar manda DELETE /channels/{id} e o grupo some", left),

    s("lista de DMs: a mais recente em cima, ao vivo"),
    run(injectReceived),
    expect("mensagem recebida sobe a DM para o topo", receivedOnTop),
    click("channel:900002"),
    run(noteSends),
    click("composer"),
    .{ .text = "subindo a conversa" },
    .{ .key = .{ .key = c.ImGuiKey_Enter } },
    expect("mensagem enviada também sobe a DM (e fica lá depois de confirmada)", sentOnTop),
    run(injectNewDm),
    expect("DM nova (CHANNEL_CREATE) aparece no topo", newDmOnTop),
    run(injectUnknownDm),
    expect("só a mensagem de uma DM que a lista não tem: ela aparece no topo e o canal é pedido", unknownOnTop),
    run(injectUnknownGroup),
    expect("grupo só pela mensagem: aparece no topo e o canal pedido traz o nome e quem está nele", groupFetched),
    .{ .shot = "dms-ordem" },
    run(closeDm),
    expect("DM fechada em outro aparelho sai da lista", dmClosed),
    run(reopenDm),
    expect("mensagem nova reabre a DM fechada, no topo", reopened),
    run(deleteLast),
    .{ .wait = 200 },
    expect("apagar a última mensagem não reordena", stillOnTop),
};
