//! O transporte do controle de fora (`larpercord ctl`; o protocolo está em app_ctl.zig):
//! TCP em 127.0.0.1, numa porta livre escrita com um segredo num arquivo só do dono,
//! como o aviso entre dois larperCords (platform/instance.zig). É outra porta, e não a
//! da instância, porque esta existe também na demonstração e no QA (com LARPER_CTL), que
//! não têm a trava de instância; some de vez quando a opção é desligada, sem levar
//! junto o "abrir o que já está aberto"; e atende várias conexões longas (o `watch`),
//! enquanto a da instância responde uma de cada vez em meio segundo.
//!
//! Threads: uma espera conexões, parada no poll (nada roda enquanto ninguém chama), e
//! cada conexão tem a sua, até `max_clients`. Quem executa os comandos é a interface: o
//! pedido entra na fila, a janela acorda (`Wake.ctl`) e a thread da conexão espera a
//! resposta por até `reply_ms`. A interface nunca escreve no socket: um cliente que não
//! lê não segura o laço.
//!
//! Também aqui, o lado de quem chama (`Conn`): a linha de comando e o QA usam o mesmo.
const std = @import("std");
const c = @import("c");
const sys = @import("sys.zig");
const fsutil = @import("fsutil.zig");
const platform = @import("window.zig");
const proto = @import("../core/ctl.zig");
const Queue = @import("../net/queue.zig").Queue;

const alloc = std.heap.c_allocator;
const Atomic = std.atomic.Value;

extern fn RAND_bytes(buf: [*]u8, num: c_int) c_int;

pub const max_clients = 8;
/// O segredo tem que chegar logo; um comando, dentro de um minuto (a conexão do
/// `watch` não tem prazo).
const auth_ms = 2000;
const idle_ms = 60_000;
/// Quanto a thread da conexão espera a interface responder.
pub const reply_ms = 5000;
/// Um cliente que parou de ler perde a conexão.
const send_timeout_ms = 10_000;
/// O que um `watch` que não lê pode acumular antes de cair.
const outbox_max = 1 << 20;

/// Esta execução pode ter o controle de fora: o app de verdade, ou a demonstração e o
/// QA com LARPER_CTL (Configurações → Avançado mostra a opção apagada sem isso).
pub var allowed = false;

/// Um comando a caminho da interface. A thread da conexão cria; quem solta é quem fica
/// por último (ver `finish` e `waitReply`).
pub const Request = struct {
    line: []u8,
    body: std.ArrayList(u8) = .empty,
    err: ?proto.Err = null,
    /// O comando virou um `watch`: a conexão passa a mandar uma linha a cada mudança.
    watch: ?proto.Format = null,
    state: Atomic(u8) = .init(queued),
    client: *Client,
};

const queued: u8 = 0;
const done: u8 = 1;
const abandoned: u8 = 2;

const Client = struct {
    sock: sys.Socket = sys.no_socket,
    wake: sys.Wake = .{},
    thread: ?*c.SDL_Thread = null,
    /// Tudo daqui para baixo, sob `lock`.
    used: bool = false,
    stop: bool = false,
    /// Em `watch`: o formato e as linhas que ainda não foram.
    format: ?proto.Format = null,
    outbox: std.ArrayList(u8) = .empty,
    overflow: bool = false,
};

var slots: [max_clients]Client = @splat(.{});
var lock: ?*c.SDL_Mutex = null;
var queue: ?Queue(*Request) = null;
var listener: sys.Socket = sys.no_socket;
var stop_pipe: sys.Wake = .{};
var accept_thread: ?*c.SDL_Thread = null;
var wake_type: u32 = 0;
var nonce: [proto.nonce_len]u8 = undefined;
var watchers: Atomic(u32) = .init(0);
/// O arquivo que escrevemos e o que tem nele (ao parar, só sai se ainda for o nosso).
var file_buf: [512]u8 = undefined;
var file_path: ?[:0]const u8 = null;
var file_text: [64]u8 = undefined;
var file_len: usize = 0;

