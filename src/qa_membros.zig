//! QA do op 8 (os membros dos autores de uma página de histórico, net/member_ask.zig),
//! com a mesma fila do gateway de verdade (net/gw_budget.zig): no máximo um op 8 por
//! servidor a cada 30 s, o limite do Discord, com as páginas se juntando. Na
//! demonstração, o servidor grande (Arch Linux BR) não traz quem está offline na lista
//! de membros, como um servidor grande do Discord, e as mensagens antigas de lá também
//! são de gente offline: a nanda (Moderação, apelido "Nanda do Arch") só ganha o apelido
//! e a cor do cargo pela resposta do op 8. Confere: DM e grupo nunca pedem; abrir e rolar
//! depressa junta tudo num pedido; rolar muitas páginas em menos de 30 s não manda um
//! segundo (o demo conta o que o Discord recusaria); ninguém é pedido duas vezes; a
//! mensagem antiga mostra o apelido e a cor; e uma sessão nova só pede membros para a
//! conversa na tela, não para cada aba. Sozinho: QA_SUITE=membros.
const std = @import("std");
const App = @import("app.zig").App;
const R = @import("qa_runner.zig");
const Op = R.Op;
const qa = @import("ui/qa.zig");
const gw = @import("net/fake_gateway.zig");
const types = @import("core/types.zig");
const platform = @import("platform/window.zig");
const Id = types.Id;

fn s(name: []const u8) Op {
    return .{ .section = name };
}
fn expect(name: []const u8, f: *const fn (*App) bool) Op {
    return .{ .expect = .{ .name = name, .check = f } };
}
fn run(f: *const fn (*App) void) Op {
    return .{ .run = f };
}

const big: Id = gw.guildId(gw.large_guild);
/// #zig e #geral do servidor grande (nenhuma outra bateria abre esse servidor).
const big_zig: Id = gw.channelId(gw.large_guild, 9);
const big_geral: Id = gw.channelId(gw.large_guild, 4);
const nanda: Id = gw.large_old_author;
const dm0: Id = 900_000;
const group: Id = 900_006;
/// A cor da Moderação na demonstração (fake_gateway.zig, `demo_roles`).
const mod_color: u32 = 0x3BA55C;

fn load(a: anytype) u64 {
    return a.load(.acquire);
}

/// O que já tinha saído antes de cada passo (a bateria geral pode ter pedido antes).
var req0: u64 = 0;
var pages0: u64 = 0;
var wrong0: u64 = 0;
var repeats0: u64 = 0;
var refused0: u64 = 0;
/// Op 8 do servidor grande (os do primeiro servidor, das abas que o demo abre, saem no
/// ritmo deles e não contam aqui).
var big_step: u64 = 0;
var pages_step: u64 = 0;

fn mark() void {
    big_step = load(&gw.sent.member_large);
    pages_step = load(&gw.sent.member_pages);
}

fn loaded(app: *App, id: Id) bool {
    const cs = app.store.channel(id) orelse return false;
    return app.st.activeChannel() == id and cs.history == .loaded;
}

/// O canal que está sendo rolado.
var scrolling: Id = big_zig;

/// A página antiga chegou (ou o canal já está no começo: não há mais o que carregar).
fn olderDone(app: *App) bool {
    const cs = app.store.channel(scrolling) orelse return false;
    return cs.older == .done or (cs.older != .loading and load(&gw.sent.member_pages) > pages_step);
}

// --- DM e grupo --------------------------------------------------------------------

/// As abas que o demo abre no começo (no primeiro servidor) já carregaram e o op 8 delas
/// já saiu: o que vem depois é só deste QA (o lote delas sai ~2 s depois, e a página de
/// cada uma é contada pela thread do demo logo depois de a interface vê-la).
fn settled(app: *App) bool {
    for (app.st.tabs.items) |id| {
        const cs = app.store.channel(id) orelse return false;
        if (cs.history != .loaded) return false;
    }
    return load(&gw.sent.member_pages) >= app.st.tabs.items.len and load(&gw.sent.member_queued) == 0;
}

