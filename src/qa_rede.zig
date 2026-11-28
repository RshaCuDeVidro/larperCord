//! QA da rede de verdade (QA_SUITE=rede, tools/qa_rede.sh): o net/discord.zig inteiro
//! (WebSocket, zlib-stream, IDENTIFY, heartbeat, RESUME, op 7 e op 9, READY, REST e o 429)
//! contra o Discord de mentira de tools/discord_falso.py, em 127.0.0.1. As outras baterias
//! trocam a rede inteira pelo net/fake_gateway.zig; aqui só o endereço muda.
//!
//! As checagens olham o efeito no app (Store, tela de entrada) e perguntam ao servidor o
//! que chegou nele (`/ctl/check/...`, o porquê de uma falha sai no fim do tools/qa_rede.sh).
//! Os comandos ao servidor (mandar um evento, fechar o socket, parar o ACK) vão pela mesma
//! porta, em `/ctl/...`. Só existe no executável de debug do QA (net/enderecos.zig).
const std = @import("std");
const c = @import("c");
const App = @import("app.zig").App;
const R = @import("qa_runner.zig");
const Op = R.Op;
const types = @import("core/types.zig");
const enderecos = @import("net/enderecos.zig");
const app_accounts = @import("app_accounts.zig");
const gw = @import("net/fake_gateway.zig");
const qa = @import("ui/qa.zig");
const Id = types.Id;

comptime {
    std.debug.assert(enderecos.pode_trocar);
}

// Os mesmos de tools/discord_falso.py.
const me: Id = 1180000000000000001;
const bia: Id = 1180000000000000002;
const guild: Id = 1190000000000000010;
const geral: Id = 1190000000000000012;
const limite: Id = 1190000000000000013;
const dm: Id = 1190000000000000020;
const voz: Id = 1190000000000000014;
const bot: Id = 1180000000000000004;
const bot2: Id = 1180000000000000005;

/// O app abre na conta do Discord de mentira, com o net/discord.zig de verdade. Recusa
/// qualquer endereço fora de http://127.0.0.1:<porta> e qualquer token que não seja o de
/// mentira: um token de verdade no LARPER_TOKEN nunca sai daqui.
pub fn comecar(app: *App) !void {
    const base = std.mem.span(c.SDL_getenv("LARPER_QA_DISCORD") orelse {
        std.log.err("QA_SUITE=rede precisa de LARPER_QA_DISCORD=http://127.0.0.1:<porta> (tools/qa_rede.sh)", .{});
        return error.QaRede;
    });
    if (!enderecos.usarLocal(base)) {
        std.log.err("LARPER_QA_DISCORD recusado: só http://127.0.0.1:<porta>", .{});
        return error.QaRede;
    }
    const token = app_accounts.envStartupToken() orelse {
        std.log.err("QA_SUITE=rede precisa do token de mentira no LARPER_TOKEN (tools/qa_rede.sh)", .{});
        return error.QaRede;
    };
    if (!std.mem.eql(u8, token, enderecos.token_qa)) {
        std.crypto.secureZero(u8, token);
        std.heap.c_allocator.free(token);
        std.log.err("QA_SUITE=rede só aceita o token de mentira fixo (net/enderecos.zig)", .{});
        return error.QaRede;
    }
    try app.startReal(token);
    app.login.begin(.connecting);
}

// --- O canal de controle -----------------------------------------------------------------

const Resp = struct {
    buf: [8192]u8 = undefined,
    len: usize = 0,

    fn body(r: *const Resp) []const u8 {
        return r.buf[0..r.len];
    }
};

fn writeCb(ptr: [*c]u8, size: usize, n: usize, ud: ?*anyopaque) callconv(.c) usize {
    const r: *Resp = @ptrCast(@alignCast(ud.?));
    const k = size * n;
    const take = @min(k, r.buf.len - r.len);
    @memcpy(r.buf[r.len..][0..take], ptr[0..take]);
    r.len += take;
    return k;
}

