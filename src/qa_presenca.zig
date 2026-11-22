//! QA do Rich Presence: a opção liga o discord-ipc (no XDG_RUNTIME_DIR do QA), um
//! jogo de mentira conecta, faz o handshake e manda a atividade, e o gateway de
//! mentira recebe o op 3. Null, desconexão e desligar limpam. Só no Linux (o
//! cliente daqui fala pelo socket Unix). tools/qa.sh dá um XDG_RUNTIME_DIR só do
//! QA: o cliente fala com o caminho que o servidor escolheu, nunca com um
//! Discord de verdade que esteja aberto.
const std = @import("std");
const c = @import("c");
const App = @import("app.zig").App;
const R = @import("qa_runner.zig");
const Op = R.Op;
const qa = @import("ui/qa.zig");
const gw = @import("net/fake_gateway.zig");
const rpc = @import("net/rpc_ipc.zig");
const proto = @import("net/rpc_proto.zig");

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

const toggle = "toggle:Compartilhar minha atividade (Rich Presence)";
const client_id = "1234567890";

// --- O jogo de mentira -----------------------------------------------------------

var fd: c_int = -1;
var rx: [32 * 1024]u8 = undefined;
var rx_len: usize = 0;
/// Onde o servidor escutou (o QA confere que o arquivo some ao desligar).
var path_buf: [256]u8 = @splat(0);
var path_len: usize = 0;

fn sockPath() [:0]const u8 {
    return path_buf[0..path_len :0];
}

fn connectClient() void {
    closeClient();
    const p = sockPath();
    var addr: extern struct { family: u16, path: [108]u8 } = .{ .family = c.AF_UNIX, .path = @splat(0) };
    if (p.len == 0 or p.len >= addr.path.len) return;
    @memcpy(addr.path[0..p.len], p);
    const f = c.socket(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_CLOEXEC, 0);
    if (f < 0) return;
    if (c.connect(f, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) != 0) {
        _ = c.close(f);
        return;
    }
    _ = c.fcntl(f, c.F_SETFL, c.O_NONBLOCK);
    fd = f;
    rx_len = 0;
}

fn closeClient() void {
    if (fd >= 0) _ = c.close(fd);
    fd = -1;
}

fn sendRaw(bytes: []const u8) void {
    if (fd < 0) return;
    _ = c.send(fd, bytes.ptr, bytes.len, 0x4000);
}

fn sendFrame(op: u32, json: []const u8) void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.heap.c_allocator);
    proto.writeFrame(&out, std.heap.c_allocator, op, json) catch return;
    sendRaw(out.items);
}

/// O que o servidor respondeu até agora (sem bloquear).
fn received() []const u8 {
    while (fd >= 0 and rx_len < rx.len) {
        const r = c.recv(fd, rx[rx_len..].ptr, rx.len - rx_len, 0);
        if (r <= 0) break;
        rx_len += @intCast(r);
    }
    return rx[0..rx_len];
}

fn got(needle: []const u8) bool {
    return std.mem.indexOf(u8, received(), needle) != null;
}

// --- Passos ------------------------------------------------------------------------

fn fileMode() ?u32 {
    const p = sockPath();
    if (p.len == 0) return null;
    var st: c.struct_stat = undefined;
    if (c.lstat(p.ptr, &st) != 0) return null;
    return @intCast(st.st_mode);
}

fn offNothing(_: *App) bool {
    return !rpc.running() and rpc.path().len == 0;
}

fn openPrivacy(app: *App) void {
    app.st.settings.page = .privacidade;
    app.st.settings.open = true;
}

fn closeSettings(app: *App) void {
    app.st.settings.open = false;
}

fn onSocket(app: *App) bool {
    if (!rpc.running()) return false;
    const p = rpc.path();
    if (p.len >= path_buf.len) return false;
    @memcpy(path_buf[0..p.len], p);
    path_buf[p.len] = 0;
    path_len = p.len;
    const dir = std.mem.span(c.SDL_getenv("XDG_RUNTIME_DIR") orelse return false);
    const mode = fileMode() orelse return false;
    // Socket (S_IFSOCK) só do dono, em $XDG_RUNTIME_DIR/discord-ipc-N, com a opção salva.
    return app.st.settings.rich_presence and std.mem.startsWith(u8, p, dir) and std.mem.indexOf(u8, p[dir.len..], "/discord-ipc-") != null and
        mode & 0o170000 == 0o140000 and mode & 0o777 == 0o600;
}