fn locked() void {
    _ = c.SDL_LockMutex(lock);
}
fn unlocked() void {
    c.SDL_UnlockMutex(lock);
}

/// O arquivo da porta: `ctl.port` do app de verdade; a demonstração e o QA (com
/// LARPER_CTL) usam `ctl-demo.port`, ou o caminho que LARPER_CTL der, e nunca escrevem
/// por cima do arquivo de um larperCord aberto.
pub fn portPath(buf: []u8, demo: bool) ?[:0]const u8 {
    if (demo) if (c.SDL_getenv("LARPER_CTL")) |raw| {
        const v = std.mem.span(raw);
        if (std.mem.indexOfAny(u8, v, "/\\") != null) return std.fmt.bufPrintSentinel(buf, "{s}", .{v}, 0) catch null;
    };
    return fsutil.configPath(buf, if (demo) "ctl-demo.port" else "ctl.port");
}

pub fn running() bool {
    return sys.valid(listener);
}

/// Abre a porta e escreve onde ela está. Falso: não deu (fica desligado até a opção mudar).
pub fn start(wake: u32, path: [:0]const u8) bool {
    if (running()) return true;
    if (lock == null) lock = c.SDL_CreateMutex() orelse return false;
    if (queue == null) queue = Queue(*Request).init(alloc) catch return false;
    var raw: [proto.nonce_len / 2]u8 = undefined;
    if (RAND_bytes(&raw, raw.len) != 1) return false;
    nonce = std.fmt.bytesToHex(raw, .lower);
    var port: u16 = 0;
    const l = sys.tcpListenLocal(&port) orelse return false;
    const text = std.fmt.bufPrint(&file_text, "{d} {s}\n", .{ port, nonce }) catch unreachable;
    file_len = text.len;
    if (path.len >= file_buf.len or !fsutil.writePrivate(path, text)) {
        sys.closeSocket(l);
        return false;
    }
    @memcpy(file_buf[0..path.len], path);
    file_buf[path.len] = 0;
    file_path = file_buf[0..path.len :0];
    stop_pipe = sys.Wake.open();
    listener = l;
    wake_type = wake;
    accept_thread = c.SDL_CreateThread(acceptMain, "ctl", null);
    if (accept_thread == null) {
        stop();
        return false;
    }
    return true;
}

/// Fecha a porta, apaga o arquivo e encerra cada conexão (o `watch` recebe o "." do
/// fim). Na thread da interface.
pub fn stop() void {
    if (accept_thread) |t| {
        sys.wakeSignal(stop_pipe.write);
        c.SDL_WaitThread(t, null);
        accept_thread = null;
    }
    stop_pipe.close();
    if (running()) sys.closeSocket(listener);
    listener = sys.no_socket;
    removeFile();
    if (lock == null) return;
    locked();
    for (&slots) |*cl| if (cl.used) {
        cl.stop = true;
        sys.wakeSignal(cl.wake.write);
    };
    unlocked();
    // Quem está mandando o "." tem um instante; quem está preso num send para um
    // cliente que não lê, não.
    var waited: u32 = 0;
    while (anyUsed() and waited < 500) : (waited += 10) c.SDL_Delay(10);
    locked();
    for (&slots) |*cl| if (cl.used) sys.shutdownSocket(cl.sock);
    unlocked();
    for (&slots) |*cl| if (cl.thread) |t| {
        c.SDL_WaitThread(t, null);
        cl.thread = null;
    };
    // O que sobrou na fila foi largado pelas conexões (que já terminaram).
    if (queue) |*q| {
        var left: std.ArrayList(*Request) = .empty;
        defer left.deinit(alloc);
        q.drain(&left);
        for (left.items) |req| freeRequest(req);
    }
    watchers.store(0, .release);
}

fn anyUsed() bool {
    locked();
    defer unlocked();
    for (&slots) |*cl| if (cl.used) return true;
    return false;
}

