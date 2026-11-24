//! QA_SUITE=plugins-api: o que os plugins ganharam na 0.7, com o app de verdade e a
//! demonstração respondendo. Rótulos em qualquer idioma (o menu em japonês), o HTTP
//! completo contra o servidor de mentira de qa_plugins.zig (outros métodos, cabeçalhos
//! da resposta, credencial só para o host de @credentials, redirecionamento só para
//! um host aprovado), o registro de rede no cartão, os segredos separados por plugin e
//! as ações na conta: cada uma muda a demonstração, só num gesto, e apagar e anexar
//! passam pela confirmação na tela. Nada sai para a internet nem fala com o Discord.
const std = @import("std");
const c = @import("c");
const App = @import("app.zig").App;
const R = @import("qa_runner.zig");
const Op = R.Op;
const qa = @import("ui/qa.zig");
const i18n = @import("ui/i18n.zig");
const types = @import("core/types.zig");
const engine = @import("plugins/engine.zig");
const plugin_confirm = @import("ui/plugin_confirm.zig");
const qp = @import("qa_plugins.zig");
const Id = types.Id;
const Plugin = engine.Plugin;

fn s(name: []const u8) Op {
    return .{ .section = name };
}
fn click(k: []const u8) Op {
    return .{ .click = .{ .mark = k } };
}
fn key(k: c_int) Op {
    return .{ .key = .{ .key = k } };
}
fn ctrl(k: c_int) Op {
    return .{ .key = .{ .key = k, .ctrl = true } };
}
fn run(f: *const fn (*App) void) Op {
    return .{ .run = f };
}
// A resposta passa pela thread dos plugins e pela do pedido: leva o que levar.
fn expect(name: []const u8, f: *const fn (*App) bool) Op {
    return .{ .expect = .{ .name = name, .check = f, .timeout_ms = 10000 } };
}

/// Um comando na caixa de mensagem: o primeiro Enter escolhe na lista do
/// autocompletar, o segundo envia (nenhum nome aqui é começo de outro).
fn cmd(comptime text: []const u8) [4]Op {
    return .{ click("composer"), .{ .text = text }, key(c.ImGuiKey_Enter), key(c.ImGuiKey_Enter) };
}

const geral: Id = 500005;

const plugin_a =
    \\-- @name QA 0.7
    \\-- @name:ja QA ゼロナナ
    \\-- @description Tests the 0.7 plugin API.
    \\-- @description:pt Testa a API de plugins da 0.7.
    \\-- @capabilities menu, http, notify, secrets, actions, send, composer, timers, messages
    \\-- @hosts qa.exemplo.com, *.cdn.exemplo.com
    \\-- @credentials qa.exemplo.com
    \\local alvo, proprio = nil, nil
    \\local function mostra(nome)
    \\  return function(r)
    \\    larper.notify(nome .. "|" .. tostring(r.ok) .. "|" .. tostring(r.status) .. "|" .. tostring(r.error) .. "|" .. r.body
    \\      .. "|" .. tostring(r.headers.etag) .. "|" .. tostring(r.headers["x-ratelimit-remaining"]) .. "|" .. tostring(r.headers["set-cookie"]))
    \\  end
    \\end
    \\larper.menu("message", { pt = "Marcar alvo", en = "Mark target", ja = "ターゲット" }, function(msg)
    \\  alvo = msg
    \\  larper.notify("alvo|" .. msg.id)
    \\end)
    \\larper.on("message", function(m)
    \\  if m.mine and m.content == "minha-qa07" then proprio = m; larper.notify("proprio|" .. m.id) end
    \\end, { contains = { "minha-qa07" } })
    \\larper.command("/qa-put", function() larper.http.put("https://qa.exemplo.com/method?x=segredo", { body = "corpo-put" }, mostra("put")) end)
    \\larper.command("/qa-head", function() larper.http.head("https://img.cdn.exemplo.com/method", mostra("head")) end)
    \\larper.command("/qa-hdr", function() larper.http.get("https://qa.exemplo.com/hdr", mostra("hdr")) end)
    \\larper.command("/qa-cred", function()
    \\  larper.secrets.set("token", "tok-123")
    \\  larper.http.get("https://qa.exemplo.com/cred", { headers = { Authorization = "Bearer " .. larper.secrets.get("token") } }, mostra("cred"))
    \\end)
    \\larper.command("/qa-rok", function() larper.http.get("https://qa.exemplo.com/redir-ok", { headers = { Authorization = "Bearer tok-123" } }, mostra("rok")) end)
    \\larper.command("/qa-rout", function() larper.http.get("https://qa.exemplo.com/redir-out", mostra("rout")) end)
    \\larper.command("/qa-rloop", function() larper.http.get("https://qa.exemplo.com/redir-loop", mostra("rloop")) end)
    \\larper.command("/qa-secret", function() larper.notify("segredo|" .. tostring(larper.secrets.get("token"))) end)
    \\larper.command("/qa-react", function() larper.react(alvo, "🔥") end)
    \\larper.command("/qa-reply", function() larper.reply(alvo, "resposta do plugin") end)
    \\larper.command("/qa-pin", function() larper.pin(alvo) end)
    \\larper.command("/qa-thread", function() larper.thread(alvo, "thread do plugin") end)
    \\larper.command("/qa-mine-edit", function() larper.edit(proprio, "editada pelo plugin") end)
    \\larper.command("/qa-other-edit", function() larper.edit(alvo, "não pode") end)
    \\larper.command("/qa-delete", function() larper.delete(proprio) end)
    \\larper.command("/qa-attach", function() larper.attach(nil) end)
    \\larper.command("/qa-timer", function() larper.after(0.05, function() larper.react(alvo, "👍") end) end)
