//! QA do controle de fora (`larpercord ctl`, app_ctl.zig): clientes em threads mandam
//! comandos de verdade pela porta de verdade (o mesmo `Conn` da linha de comando) e as
//! checagens olham o efeito no app: status e não lidas iguais ao Store, mudo e surdo na
//! call da demonstração (e o que vai para o Discord de mentira), o aperte para falar de
//! fora fazendo a thread de voz transmitir e parar (inclusive sem foco), a janela indo
//! para a bandeja e voltando com os comandos ainda respondendo, abrir um canal por link
//! e por ID, o `watch` mandando uma linha quando as não lidas mudam, o segredo errado
//! recusado, a interface parada respondendo "timeout", o limite de conexões e a opção
//! desligada fechando a porta.
//!
//! `QA_SUITE=ctl LARPER_CTL=1` roda isto (sem LARPER_CTL a porta não abre na demonstração).
const std = @import("std");
const c = @import("c");
const App = @import("app.zig").App;
const R = @import("qa_runner.zig");
const Op = R.Op;
const qa = @import("ui/qa.zig");
const gw = @import("net/fake_gateway.zig");
const types = @import("core/types.zig");
const tray = @import("platform/tray.zig");
const sys = @import("platform/sys.zig");
const ctl = @import("platform/ctl.zig");
const proto = @import("core/ctl.zig");
const voz_audio = @import("net/voz_audio.zig");
const jsonx = @import("net/jsonx.zig");
const Id = types.Id;

const alloc = std.heap.c_allocator;
const Atomic = std.atomic.Value;

fn s(name: []const u8) Op {
    return .{ .section = name };
}
fn click(k: []const u8) Op {
    return .{ .click = .{ .mark = k } };
}
fn expect(name: []const u8, f: *const fn (*App) bool) Op {
    return .{ .expect = .{ .name = name, .check = f } };
}
fn expectLong(name: []const u8, f: *const fn (*App) bool) Op {
    return .{ .expect = .{ .name = name, .check = f, .timeout_ms = 8000 } };
}
fn run(f: *const fn (*App) void) Op {
    return .{ .run = f };
}

const g0: Id = gw.guildId(0);
const call0: Id = gw.channelId(0, 13);
const me: Id = 1000;
const kaique: Id = 1003;

fn portFile(buf: []u8) ?[:0]const u8 {
    return ctl.portPath(buf, true);
}

fn portInfo(buf: []u8) ?proto.PortFile {
    var pb: [512]u8 = undefined;
    const path = portFile(&pb) orelse return null;
    var size: usize = 0;
    const data = c.SDL_LoadFile(path.ptr, &size) orelse return null;
    defer c.SDL_free(data);
    if (size > buf.len) return null;
    @memcpy(buf[0..size], @as([*]const u8, @ptrCast(data))[0..size]);
    return proto.PortFile.parse(buf[0..size]);
}

// --- Um comando numa thread ------------------------------------------------------------

/// Um pedido pela porta, do jeito da linha de comando: conecta, manda, lê a resposta.
const Ask = struct {
    line_buf: [256]u8 = undefined,
    line_len: usize = 0,
    done: Atomic(bool) = .init(false),
    ok: bool = false,
    code: ?proto.Code = null,
    open_err: ?ctl.Conn.OpenError = null,
    body: [64 * 1024]u8 = undefined,
    len: usize = 0,

    fn line(a: *const Ask) []const u8 {
        return a.line_buf[0..a.line_len];
    }
    fn text(a: *const Ask) []const u8 {
        return a.body[0..a.len];
    }
};

var asks: [64]Ask = undefined;
var n_asks: usize = 0;

fn ask(comptime fmt: []const u8, args: anytype) void {
    const a = &asks[n_asks % asks.len];
    n_asks += 1;
    a.* = .{};
    a.line_len = if (std.fmt.bufPrint(&a.line_buf, fmt, args)) |l| l.len else |_| 0;
    c.SDL_DetachThread(c.SDL_CreateThread(askMain, "qa-ctl", a));
}

fn askMain(arg: ?*anyopaque) callconv(.c) c_int {
    const a: *Ask = @ptrCast(@alignCast(arg));
    defer a.done.store(true, .release);
    var pb: [512]u8 = undefined;
    const path = portFile(&pb) orelse return 0;
    var conn = ctl.Conn.open(path) catch |e| {
        a.open_err = e;
        return 0;
    };
    defer conn.close();
    if (!conn.send(a.line())) return 0;
    var r = conn.response(alloc, 10_000) orelse return 0;
    defer r.deinit(alloc);
    a.ok = r.ok;
    a.code = r.code;
    a.len = @min(r.body.items.len, a.body.len);
    @memcpy(a.body[0..a.len], r.body.items[0..a.len]);
    return 0;
}