fn removeFile() void {
    const path = file_path orelse return;
    file_path = null;
    var size: usize = 0;
    const data = c.SDL_LoadFile(path.ptr, &size) orelse return;
    defer c.SDL_free(data);
    if (std.mem.eql(u8, @as([*]const u8, @ptrCast(data))[0..size], file_text[0..file_len])) _ = c.SDL_RemovePath(path.ptr);
}

fn freeRequest(req: *Request) void {
    alloc.free(req.line);
    req.body.deinit(alloc);
    alloc.destroy(req);
}

// --- Lado da interface ----------------------------------------------------------------

/// Os pedidos que chegaram (a interface chama em `Wake.ctl`).
pub fn take(out: *std.ArrayList(*Request)) void {
    if (queue) |*q| q.drain(out);
}

/// O pedido respondido: volta para a conexão, ou é solto se ela desistiu de esperar.
pub fn finish(req: *Request) void {
    locked();
    defer unlocked();
    if (req.state.cmpxchgStrong(queued, done, .acq_rel, .acquire) == null) {
        // Sob a trava: a conexão só fecha o aviso dela com a trava na mão.
        sys.wakeSignal(req.client.wake.write);
    } else freeRequest(req);
}

/// O comando em andamento passa a ser um `watch` neste formato.
pub fn watch(req: *Request, fmt: proto.Format) void {
    locked();
    defer unlocked();
    if (req.state.load(.acquire) != queued) return;
    const cl = req.client;
    if (cl.format == null) _ = watchers.fetchAdd(1, .acq_rel);
    cl.format = fmt;
    req.watch = fmt;
}

/// Alguém está no `watch`? (A interface só olha o estado do app quando sim.)
pub fn watching() bool {
    return watchers.load(.acquire) > 0;
}

/// Os formatos com alguém olhando, para montar só as linhas que vão.
pub fn formatsWatched() std.EnumSet(proto.Format) {
    var set: std.EnumSet(proto.Format) = .{};
    if (lock == null or !watching()) return set;
    locked();
    defer unlocked();
    for (&slots) |*cl| if (cl.used) if (cl.format) |f| set.insert(f);
    return set;
}

/// Uma linha para todos os `watch` neste formato.
pub fn broadcast(fmt: proto.Format, line: []const u8) void {
    locked();
    defer unlocked();
    for (&slots) |*cl| {
        if (!cl.used or cl.format != fmt or cl.overflow) continue;
        if (cl.outbox.items.len + line.len + 2 > outbox_max) {
            cl.overflow = true;
        } else proto.stuffLine(&cl.outbox, alloc, line) catch {
            cl.overflow = true;
        };
        sys.wakeSignal(cl.wake.write);
    }
}

// --- Threads das conexões ---------------------------------------------------------------

fn acceptMain(_: ?*anyopaque) callconv(.c) c_int {
    while (true) {
        var fds = [2]sys.PollFd{
            .{ .fd = listener, .events = c.POLLIN, .revents = 0 },
            .{ .fd = stop_pipe.read, .events = c.POLLIN, .revents = 0 },
        };
        sys.poll(&fds, 2, -1);
        if (fds[1].revents != 0) return 0;
        if (fds[0].revents == 0) continue;
        const sock = sys.tcpAccept(listener) orelse continue;
        sys.noInherit(sock);
        sys.setSendTimeout(sock, send_timeout_ms);
        const cl = claim(sock) orelse {
            // O cliente manda o segredo assim que conecta. Lido antes de responder, o fechar
            // sai limpo; com ele ainda na fila, o sistema manda um RST, e o cliente perde o
            // "ERR busy" e vê "sem resposta".
            var key: [128]u8 = undefined;
            _ = sys.tcpRecv(sock, &key, 200);
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(alloc);
            proto.frame(&out, alloc, .{ .code = .busy }, "", true) catch {};
            _ = sys.tcpSendAll(sock, out.items);
            sys.closeSocket(sock);
            continue;
        };
        const t = c.SDL_CreateThread(clientMain, "ctl-conn", cl);
        locked();
        cl.thread = t;
        unlocked();
        if (t == null) release(cl);
    }
}