/// GET num caminho do servidor de mentira; true = respondeu 200.
fn pedir(path: []const u8, r: *Resp) bool {
    @import("ui/images.zig").curlGlobalInit();
    var ub: [512]u8 = undefined;
    const url = std.fmt.bufPrintSentinel(&ub, "{s}{s}", .{ enderecos.baseLocal(), path }, 0) catch return false;
    const h = c.curl_easy_init() orelse return false;
    defer c.curl_easy_cleanup(h);
    _ = c.curl_easy_setopt(h, c.CURLOPT_URL, url.ptr);
    _ = c.curl_easy_setopt(h, c.CURLOPT_PROTOCOLS_STR, "http");
    _ = c.curl_easy_setopt(h, c.CURLOPT_PROXY, "");
    _ = c.curl_easy_setopt(h, c.CURLOPT_NOSIGNAL, @as(c_long, 1));
    _ = c.curl_easy_setopt(h, c.CURLOPT_TIMEOUT_MS, @as(c_long, 3000));
    _ = c.curl_easy_setopt(h, c.CURLOPT_WRITEFUNCTION, writeCb);
    _ = c.curl_easy_setopt(h, c.CURLOPT_WRITEDATA, r);
    if (c.curl_easy_perform(h) != c.CURLE_OK) return false;
    var status: c_long = 0;
    _ = c.curl_easy_getinfo(h, c.CURLINFO_RESPONSE_CODE, &status);
    return status == 200;
}

/// `{"ok": true, ...}` na resposta.
fn respostaOk(r: *const Resp) bool {
    const parsed = std.json.parseFromSlice(std.json.Value, std.heap.c_allocator, r.body(), .{}) catch return false;
    defer parsed.deinit();
    const v = if (parsed.value == .object) parsed.value.object.get("ok") else null;
    return if (v) |x| x == .bool and x.bool else false;
}

/// Uma pergunta ao servidor a cada 100 ms no máximo (a checagem roda a cada quadro).
var ultimo_ms: i64 = 0;
var ultimo_path: []const u8 = "";

fn checar(path: []const u8) bool {
    const t = gw.monoMs();
    if (ultimo_path.ptr == path.ptr and t - ultimo_ms < 100) return false;
    ultimo_ms = t;
    ultimo_path = path;
    var r: Resp = .{};
    return pedir(path, &r) and respostaOk(&r);
}

fn pergunta(comptime path: []const u8) *const fn (*App) bool {
    return struct {
        fn f(_: *App) bool {
            return checar(path);
        }
    }.f;
}

/// Um comando ao servidor, como uma etapa que passa quando ele aceita.
fn manda(comptime nome: []const u8, comptime path: []const u8) Op {
    return .{ .expect = .{ .name = nome, .check = struct {
        fn f(_: *App) bool {
            var r: Resp = .{};
            return pedir(path, &r) and respostaOk(&r);
        }
    }.f } };
}

fn ctl(comptime fmt: []const u8, args: anytype) []const u8 {
    return comptime std.fmt.comptimePrint(fmt, args);
}

// --- Ajudantes ---------------------------------------------------------------------------

fn s(name: []const u8) Op {
    return .{ .section = name };
}
fn click(k: []const u8) Op {
    return .{ .click = .{ .mark = k } };
}
fn expect(name: []const u8, f: *const fn (*App) bool) Op {
    return .{ .expect = .{ .name = name, .check = f } };
}
fn expectT(name: []const u8, f: *const fn (*App) bool, ms: u32) Op {
    return .{ .expect = .{ .name = name, .check = f, .timeout_ms = ms } };
}
fn key(k: c_int) Op {
    return .{ .key = .{ .key = k } };
}

/// Posição da mensagem com esse texto no canal (null = não está).
fn achar(app: *App, ch: Id, texto: []const u8) ?usize {
    const cs = app.store.channel(ch) orelse return null;
    for (cs.messages.items, 0..) |*m, i| if (std.mem.eql(u8, m.msg.content, texto)) return i;
    return null;
}

fn quantas(app: *App, ch: Id, texto: []const u8) usize {
    const cs = app.store.channel(ch) orelse return 0;
    var n: usize = 0;
    for (cs.messages.items) |*m| {
        if (std.mem.eql(u8, m.msg.content, texto)) n += 1;
    }
    return n;
}

fn temMsg(comptime ch: Id, comptime texto: []const u8) *const fn (*App) bool {
    return struct {
        fn f(app: *App) bool {
            const i = achar(app, ch, texto) orelse return false;
            const m = &app.store.channel(ch).?.messages.items[i];
            return !m.pending and m.msg.id != 0 and quantas(app, ch, texto) == 1;
        }
    }.f;
}

fn emOrdem(app: *App, ch: Id, textos: []const []const u8) bool {
    var antes: ?usize = null;
    for (textos) |t| {
        const i = achar(app, ch, t) orelse return false;
        if (antes) |a| if (i <= a) return false;
        antes = i;
    }
    return true;
}

// --- Checagens no app --------------------------------------------------------------------