/// A resposta do último pedido, quando chegou.
fn last() ?*Ask {
    if (n_asks == 0) return null;
    const a = &asks[(n_asks - 1) % asks.len];
    return if (a.done.load(.acquire)) a else null;
}

fn lastOk() ?*Ask {
    const a = last() orelse return null;
    return if (a.ok) a else null;
}

fn lastErr(code: proto.Code) bool {
    const a = last() orelse return false;
    return !a.ok and a.code == code;
}

/// O corpo da última resposta como JSON (o arena vive até a próxima chamada).
var json_arena: ?std.heap.ArenaAllocator = null;
fn lastJson() ?std.json.Value {
    const a = lastOk() orelse return null;
    return parseJson(a.text());
}
fn parseJson(text: []const u8) ?std.json.Value {
    if (json_arena) |*ar| ar.deinit();
    json_arena = std.heap.ArenaAllocator.init(alloc);
    return std.json.parseFromSliceLeaky(std.json.Value, json_arena.?.allocator(), text, .{}) catch null;
}
fn getBool(v: ?std.json.Value) ?bool {
    const x = v orelse return null;
    return switch (x) {
        .bool => |b| b,
        else => null,
    };
}

// --- O que o Store diz --------------------------------------------------------------------

/// As contas pelo caminho mais longo: todos os canais da memória, sem as listas de cada
/// servidor que o app usa (as duas maneiras precisam dar o mesmo).
fn storeCounts(app: *App) [3]i64 {
    var m: i64 = 0;
    var it = app.st.filtros.mentions.valueIterator();
    while (it.next()) |v| m += v.*;
    var dms: i64 = 0;
    var chans: i64 = 0;
    var ci = app.store.channels.valueIterator();
    while (ci.next()) |p| {
        const cs = p.*;
        if (!cs.info.unread or app.st.muted_channels.contains(cs.info.id)) continue;
        if (cs.info.guild == 0) {
            if (cs.info.request == .none) dms += 1;
        } else if (cs.info.kind == .text and cs.info.thread == null) chans += 1;
    }
    return .{ m, dms, chans };
}

fn unreadMatches(v: std.json.Value, app: *App) bool {
    const want = storeCounts(app);
    return jsonx.int(jsonx.get(v, "mentions")) == want[0] and jsonx.int(jsonx.get(v, "dms")) == want[1] and
        jsonx.int(jsonx.get(v, "channels")) == want[2];
}

/// Um canal de texto lido, fora do aberto: a mensagem nova nele acende mais um.
var target: Id = 0;
var channels_before: i64 = 0;
fn pickRead(app: *App, want_read: bool) Id {
    for (app.store.channelsOf(g0)) |id| {
        const cs = app.store.channel(id) orelse continue;
        if (cs.info.kind != .text or (want_read and cs.info.unread) or id == app.st.activeChannel() or id == target) continue;
        if (!app.store.canAccess(&cs.info) or app.st.muted_channels.contains(id)) continue;
        return id;
    }
    return 0;
}
fn injectUnread(app: *App) void {
    // Todos acesos: um volta a ficar lido antes (só no Store, sem confirmar nada).
    target = pickRead(app, true);
    if (target == 0) {
        target = pickRead(app, false);
        if (target != 0) app.store.markRead(target);
    }
    channels_before = storeCounts(app)[2];
    if (target == 0) return;
    const content = alloc.dupe(u8, "chegou pelo qa do ctl") catch return;
    app.events.push(.{ .message_create = .{ .id = types.makeSnowflake(gw.nowMs(), 0xc71), .channel = target, .author = kaique, .timestamp = @divTrunc(gw.nowMs(), 1000), .content = content } });
    @import("platform/window.zig").Window.wake(app.win.wake_type, .gateway);
}
fn oneMoreUnread(app: *App) bool {
    return target != 0 and storeCounts(app)[2] == channels_before + 1;
}

// --- Porta e segredo ------------------------------------------------------------------------

var port_buf: [64]u8 = undefined;
fn listening(_: *App) bool {
    var pb: [64]u8 = undefined;
    return ctl.running() and portInfo(&pb) != null;
}

