//! As notificações do sistema no Linux direto pelo D-Bus (org.freedesktop.Notifications),
//! no lugar do notify-send: o clique abre a conversa, "Marcar como lida" e "Responder"
//! viram botões e, onde o servidor tem (o KDE Plasma, `inline-reply`), a resposta é
//! digitada na própria notificação. O GNOME tem botões e não tem a caixa.
//!
//! Uma thread só dela fica com a conexão: o app põe o que mostrar ou fechar numa fila,
//! e o que a pessoa fez (clique, botão, resposta) volta por outra, com um aviso ao
//! laço (Wake.notificacao). Quem age é a thread da interface, também com a janela
//! escondida na bandeja, sem desenhar quadro nenhum.
//!
//! A libdbus-1 é a mesma do ícone da bandeja (dbus.zig), aberta na hora. Sem ela, sem
//! sessão D-Bus ou sem servidor de notificações, `mostrar` diz não e quem chama usa o
//! notify-send de antes; o que já estava na fila volta (Volta.devolvida) e também sai
//! pelo notify-send: nenhuma se perde.
const std = @import("std");
const c = @import("c");
const dbus = @import("dbus.zig");
const n = @import("../core/notificacao.zig");
const platform = @import("window.zig");
const sys = @import("sys.zig");

const d = &dbus.d;
const Out = dbus.Out;
const In = dbus.In;
const gpa = std.heap.c_allocator;

const servico = "org.freedesktop.Notifications";
const caminho = "/org/freedesktop/Notifications";
/// O .desktop do app (install.sh e o pacote do AUR): o servidor acha o ícone e o nome por ele.
const desktop_entry = "dev.larpercord";
/// Quantas podem estar a caminho do servidor ao mesmo tempo (como os notify-send de antes).
pub const max_em_voo = 8;

pub const Estado = enum(u8) {
    /// Nada começou ainda: a primeira notificação começa a thread.
    parado,
    /// Conectando e perguntando ao servidor o que ele sabe fazer.
    conectando,
    /// O servidor responde: as notificações vão por aqui.
    pronto,
    /// Conectado, sem servidor de notificações agora: o notify-send cobre até um
    /// aparecer (NameOwnerChanged), e aí volta a ser `pronto`.
    sem_servidor,
    /// Sem libdbus ou sem sessão: o notify-send cobre, e a próxima tentativa é
    /// depois de `tentar_ms`.
    sem,
};

/// O que o app pede à thread.
const Envio = union(enum) {
    /// Cópia do app (n.Aviso.copiar): a thread solta, ou devolve.
    mostrar: n.Aviso,
    /// Fecha as da conversa (0: todas).
    fechar: n.Id,
};

var estado_v: std.atomic.Value(u8) = .init(@backingInt(Estado.parado));
/// n.Caps em bits: 1 botões, 2 caixa de texto, 4 marcação no corpo.
var caps_v: std.atomic.Value(u8) = .init(0);
var em_voo: std.atomic.Value(u32) = .init(0);
var saindo: std.atomic.Value(bool) = .init(false);
var falhou_ms: sys.Atomic(i64) = .init(0);
/// Depois de um `sem`, a próxima notificação só tenta de novo passado este tempo.
pub var tentar_ms: i64 = 60_000;

var lock: ?*c.SDL_Mutex = null;
var envios: std.ArrayList(Envio) = .empty;
var voltas: std.ArrayList(n.Volta) = .empty;
var thread: ?*c.SDL_Thread = null;
/// A thread avisa por aqui que acabou (o fim do app espera um pouco, não para sempre).
var fim: ?*c.SDL_Semaphore = null;
/// Acorda o poll da thread quando chega pedido do app.
var tubo: [2]c_int = .{ -1, -1 };
var wake_type: u32 = 0;

// Só da thread:
var conn: *dbus.Conn = undefined;
var tabela: n.Tabela = .{};
/// Outro servidor pegou o nome: pergunta de novo o que ele sabe, fora do despacho.
var reperguntar = false;

pub fn estado() Estado {
    return @fromBackingInt(@intCast(estado_v.load(.acquire)));
}

fn por(e: Estado) void {
    estado_v.store(@backingInt(e), .release);
}

