//! QA do op 8 (os membros dos autores de uma página de histórico, net/member_ask.zig).
//! Na demonstração, o servidor grande (Arch Linux BR) não traz quem está offline na
//! lista de membros, como um servidor grande do Discord, e as mensagens antigas de lá
//! também são de gente offline: a nanda (Moderação, apelido "Nanda do Arch") só ganha o
//! apelido e a cor do cargo pela resposta do op 8. Confere: DM e grupo nunca pedem, cada
//! página pede no máximo um, ninguém é pedido duas vezes, e a mensagem antiga mostra o
//! apelido e a cor depois da resposta. Sozinho: QA_SUITE=membros.
const std = @import("std");
const App = @import("app.zig").App;
const R = @import("qa_runner.zig");
const Op = R.Op;
const qa = @import("ui/qa.zig");
const gw = @import("net/fake_gateway.zig");
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
var req_step: u64 = 0;
var pages_step: u64 = 0;

fn mark() void {
    req_step = load(&gw.sent.member_requests);
    pages_step = load(&gw.sent.member_pages);
}

/// Desde `mark`: chegou ao menos uma página nova e no máximo um op 8 por página.
fn onePerPage() bool {
    const pages = load(&gw.sent.member_pages) - pages_step;
    const reqs = load(&gw.sent.member_requests) - req_step;
    return pages > 0 and reqs <= pages;
}

fn loaded(app: *App, id: Id) bool {
    const cs = app.store.channel(id) orelse return false;
    return app.st.activeChannel() == id and cs.history == .loaded;
}

// --- DM e grupo --------------------------------------------------------------------

fn start(app: *App) void {
    req0 = load(&gw.sent.member_requests);
    pages0 = load(&gw.sent.member_pages);
    wrong0 = load(&gw.sent.member_wrong);
    repeats0 = load(&gw.sent.member_repeats);
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

// --- Servidor grande ---------------------------------------------------------------

fn openBig(app: *App) void {
    mark();
    app.handle(.{ .select_guild = big });
    app.handle(.{ .select_channel = big_zig });
}
fn firstPage(app: *App) bool {
    if (!loaded(app, big_zig) or !onePerPage()) return false;
    return load(&gw.sent.member_requests) == req_step or load(&gw.sent.member_guild) == big;
}

/// A nanda ainda não é conhecida: sem apelido e sem cor antes da página antiga.
fn nandaUnknown(app: *App) bool {
    return app.store.face(big, nanda) == null and app.store.nameColor(big, nanda) == 0;
}

fn older(app: *App) void {
    mark();
    app.handle(.{ .load_older = big_zig });
}
fn olderDone(app: *App) bool {
    const cs = app.store.channel(big_zig) orelse return false;
    return cs.older != .loading and onePerPage();
}
/// A página antiga trouxe a nanda: saiu um op 8, do servidor grande.
fn olderAsked(app: *App) bool {
    return olderDone(app) and load(&gw.sent.member_requests) > req_step and load(&gw.sent.member_guild) == big;
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

/// Outra página antiga, com a nanda de novo: ninguém pedido duas vezes.
fn noRepeat(app: *App) bool {
    return olderDone(app) and load(&gw.sent.member_repeats) == repeats0;
}

fn openGeral(app: *App) void {
    mark();
    app.handle(.{ .select_channel = big_geral });
}
fn geralClean(app: *App) bool {
    return loaded(app, big_geral) and onePerPage() and load(&gw.sent.member_repeats) == repeats0;
}

fn allClean(_: *App) bool {
    return load(&gw.sent.member_wrong) == wrong0 and load(&gw.sent.member_repeats) == repeats0 and
        load(&gw.sent.member_requests) - req0 <= load(&gw.sent.member_pages) - pages0;
}

pub const ops = [_]Op{
    s("op 8: DM e grupo"),
    run(start),
    expect("a DM abre", dmLoaded),
    run(openGroup),
    expect("o grupo abre; nenhuma página de DM ou grupo pediu membros", groupNoAsk),
    s("op 8: servidor grande"),
    run(openBig),
    expect("a primeira página do servidor grande pede no máximo um op 8, de lá", firstPage),
    expect("a nanda (offline, fora da lista) ainda sem apelido e sem cor", nandaUnknown),
    run(older),
    expect("a página antiga pede um op 8 só, com quem ninguém conhecia", olderAsked),
    run(jumpNanda),
    expect("depois da resposta, a mensagem antiga da nanda mostra o apelido de lá", nandaNick),
    expect("e a cor do cargo dela (Moderação)", nandaColor),
    .{ .shot = "membros-antiga" },
    run(older),
    expect("mais uma página antiga com a nanda: ninguém pedido de novo", noRepeat),
    run(openGeral),
    expect("outro canal do mesmo servidor: no máximo um op 8, sem repetir ninguém", geralClean),
    expect("no total: um op 8 por página no máximo, nenhum repetido, nenhum com o servidor errado", allClean),
};