/// Segredo errado, à mão: a resposta é "ERR auth" e a conexão fecha.
var wrong_line: [128]u8 = undefined;
var wrong_len: usize = 0;
var wrong_closed = Atomic(bool).init(false);
var wrong_done = Atomic(bool).init(false);
fn wrongKey(_: *App) void {
    wrong_done.store(false, .release);
    c.SDL_DetachThread(c.SDL_CreateThread(wrongMain, "qa-ctl-wrong", null));
}
fn wrongMain(_: ?*anyopaque) callconv(.c) c_int {
    defer wrong_done.store(true, .release);
    var pb: [64]u8 = undefined;
    const info = portInfo(&pb) orelse return 0;
    const sock = sys.tcpConnectLocal(info.port) orelse return 0;
    var conn: ctl.Conn = .{ .sock = sock };
    defer conn.close();
    // Do mesmo tamanho e com o formato certo, só não é o segredo.
    var key: [proto.nonce_len]u8 = undefined;
    @memcpy(&key, info.nonce);
    key[0] = if (key[0] == 'a') 'b' else 'a';
    if (!conn.send(&key)) return 0;
    const line = conn.readLine(3000) orelse return 0;
    wrong_len = @min(line.len, wrong_line.len);
    @memcpy(wrong_line[0..wrong_len], line[0..wrong_len]);
    // Depois do "." do fim, nada: a conexão fechou.
    _ = conn.readLine(1000);
    wrong_closed.store(conn.readLine(1000) == null, .release);
    return 0;
}
fn wrongRefused(_: *App) bool {
    if (!wrong_done.load(.acquire)) return false;
    return std.mem.startsWith(u8, wrong_line[0..wrong_len], "ERR auth ") and wrong_closed.load(.acquire);
}

fn askBogus(_: *App) void {
    ask("fazer-cafe", .{});
}
fn bogusUnknown(_: *App) bool {
    return lastErr(.unknown);
}
fn askOpenNothing(_: *App) void {
    ask("open", .{});
}
fn openUsage(_: *App) bool {
    return lastErr(.usage);
}

// --- Status e não lidas ------------------------------------------------------------------------

// --- inspect ---------------------------------------------------------------------------

/// Um canal de texto do servidor aberto que não é o atual (o `click` abre ele).
var insp_target: Id = 0;
fn askInspectFind(app: *App) void {
    const ch = app.st.activeChannel() orelse return;
    const cs = app.store.channel(ch) orelse return;
    for (app.store.channelsOf(app.st.guild)) |id| {
        const other = app.store.channel(id) orelse continue;
        if (id != ch and other.info.kind == .text) {
            insp_target = id;
            break;
        }
    }
    ask("inspect find {s}", .{cs.info.name});
}
fn inspectFound(_: *App) bool {
    const a = lastOk() orelse return false;
    return std.mem.indexOf(u8, a.text(), "text.") != null;
}
fn askInspectEl(_: *App) void {
    ask("inspect el qa:composer", .{});
}
fn inspectEl(_: *App) bool {
    const a = lastOk() orelse return false;
    return std.mem.startsWith(u8, a.text(), "{\"index\":") and std.mem.indexOf(u8, a.text(), "\"scope\":\"composer\"") != null;
}
fn askInspectClick(_: *App) void {
    ask("inspect click qa:channel:{d}", .{insp_target});
}
fn inspectClicked(app: *App) bool {
    _ = lastOk() orelse return false;
    return insp_target != 0 and app.st.activeChannel() == insp_target;
}
fn askInspectShot(_: *App) void {
    _ = c.SDL_RemovePath("qa-out/ctl-inspect.png");
    ask("inspect shot qa-out/ctl-inspect.png", .{});
}
fn inspectShot(_: *App) bool {
    const a = lastOk() orelse return false;
    var info: c.SDL_PathInfo = undefined;
    return std.mem.indexOf(u8, a.text(), "saved") != null and c.SDL_GetPathInfo("qa-out/ctl-inspect.png", &info) and info.size > 1000;
}
fn askInspectNothing(_: *App) void {
    ask("inspect", .{});
}
fn inspectUsage(_: *App) bool {
    return lastErr(.usage);
}

fn askStatus(_: *App) void {
    ask("status", .{});
}
fn askUnread(_: *App) void {
    ask("unread", .{});
}
fn statusMatches(app: *App) bool {
    const v = lastJson() orelse return false;
    const u = app.store.user(me) orelse return false;
    const account = jsonx.get(v, "account") orelse return false;
    if (getBool(jsonx.get(v, "connected")) != true or getBool(jsonx.get(v, "demo")) != true) return false;
    if (!std.mem.eql(u8, jsonx.str(jsonx.get(account, "name")) orelse "", u.name) or jsonx.id(jsonx.get(account, "id")) != me) return false;
    const voice = jsonx.get(v, "voice") orelse return false;
    if (getBool(jsonx.get(voice, "muted")) != app.st.muted or !jsonx.isNull(jsonx.get(voice, "call"))) return false;
    // Pelo menos o canal que acabou de acender: a conta não pode dar certo por ser zero.
    return storeCounts(app)[2] > 0 and unreadMatches(jsonx.get(v, "unread") orelse return false, app);
}
fn unreadAnswer(app: *App) bool {
    return unreadMatches(lastJson() orelse return false, app);
}

// --- watch ------------------------------------------------------------------------------------

/// Um `watch` aberto numa thread, guardando a última linha.
const Watcher = struct {
    cmd: []const u8,
    lines: Atomic(u32) = .init(0),
    ended: Atomic(bool) = .init(false),
    lock: ?*c.SDL_Mutex = null,
    last: [4096]u8 = undefined,
    last_len: usize = 0,

    fn copy(w: *Watcher, out: []u8) []const u8 {
        _ = c.SDL_LockMutex(w.lock);
        defer c.SDL_UnlockMutex(w.lock);
        const n = @min(w.last_len, out.len);
        @memcpy(out[0..n], w.last[0..n]);
        return out[0..n];
    }
};