fn pronto(app: *App) bool {
    return app.store.ready and !app.store.demo and app.store.me == me and app.store.connection == .ready and
        app.store.guild(guild) != null and app.store.channel(geral) != null and
        app.store.channel(limite) != null and app.store.channel(dm) != null and app.store.user(bia) != null;
}

fn conectado(app: *App) bool {
    return app.store.ready and app.store.connection == .ready;
}

fn historicoGeral(app: *App) bool {
    if (app.st.activeChannel() != geral) return false;
    return emOrdem(app, geral, &.{ "primeira do histórico", "segunda do histórico", "terceira do histórico" });
}

fn historicoLimite(app: *App) bool {
    return app.st.activeChannel() == limite and achar(app, limite, "histórico depois do 429") != null;
}

const enviada = "mensagem do app pela rede";

fn pendente(app: *App) bool {
    const i = achar(app, geral, enviada) orelse return false;
    return app.store.channel(geral).?.messages.items[i].pending;
}

fn confirmada(app: *App) bool {
    return temMsg(geral, enviada)(app);
}

fn rajada(app: *App) bool {
    var nomes: [30][16]u8 = undefined;
    var lista: [30][]const u8 = undefined;
    for (0..30) |i| lista[i] = std.fmt.bufPrint(&nomes[i], "rajada {d}", .{i + 1}) catch return false;
    return emOrdem(app, geral, &lista);
}

fn perdidas(app: *App) bool {
    return emOrdem(app, geral, &.{ "perdida 1", "perdida 2" }) and quantas(app, geral, "perdida 1") == 1;
}

/// O bot está no Store (como bot), na lista de #voz e desenhado embaixo do canal.
fn botNaCall(comptime uid: Id) *const fn (*App) bool {
    return struct {
        fn f(app: *App) bool {
            const u = app.store.user(uid) orelse return false;
            const cs = app.store.channel(voz) orelse return false;
            if (!u.bot or std.mem.indexOfScalar(Id, cs.voice_members.items, uid) == null) return false;
            return qa.find(ctl("voice-member:{d}:{d}", .{ voz, uid })) != null;
        }
    }.f;
}

fn naEntrada(app: *App) bool {
    const err = app.login.err_buf[0..app.login.err_len];
    return app.net == .none and app.login.phase == .form and std.mem.indexOf(u8, err, "4004") != null;
}

// --- O roteiro ---------------------------------------------------------------------------