/// Uma vaga livre para a conexão (e o aviso dela). A thread de quem estava antes já
/// terminou ou está terminando: o SDL_WaitThread não demora.
fn claim(sock: sys.Socket) ?*Client {
    locked();
    defer unlocked();
    for (&slots) |*cl| {
        if (cl.used) continue;
        if (cl.thread) |t| c.SDL_WaitThread(t, null);
        const w = sys.Wake.open();
        if (!sys.valid(w.read)) return null;
        cl.* = .{ .used = true, .sock = sock, .wake = w };
        return cl;
    }
    return null;
}

/// Fim da conexão: fecha o socket e o aviso sob a trava (ver `finish`).
fn release(cl: *Client) void {
    locked();
    defer unlocked();
    sys.closeSocket(cl.sock);
    cl.sock = sys.no_socket;
    cl.wake.close();
    if (cl.format != null) _ = watchers.fetchSub(1, .acq_rel);
    cl.format = null;
    cl.outbox.deinit(alloc);
    cl.outbox = .empty;
    cl.overflow = false;
    cl.used = false;
}

fn stopping(cl: *Client) bool {
    locked();
    defer unlocked();
    return cl.stop;
}

fn clientMain(arg: ?*anyopaque) callconv(.c) c_int {
    const cl: *Client = @ptrCast(@alignCast(arg));
    serve(cl);
    release(cl);
    return 0;
}

fn reply(cl: *Client, err: ?proto.Err, body: []const u8, close: bool) bool {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    proto.frame(&out, alloc, err, body, close) catch return false;
    return sys.tcpSendAll(cl.sock, out.items);
}

fn serve(cl: *Client) void {
    var rd: LineReader = .{};
    const first = rd.next(cl, auth_ms) orelse return;
    if (!proto.sameNonce(first, &nonce)) {
        _ = reply(cl, .{ .code = .auth }, "", true);
        return;
    }
    if (!reply(cl, null, proto.greeting, true)) return;
    while (true) {
        const line = rd.next(cl, idle_ms) orelse return;
        if (std.mem.trim(u8, line, " \t").len == 0) continue;
        const req = alloc.create(Request) catch return;
        req.* = .{ .line = alloc.dupe(u8, line) catch {
            alloc.destroy(req);
            return;
        }, .client = cl };
        queue.?.push(req);
        platform.Window.wake(wake_type, .ctl);
        if (!waitReply(cl, req)) {
            const code: proto.Code = if (stopping(cl)) .closing else .timeout;
            if (!reply(cl, .{ .code = code }, "", true) or code == .closing) return;
            continue;
        }
        const fmt = req.watch;
        const sent = reply(cl, req.err, req.body.items, fmt == null);
        freeRequest(req);
        if (!sent) return;
        if (fmt != null) return stream(cl);
    }
}

/// Espera a interface. Falso: o tempo acabou ou o app está fechando; o pedido fica
/// com a interface, que o solta quando chegar nele.
fn waitReply(cl: *Client, req: *Request) bool {
    const deadline = c.SDL_GetTicks() + reply_ms;
    while (req.state.load(.acquire) != done) {
        if (stopping(cl)) break;
        const now = c.SDL_GetTicks();
        if (now >= deadline) break;
        var fds = [1]sys.PollFd{.{ .fd = cl.wake.read, .events = c.POLLIN, .revents = 0 }};
        sys.poll(&fds, 1, @intCast(deadline - now));
        if (fds[0].revents != 0) cl.wake.drain();
    }
    if (req.state.cmpxchgStrong(queued, abandoned, .acq_rel, .acquire) == null) {
        // Um `watch` registrado bem nessa hora não fica pendurado nesta conexão.
        locked();
        if (cl.format != null) _ = watchers.fetchSub(1, .acq_rel);
        cl.format = null;
        unlocked();
        return false;
    }
    return true;
}