pub fn caps() n.Caps {
    const b = caps_v.load(.acquire);
    return .{ .acoes = b & 1 != 0, .resposta = b & 2 != 0, .markup = b & 4 != 0 };
}

/// Há notificações demais a caminho do servidor (uma rajada de mensagens): a nova fica de fora.
pub fn cheio() bool {
    return em_voo.load(.acquire) >= max_em_voo;
}

/// Manda para a thread mostrar. Falso: o D-Bus não serve agora e quem chama mostra
/// pelo notify-send.
pub fn mostrar(wake: u32, a: n.Aviso, now_ms: i64) bool {
    switch (estado()) {
        .sem_servidor => return false,
        .sem => {
            if (now_ms - falhou_ms.load(.acquire) < tentar_ms) return false;
            // A thread que desistiu já acabou: começa outra (o aviso de fim dela não
            // vale para a próxima).
            if (thread) |t| c.SDL_WaitThread(t, null);
            thread = null;
            if (fim) |f| _ = c.SDL_TryWaitSemaphore(f);
            por(.parado);
        },
        .parado, .conectando, .pronto => {},
    }
    if (estado() == .parado and !iniciar(wake)) {
        falhou_ms.store(now_ms, .release);
        por(.sem);
        return false;
    }
    const copia = a.copiar(gpa) catch return false;
    _ = em_voo.fetchAdd(1, .acq_rel);
    if (!enviar(.{ .mostrar = copia })) {
        _ = em_voo.fetchSub(1, .acq_rel);
        gpa.free(copia.buf);
        return false;
    }
    return true;
}

/// Fecha as notificações da conversa `canal` (0: todas): ela foi lida aqui, em outro
/// aparelho, ou a conta saiu. Sem a thread de pé, não há nenhuma nossa para fechar.
pub fn fechar(canal: n.Id) void {
    switch (estado()) {
        .conectando, .pronto => _ = enviar(.{ .fechar = canal }),
        else => {},
    }
}

/// O que voltou da thread (cliques, respostas, as que não deu para mostrar) vai para
/// `out`, vazia e do c_allocator. Quem chama solta cada uma (Volta.liberar).
pub fn pegar(out: *std.ArrayList(n.Volta)) void {
    const l = lock orelse return;
    c.SDL_LockMutex(l);
    defer c.SDL_UnlockMutex(l);
    std.mem.swap(std.ArrayList(n.Volta), &voltas, out);
}

/// QA: esquece a última falha (a sessão D-Bus particular acabou de subir).
pub fn tentarDeNovo() void {
    falhou_ms.store(std.math.minInt(i64) / 2, .release);
}

/// O app está saindo: as notificações ainda na tela fecham (os botões delas não
/// teriam mais quem atender) e a thread acaba. Espera pouco: uma sessão D-Bus
/// travada não segura o fim do app.
pub fn parar() void {
    const t = thread orelse return;
    thread = null;
    saindo.store(true, .release);
    acordar();
    if (fim) |f| {
        if (c.SDL_WaitSemaphoreTimeout(f, 500)) c.SDL_WaitThread(t, null) else c.SDL_DetachThread(t);
    } else c.SDL_DetachThread(t);
}

fn iniciar(wake: u32) bool {
    wake_type = wake;
    if (lock == null) lock = c.SDL_CreateMutex();
    if (fim == null) fim = c.SDL_CreateSemaphore(0);
    if (lock == null or fim == null) return false;
    if (tubo[0] < 0) {
        if (c.pipe(&tubo) != 0) return false;
        for (tubo) |fd| {
            _ = c.fcntl(fd, c.F_SETFD, @as(c_int, c.FD_CLOEXEC));
            _ = c.fcntl(fd, c.F_SETFL, @as(c_int, c.O_NONBLOCK));
        }
    }
    saindo.store(false, .release);
    por(.conectando);
    thread = c.SDL_CreateThread(principal, "notificacoes", null) orelse return false;
    return true;
}

fn enviar(e: Envio) bool {
    const l = lock orelse return false;
    c.SDL_LockMutex(l);
    envios.append(gpa, e) catch {
        c.SDL_UnlockMutex(l);
        return false;
    };
    c.SDL_UnlockMutex(l);
    acordar();
    return true;
}