;

const plugin_b =
    \\-- @name QA 0.7 b
    \\-- @capabilities secrets, notify
    \\larper.command("/qb-secret", function() larper.notify("b|" .. tostring(larper.secrets.get("token"))) end)
;

fn plugin(app: *App, name: []const u8) ?*Plugin {
    for (app.plugins.list.items) |p| if (std.mem.eql(u8, p.name, name)) return p;
    return null;
}

fn toastHas(app: *App, needle: []const u8) bool {
    return std.mem.indexOf(u8, app.st.toast.text(), needle) != null;
}

fn clearToast(app: *App) void {
    app.st.toast.len = 0;
}

fn writePlugins(app: *App) void {
    qp.removeAllPluginsPub(app);
    _ = c.SDL_CreateDirectory("qa-out/plugins");
    _ = c.SDL_SaveFile("qa-out/plugins/qa07.lua", plugin_a.ptr, plugin_a.len);
    _ = c.SDL_SaveFile("qa-out/plugins/qa07b.lua", plugin_b.ptr, plugin_b.len);
    app.plugins.reload();
}

fn loaded(app: *App) bool {
    const a = plugin(app, "qa07.lua") orelse return false;
    const b = plugin(app, "qa07b.lua") orelse return false;
    return a.status() == .running and b.status() == .running and a.menus.items.len == 1 and app.plugins.n_commands > 10;
}

fn approveMain(app: *App) void {
    if (plugin(app, "qa07.lua")) |p| app.plugins.setApproved(p, "qa.exemplo.com", true);
}

fn approveWildcard(app: *App) void {
    if (plugin(app, "qa07.lua")) |p| app.plugins.setApproved(p, "*.cdn.exemplo.com", true);
}

fn toGeral(app: *App) void {
    app.handle(.{ .open_message = .{ .channel = geral, .id = 0 } });
}

// --- A mensagem de outra pessoa (o alvo) e a sua ---------------------------------------

var other_id: Id = 0;
var own_id: Id = 0;
var mbuf: [64]u8 = undefined;

/// Uma mensagem de texto recente de outra pessoa, à vista (como qa_plugins.pickOther).
fn pickOther(app: *App) void {
    const ch = app.st.activeChannel() orelse return;
    const cs = app.store.channel(ch) orelse return;
    var i = cs.messages.items.len;
    while (i > 0) {
        i -= 1;
        const m = &cs.messages.items[i];
        if (m.msg.author == app.store.me or m.msg.id == 0 or m.msg.system != .none or m.msg.content.len == 0 or std.mem.indexOf(u8, m.msg.content, "://") != null) continue;
        if (m.msg.thread != 0 or m.msg.pinned) continue;
        const r = qa.find(std.fmt.bufPrint(&mbuf, "msgtext:{d}", .{m.msg.id}) catch continue) orelse continue;
        if (r.y < 120 or r.bottom() > app.io.*.DisplaySize.y - 120) continue;
        other_id = m.msg.id;
        return;
    }
}

fn tOther(_: *App, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "msgtext:{d}", .{other_id}) catch "";
}

const rmsg: Op = .{ .rclick = .{ .dyn_at = .{ .f = tOther, .fx = 0.25, .fy = 0.5 } } };

// --- Idiomas ---------------------------------------------------------------------------

fn setJa(_: *App) void {
    i18n.set("ja");
}