/// O `watch`: as linhas que a interface manda, até o cliente fechar ou o app parar.
fn stream(cl: *Client) void {
    var pend: std.ArrayList(u8) = .empty;
    defer pend.deinit(alloc);
    while (true) {
        var fds = [2]sys.PollFd{
            .{ .fd = cl.wake.read, .events = c.POLLIN, .revents = 0 },
            .{ .fd = cl.sock, .events = c.POLLIN, .revents = 0 },
        };
        sys.poll(&fds, 2, -1);
        if (fds[0].revents != 0) cl.wake.drain();
        locked();
        std.mem.swap(std.ArrayList(u8), &pend, &cl.outbox);
        const over = cl.overflow;
        const stop_now = cl.stop;
        unlocked();
        if (pend.items.len > 0 and !sys.tcpSendAll(cl.sock, pend.items)) return;
        pend.clearRetainingCapacity();
        if (stop_now) {
            _ = sys.tcpSendAll(cl.sock, ".\n");
            return;
        }
        if (over) return;
        // O cliente não manda nada no watch: o que chegar é jogado fora; 0 é ele fechando.
        if (fds[1].revents != 0) {
            var junk: [256]u8 = undefined;
            if (sys.tcpRecvSome(cl.sock, &junk) <= 0) return;
        }
    }
}

/// As linhas que chegam numa conexão do servidor (comandos curtos: buffer fixo).
const LineReader = struct {
    buf: [proto.max_line + 2]u8 = undefined,
    start: usize = 0,
    len: usize = 0,

    /// A próxima linha, sem o \n (vale até a próxima chamada). Nulo: o prazo acabou, o
    /// cliente fechou, a linha passou do tamanho ou o app está parando.
    fn next(r: *LineReader, cl: *Client, wait_ms: u32) ?[]const u8 {
        if (r.start > 0) {
            std.mem.copyForwards(u8, r.buf[0 .. r.len - r.start], r.buf[r.start..r.len]);
            r.len -= r.start;
            r.start = 0;
        }
        const deadline = c.SDL_GetTicks() + wait_ms;
        while (true) {
            if (std.mem.indexOfScalar(u8, r.buf[0..r.len], '\n')) |i| {
                r.start = i + 1;
                return std.mem.trimEnd(u8, r.buf[0..i], "\r");
            }
            if (r.len == r.buf.len or stopping(cl)) return null;
            const now = c.SDL_GetTicks();
            if (now >= deadline) return null;
            var fds = [2]sys.PollFd{
                .{ .fd = cl.sock, .events = c.POLLIN, .revents = 0 },
                .{ .fd = cl.wake.read, .events = c.POLLIN, .revents = 0 },
            };
            sys.poll(&fds, 2, @intCast(deadline - now));
            if (fds[1].revents != 0) cl.wake.drain();
            if (fds[0].revents != 0) {
                const n = sys.tcpRecvSome(cl.sock, r.buf[r.len..]);
                if (n <= 0) return null;
                r.len += @intCast(n);
            }
        }
    }
};

// --- Quem chama -------------------------------------------------------------------------