fn acordar() void {
    if (tubo[1] >= 0) _ = c.write(tubo[1], "x", 1);
}

/// Da thread para o app: guarda e acorda o laço.
fn voltar(v: n.Volta) void {
    const l = lock orelse return v.liberar(gpa);
    c.SDL_LockMutex(l);
    voltas.append(gpa, v) catch {
        c.SDL_UnlockMutex(l);
        return v.liberar(gpa);
    };
    c.SDL_UnlockMutex(l);
    if (!saindo.load(.acquire)) platform.Window.wake(wake_type, .notificacao);
}

fn devolver(a: n.Aviso) void {
    _ = em_voo.fetchSub(1, .acq_rel);
    voltar(.{ .devolvida = a });
}

fn pedir(p: n.Pedido) void {
    const copia = p.copiar(gpa) catch return;
    voltar(.{ .pedido = copia });
}

fn nowMs() i64 {
    return @intCast(c.SDL_GetTicks());
}

// --- A thread ------------------------------------------------------------------

fn principal(_: ?*anyopaque) callconv(.c) c_int {
    defer if (fim) |f| c.SDL_SignalSemaphore(f);
    var fd: c_int = -1;
    if (!conectar(&fd)) {
        desistir();
        return 0;
    }
    perguntar();
    laco(fd);
    // Saindo (ou a sessão caiu): as nossas na tela fecham, e a conexão também.
    if (d.dbus_connection_get_is_connected(conn) != 0) {
        fecharCanal(0);
        d.dbus_connection_flush(conn);
    }
    d.dbus_connection_close(conn);
    d.dbus_connection_unref(conn);
    return 0;
}

/// Sem D-Bus: o que estava na fila volta para o notify-send.
fn desistir() void {
    falhou_ms.store(nowMs(), .release);
    caps_v.store(0, .release);
    tabela.n = 0;
    por(.sem);
    devolverFila();
}

fn devolverFila() void {
    var lista: std.ArrayList(Envio) = .empty;
    defer lista.deinit(gpa);
    tomarFila(&lista);
    for (lista.items) |e| switch (e) {
        .mostrar => |a| devolver(a),
        .fechar => {},
    };
}

fn tomarFila(out: *std.ArrayList(Envio)) void {
    const l = lock orelse return;
    c.SDL_LockMutex(l);
    defer c.SDL_UnlockMutex(l);
    std.mem.swap(std.ArrayList(Envio), &envios, out);
}

fn conectar(fd: *c_int) bool {
    if (!dbus.load()) {
        std.log.info("notificações: sem libdbus-1, fica o notify-send", .{});
        return false;
    }
    var err: dbus.Err = undefined;
    d.dbus_error_init(&err);
    defer d.dbus_error_free(&err);
    const cn = sessao(&err) orelse {
        std.log.info("notificações: sem sessão D-Bus ({s}), fica o notify-send", .{err.message orelse "?"});
        return false;
    };
    // Por padrão a libdbus derruba o processo quando a conexão cai; aqui quem sai é o laço.
    d.dbus_connection_set_exit_on_disconnect(cn, 0);
    if (d.dbus_connection_add_filter(cn, &filtro, null, null) == 0 or d.dbus_connection_get_unix_fd(cn, fd) == 0) {
        d.dbus_connection_close(cn);
        d.dbus_connection_unref(cn);
        return false;
    }
    conn = cn;
    // Os sinais do servidor (de quem tem o nome agora) e a troca de servidor.
    d.dbus_bus_add_match(cn, "type='signal',sender='" ++ servico ++ "',path='" ++ caminho ++ "',interface='" ++ servico ++ "'", &err);
    if (err.name != null) {
        d.dbus_error_free(&err);
        d.dbus_error_init(&err);
    }
    d.dbus_bus_add_match(cn, "type='signal',sender='org.freedesktop.DBus',interface='org.freedesktop.DBus',member='NameOwnerChanged',arg0='" ++ servico ++ "'", &err);
    return true;
}