var w_json: Watcher = .{ .cmd = "watch json" };
var w_bar: Watcher = .{ .cmd = "watch waybar" };

fn startWatch(w: *Watcher) void {
    if (w.lock == null) w.lock = c.SDL_CreateMutex();
    w.lines.store(0, .release);
    w.ended.store(false, .release);
    c.SDL_DetachThread(c.SDL_CreateThread(watchMain, "qa-ctl-watch", w));
}
fn watchMain(arg: ?*anyopaque) callconv(.c) c_int {
    const w: *Watcher = @ptrCast(@alignCast(arg));
    defer w.ended.store(true, .release);
    var pb: [512]u8 = undefined;
    const path = portFile(&pb) orelse return 0;
    var conn = ctl.Conn.open(path) catch return 0;
    defer conn.close();
    if (!conn.send(w.cmd)) return 0;
    const status = conn.readLine(5000) orelse return 0;
    if (!std.mem.eql(u8, status, "OK")) return 0;
    while (conn.readLine(null)) |raw| {
        const body = proto.unstuff(raw) orelse break;
        _ = c.SDL_LockMutex(w.lock);
        w.last_len = @min(body.len, w.last.len);
        @memcpy(w.last[0..w.last_len], body[0..w.last_len]);
        c.SDL_UnlockMutex(w.lock);
        _ = w.lines.fetchAdd(1, .acq_rel);
    }
    return 0;
}
fn startWatchers(_: *App) void {
    startWatch(&w_json);
    startWatch(&w_bar);
}

var json_lines0: u32 = 0;
fn watchersStarted(app: *App) bool {
    if (w_json.lines.load(.acquire) < 1 or w_bar.lines.load(.acquire) < 1) return false;
    json_lines0 = w_json.lines.load(.acquire);
    var buf: [4096]u8 = undefined;
    const v = parseJson(w_json.copy(&buf)) orelse return false;
    if (!unreadMatches(jsonx.get(v, "unread") orelse return false, app)) return false;
    // O do waybar é o JSON do módulo custom, com os quatro campos.
    const b = parseJson(w_bar.copy(&buf)) orelse return false;
    return jsonx.get(b, "text") != null and jsonx.str(jsonx.get(b, "tooltip")) != null and jsonx.get(b, "class") != null and
        jsonx.str(jsonx.get(b, "alt")) != null;
}
fn watchSawUnread(app: *App) bool {
    if (!oneMoreUnread(app) or w_json.lines.load(.acquire) <= json_lines0) return false;
    var buf: [4096]u8 = undefined;
    const v = parseJson(w_json.copy(&buf)) orelse return false;
    return jsonx.int(jsonx.get(jsonx.get(v, "unread") orelse return false, "channels")) == channels_before + 1;
}
fn barSays(comptime alt: []const u8) fn (*App) bool {
    return struct {
        fn f(_: *App) bool {
            var buf: [4096]u8 = undefined;
            const b = parseJson(w_bar.copy(&buf)) orelse return false;
            return std.mem.eql(u8, jsonx.str(jsonx.get(b, "alt")) orelse "", alt);
        }
    }.f;
}

// --- Mudo e surdo na call ---------------------------------------------------------------------

// --- call, volume, status, menções e canais ---------------------------------------