fn handshake(_: *App) void {
    connectClient();
    sendFrame(proto.op_handshake, "{\"v\":1,\"client_id\":\"" ++ client_id ++ "\"}");
}

fn readyReply(app: *App) bool {
    var b: [64]u8 = undefined;
    const id = std.fmt.bufPrint(&b, "\"user\":{{\"id\":\"{d}\"", .{app.store.me}) catch return false;
    return got("\"evt\":\"READY\"") and got(id) and got("\"discriminator\":\"0\"");
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

fn activityFrame(nonce: []const u8, details: []const u8) void {
    var b: [512]u8 = undefined;
    const json = std.fmt.bufPrint(&b, "{{\"cmd\":\"SET_ACTIVITY\",\"nonce\":\"{s}\",\"args\":{{\"pid\":{d},\"activity\":{{\"details\":\"{s}\",\"state\":\"No menu\",\"timestamps\":{{\"start\":1700000000}},\"assets\":{{\"large_image\":\"logo\",\"large_text\":\"Logo do jogo\"}}}}}}}}", .{ nonce, c.getpid(), details }) catch return;
    sendFrame(proto.op_frame, json);
}

fn setActivity(_: *App) void {
    notePresences();
    activityFrame("qa-1", "Fase 3");
}

fn activityReply(_: *App) bool {
    return got("\"cmd\":\"SET_ACTIVITY\",\"data\":{") and got("\"nonce\":\"qa-1\"");
}

fn op3Activity(_: *App) bool {
    return op3Has(&.{ "\"status\":\"online\"", "\"name\":\"Jogo de Teste\"", "\"application_id\":\"" ++ client_id ++ "\"", "\"details\":\"Fase 3\"", "\"start\":1700000000000", "\"large_image\":\"4242\"" });
}

fn myActivities(app: *App) []const @import("core/types.zig").Activity {
    return app.store.activities.get(app.store.me) orelse &.{};
}

fn panelShows(app: *App) bool {
    const acts = myActivities(app);
    const me = app.store.user(app.store.me) orelse return false;
    return acts.len == 1 and std.mem.eql(u8, acts[0].details, "Fase 3") and std.mem.eql(u8, acts[0].name, "Jogo de Teste") and
        me.activity != null and std.mem.endsWith(u8, me.activity.?, "Jogo de Teste") and qa.find("me-activity") != null;
}

fn unknownCmd(_: *App) void {
    sendFrame(proto.op_frame, "{\"cmd\":\"SUBSCRIBE\",\"nonce\":\"qa-2\",\"evt\":\"ACTIVITY_JOIN\",\"args\":{}}");
}

fn unknownReply(_: *App) bool {
    return got("{\"cmd\":\"SUBSCRIBE\",\"evt\":\"ERROR\",\"data\":{\"code\":4000,\"message\":\"not supported\"},\"nonce\":\"qa-2\"}");
}

fn clearActivity(_: *App) void {
    notePresences();
    sendFrame(proto.op_frame, "{\"cmd\":\"SET_ACTIVITY\",\"nonce\":\"qa-3\",\"args\":{\"pid\":1,\"activity\":null}}");
}

fn cleared(app: *App) bool {
    const me = app.store.user(app.store.me) orelse return false;
    return op3Has(&.{ "\"activities\":[]", "\"status\":\"online\"" }) and myActivities(app).len == 0 and me.activity == null and qa.find("me-activity") == null;
}

fn setAgain(_: *App) void {
    notePresences();
    activityFrame("qa-4", "Fase 4");
}

fn op3Again(_: *App) bool {
    return op3Has(&.{"\"details\":\"Fase 4\""});
}

fn disconnect(_: *App) void {
    notePresences();
    closeClient();
}

fn clearedAfterDisconnect(app: *App) bool {
    return op3Has(&.{"\"activities\":[]"}) and myActivities(app).len == 0;
}

fn garbage(_: *App) void {
    connectClient();
    // Op desconhecido e tamanho absurdo: a conexão cai, o servidor fica.
    sendRaw("\x09\x00\x00\x00\xff\xff\xff\xff{lixo");
}

fn garbageDropped(_: *App) bool {
    if (!rpc.running()) return false;
    // O servidor fechou: o recv dá 0 (fim) depois do quadro de CLOSE.
    var junk: [256]u8 = undefined;
    const r = c.recv(fd, &junk, junk.len, 0);
    return r == 0 or (r > 0 and junk[0] == proto.op_close);
}

fn dndActivity(app: *App) void {
    app.handle(.{ .set_status = .dnd });
    handshake(app);
    notePresences();
    activityFrame("qa-5", "Fase 5");
}

fn op3KeepsStatus(_: *App) bool {
    return op3Has(&.{ "\"status\":\"dnd\"", "\"details\":\"Fase 5\"" });
}

fn turnOff(app: *App) void {
    notePresences();
    openPrivacy(app);
}

fn offCleared(app: *App) bool {
    return !app.st.settings.rich_presence and offNothing(app) and path_len > 0 and fileMode() == null and op3Has(&.{"\"activities\":[]"});
}

fn restore(app: *App) void {
    closeClient();
    closeSettings(app);
    app.handle(.{ .set_status = .online });
}

pub const ops = [_]Op{
    s("presenca"),
    expect("desligado: nenhum socket, nenhuma thread", offNothing),
    run(openPrivacy),
    click(toggle),
    expect("ligado: socket só do dono em $XDG_RUNTIME_DIR/discord-ipc-N", onSocket),
    run(closeSettings),
    run(handshake),
    expect("handshake responde READY com o nosso usuário", readyReply),
    run(setActivity),
    expect("SET_ACTIVITY responde com o mesmo nonce", activityReply),
    expect("o gateway recebe o op 3 com o nome da aplicação e a imagem resolvida", op3Activity),
    expect("a atividade aparece no nosso painel e no perfil", panelShows),
    .{ .shot = "presenca-painel" },
    run(unknownCmd),
    expect("comando sem suporte responde ERROR 4000 com o nonce", unknownReply),
    run(clearActivity),
    expect("atividade null limpa (op 3 sem atividades, painel volta ao status)", cleared),
    run(setAgain),
    expect("a atividade volta", op3Again),
    run(disconnect),
    expect("o jogo desconectar limpa a atividade", clearedAfterDisconnect),
    run(garbage),
    expect("lixo derruba só aquela conexão", garbageDropped),
    run(dndActivity),
    expect("a atividade vai junto com o status escolhido (não perturbe)", op3KeepsStatus),
    run(turnOff),
    click(toggle),
    expect("desligar apaga o socket, para a thread e limpa a atividade", offCleared),
    run(restore),
};

// --- O jogo aberto pelo processo -------------------------------------------------
//
// Os processos do QA são de mentira (platform/processos.zig `fake`): a lista para
// escolher, a varredura de 15 em 15 s (aqui, de 200 em 200 ms) e o fechar do jogo
// são o mesmo código, só a fonte muda. A varredura de verdade tem o passo dela no
// fim (Linux: acha o próprio QA em /proc) e o teste em processos.zig.

const app_presenca = @import("app_presenca.zig");
const processos = @import("platform/processos.zig");
const jogos = @import("core/jogos.zig");
const settings_jogos = @import("ui/settings_jogos.zig");
const paineis = @import("qa_paineis.zig");
const windows = @import("builtin").os.tag == .windows;

const game_toggle = "toggle:Mostrar o jogo aberto";
const fake_path = if (windows) "D:\\Jogos\\fakegame\\fakegame.exe" else "/opt/jogos/fakegame/fakegame";
const fake_name = if (windows) "fakegame.exe" else "fakegame";
const moved_path = if (windows) "D:\\Outro\\fakegame.exe" else "/outro/lugar/fakegame";
const chosen_path = if (windows) "D:\\Jogos\\Escolhido\\Escolhido.exe" else "/opt/jogos/escolhido/Escolhido.x86_64";
const chosen_exe = if (windows) "Escolhido.exe" else "Escolhido.x86_64";

const running_list = [_]jogos.Proc{
    .{ .pid = 4242, .name = fake_name, .path = fake_path },
    .{ .pid = 4243, .name = "pipewire", .path = "/usr/bin/pipewire" },
    .{ .pid = 4244, .name = if (windows) "outro.exe" else "outro", .path = if (windows) "D:\\Apps\\outro.exe" else "/opt/outro/outro" },
    // O mesmo jogo duas vezes (outro processo dele): aparece uma vez só para escolher.
    .{ .pid = 4245, .name = fake_name, .path = fake_path },
};
const closed_list = [_]jogos.Proc{running_list[1]};
const moved_list = [_]jogos.Proc{ .{ .pid = 4246, .name = fake_name, .path = moved_path }, running_list[1] };

fn fakeRunning(_: *App) void {
    notePresences();
    processos.fake = &running_list;
}
fn fakeClosed(_: *App) void {
    notePresences();
    processos.fake = &closed_list;
}
fn fakeMoved(_: *App) void {
    notePresences();
    processos.fake = &moved_list;
}

var scans_before: u32 = 0;
fn noteScans(_: *App) void {
    scans_before = app_presenca.scans;
    notePresences();
}

fn gameOffNothing(app: *App) bool {
    return !app.st.settings.show_game and !app_presenca.gameActive() and app_presenca.scans == 0 and qa.find("button:Adicionar processo aberto") == null;
}

fn gameOnEmpty(app: *App) bool {
    // Ligado com a lista vazia: olha os processos, mas nada vai para o gateway.
    return app.st.settings.show_game and app_presenca.gameActive() and app_presenca.scans > scans_before + 2 and
        gw.sent.presences.load(.acquire) == presences_before and qa.find("button:Adicionar processo aberto") != null and qa.find("button:Escolher executável") != null;
}

fn pickerOpen(_: *App) bool {
    // O jogo aparece uma vez, os do sistema não.
    return qa.find("jogo-filtro") != null and qa.find("jogo-proc:" ++ fake_name) != null and qa.find("jogo-proc:pipewire") == null and
        qa.find("jogo-proc:" ++ (if (windows) "outro.exe" else "outro")) != null and countMarks("jogo-proc:" ++ fake_name) == 1;
}

fn countMarks(key: []const u8) usize {
    var keys: [64][56]u8 = undefined;
    var lens: [64]u8 = undefined;
    const n = qa.keysWith(&.{key}, &keys, &lens);
    var k: usize = 0;
    for (0..n) |i| {
        if (std.mem.eql(u8, keys[i][0..lens[i]], key)) k += 1;
    }
    return k;
}

fn filtered(_: *App) bool {
    return qa.find("jogo-proc:" ++ fake_name) != null and qa.find("jogo-proc:" ++ (if (windows) "outro.exe" else "outro")) == null;
}

fn firstEntry(app: *App) ?*jogos.Entry {
    if (app.st.jogos.len == 0) return null;
    return &app.st.jogos.items[0];
}

fn entryAdded(app: *App) bool {
    const e = firstEntry(app) orelse return false;
    return app.st.jogos.len == 1 and std.mem.eql(u8, e.exe.slice(), fake_name) and std.mem.eql(u8, e.name.slice(), "Fakegame") and
        std.mem.eql(u8, e.path.slice(), fake_path) and e.on and !e.exact and qa.find("jogo-filtro") == null and qa.find("jogo-nome:0") != null;
}

/// O começo da atividade no último op 3 (0 = não tem).
fn op3Start() i64 {
    const t = lastOp3();
    const key = "\"timestamps\":{\"start\":";
    const i = std.mem.indexOf(u8, t, key) orelse return 0;
    var end = i + key.len;
    while (end < t.len and std.ascii.isDigit(t[end])) end += 1;
    return std.fmt.parseInt(i64, t[i + key.len .. end], 10) catch 0;
}

var first_start: i64 = 0;
fn op3Game(app: *App) bool {
    if (!op3Has(&.{ "\"status\":\"online\"", "{\"type\":0,\"name\":\"Fakegame\",\"timestamps\":{\"start\":" })) return false;
    first_start = op3Start();
    const me = app.store.user(app.store.me) orelse return false;
    const now = gw.nowMs();
    return first_start > now - 60_000 and first_start <= now and me.activity != null and std.mem.eql(u8, me.activity.?, "Jogando Fakegame") and
        myActivities(app).len == 1;
}

fn renameGame(app: *App) void {
    notePresences();
    const e = firstEntry(app) orelse return;
    // Como digitar na caixa: muda o texto e avisa a lista.
    e.name.set("Jogo Falso");
    app.st.jogos.changed();
}

fn op3Renamed(_: *App) bool {
    // Mesmo jogo aberto: o nome muda, a hora do começo fica.
    return op3Has(&.{"\"name\":\"Jogo Falso\""}) and op3Start() == first_start;
}

fn op3Cleared(app: *App) bool {
    return op3Has(&.{"\"activities\":[]"}) and myActivities(app).len == 0;
}

fn op3Reopened(_: *App) bool {
    // Abriu de novo: conta de novo (o começo é outro, mais novo).
    return op3Has(&.{"\"name\":\"Jogo Falso\""}) and op3Start() > first_start;
}

fn invisibleRename(app: *App) void {
    app.handle(.{ .set_status = .offline });
    renameGame(app);
    const e = firstEntry(app) orelse return;
    e.name.set("Jogo Escondido");
}

fn op3Invisible(_: *App) bool {
    // Invisível vai como no Rich Presence: o status invisível, com a atividade (quem
    // esconde dos outros é o Discord).
    return op3Has(&.{ "\"status\":\"invisible\"", "\"name\":\"Jogo Escondido\"" });
}

fn backOnline(app: *App) void {
    notePresences();
    app.handle(.{ .set_status = .online });
}

fn op3Online(_: *App) bool {
    return op3Has(&.{ "\"status\":\"online\"", "\"name\":\"Jogo Escondido\"" });
}

fn entryOff(app: *App) bool {
    const e = firstEntry(app) orelse return false;
    return !e.on and op3Cleared(app);
}

fn entryOn(app: *App) bool {
    const e = firstEntry(app) orelse return false;
    return e.on and op3Has(&.{"\"name\":\"Jogo Escondido\""});
}

fn pickExe(app: *App) void {
    const z = std.heap.c_allocator.dupeSentinel(u8, chosen_path, 0) catch return;
    app.picked.push(z);
}

fn exeAdded(app: *App) bool {
    if (app.st.jogos.len != 2) return false;
    const e = &app.st.jogos.items[1];
    return std.mem.eql(u8, e.exe.slice(), chosen_exe) and std.mem.eql(u8, e.name.slice(), "Escolhido") and std.mem.eql(u8, e.path.slice(), chosen_path) and
        qa.find("jogo-nome:1") != null and qa.find("jogo-exato:1") != null;
}

fn cancelThenAttach(app: *App) void {
    // O seletor fechou sem arquivo: o próximo arquivo que chegar é anexo, não jogo.
    settings_jogos.cancelPick();
    settings_jogos.pollCancel();
    pickExe(app);
}

fn notTwice(app: *App) bool {
    return app.st.jogos.len == 2;
}

/// A lista vai e volta pelo settings.kdl (o QA não grava o arquivo dele).
fn persists(app: *App) bool {
    const gpa = std.heap.c_allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    app.st.jogos.write(&out, gpa) catch return false;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const nodes = @import("theme/kdl.zig").parse(arena.allocator(), out.items, null) catch return false;
    var back: jogos.Lista = .{};
    for (nodes) |*n| if (!back.applyNode(n)) return false;
    if (back.len != app.st.jogos.len) return false;
    for (back.constSlice(), app.st.jogos.constSlice()) |*a, *b| {
        if (!std.mem.eql(u8, a.name.slice(), b.name.slice()) or !std.mem.eql(u8, a.exe.slice(), b.exe.slice()) or
            !std.mem.eql(u8, a.path.slice(), b.path.slice()) or a.on != b.on or a.exact != b.exact) return false;
    }
    return true;
}

fn exactSameFile(app: *App) bool {
    // "Só este arquivo" com o mesmo caminho: continua aberto, nada muda.
    const e = firstEntry(app) orelse return false;
    return e.exact and gw.sent.presences.load(.acquire) == presences_before and std.mem.indexOf(u8, lastOp3(), "\"name\":\"Jogo Escondido\"") != null;
}

fn exactOtherFile(app: *App) bool {
    return op3Cleared(app);
}

fn exactOffShows(app: *App) bool {
    const e = firstEntry(app) orelse return false;
    return !e.exact and op3Has(&.{"\"name\":\"Jogo Escondido\""});
}

fn switchedOff(app: *App) bool {
    return !app.st.settings.show_game and !app_presenca.gameActive() and op3Cleared(app) and qa.find("button:Adicionar processo aberto") == null;
}

fn offStaysQuiet(_: *App) bool {
    return app_presenca.scans == scans_before and gw.sent.presences.load(.acquire) == presences_before;
}

fn removedFirst(app: *App) bool {
    return app.st.jogos.len == 1 and std.mem.eql(u8, app.st.jogos.items[0].exe.slice(), chosen_exe);
}

fn gameRestore(app: *App) void {
    processos.fake = null;
    app.st.jogos.len = 0;
    app.st.jogos.changed();
    app.st.settings.show_game = false;
    app.st.settings.open = false;
    app.handle(.{ .set_status = .online });
}

pub const ops_jogo = [_]Op{
    s("jogo aberto pelo processo"),
    run(fakeRunning),
    expect("desligado: nenhuma varredura, nenhum timer, nenhuma lista", gameOffNothing),
    run(openPrivacy),
    .{ .wait = 150 },
    run(noteScans),
    click(game_toggle),
    .{ .wait = 800 },
    expect("ligado com a lista vazia: olha os processos e não manda nada", gameOnEmpty),
    .{ .shot = "jogo-lista-vazia" },
    click("button:Adicionar processo aberto"),
    expect("a lista dos processos abertos, sem os do sistema e sem repetir", pickerOpen),
    .{ .shot = "jogo-escolher-processo" },
    click("jogo-filtro"),
    .{ .text = "fake" },
    expect("o filtro deixa só o que bate", filtered),
    run(notePresencesRun),
    click("jogo-proc:" ++ fake_name),
    expect("escolher acrescenta o jogo com o nome do arquivo e fecha a lista", entryAdded),
    expect("o gateway recebe o op 3 com \"Jogando Fakegame\" e o começo, e o painel mostra", op3Game),
    expect("nada se sobrepõe na Privacidade com a lista", paineis.noOverlap),
    .{ .shot = "jogo-lista" },
    run(closeSettings),
    .{ .wait = 300 },
    .{ .shot = "jogo-painel" },
    run(openPrivacy),
    .{ .wait = 150 },
    run(renameGame),
    expect("mudar o nome muda a atividade, com o mesmo começo", op3Renamed),
    run(fakeClosed),
    expect("o jogo fechou: o op 3 limpa e o painel volta ao status", op3Cleared),
    run(fakeRunning),
    expect("abriu de novo: volta, contando de novo", op3Reopened),
    run(invisibleRename),
    expect("invisível: o op 3 vai com o status invisível, como o Rich Presence", op3Invisible),
    run(backOnline),
    expect("e volta ao online com o jogo", op3Online),
    run(notePresencesRun),
    click("jogo-ligado:0"),
    expect("desligar o jogo na lista limpa", entryOff),
    run(notePresencesRun),
    click("jogo-ligado:0"),
    expect("ligar de novo volta", entryOn),
    click("button:Escolher executável"),
    run(pickExe),
    expect("o executável escolhido entra na lista, com o caminho e \"só este arquivo\"", exeAdded),
    .{ .shot = "jogo-dois" },
    click("button:Escolher executável"),
    run(cancelThenAttach),
    .{ .wait = 200 },
    expect("seletor cancelado: o próximo arquivo não vira jogo", notTwice),
    expect("a lista vai e volta pelo settings.kdl", persists),
    run(notePresencesRun),
    click("jogo-exato:0"),
    .{ .wait = 700 },
    expect("\"só este arquivo\" com o mesmo caminho: nada muda", exactSameFile),
    run(fakeMoved),
    expect("o mesmo nome em outro caminho não conta", exactOtherFile),
    run(notePresencesRun),
    click("jogo-exato:0"),
    expect("sem a opção, qualquer caminho vale de novo", exactOffShows),
} ++ (if (windows) [_]Op{} else ops_merge) ++ [_]Op{
    run(notePresencesRun),
    click(game_toggle),
    expect("desligar a opção limpa na hora e para de olhar", switchedOff),
    run(noteScans),
    run(fakeRunning),
    .{ .wait = 1000 },
    expect("desligado: nenhuma varredura e nada para o gateway", offStaysQuiet),
    click(game_toggle),
    .{ .wait = 150 },
    run(notePresencesRun),
    click("jogo-tirar:0"),
    expect("tirar da lista: sobra o outro", removedFirst),
    expect("e o jogo que saiu da lista limpa", op3Cleared),
} ++ (if (windows) [_]Op{} else [_]Op{expect("varredura de verdade: acha o próprio QA em /proc", realScan)}) ++ [_]Op{
    run(gameRestore),
};

fn notePresencesRun(_: *App) void {
    notePresences();
}

/// A varredura de verdade (sem a lista de mentira) acha este processo, rápido.
fn realScan(_: *App) bool {
    const saved = processos.fake;
    processos.fake = null;
    defer processos.fake = saved;
    var l: processos.List = .{};
    defer l.deinit(std.heap.c_allocator);
    const t0 = c.SDL_GetTicksNS();
    processos.scan(&l, std.heap.c_allocator, .all);
    const us = (c.SDL_GetTicksNS() - t0) / 1000;
    const me: u32 = @intCast(c.getpid());
    var found = false;
    for (l.items()) |p| if (p.pid == me) {
        std.log.info("varredura de verdade: {d} processos em {d} µs; este é {s}", .{ l.items().len, us, p.name });
        found = std.mem.eql(u8, p.name, "larpercord") and p.path.len > 0;
    };
    if (!found) return false;
    // A de 15 em 15 s (só os candidatos aos jogos da lista): o mesmo custo de ler os links.
    var games: jogos.Lista = .{};
    _ = games.add("larpercord", "", .linux);
    const t1 = c.SDL_GetTicksNS();
    processos.scan(&l, std.heap.c_allocator, .{ .games = games.slice() });
    std.log.info("varredura de verdade só dos jogos da lista: {d} candidato(s) em {d} µs", .{ l.items().len, (c.SDL_GetTicksNS() - t1) / 1000 });
    return jogos.firstRunning(games.slice(), l.items(), .linux) == 0;
}

// Linux: o Rich Presence (o jogo de mentira do discord-ipc, lá de cima) e o jogo
// aberto ao mesmo tempo: os dois no op 3, e um sair não leva o outro.

fn rpcOn(app: *App) void {
    app.st.settings.rich_presence = true;
}

fn rpcListening(_: *App) bool {
    if (!rpc.running()) return false;
    const p = rpc.path();
    if (p.len >= path_buf.len) return false;
    @memcpy(path_buf[0..p.len], p);
    path_buf[p.len] = 0;
    path_len = p.len;
    return true;
}

fn rpcActivity(_: *App) void {
    notePresences();
    activityFrame("qa-m", "Fase M");
}

fn bothInOp3(app: *App) bool {
    return op3Has(&.{ "\"details\":\"Fase M\"", "\"name\":\"Jogo Escondido\"" }) and myActivities(app).len == 2;
}

fn rpcStays(app: *App) bool {
    return op3Has(&.{"\"details\":\"Fase M\""}) and std.mem.indexOf(u8, lastOp3(), "Jogo Escondido") == null and myActivities(app).len == 1;
}

fn rpcClear(_: *App) void {
    notePresences();
    sendFrame(proto.op_frame, "{\"cmd\":\"SET_ACTIVITY\",\"nonce\":\"qa-m2\",\"args\":{\"pid\":1,\"activity\":null}}");
}

fn gameStays(app: *App) bool {
    return op3Has(&.{"\"name\":\"Jogo Escondido\""}) and std.mem.indexOf(u8, lastOp3(), "Fase M") == null and myActivities(app).len == 1;
}

fn rpcOff(app: *App) void {
    closeClient();
    app.st.settings.rich_presence = false;
}

fn rpcStopped(_: *App) bool {
    return !rpc.running();
}

const ops_merge = [_]Op{
    run(rpcOn),
    expect("Rich Presence ligado junto", rpcListening),
    run(handshake),
    expect("o jogo do discord-ipc faz o handshake", readyReply),
    run(rpcActivity),
    expect("Rich Presence e jogo aberto juntos no op 3 e no painel", bothInOp3),
    run(closeSettings),
    .{ .wait = 300 },
    .{ .shot = "jogo-e-rich-presence" },
    run(openPrivacy),
    .{ .wait = 150 },
    run(fakeClosed),
    expect("o jogo fechou: o Rich Presence fica", rpcStays),
    run(fakeRunning),
    expect("o jogo voltou: os dois de novo", bothInOp3),
    run(rpcClear),
    expect("o Rich Presence limpou: o jogo fica", gameStays),
    run(rpcOff),
    expect("Rich Presence desligado", rpcStopped),
};