/// A sessão D-Bus. Com DBUS_SESSION_BUS_ADDRESS, conecta direto nele: o
/// dbus_bus_get_private lê o endereço uma vez por processo e não veria uma sessão que
/// apareceu depois de uma tentativa sem nenhuma (o QA sobe a dele no meio).
fn sessao(err: *dbus.Err) ?*dbus.Conn {
    const addr = c.getenv("DBUS_SESSION_BUS_ADDRESS");
    if (addr == null or addr[0] == 0) return d.dbus_bus_get_private(dbus.bus_session, err);
    const cn = d.dbus_connection_open_private(addr, err) orelse return null;
    if (d.dbus_bus_register(cn, err) == 0) {
        d.dbus_connection_close(cn);
        d.dbus_connection_unref(cn);
        return null;
    }
    return cn;
}

/// GetCapabilities: o servidor de agora (o D-Bus pode começar um que esteja só
/// instalado). Sem resposta, fica `sem_servidor` até um aparecer.
fn perguntar() void {
    tabela.n = 0;
    const msg = d.dbus_message_new_method_call(servico, caminho, servico, "GetCapabilities") orelse return semServidor();
    defer d.dbus_message_unref(msg);
    var err: dbus.Err = undefined;
    d.dbus_error_init(&err);
    defer d.dbus_error_free(&err);
    const reply = d.dbus_connection_send_with_reply_and_block(conn, msg, 5000, &err) orelse {
        std.log.info("notificações: sem servidor ({s}), fica o notify-send", .{err.name orelse "?"});
        return semServidor();
    };
    defer d.dbus_message_unref(reply);
    var lista: [32][]const u8 = undefined;
    var k: usize = 0;
    var in: In = .{};
    if (in.start(reply) and in.kind() == 'a') {
        var sub: In = .{};
        in.recurse(&sub);
        while (sub.str()) |s| : (sub.next()) {
            if (k == lista.len) break;
            lista[k] = s;
            k += 1;
        }
    }
    const cp = n.Caps.de(lista[0..k]);
    caps_v.store(@as(u8, @intFromBool(cp.acoes)) | @as(u8, @intFromBool(cp.resposta)) << 1 | @as(u8, @intFromBool(cp.markup)) << 2, .release);
    por(.pronto);
}

fn semServidor() void {
    caps_v.store(0, .release);
    tabela.n = 0;
    por(.sem_servidor);
    devolverFila();
}

fn laco(bus_fd: c_int) void {
    while (true) {
        // O flush também lê do socket: o que chegou durante ele fica na fila da
        // libdbus sem acordar o poll, então despacha de novo até ela esvaziar.
        while (true) {
            while (d.dbus_connection_dispatch(conn) == dbus.dispatch_data_remains) {}
            d.dbus_connection_flush(conn);
            if (d.dbus_connection_get_dispatch_status(conn) != dbus.dispatch_data_remains) break;
        }
        if (saindo.load(.acquire)) return;
        // A sessão caiu: daqui em diante é o notify-send (e outra tentativa mais tarde).
        if (d.dbus_connection_get_is_connected(conn) == 0) return desistir();
        if (reperguntar) {
            reperguntar = false;
            perguntar();
            continue;
        }
        if (atender()) continue;
        var fds = [2]c.struct_pollfd{
            .{ .fd = tubo[0], .events = c.POLLIN, .revents = 0 },
            .{ .fd = bus_fd, .events = c.POLLIN, .revents = 0 },
        };
        if (c.poll(&fds, 2, -1) < 0) continue;
        if (fds[0].revents != 0) {
            var lixo: [64]u8 = undefined;
            while (c.read(tubo[0], &lixo, lixo.len) > 0) {}
        }
        if (fds[1].revents != 0) _ = d.dbus_connection_read_write(conn, 0);
    }
}

/// Os pedidos do app. true: tinha algum.
fn atender() bool {
    var lista: std.ArrayList(Envio) = .empty;
    defer lista.deinit(gpa);
    tomarFila(&lista);
    for (lista.items) |e| switch (e) {
        .mostrar => |a| notify(a),
        .fechar => |canal| fecharCanal(canal),
    };
    return lista.items.len > 0;
}

// --- Notify ----------------------------------------------------------------------