/// Uma conexão com o app aberto, já com o segredo aceito.
pub const Conn = struct {
    sock: sys.Socket,
    buf: std.ArrayList(u8) = .empty,
    start: usize = 0,

    pub const OpenError = error{
        /// Sem o arquivo da porta, ou ninguém escutando nela.
        NotRunning,
        /// Conectou e ninguém respondeu.
        NoAnswer,
        /// Respondeu, mas recusou (o segredo é de outra vez, ou não é o larperCord).
        Refused,
        /// Já tem conexões demais.
        Busy,
    };

    pub fn open(path: [:0]const u8) OpenError!Conn {
        var size: usize = 0;
        const data = c.SDL_LoadFile(path.ptr, &size) orelse return error.NotRunning;
        defer c.SDL_free(data);
        const info = proto.PortFile.parse(@as([*]const u8, @ptrCast(data))[0..size]) orelse return error.NotRunning;
        return openPort(info.port, info.nonce);
    }

    /// Com a porta e o segredo na mão (o QA testa um segredo errado por aqui).
    pub fn openPort(port: u16, key: []const u8) OpenError!Conn {
        const s = sys.tcpConnectLocal(port) orelse return error.NotRunning;
        sys.noInherit(s);
        var conn: Conn = .{ .sock = s };
        errdefer conn.close();
        if (!conn.send(key)) return error.NoAnswer;
        var r = conn.response(alloc, 3000) orelse return error.NoAnswer;
        defer r.deinit(alloc);
        if (r.ok and std.mem.startsWith(u8, r.body.items, "larpercord-ctl ")) return conn;
        if (r.code == .busy) return error.Busy;
        return error.Refused;
    }

    pub fn close(conn: *Conn) void {
        sys.closeSocket(conn.sock);
        conn.buf.deinit(alloc);
    }

    pub fn send(conn: *Conn, line: []const u8) bool {
        return sys.tcpSendAll(conn.sock, line) and sys.tcpSendAll(conn.sock, "\n");
    }

    /// A próxima linha, sem o \n (vale até a próxima chamada), de qualquer tamanho.
    /// Nulo: fechou ou passou `wait_ms` (nulo: espera o quanto for).
    pub fn readLine(conn: *Conn, wait_ms: ?u32) ?[]const u8 {
        if (conn.start > 0) {
            const rest = conn.buf.items.len - conn.start;
            std.mem.copyForwards(u8, conn.buf.items[0..rest], conn.buf.items[conn.start..]);
            conn.buf.shrinkRetainingCapacity(rest);
            conn.start = 0;
        }
        const deadline = if (wait_ms) |ms| c.SDL_GetTicks() + ms else 0;
        var from: usize = 0;
        while (true) {
            if (std.mem.indexOfScalarPos(u8, conn.buf.items, from, '\n')) |i| {
                conn.start = i + 1;
                return std.mem.trimEnd(u8, conn.buf.items[0..i], "\r");
            }
            from = conn.buf.items.len;
            var timeout: c_int = -1;
            if (wait_ms != null) {
                const now = c.SDL_GetTicks();
                if (now >= deadline) return null;
                timeout = @intCast(deadline - now);
            }
            var fds = [1]sys.PollFd{.{ .fd = conn.sock, .events = c.POLLIN, .revents = 0 }};
            sys.poll(&fds, 1, timeout);
            if (fds[0].revents == 0) continue;
            conn.buf.ensureUnusedCapacity(alloc, 16 * 1024) catch return null;
            const room = conn.buf.unusedCapacitySlice();
            const n = sys.tcpRecvSome(conn.sock, room);
            if (n <= 0) return null;
            conn.buf.items.len += @intCast(n);
        }
    }

    /// Uma resposta inteira: a linha de status e o corpo até o ".". Nulo: a conexão caiu
    /// ou passou `wait_ms` em alguma linha.
    pub fn response(conn: *Conn, gpa: std.mem.Allocator, wait_ms: u32) ?Response {
        const status = conn.readLine(wait_ms) orelse return null;
        var r: Response = switch (proto.parseReply(status) orelse return null) {
            .ok => .{ .ok = true },
            .err => |e| .{ .ok = false, .code = e.code, .text = gpa.dupe(u8, e.text) catch return null },
        };
        while (true) {
            const line = conn.readLine(wait_ms) orelse {
                r.deinit(gpa);
                return null;
            };
            const body = proto.unstuff(line) orelse return r;
            r.body.appendSlice(gpa, body) catch {};
            r.body.append(gpa, '\n') catch {};
        }
    }
};

pub const Response = struct {
    ok: bool,
    code: ?proto.Code = null,
    text: []const u8 = "",
    body: std.ArrayList(u8) = .empty,

    pub fn deinit(r: *Response, gpa: std.mem.Allocator) void {
        if (r.text.len > 0) gpa.free(r.text);
        r.body.deinit(gpa);
    }
};