fn setPt(_: *App) void {
    i18n.set("pt");
}

fn titleJa(app: *App) bool {
    const p = plugin(app, "qa07.lua") orelse return false;
    return std.mem.eql(u8, p.title(), "QA ゼロナナ") and std.mem.eql(u8, p.about(), "Tests the 0.7 plugin API.");
}

fn menuJa(app: *App) bool {
    return app.st.popup == .menu and qa.find("menu:ターゲット") != null and qa.find("menu:Marcar alvo") == null;
}

fn targetMarked(app: *App) bool {
    var b: [40]u8 = undefined;
    const want = std.fmt.bufPrint(&b, "alvo|{d}", .{other_id}) catch return false;
    const p = plugin(app, "qa07.lua") orelse return false;
    return other_id != 0 and toastHas(app, want) and std.mem.eql(u8, p.title(), "QA 0.7");
}

// --- HTTP ------------------------------------------------------------------------------

var count0: u32 = 0;

fn rememberCount(_: *App) void {
    count0 = qp.serverCountPub();
}

fn putOk(app: *App) bool {
    return toastHas(app, "put|true|200|nil|PUT:corpo-put|\"p1\"|nil|nil") and qp.serverLastHasPub("PUT /method?x=segredo ");
}

fn headRefused(app: *App) bool {
    return toastHas(app, "head|false|0|not_approved|");
}

fn headOk(app: *App) bool {
    return toastHas(app, "head|true|200|nil||nil|nil|nil") and qp.serverLastHasPub("HEAD /method ");
}

fn headersOk(app: *App) bool {
    // ETag e o limite chegam; o Set-Cookie nunca.
    return toastHas(app, "hdr|true|200|nil|ok|\"v7\"|41|nil");
}

fn credOk(app: *App) bool {
    return toastHas(app, "cred|true|200|nil|auth:sim|") and !qp.serverLeaked();
}

fn redirectFollowed(app: *App) bool {
    // Seguiu para o CDN aprovado, e a credencial ficou para trás.
    return toastHas(app, "rok|true|200|nil|final:sem|") and qp.serverLastHasPub("GET /final ") and !qp.serverLeaked();
}

fn redirectOutRefused(app: *App) bool {
    return toastHas(app, "rout|false|0|redirect|");
}

fn redirectLoopStops(app: *App) bool {
    // O primeiro pedido e mais 5 redirecionamentos, e para.
    return toastHas(app, "rloop|false|0|redirect|") and qp.serverCountPub() - count0 == 6;
}

// --- O cartão: credencial, capacidades e o registro de rede ------------------------------

fn cardShows(_: *App) bool {
    return qa.find("plugin-creds:qa07.lua") != null and qa.find("plugin-chip:qa07.lua:secrets") != null and
        qa.find("plugin-chip:qa07.lua:actions") != null and qa.find("plugin-net:qa07.lua") != null and
        qa.find("plugin-creds:qa07b.lua") == null and qa.find("plugin-net:qa07b.lua") == null;
}

fn netOpen(app: *App) bool {
    const p = plugin(app, "qa07.lua") orelse return false;
    if (!p.net_open or qa.find("plugin-net-row:qa07.lua:0") == null) return false;
    // O mais novo primeiro: o laço de redirecionamento, recusado no fim.
    const newest = p.netEntry(0) orelse return false;
    if (!std.mem.eql(u8, newest.path(), "/redir-loop") or newest.err != .redirect) return false;
    // Nunca a busca da URL (o PUT levava "?x=segredo").
    var saw_put = false;
    var i: usize = 0;
    while (p.netEntry(i)) |e| : (i += 1) {
        if (std.mem.indexOf(u8, e.path(), "segredo") != null or std.mem.indexOfScalar(u8, e.path(), '?') != null) return false;
        if (e.method == .PUT and std.mem.eql(u8, e.path(), "/method") and e.status == 200 and std.mem.eql(u8, e.host(), "qa.exemplo.com")) saw_put = true;
    }
    return saw_put and p.net_n >= 8 and qa.find(std.fmt.bufPrint(&mbuf, "plugin-net-row:qa07.lua:{d}", .{p.net_n - 1}) catch "") != null;
}

fn netClosed(app: *App) bool {
    const p = plugin(app, "qa07.lua") orelse return false;
    return !p.net_open and qa.find("plugin-net-row:qa07.lua:0") == null;
}

// --- Segredos --------------------------------------------------------------------------

fn secretOwn(app: *App) bool {
    return toastHas(app, "segredo|tok-123");
}