pub const ops = [_]Op{
    s("rede: conectar"),
    expectT("conecta no Discord de mentira: READY com o servidor, os canais, a DM e a conta no Store", pronto, 10000),
    expectT("IDENTIFY do cliente web (properties, capabilities, compress false, presence, client_state) e a URL com zlib-stream", pergunta("/ctl/check/identify"), 3000),
    expectT("heartbeat no intervalo do HELLO, levando o último seq", pergunta("/ctl/check/heartbeat"), 4000),

    s("rede: histórico"),
    click(ctl("guild:{d}", .{guild})),
    click(ctl("channel:{d}", .{geral})),
    expectT("abrir o canal pede GET /channels/{id}/messages?limit=50", pergunta(ctl("/ctl/check/history?channel={d}", .{geral})), 4000),
    expectT("o histórico aparece na conversa, na ordem", historicoGeral, 4000),
    expect("REST com o token no Authorization, o User-Agent e o X-Super-Properties das properties do IDENTIFY", pergunta("/ctl/check/rest")),

    s("rede: mensagem que chega"),
    manda("o servidor manda um MESSAGE_CREATE", ctl("/ctl/message?channel={d}&text=oi%20do%20servidor", .{geral})),
    expect("o MESSAGE_CREATE aparece no canal", temMsg(geral, "oi do servidor")),

    s("rede: bot na call"),
    expectT("quem já estava na call ao abrir e nunca escreveu (um bot) vai num op 8, uma vez", pergunta(ctl("/ctl/check/op8?user={d}&times=1", .{bot})), 4000),
    expectT("com a resposta do op 8, o bot aparece embaixo de #voz", botNaCall(bot), 4000),
    manda("outro bot entra na call (VOICE_STATE_UPDATE com o membro e a pessoa)", ctl("/ctl/voz?user={d}", .{bot2})),
    expectT("ele aparece embaixo de #voz na hora", botNaCall(bot2), 3000),
    expect("e não vai op 8 por ele (o evento já trouxe a pessoa)", pergunta(ctl("/ctl/check/op8?user={d}&times=0", .{bot2}))),

    s("rede: enviar"),
    manda("o eco do envio vai atrasar 800 ms", "/ctl/echo?ms=800"),
    click("composer"),
    .{ .text = enviada },
    key(c.ImGuiKey_Enter),
    expect("a mensagem fica pendente até o Discord confirmar", pendente),
    expect("POST /channels/{id}/messages com content, nonce e tts", pergunta(ctl("/ctl/check/sent?channel={d}&text=mensagem%20do%20app%20pela%20rede", .{geral}))),
    expectT("o MESSAGE_CREATE com o nonce troca a pendente pela confirmada (uma só)", confirmada, 4000),
    manda("o eco volta a ser na hora", "/ctl/echo?ms=0"),

    s("rede: zlib-stream"),
    manda("o próximo evento vai em 3 mensagens do WebSocket", "/ctl/split?parts=3"),
    manda("o servidor manda o evento dividido", ctl("/ctl/message?channel={d}&text=dividida%20em%20tres", .{geral})),
    expect("um evento dividido em 3 mensagens do WebSocket chega inteiro", temMsg(geral, "dividida em tres")),
    manda("o próximo evento vai numa mensagem de 4 quadros", "/ctl/fragment?parts=4"),
    manda("o servidor manda o evento fragmentado", ctl("/ctl/message?channel={d}&text=em%20quatro%20quadros", .{geral})),
    expect("uma mensagem do WebSocket em 4 quadros (continuação) chega inteira", temMsg(geral, "em quatro quadros")),
    manda("30 eventos seguidos no mesmo stream zlib", ctl("/ctl/burst?channel={d}&n=30&prefix=rajada", .{geral})),
    expect("os 30 chegam todos, na ordem", rajada),
    manda("um evento de ~200 KB comprimido", ctl("/ctl/big?channel={d}&text=evento%20grande", .{geral})),
    expect("o evento grande (várias leituras do socket) chega", temMsg(geral, "evento grande")),

    s("rede: queda e RESUME"),
    manda("o servidor fecha o socket com 4000 e guarda 2 eventos", ctl("/ctl/close?code=4000&missed=2&channel={d}", .{geral})),
    expectT("volta com RESUME (session_id e seq) no resume_gateway_url, sem fechar com 1000", pergunta("/ctl/check/resume?kind=close"), 6000),
    expect("as 2 mensagens perdidas na queda chegam no replay", perdidas),
    expect("o app volta para conectado", conectado),

    s("rede: op 7"),
    manda("o servidor manda op 7 RECONNECT", "/ctl/op7"),
    expectT("op 7: reconecta e volta com RESUME", pergunta("/ctl/check/resume?kind=op7"), 6000),
    expect("o app volta para conectado", conectado),

    s("rede: op 9"),
    manda("o servidor manda op 9 sem retomada", "/ctl/op9?resumable=0"),
    expectT("op 9: espera e abre uma sessão nova com IDENTIFY no gateway", pergunta("/ctl/check/fresh?min_ms=100"), 8000),
    expectT("READY de novo e o app conectado", conectado, 5000),

    s("rede: heartbeat sem ACK"),
    manda("o servidor para de responder o heartbeat", "/ctl/noack"),
    expectT("sem o ACK, larga a conexão zumbi no heartbeat seguinte e volta com RESUME", pergunta("/ctl/check/zombie"), 8000),
    expect("o app volta para conectado", conectado),

    s("rede: 429"),
    manda("o próximo GET do histórico de #limite leva 429 (retry_after 0,6 s)", ctl("/ctl/rate429?channel={d}&count=1&retry_after=0.6", .{limite})),
    click(ctl("channel:{d}", .{limite})),
    expectT("429 com retry_after: espera e tenta de novo uma vez só", pergunta(ctl("/ctl/check/ratelimit?channel={d}&ms=600", .{limite})), 5000),
    expect("o histórico chega depois da espera", historicoLimite),
    .{ .wait = 1200 },
    expect("nenhum pedido a mais depois disso", pergunta(ctl("/ctl/check/ratelimit?channel={d}&ms=600&depois=1", .{limite}))),

    s("rede: token recusado (4004)"),
    manda("o servidor fecha com 4004", "/ctl/close?code=4004"),
    expectT("volta para a tela de entrada com o aviso do 4004", naEntrada, 5000),
    .{ .wait = 1500 },
    expect("nenhuma conexão nova depois do 4004", pergunta("/ctl/check/no_reconnect?min_ms=1400")),
};