var refetch0: u64 = 0;
fn start(app: *App) void {
    refetch0 = load(&gw.sent.history_refetches);
    req0 = load(&gw.sent.member_requests);
    pages0 = load(&gw.sent.member_pages);
    wrong0 = load(&gw.sent.member_wrong);
    repeats0 = load(&gw.sent.member_repeats);
    refused0 = load(&gw.sent.member_refused);
    app.handle(.{ .select_channel = dm0 });
}
fn dmLoaded(app: *App) bool {
    return loaded(app, dm0);
}
fn openGroup(app: *App) void {
    app.handle(.{ .select_channel = group });
}
fn groupNoAsk(app: *App) bool {
    return loaded(app, group) and load(&gw.sent.member_requests) == req0 and load(&gw.sent.member_pages) == pages0 and load(&gw.sent.member_wrong) == wrong0;
}
/// Abrir a DM e o grupo não fez nenhuma aba pedir a última página de novo.
fn noReload(_: *App) bool {
    return load(&gw.sent.history_refetches) == refetch0;
}

// --- Servidor grande: abrir e rolar depressa -----------------------------------------

fn openBig(app: *App) void {
    mark();
    app.handle(.{ .select_guild = big });
    app.handle(.{ .select_channel = big_zig });
}
fn bigLoaded(app: *App) bool {
    return loaded(app, big_zig) and load(&gw.sent.member_pages) > pages_step;
}

/// A nanda ainda não é conhecida: sem apelido e sem cor antes da página antiga.
fn nandaUnknown(app: *App) bool {
    return app.store.face(big, nanda) == null and app.store.nameColor(big, nanda) == 0;
}

fn older(app: *App) void {
    pages_step = load(&gw.sent.member_pages);
    app.handle(.{ .load_older = scrolling });
}

/// Abriu e rolou dentro do lote de 2 s: as páginas viraram um pedido só, de lá, com a
/// nanda (que só aparece nas antigas) junto com quem a primeira página trouxe.
fn oneBatch(_: *App) bool {
    return load(&gw.sent.member_large) == big_step + 1 and load(&gw.sent.member_large_first_n) >= 2 and load(&gw.sent.member_refused) == refused0;
}

/// A primeira mensagem de um grupo da nanda (a que mostra o nome).
var nanda_msg: Id = 0;
fn jumpNanda(app: *App) void {
    const cs = app.store.channel(big_zig) orelse return;
    var prev: Id = 0;
    for (cs.messages.items) |m| {
        if (m.msg.author == nanda and prev != nanda and m.msg.id != 0) {
            nanda_msg = m.msg.id;
            break;
        }
        prev = m.msg.author;
    }
    app.handle(.{ .jump_to = nanda_msg });
}
fn nandaNick(_: *App) bool {
    if (nanda_msg == 0) return false;
    var b: [64]u8 = undefined;
    const r = qa.find(std.fmt.bufPrint(&b, "msg:{d}", .{nanda_msg}) catch return false) orelse return false;
    return qa.anyIn(std.fmt.bufPrint(&b, "nome:msg:{d}:Nanda do Arch", .{nanda}) catch return false, r);
}
fn nandaColor(app: *App) bool {
    return app.store.nameColor(big, nanda) == mod_color;
}

// --- Rolar muitas páginas em menos de 30 s -------------------------------------------

/// Quando o op 8 do lote saiu (relógio monotônico do demo).
var batch_at: u64 = 0;
var window_pages: u64 = 0;
fn markWindow(_: *App) void {
    batch_at = load(&gw.sent.member_large_at);
    big_step = load(&gw.sent.member_large);
    window_pages = load(&gw.sent.member_pages);
}

fn openGeral(app: *App) void {
    pages_step = load(&gw.sent.member_pages);
    scrolling = big_geral;
    app.handle(.{ .select_channel = big_geral });
}
fn geralLoaded(app: *App) bool {
    return loaded(app, big_geral) and load(&gw.sent.member_pages) > pages_step;
}
/// Outro canal do mesmo servidor, aberto e rolado na mesma janela: a página antiga dele
/// traz alguém que ninguém pediu (o gustavo), e mesmo com o lote já fechado (mais de 2 s
/// depois) o pedido dele espera a janela; nenhum op 8 novo de lá.
fn geralHeld(app: *App) bool {
    const in_window = gw.monoMs() - @as(i64, @intCast(batch_at)) < 30_000;
    const waiting = app.store.channel(big_geral) != null and app.store.memberInfo(big, 1008) == null;
    return in_window and waiting and load(&gw.sent.member_pages) >= window_pages + 3 and load(&gw.sent.member_large) == big_step and load(&gw.sent.member_refused) == refused0;
}