fn secretSeparate(app: *App) bool {
    return toastHas(app, "b|nil");
}

// --- Ações -----------------------------------------------------------------------------

fn reacted(app: *App) bool {
    const f = app.store.findAny(other_id) orelse return false;
    for (f.m.reactionSlice()) |*x| if (x.me and std.mem.eql(u8, x.text(), "🔥")) return true;
    return false;
}

fn replied(app: *App) bool {
    const cs = app.store.channel(geral) orelse return false;
    for (cs.messages.items) |*m| {
        if (m.msg.author == app.store.me and m.msg.reply_to == other_id and std.mem.eql(u8, m.msg.content, "resposta do plugin")) return true;
    }
    return false;
}

fn pinned(app: *App) bool {
    const f = app.store.findAny(other_id) orelse return false;
    return f.m.msg.pinned;
}

fn ownSeen(app: *App) bool {
    const cs = app.store.channel(geral) orelse return false;
    var i = cs.messages.items.len;
    while (i > 0) {
        i -= 1;
        const m = &cs.messages.items[i];
        if (m.msg.author != app.store.me or m.msg.id == 0 or m.pending or !std.mem.eql(u8, m.msg.content, "minha-qa07")) continue;
        var b: [40]u8 = undefined;
        if (!toastHas(app, std.fmt.bufPrint(&b, "proprio|{d}", .{m.msg.id}) catch return false)) return false;
        own_id = m.msg.id;
        return true;
    }
    return false;
}

fn edited(app: *App) bool {
    const f = app.store.findAny(own_id) orelse return false;
    return std.mem.eql(u8, f.m.msg.content, "editada pelo plugin");
}

fn otherEditRefused(app: *App) bool {
    const p = plugin(app, "qa07.lua") orelse return false;
    const err = p.err() orelse return false;
    const f = app.store.findAny(other_id) orelse return false;
    return std.mem.indexOf(u8, err, "larper.edit") != null and !std.mem.eql(u8, f.m.msg.content, "não pode");
}

fn askingDelete(app: *App) bool {
    const ask = plugin_confirm.current() orelse return false;
    return app.st.popup == .plugin_confirm and ask == .delete and ask.delete == own_id and qa.find("plugin-confirm-yes") != null;
}

fn ownStillThere(app: *App) bool {
    const f = app.store.findAny(own_id) orelse return false;
    return app.st.popup == .none and !f.m.deleted;
}

fn ownDeleted(app: *App) bool {
    if (app.st.popup != .none) return false;
    const f = app.store.findAny(own_id) orelse return true;
    return f.m.deleted;
}

var picks0: u32 = 0;

fn rememberPicks(_: *App) void {
    picks0 = plugin_confirm.qa_picks;
}

fn askingAttach(app: *App) bool {
    const ask = plugin_confirm.current() orelse return false;
    return app.st.popup == .plugin_confirm and ask == .attach and ask.attach == geral;
}

fn picked(app: *App) bool {
    // O seletor do app foi chamado (no QA ele não abre) e o plugin não recebeu nada.
    return app.st.popup == .none and plugin_confirm.qa_picks == picks0 + 1;
}

fn timerRefused(app: *App) bool {
    const p = plugin(app, "qa07.lua") orelse return false;
    const err = p.err() orelse return false;
    if (std.mem.indexOf(u8, err, "larper.react") == null) return false;
    const f = app.store.findAny(other_id) orelse return false;
    for (f.m.reactionSlice()) |*x| if (x.me and std.mem.eql(u8, x.text(), "👍")) return false;
    return true;
}

fn threadMade(app: *App) bool {
    const t = app.store.channel(other_id) orelse return false;
    return t.info.thread != null and std.mem.eql(u8, t.info.name, "thread do plugin");
}

fn backInGeral(app: *App) bool {
    return app.st.activeChannel() == geral;
}

fn cleanup(app: *App) void {
    qp.removeAllPluginsPub(app);
    app.plugins.reload();
}

fn gone(app: *App) bool {
    return app.plugins.list.items.len == 0;
}

