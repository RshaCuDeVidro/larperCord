//! QA da abertura pelo retrato da conta em disco (net/state_cache.zig), em dois
//! processos, como abrir o app de novo. O primeiro (QA_SUITE=cache-a) conecta, grava o
//! retrato e o cache de mensagens e fecha. O segundo (QA_SUITE=cache-b, com o READY da
//! demonstração atrasado por LARPER_DEMO_READY_MS) abre pelo retrato: servidores,
//! canais e a conversa aparecem antes do READY, a caixa diz que só manda depois de
//! conectar (e o Enter não manda), e quando o READY e o histórico chegam nada pula: a
//! mesma conversa, a última mensagem e as listas no mesmo lugar. Os dois com o mesmo
//! LARPER_DEMO_EPOCH_MS (as conversas da demonstração são as mesmas nos dois) e sem
//! apagar qa-out/cache entre eles (tools/qa.sh).
const std = @import("std");
const App = @import("app.zig").App;
const R = @import("qa_runner.zig");
const Op = R.Op;
const qa = @import("ui/qa.zig");
const gw = @import("net/fake_gateway.zig");
const msg_cache = @import("net/msg_cache.zig");
const state_cache = @import("net/state_cache.zig");
const send_limits = @import("ui/composer_limits.zig");
const ui_cj = @import("ui/conjuntos.zig");
const app_cj = @import("app_conjuntos.zig");
const c = @import("c");
const Rect = @import("theme/layout.zig").Rect;
const Id = @import("core/types.zig").Id;

fn s(name: []const u8) Op {
    return .{ .section = name };
}
fn expect(name: []const u8, f: *const fn (*App) bool) Op {
    return .{ .expect = .{ .name = name, .check = f } };
}
fn run(f: *const fn (*App) void) Op {
    return .{ .run = f };
}

fn active(app: *App) ?*@import("core/store.zig").ChannelState {
    const id = app.st.activeChannel() orelse return null;
    return app.store.channel(id);
}

fn find(comptime fmt: []const u8, args: anytype) ?Rect {
    var b: [48]u8 = undefined;
    return qa.find(std.fmt.bufPrint(&b, fmt, args) catch return null);
}

// --- Primeiro processo: conecta, grava e fecha ---------------------------------------

/// Um conjunto de abas em uso, com outra ordem que a do demo (#zig e #geral, a ativa é
/// o #geral): ele volta na abertura pelo retrato, antes do READY, e fica depois dele.
const set_tabs = [_]Id{ gw.channelId(0, 9), gw.channelId(0, 4) };
fn saveTabSet(app: *App) void {
    ui_cj.qa_read = true;
    var buf: [256]u8 = undefined;
    if (ui_cj.filePath(&buf, app.store.me)) |p| _ = c.SDL_RemovePath(p.ptr);
    app.st.tabs.clearRetainingCapacity();
    app.st.tabs.appendSlice(app.gpa, &set_tabs) catch return;
    app.st.tab = 1;
    const name = app.st.gpa.dupe(u8, "retrato") catch return;
    app_cj.handle(app, .{ .save = name });
}
fn tabSetOn(app: *App) bool {
    const set = app.st.conjuntos.activeSet() orelse return false;
    return std.mem.eql(u8, set.name, "retrato") and std.mem.eql(Id, app.st.tabs.items, &set_tabs) and app.st.tab == 1;
}
fn tabSetSaved(app: *App) bool {
    var buf: [256]u8 = undefined;
    const p = ui_cj.filePath(&buf, app.store.me) orelse return false;
    var info: c.SDL_PathInfo = undefined;
    return tabSetOn(app) and c.SDL_GetPathInfo(p.ptr, &info);
}

var saved_ok = false;
fn saveNow(app: *App) void {
    msg_cache.flushDirty(&app.store);
    saved_ok = state_cache.save(&app.store);
}
fn snapshotSaved(app: *App) bool {
    if (!saved_ok) return false;
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const snap = state_cache.load(arena.allocator()) orelse return false;
    return snap.me == app.store.me and snap.guilds.len == app.store.guilds.items.len and snap.channels.len > 0;
}

pub const ops_a = [_]Op{
    s("abrir pelo retrato: antes de fechar"),
    run(saveTabSet),
    expect("um conjunto de abas em uso, gravado (outra ordem que a do demo)", tabSetSaved),
    run(saveNow),
    expect("o retrato da conta e a conversa aberta vão para o disco", snapshotSaved),
};

// --- Segundo processo: abre pelo retrato --------------------------------------------

fn cachedOpen(app: *App) bool {
    return app.store.from_cache and !app.store.ready and !app.login.visible() and app.st.activeChannel() != null;
}
fn railShown(app: *App) bool {
    return !app.store.ready and find("guild:{d}", .{app.store.guilds.items[0].id}) != null;
}

/// O canal aberto e uma linha da lista de canais dele à vista.
fn channelListed(app: *App) bool {
    const cs = active(app) orelse return false;
    return find("channel:{d}", .{cs.info.id}) != null;
}

/// A última mensagem com ID que está na conversa (a de baixo, que fica parada).
fn lastId(app: *App) Id {
    const cs = active(app) orelse return 0;
    var i = cs.messages.items.len;
    while (i > 0) {
        i -= 1;
        if (cs.messages.items[i].msg.id != 0) return cs.messages.items[i].msg.id;
    }
    return 0;
}