// --- Sessão nova ---------------------------------------------------------------------

fn push(app: *App, e: @import("core/event.zig").Event) void {
    app.events.push(e);
    platform.Window.wake(app.win.wake_type, .gateway);
}

var fetches0: u64 = 0;
var tabs_open: usize = 0;
/// Um READY de uma sessão nova (o notebook dormiu e acordou): as abas carregadas pedem
/// a última página de novo, mas membros só a que está na tela.
fn newSession(app: *App) void {
    fetches0 = load(&gw.sent.member_fetches);
    tabs_open = app.st.tabs.items.len;
    const ca = std.heap.c_allocator;
    const users = ca.alloc(types.User, 0) catch return;
    const guilds = ca.alloc(types.Guild, 0) catch return;
    const channels = ca.alloc(types.Channel, 0) catch return;
    push(app, .{ .ready = .{ .me = app.store.me, .users = users, .guilds = guilds, .channels = channels, .voice = &.{} } });
    push(app, .{ .status = .ready });
}
fn noReloadYet(_: *App) bool {
    return load(&gw.sent.history_refetches) == refetch0;
}
fn activeOnly(_: *App) bool {
    return tabs_open >= 2 and load(&gw.sent.member_fetches) == fetches0 + 1;
}

fn allClean(_: *App) bool {
    return load(&gw.sent.member_wrong) == wrong0 and load(&gw.sent.member_repeats) == repeats0 and load(&gw.sent.member_refused) == refused0;
}

pub const ops = [_]Op{
    s("op 8: DM e grupo"),
    .{ .expect = .{ .name = "as abas do começo carregaram e o op 8 delas já saiu", .check = settled, .timeout_ms = 8000 } },
    run(start),
    expect("a DM abre", dmLoaded),
    run(openGroup),
    expect("o grupo abre; nenhuma página de DM ou grupo pediu membros", groupNoAsk),
    expect("e nenhuma aba pediu a última página de novo", noReload),
    s("op 8: abrir e rolar depressa"),
    run(openBig),
    expect("o canal do servidor grande abre", bigLoaded),
    expect("a nanda (offline, fora da lista) ainda sem apelido e sem cor", nandaUnknown),
    run(older),
    expect("uma página antiga", olderDone),
    run(older),
    expect("e outra", olderDone),
    .{ .expect = .{ .name = "as três páginas viram um op 8 só, do servidor grande", .check = oneBatch, .timeout_ms = 4000 } },
    run(jumpNanda),
    // Em poucos segundos, não 30: a nanda foi no primeiro pedido (o lote juntou as páginas).
    .{ .expect = .{ .name = "logo depois da resposta, a mensagem antiga da nanda mostra o apelido de lá", .check = nandaNick, .timeout_ms = 5000 } },
    expect("e a cor do cargo dela (Moderação)", nandaColor),
    .{ .shot = "membros-antiga" },
    s("op 8: rolar muitas páginas em menos de 30 s"),
    run(markWindow),
    run(older),
    expect("página 4", olderDone),
    run(older),
    expect("página 5", olderDone),
    run(older),
    expect("página 6", olderDone),
    run(older),
    expect("página 7", olderDone),
    run(openGeral),
    expect("outro canal do mesmo servidor", geralLoaded),
    run(older),
    expect("uma página antiga dele", olderDone),
    // Mais que o lote (2 s): sem a janela por servidor, o pedido já teria saído.
    .{ .wait = 2500 },
    expect("também dentro da janela: quem é novo espera, e nenhum op 8 novo de lá", geralHeld),
    s("op 8: sessão nova"),
    expect("até aqui, nenhum canal pediu a última página duas vezes", noReloadYet),
    run(newSession),
    // Espera as abas pedirem e confere a conta exata (não o momento em que ela passa por 1).
    .{ .wait = 800 },
    .{ .expect = .{ .name = "READY de uma sessão nova com várias abas: membros só para a conversa na tela", .check = activeOnly, .timeout_ms = 1 } },
    expect("no total: nenhum repetido, nenhum com o servidor errado, nenhum que seria recusado", allClean),
};