const ana: Id = 1001;
fn statusMembers(app: *App) bool {
    const v = lastJson() orelse return false;
    const call = (v.object.get("voice") orelse return false).object.get("call") orelse return false;
    if (call != .object) return false;
    const members = (call.object.get("members") orelse return false).array.items;
    var eu = false;
    var ana_in = false;
    for (members) |m| {
        const id = std.fmt.parseInt(Id, m.object.get("id").?.string, 10) catch continue;
        if (id == app.store.me and m.object.get("self").?.bool) eu = true;
        if (id == ana) ana_in = std.mem.startsWith(u8, m.object.get("avatar").?.string, "https://cdn.discordapp.com/avatars/") or m.object.get("avatar").?.string.len == 0;
    }
    return eu and ana_in and members.len >= 2 and (v.object.get("presence") orelse return false) == .string;
}
fn askVolume(_: *App) void {
    ask("volume {d} 150", .{ana});
}
fn volumeSet(app: *App) bool {
    _ = lastOk() orelse return false;
    return @abs(app.st.volumes.volume(ana) - 1.5) < 0.01;
}
fn askVolumeBad(_: *App) void {
    ask("volume {d} 300", .{ana});
}
fn lastUsage(_: *App) bool {
    return lastErr(.usage);
}
fn askPresence(_: *App) void {
    ask("presence dnd", .{});
}
fn presenceDnd(app: *App) bool {
    _ = lastOk() orelse return false;
    return app.st.settings.my_status == @backingInt(types.Status.dnd);
}
fn askPresenceBack(_: *App) void {
    ask("presence online", .{});
}
fn presenceOnline(app: *App) bool {
    _ = lastOk() orelse return false;
    return app.st.settings.my_status == @backingInt(types.Status.online);
}
fn askMentions(_: *App) void {
    ask("mentions 10", .{});
}
fn mentionsJson(_: *App) bool {
    const a = lastOk() orelse return false;
    const v = parseJson(a.text()) orelse return false;
    if (v != .array or v.array.items.len == 0) return false;
    const first = v.array.items[0].object;
    return std.mem.startsWith(u8, (first.get("link") orelse return false).string, "https://discord.com/channels/") and first.get("text") != null and first.get("author") != null;
}
fn askChannels(_: *App) void {
    ask("channels", .{});
}
fn channelsJson(app: *App) bool {
    const a = lastOk() orelse return false;
    const v = parseJson(a.text()) orelse return false;
    if (v != .array) return false;
    var voice = false;
    var dm = false;
    for (v.array.items) |it| {
        const kind = it.object.get("kind").?.string;
        if (std.mem.eql(u8, kind, "voice")) voice = true;
        if (std.mem.eql(u8, kind, "dm")) dm = true;
    }
    return voice and dm and v.array.items.len >= app.store.channelsOf(0).len;
}

fn join(app: *App) void {
    app.handle(.{ .select_guild = g0 });
    if (app.st.voice != call0) app.handle(.{ .toggle_voice = call0 });
}
fn inCall(app: *App) bool {
    return app.st.voice == call0 and app.st.voice_status == .connected;
}
fn askMute(_: *App) void {
    ask("mute", .{});
}
fn askUnmute(_: *App) void {
    ask("unmute", .{});
}
fn askToggleMute(_: *App) void {
    ask("toggle-mute", .{});
}
fn askDeafen(_: *App) void {
    ask("toggle-deafen", .{});
}
fn askUndeafen(_: *App) void {
    ask("undeafen", .{});
}
/// O app, a resposta e o Discord (o gateway de mentira devolve o que recebeu) concordam.
fn voiceIs(comptime muted: bool, comptime deaf: bool) fn (*App) bool {
    return struct {
        fn f(app: *App) bool {
            const v = lastJson() orelse return false;
            if (getBool(jsonx.get(v, "muted")) != muted or getBool(jsonx.get(v, "deafened")) != deaf) return false;
            const flags = app.store.voiceFlags(me);
            return app.st.muted == muted and app.st.deafened == deaf and flags.self_mute == muted and flags.self_deaf == deaf;
        }
    }.f;
}
fn statusInCall(app: *App) bool {
    const v = lastJson() orelse return false;
    const call = jsonx.get(jsonx.get(v, "voice") orelse return false, "call") orelse return false;
    const g = app.store.guild(g0) orelse return false;
    return jsonx.id(jsonx.get(call, "channel_id")) == call0 and jsonx.id(jsonx.get(call, "guild_id")) == g0 and
        std.mem.eql(u8, jsonx.str(jsonx.get(call, "state")) orelse "", "connected") and
        std.mem.eql(u8, jsonx.str(jsonx.get(call, "guild")) orelse "", g.name);
}

// --- Aperte para falar ------------------------------------------------------------------------

const sh = &voz_audio.sh;
fn askPttDown(_: *App) void {
    ask("ptt-down", .{});
}
fn askPttUp(_: *App) void {
    ask("ptt-up", .{});
}
fn askPttToggle(_: *App) void {
    ask("ptt-toggle", .{});
}
fn notPtt(_: *App) bool {
    return lastErr(.not_ptt);
}
fn noCall(_: *App) bool {
    return lastErr(.no_call);
}
fn setPtt(app: *App) void {
    app.st.settings.voice_ptt = true;
    app.st.settings.voice_key.set("k:9");
    // O tom constante no lugar do microfone: com a tecla, ele sai.
    app.st.settings.voice_denoise = 0;
    sh.qa_tone.store(0.25, .monotonic);
}
fn clearPtt(app: *App) void {
    app.st.settings.voice_ptt = false;
    sh.qa_tone.store(0, .monotonic);
}
fn pttReady(app: *App) bool {
    return sh.ptt.load(.monotonic) and !app.store.isSpeaking(me, gw.nowMs());
}
fn transmitting(app: *App) bool {
    const a = lastOk() orelse return false;
    if (std.mem.indexOf(u8, a.text(), "\"ptt_held\":true") == null) return false;
    return voz_audio.pttKey() and app.store.isSpeaking(me, gw.nowMs());
}
fn released(app: *App) bool {
    const a = lastOk() orelse return false;
    if (std.mem.indexOf(u8, a.text(), "\"ptt_held\":false") == null) return false;
    return !voz_audio.pttKey() and !app.store.isSpeaking(me, gw.nowMs());
}
fn focusLost(_: *App) void {
    var e: c.SDL_Event = std.mem.zeroes(c.SDL_Event);
    e.type = c.SDL_EVENT_WINDOW_FOCUS_LOST;
    _ = c.SDL_PushEvent(&e);
}
fn stillTransmitting(app: *App) bool {
    c.SDL_Delay(30);
    return transmitting(app);
}
fn leave(app: *App) void {
    app.handle(.leave_voice);
}
fn releasedOnLeave(app: *App) bool {
    return app.st.voice == null and !sh.ptt_ext.load(.monotonic) and !voz_audio.pttKey();
}