fn cachedMessages(app: *App) bool {
    const cs = active(app) orelse return false;
    if (!cs.cached or cs.messages.items.len == 0 or !cs.messages.items[cs.messages.items.len - 1].from_cache) return false;
    return find("msg:{d}", .{lastId(app)}) != null;
}

/// Os nomes já saem com o apelido do servidor (a ana é "Aninha" no primeiro servidor da
/// demonstração), e a nossa linha com o status escolhido, não offline.
fn facesAndStatus(app: *App) bool {
    if (app.store.ready) return false;
    const me = app.store.user(app.store.me) orelse return false;
    return qa.find("nome:msg:1001:Aninha") != null and qa.find("nome:msg:1001:ana.exe") == null and me.status == .online;
}

fn connectingNote(app: *App) bool {
    const cs = active(app) orelse return false;
    return send_limits.blockFor(&app.store, &cs.info, gw.nowMs()).reason == .connecting;
}
fn composerShown(app: *App) bool {
    return !app.store.ready and qa.find("composer") != null;
}

const typed = "oi, escrito antes de conectar";
var sends_before: u64 = 0;
fn trySend(app: *App) void {
    sends_before = gw.sent.messages.load(.acquire);
    // Como a caixa faz no Enter: o texto sai dela e vai para o App.
    @memset(&app.st.input, 0);
    const text = app.gpa.dupe(u8, typed) catch return;
    app.handle(.{ .send_message = text });
}
fn notSent(app: *App) bool {
    const cs = active(app) orelse return false;
    for (cs.messages.items) |m| if (m.pending) return false;
    const box = std.mem.sliceTo(&app.st.input, 0);
    return std.mem.eql(u8, box, typed) and gw.sent.messages.load(.acquire) == sends_before and
        std.mem.indexOf(u8, app.st.toast.text(), "conectando") != null;
}
fn clearBox(app: *App) void {
    @memset(&app.st.input, 0);
    app.st.input_sync = true;
}

/// Onde estavam as coisas antes do READY.
var before_channel: Id = 0;
var before_last: Id = 0;
var before_msg_y: f32 = 0;
var before_guild_y: f32 = 0;
var before_chan_y: f32 = 0;
var before_tabs: usize = 0;
fn recordPlaces(app: *App) void {
    before_channel = app.st.activeChannel() orelse 0;
    before_last = lastId(app);
    before_tabs = app.st.tabs.items.len;
    if (find("msg:{d}", .{before_last})) |r| before_msg_y = r.y;
    if (find("guild:{d}", .{app.store.guilds.items[0].id})) |r| before_guild_y = r.y;
    if (find("channel:{d}", .{before_channel})) |r| before_chan_y = r.y;
}
fn placesRecorded(_: *App) bool {
    return before_channel != 0 and before_last != 0 and before_msg_y != 0 and before_guild_y != 0 and before_chan_y != 0;
}

fn synced(app: *App) bool {
    const cs = active(app) orelse return false;
    return app.store.ready and !app.store.from_cache and cs.history == .loaded and !cs.cached;
}

fn near(a: f32, b: f32) bool {
    return @abs(a - b) <= 1;
}
fn noJump(app: *App) bool {
    if (app.st.activeChannel() != before_channel or app.st.tabs.items.len != before_tabs) return false;
    if (lastId(app) != before_last) return false;
    const m = find("msg:{d}", .{before_last}) orelse return false;
    const g = find("guild:{d}", .{app.store.guilds.items[0].id}) orelse return false;
    const row = find("channel:{d}", .{before_channel}) orelse return false;
    return near(m.y, before_msg_y) and near(g.y, before_guild_y) and near(row.y, before_chan_y);
}
fn sendsAgain(app: *App) bool {
    const cs = active(app) orelse return false;
    return send_limits.blockFor(&app.store, &cs.info, gw.nowMs()).reason != .connecting;
}

pub const ops_b = [_]Op{
    s("abrir pelo retrato: antes do READY"),
    expect("a tela abre pelo retrato, sem a abertura e sem esperar o READY", cachedOpen),
    .{ .wait = 100 },
    .{ .shot = "cache-0" },
    expect("os servidores na barra", railShown),
    expect("o canal aberto está na lista de canais", channelListed),
    expect("o conjunto de abas que estava em uso voltou, com a aba ativa dele, antes do READY", tabSetOn),
    expect("a conversa aberta mostra as mensagens do cache", cachedMessages),
    expect("os nomes com o apelido do servidor e a nossa linha com o status escolhido, antes do READY", facesAndStatus),
    expect("a caixa diz que só dá para enviar depois de conectar", connectingNote),
    expect("a caixa está na tela", composerShown),
    run(trySend),
    expect("Enter antes de conectar: nada sai, o texto volta para a caixa e o aviso explica", notSent),
    run(clearBox),
    .{ .wait = 150 },
    run(recordPlaces),
    expect("anota onde a conversa e as listas estão", placesRecorded),
    .{ .shot = "cache-antes" },
    s("abrir pelo retrato: o READY chega"),
    .{ .expect = .{ .name = "o READY chega e o histórico de verdade troca o do cache", .check = synced, .timeout_ms = 8000 } },
    .{ .wait = 300 },
    expect("nada pulou: a mesma conversa, a última mensagem e as listas no mesmo lugar", noJump),
    expect("a caixa volta a enviar", sendsAgain),
    expect("e o conjunto de abas continua em uso, com as mesmas abas", tabSetOn),
    .{ .shot = "cache-depois" },
};