pub const ops = [_]Op{
    s("plugins 0.7: carrega"),
    run(qp.startServerPub),
    run(writePlugins),
    expect("os plugins de teste ligam", loaded),
    run(approveMain),
    run(toGeral),
    .{ .wait = 300 },
    run(pickOther),

    s("plugins 0.7: rótulos em qualquer idioma"),
    run(setJa),
    expect("nome e descrição do cabeçalho em japonês, e o inglês onde não tem", titleJa),
    rmsg,
    expect("a entrada do plugin no menu aparece em japonês", menuJa),
    key(c.ImGuiKey_Escape),
    run(setPt),
    rmsg,
    click("menu:Marcar alvo"),
    expect("em português o menu volta, e o clique é um gesto do plugin", targetMarked),
} ++ cmd("/qa-put") ++ [_]Op{
    s("plugins 0.7: HTTP"),
    expect("PUT com corpo, e o ETag da resposta chega", putOk),
} ++ cmd("/qa-head") ++ [_]Op{
    expect("curinga ainda não aprovado: nada sai", headRefused),
    run(approveWildcard),
    run(clearToast),
} ++ cmd("/qa-head") ++ [_]Op{
    expect("aprovado *.cdn.exemplo.com, o HEAD vai para o subdomínio", headOk),
} ++ cmd("/qa-hdr") ++ [_]Op{
    expect("cabeçalhos da lista chegam ao plugin, o Set-Cookie não", headersOk),
} ++ cmd("/qa-cred") ++ [_]Op{
    expect("Authorization vai para o host de @credentials, com o segredo do chaveiro", credOk),
} ++ cmd("/qa-rok") ++ [_]Op{
    expect("redireciona para o CDN aprovado e deixa a credencial para trás", redirectFollowed),
} ++ cmd("/qa-rout") ++ [_]Op{
    expect("redirecionamento para um host não aprovado para ali", redirectOutRefused),
    run(rememberCount),
} ++ cmd("/qa-rloop") ++ [_]Op{
    expect("redirecionamento em laço para depois de 5", redirectLoopStops),

    s("plugins 0.7: o cartão e o registro de rede"),
    ctrl(c.ImGuiKey_Comma),
    click("settings:Plugins"),
    expect("o cartão avisa da credencial e mostra as capacidades novas", cardShows),
    click("plugin-net:qa07.lua"),
    expect("o registro lista os pedidos, sem a busca da URL", netOpen),
    .{ .shot = "plugins-07-rede" },
    click("plugin-net:qa07.lua"),
    expect("o botão fecha o registro", netClosed),
    key(c.ImGuiKey_Escape),
    run(toGeral),
} ++ cmd("/qa-secret") ++ [_]Op{
    s("plugins 0.7: segredos"),
    expect("o plugin lê o próprio segredo", secretOwn),
} ++ cmd("/qb-secret") ++ [_]Op{
    expect("outro plugin não vê o segredo dele", secretSeparate),
} ++ cmd("/qa-react") ++ [_]Op{
    s("plugins 0.7: ações na conta"),
    expect("larper.react põe a reação na mensagem da demonstração", reacted),
} ++ cmd("/qa-reply") ++ [_]Op{
    expect("larper.reply responde à mensagem, no canal dela", replied),
} ++ cmd("/qa-pin") ++ [_]Op{
    expect("larper.pin fixa a mensagem", pinned),
    click("composer"),
    .{ .text = "minha-qa07" },
    key(c.ImGuiKey_Enter),
    expect("a mensagem sua chega ao plugin", ownSeen),
} ++ cmd("/qa-mine-edit") ++ [_]Op{
    expect("larper.edit troca o texto da mensagem sua", edited),
} ++ cmd("/qa-other-edit") ++ [_]Op{
    expect("editar a mensagem de outra pessoa é recusado, com o motivo no cartão", otherEditRefused),
} ++ cmd("/qa-delete") ++ [_]Op{
    expect("larper.delete pergunta na tela antes", askingDelete),
    .{ .shot = "plugins-07-confirma" },
    click("plugin-confirm-no"),
    expect("Cancelar não apaga", ownStillThere),
} ++ cmd("/qa-delete") ++ [_]Op{
    expect("pergunta de novo", askingDelete),
    click("plugin-confirm-yes"),
    expect("confirmado, a mensagem some", ownDeleted),
    run(rememberPicks),
} ++ cmd("/qa-attach") ++ [_]Op{
    expect("larper.attach pergunta antes de abrir o seletor", askingAttach),
    click("plugin-confirm-yes"),
    expect("confirmado, o seletor de arquivos do app é chamado", picked),
} ++ cmd("/qa-timer") ++ [_]Op{
    expect("uma ação num temporizador é recusada, com erro para o plugin", timerRefused),
} ++ cmd("/qa-thread") ++ [_]Op{
    expect("larper.thread cria a thread a partir da mensagem", threadMade),
    run(toGeral),
    expect("volta ao canal", backInGeral),
    run(cleanup),
    expect("sem os plugins de teste", gone),
};