// --- Janela --------------------------------------------------------------------------------

fn trayOn(app: *App) void {
    tray.fake = true;
    app.st.settings.close_to_tray = true;
}
fn askHide(_: *App) void {
    ask("hide", .{});
}
fn askShow(_: *App) void {
    ask("show", .{});
}
fn askToggle(_: *App) void {
    ask("toggle", .{});
}
fn hiddenFlag(app: *App) bool {
    return app.win.flags() & c.SDL_WINDOW_HIDDEN != 0;
}
fn inTray(app: *App) bool {
    const a = lastOk() orelse return false;
    return std.mem.indexOf(u8, a.text(), "\"window\":\"hidden\"") != null and hiddenFlag(app) and app.in_tray;
}
fn statusHidden(app: *App) bool {
    const v = lastJson() orelse return false;
    return std.mem.eql(u8, jsonx.str(jsonx.get(v, "window")) orelse "", "hidden") and hiddenFlag(app);
}
/// Fora da call nada vai para o Discord: só o app e a resposta.
fn appMuted(app: *App, muted: bool) bool {
    const v = lastJson() orelse return false;
    return getBool(jsonx.get(v, "muted")) == muted and app.st.muted == muted;
}
fn mutedHidden(app: *App) bool {
    return appMuted(app, true) and hiddenFlag(app);
}
fn unmutedHidden(app: *App) bool {
    return appMuted(app, false) and hiddenFlag(app);
}
fn shown(app: *App) bool {
    const a = lastOk() orelse return false;
    return std.mem.indexOf(u8, a.text(), "\"window\":\"shown\"") != null and !hiddenFlag(app) and !app.in_tray;
}
/// O toggle diz o que fez, e a janela ficou assim.
fn toggled(app: *App) bool {
    const a = lastOk() orelse return false;
    const t = a.text();
    if (std.mem.indexOf(u8, t, "\"window\":\"hidden\"") != null) return hiddenFlag(app) and app.in_tray;
    if (std.mem.indexOf(u8, t, "\"window\":\"shown\"") != null) return !hiddenFlag(app);
    return std.mem.indexOf(u8, t, "\"window\":\"minimized\"") != null and app.tray_click == .minimizar;
}

// --- Abrir ------------------------------------------------------------------------------------

fn askOpenLink(_: *App) void {
    ask("open https://discord.com/channels/{d}/{d}", .{ g0, gw.channelId(0, 5) });
}
fn askOpenId(_: *App) void {
    ask("open {d}", .{gw.channelId(0, 9)});
}
fn askOpenMissing(_: *App) void {
    ask("open 999", .{});
}
fn askOpenVoice(_: *App) void {
    ask("open {d}", .{call0});
}
fn askOpenOther(_: *App) void {
    ask("open https://example.com/channels/1/2", .{});
}
fn openedOn(comptime index: usize) fn (*App) bool {
    return struct {
        fn f(app: *App) bool {
            const want = gw.channelId(0, index);
            const v = lastJson() orelse return false;
            return jsonx.id(jsonx.get(v, "channel_id")) == want and app.st.activeChannel() == want and !hiddenFlag(app);
        }
    }.f;
}
fn notFound(_: *App) bool {
    return lastErr(.not_found);
}
fn notText(_: *App) bool {
    return lastErr(.not_text);
}

// --- Interface parada -----------------------------------------------------------------------------

/// A interface fica 6 s sem voltar ao laço: a conexão desiste em 5 s e responde
/// "timeout"; o pedido que ela largou é solto quando a interface volta.
fn freeze(_: *App) void {
    const t0 = c.SDL_GetTicks();
    while (c.SDL_GetTicks() - t0 < ctl.reply_ms + 1000) c.SDL_Delay(50);
}
fn timedOut(_: *App) bool {
    return lastErr(.timeout);
}
fn statusOk(_: *App) bool {
    return lastJson() != null;
}

// --- Conexões demais -----------------------------------------------------------------------------