/// A notificação a caminho do servidor: o número dela chega na resposta.
const Caminho = struct { aviso: ?n.Aviso };

fn notify(a: n.Aviso) void {
    if (estado() != .pronto) return devolver(a);
    const msg = montar(a) orelse return devolver(a);
    defer d.dbus_message_unref(msg);
    const ctx = gpa.create(Caminho) catch return devolver(a);
    ctx.* = .{ .aviso = a };
    var p: ?*dbus.Pending = null;
    if (d.dbus_connection_send_with_reply(conn, msg, &p, 10_000) == 0 or p == null) {
        gpa.destroy(ctx);
        return devolver(a);
    }
    if (d.dbus_pending_call_set_notify(p.?, &numerada, ctx, &soltarCaminho) == 0) {
        d.dbus_pending_call_cancel(p.?);
        d.dbus_pending_call_unref(p.?);
        gpa.destroy(ctx);
        return devolver(a);
    }
}

fn soltarCaminho(data: ?*anyopaque) callconv(.c) void {
    const ctx: *Caminho = @ptrCast(@alignCast(data orelse return));
    // A conexão fechou antes da resposta: a notificação não volta mais.
    if (ctx.aviso) |a| gpa.free(a.buf);
    gpa.destroy(ctx);
}

/// A resposta do Notify: o número, que o ActionInvoked vai trazer de volta. Erro (o
/// servidor saiu bem agora, recusou): a notificação volta para o notify-send.
fn numerada(p: *dbus.Pending, data: ?*anyopaque) callconv(.c) void {
    const ctx: *Caminho = @ptrCast(@alignCast(data.?));
    defer d.dbus_pending_call_unref(p);
    const a = ctx.aviso orelse return;
    ctx.aviso = null;
    const reply = d.dbus_pending_call_steal_reply(p) orelse return devolver(a);
    defer d.dbus_message_unref(reply);
    var in: In = .{};
    const id = if (d.dbus_message_get_type(reply) == dbus.msg_method_return and in.start(reply)) in.uint() else null;
    if (id == null or id.? == 0) {
        std.log.info("notificações: o servidor recusou ({s})", .{dbus.span(d.dbus_message_get_error_name(reply)) orelse "?"});
        return devolver(a);
    }
    _ = em_voo.fetchSub(1, .acq_rel);
    if (tabela.por(id.?, a.alvo, a.tipo)) |velha| closeNotification(velha);
    gpa.free(a.buf);
}

/// O Notify(app_name, replaces_id, app_icon, summary, body, actions, hints, expire_timeout).
fn montar(a: n.Aviso) ?*dbus.Msg {
    const cp = caps();
    var botoes_buf: [3]n.Botao = undefined;
    var chaves: n.Chaves = .{};
    const botoes = n.botoesDbus(&botoes_buf, &chaves, cp, a);
    // Tudo num buffer só, cada texto terminado em zero (e em UTF-8 válido, que a
    // libdbus derruba o processo com UTF-8 quebrado): o título, o corpo, a dica da
    // caixa e, de cada botão, a chave e o rótulo.
    var txt: std.ArrayList(u8) = .empty;
    defer txt.deinit(gpa);
    var ini: [3 + 2 * botoes_buf.len]usize = undefined;
    var k: usize = 0;
    campo(&txt, &ini, &k, a.titulo, .texto) catch return null;
    campo(&txt, &ini, &k, a.corpo, if (cp.markup) .markup else .texto) catch return null;
    campo(&txt, &ini, &k, a.dica, .texto) catch return null;
    for (botoes) |b| {
        campo(&txt, &ini, &k, b.chave, .texto) catch return null;
        campo(&txt, &ini, &k, b.rotulo, .texto) catch return null;
    }
    const z = struct {
        fn at(buf: []const u8, i: usize) [*:0]const u8 {
            return @ptrCast(buf[i..].ptr);
        }
    };
    const base = txt.items;

    const msg = d.dbus_message_new_method_call(servico, caminho, servico, "Notify") orelse return null;
    var out: Out = .{};
    d.dbus_message_iter_init_append(msg, &out.it);
    out.str("larperCord");
    out.uint(0);
    // O ícone pelo nome: o do mascote escolhido (ver App.applyMascot e icone_sistema).
    out.str("larpercord");
    out.str(z.at(base, ini[0]));
    out.str(z.at(base, ini[1]));
    var arr: Out = .{};
    out.open(&arr, 'a', "s");
    for (0..botoes.len) |i| {
        arr.str(z.at(base, ini[3 + 2 * i]));
        arr.str(z.at(base, ini[4 + 2 * i]));
    }
    out.close(&arr);
    var dict: Out = .{};
    out.open(&dict, 'a', "{sv}");
    var e: Out = .{};
    dict.entry(&e, "desktop-entry");
    e.variantStr(desktop_entry);
    dict.close(&e);
    dict.entry(&e, "urgency");
    e.variantByte(1);
    dict.close(&e);
    if (a.tipo == .mensagem) {
        dict.entry(&e, "category");
        e.variantStr("im.received");
        dict.close(&e);
    }
    if (n.temCaixa(cp, a)) {
        dict.entry(&e, "x-kde-reply-placeholder-text");
        e.variantStr(z.at(base, ini[2]));
        dict.close(&e);
    }
    out.close(&dict);
    out.int(-1);
    return msg;
}