var held: [ctl.max_clients + 1]ctl.Conn = undefined;
var held_n = Atomic(usize).init(0);
var held_err: ?ctl.Conn.OpenError = null;
var held_done = Atomic(bool).init(false);
fn fillUp(_: *App) void {
    held_done.store(false, .release);
    c.SDL_DetachThread(c.SDL_CreateThread(fillMain, "qa-ctl-fill", null));
}
fn fillMain(_: ?*anyopaque) callconv(.c) c_int {
    defer held_done.store(true, .release);
    var pb: [512]u8 = undefined;
    const path = portFile(&pb) orelse return 0;
    // As conexões dos pedidos anteriores terminam do lado do app logo depois de fechar. Numa
    // máquina lenta (o CI) uma ainda pode ocupar a vaga quando as oito chegam: solta as que
    // abriu e tenta de novo.
    var tries: u32 = 0;
    while (true) : (tries += 1) {
        c.SDL_Delay(300);
        held_err = null;
        var n: usize = 0;
        while (n < held.len) : (n += 1) {
            held[n] = ctl.Conn.open(path) catch |e| {
                held_err = e;
                break;
            };
        }
        if (n >= ctl.max_clients or tries == 6) {
            held_n.store(n, .release);
            return 0;
        }
        for (held[0..n]) |*conn| conn.close();
    }
}
fn ninthBusy(_: *App) bool {
    return held_done.load(.acquire) and held_n.load(.acquire) == ctl.max_clients and
        (if (held_err) |e| e == error.Busy else false);
}
fn letGo(_: *App) void {
    for (held[0..held_n.load(.acquire)]) |*conn| conn.close();
    held_n.store(0, .release);
}

// --- Desligar ----------------------------------------------------------------------------------

const toggle_mark = "toggle:Controle externo (larpercord ctl)";
var old_port: u16 = 0;
var old_nonce: [proto.nonce_len]u8 = undefined;
fn openAdvanced(app: *App) void {
    var pb: [64]u8 = undefined;
    if (portInfo(&pb)) |info| {
        old_port = info.port;
        @memcpy(&old_nonce, info.nonce);
    }
    app.st.settings.open = true;
    app.st.settings.page = .avancado;
}
fn toggleShown(app: *App) bool {
    return app.st.settings.external_control and qa.visiblePart(toggle_mark) != null;
}
fn closed(app: *App) bool {
    var pb: [512]u8 = undefined;
    const path = portFile(&pb) orelse return false;
    return !app.st.settings.external_control and !ctl.running() and !sys.exists(path.ptr) and
        w_json.ended.load(.acquire) and w_bar.ended.load(.acquire);
}
var old_refused = Atomic(u8).init(0);
fn tryOld(_: *App) void {
    old_refused.store(0, .release);
    c.SDL_DetachThread(c.SDL_CreateThread(tryOldMain, "qa-ctl-old", null));
}
fn tryOldMain(_: ?*anyopaque) callconv(.c) c_int {
    var conn = ctl.Conn.openPort(old_port, &old_nonce) catch |e| {
        old_refused.store(if (e == error.NotRunning) 1 else 2, .release);
        return 0;
    };
    conn.close();
    old_refused.store(2, .release);
    return 0;
}
fn oldRefused(_: *App) bool {
    return old_refused.load(.acquire) == 1;
}
fn reopened(app: *App) bool {
    var pb: [64]u8 = undefined;
    const info = portInfo(&pb) orelse return false;
    return app.st.settings.external_control and ctl.running() and !std.mem.eql(u8, info.nonce, &old_nonce);
}
fn closeSettings(app: *App) void {
    app.st.settings.open = false;
}

pub const ops = [_]Op{
    s("ctl: porta"),
    expect("a porta abre e o arquivo dela existe (rode com LARPER_CTL=1)", listening),

    s("ctl: segredo e pedidos errados"),
    run(wrongKey),
    expect("segredo errado: ERR auth e a conexão fecha", wrongRefused),
    run(askBogus),
    expect("comando que não existe: ERR unknown", bogusUnknown),
    run(askOpenNothing),
    expect("open sem nada: ERR usage", openUsage),

    s("ctl: status e não lidas"),
    run(injectUnread),
    expect("uma mensagem nova num canal lido acende mais um", oneMoreUnread),
    run(askStatus),
    expect("status: conectado, a conta, sem call e as não lidas do Store", statusMatches),
    run(askUnread),
    expect("unread: as mesmas contas", unreadAnswer),

    s("ctl: watch"),
    run(startWatchers),
    expect("json e waybar mandam a linha de agora", watchersStarted),
    run(injectUnread),
    expect("as não lidas mudam: o watch manda a linha nova", watchSawUnread),

    s("ctl: mudo e surdo na call"),
    run(join),
    expectLong("entra na call da demonstração", inCall),
    run(askStatus),
    expect("status mostra a call, o canal e o servidor", statusInCall),
    run(askMute),
    expect("mute: mudo no app e no Discord", voiceIs(true, false)),
    expect("o waybar passa para mudo", barSays("muted")),
    run(askUnmute),
    expect("unmute", voiceIs(false, false)),
    expect("o waybar volta para a call", barSays("call")),
    run(askDeafen),
    expect("toggle-deafen: surdo e mudo", voiceIs(true, true)),
    run(askUndeafen),
    expect("undeafen: ouve, continua mudo (como o botão)", voiceIs(true, false)),
    run(askToggleMute),
    expect("toggle-mute desmuta", voiceIs(false, false)),

    s("ctl: quem está na call, volume, status, menções e canais"),
    run(askStatus),
    expect("status lista quem está na call, com a gente e a foto de quem tem", statusMembers),
    run(askVolume),
    expect("volume muda o volume da pessoa no mixer", volumeSet),
    run(askVolumeBad),
    expect("volume fora de 0 a 200: ERR usage", lastUsage),
    run(askPresence),
    expect("presence dnd troca o status (e o status diz)", presenceDnd),
    run(askPresenceBack),
    expect("presence online volta", presenceOnline),
    run(askMentions),
    expect("mentions devolve as não lidas em JSON, com o link de cada uma", mentionsJson),
    run(askChannels),
    expect("channels devolve servidores, canais e DMs em JSON", channelsJson),

    s("ctl: aperte para falar"),
    run(askPttDown),
    expect("fora do modo aperte para falar: ERR not_ptt", notPtt),
    run(setPtt),
    expect("modo aperte para falar, com som e sem a tecla: calado", pttReady),
    run(askPttDown),
    expect("ptt-down: a thread de voz transmite", transmitting),
    expect("o waybar diz falando", barSays("talking")),
    run(focusLost),
    .{ .wait = 300 },
    expect("sem foco continua apertado (é o atalho do sistema)", stillTransmitting),
    run(askPttUp),
    expect("ptt-up: para de transmitir", released),
    run(askPttToggle),
    expect("ptt-toggle aperta", transmitting),
    run(askPttToggle),
    expect("ptt-toggle de novo solta", released),
    run(askPttDown),
    expect("apertado de novo", transmitting),
    run(leave),
    expect("sair da call solta a tecla de fora", releasedOnLeave),
    run(askPttDown),
    expect("fora da call: ERR no_call", noCall),
    run(clearPtt),

    s("ctl: janela"),
    run(trayOn),
    run(askHide),
    expect("hide: a janela vai para a bandeja", inTray),
    run(askStatus),
    expect("escondida, o status responde e diz hidden", statusHidden),
    run(askMute),
    expect("escondida, o mute também vale", mutedHidden),
    run(askUnmute),
    expect("e o unmute", unmutedHidden),
    run(askShow),
    expect("show: a janela volta", shown),
    run(askToggle),
    expect("toggle faz o que diz", toggled),
    run(askShow),
    expect("show de novo", shown),

    s("ctl: abrir"),
    run(askOpenLink),
    expect("open com o link do canal abre o canal", openedOn(5)),
    run(askOpenId),
    expect("open com o ID abre o canal", openedOn(9)),
    run(askOpenMissing),
    expect("canal que não existe: ERR not_found", notFound),
    run(askOpenVoice),
    expect("canal de voz: ERR not_text", notText),
    run(askOpenOther),
    expect("link de outro site: ERR usage", openUsage),

    s("ctl: inspect (os comandos do Inspetor)"),
    run(askInspectFind),
    expect("inspect find acha os elementos do quadro (gravado a pedido, com o Inspetor fechado)", inspectFound),
    run(askInspectEl),
    expect("inspect el devolve o JSON do elemento", inspectEl),
    run(askInspectClick),
    expect("inspect click (na demonstração) clica e o canal abre", inspectClicked),
    run(askInspectShot),
    expect("inspect shot responde depois que o arquivo foi gravado", inspectShot),
    run(askInspectNothing),
    expect("inspect sem comando: ERR usage", inspectUsage),

    s("ctl: interface parada"),
    run(askStatus),
    run(freeze),
    expectLong("a interface não volta: ERR timeout, sem prender quem chamou", timedOut),
    run(askStatus),
    expect("de volta, responde de novo", statusOk),

    s("ctl: desligar"),
    run(openAdvanced),
    .{ .wait = 200 },
    expect("a opção está em Avançado, ligada", toggleShown),
    click(toggle_mark),
    expectLong("desligada: a porta fecha, o arquivo some e os watch terminam", closed),
    run(tryOld),
    expect("a porta antiga recusa a conexão", oldRefused),
    click(toggle_mark),
    expect("ligada de novo: outra porta, outro segredo", reopened),
    run(closeSettings),
    run(askStatus),
    expect("e responde", statusOk),

    s("ctl: conexões demais"),
    run(fillUp),
    expect("oito conexões ao mesmo tempo; a nona recebe ERR busy", ninthBusy),
    run(letGo),
    run(askStatus),
    expectLong("soltas, responde de novo", statusOk),
};