fn campo(txt: *std.ArrayList(u8), ini: []usize, k: *usize, s: []const u8, modo: n.Modo) !void {
    ini[k.*] = txt.items.len;
    k.* += 1;
    try n.limpar(gpa, txt, s, modo);
    try txt.append(gpa, 0);
}

fn closeNotification(id: u32) void {
    const msg = d.dbus_message_new_method_call(servico, caminho, servico, "CloseNotification") orelse return;
    defer d.dbus_message_unref(msg);
    d.dbus_message_set_no_reply(msg, 1);
    var out: Out = .{};
    d.dbus_message_iter_init_append(msg, &out.it);
    out.uint(id);
    _ = d.dbus_connection_send(conn, msg, null);
}

fn fecharCanal(canal: n.Id) void {
    if (estado() != .pronto) return;
    var ids: [n.max_vivas]u32 = undefined;
    for (tabela.tirarDoCanal(canal, &ids)) |id| closeNotification(id);
}

// --- Sinais ----------------------------------------------------------------------

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn filtro(_: *dbus.Conn, msg: *dbus.Msg, _: ?*anyopaque) callconv(.c) c_int {
    if (d.dbus_message_get_type(msg) != dbus.msg_signal) return dbus.not_yet;
    const iface = dbus.span(d.dbus_message_get_interface(msg)) orelse return dbus.not_yet;
    const member = dbus.span(d.dbus_message_get_member(msg)) orelse return dbus.not_yet;
    var in: In = .{};
    if (!in.start(msg)) return dbus.not_yet;
    if (eql(iface, "org.freedesktop.DBus") and eql(member, "NameOwnerChanged")) {
        const nome = in.str() orelse return dbus.not_yet;
        in.next();
        in.next();
        const novo = in.str() orelse return dbus.not_yet;
        if (!eql(nome, servico)) return dbus.not_yet;
        // O servidor saiu (as notificações dele foram junto) ou (re)começou: o novo
        // pode saber outras coisas (do KDE para o GNOME, com ou sem caixa de texto).
        if (novo.len == 0) semServidor() else reperguntar = true;
        return dbus.not_yet;
    }
    if (!eql(iface, servico)) return dbus.not_yet;
    const id = in.uint() orelse return dbus.not_yet;
    in.next();
    if (eql(member, "ActivationToken")) {
        // Vem antes do ActionInvoked: a janela volta com o foco no Wayland.
        if (in.str()) |ficha| tabela.guardarFicha(id, ficha);
    } else if (eql(member, "ActionInvoked")) {
        const k = in.str() orelse return dbus.not_yet;
        if (n.deAcao(&tabela, id, k)) |p| pedir(p);
    } else if (eql(member, "NotificationReplied")) {
        const texto = in.str() orelse return dbus.not_yet;
        if (n.deResposta(&tabela, id, texto)) |p| pedir(p);
    } else if (eql(member, "NotificationClosed")) {
        tabela.tirar(id);
    }
    return dbus.not_yet;
}
