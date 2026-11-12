//! O op 8 (REQUEST_GUILD_MEMBERS com `user_ids`): os membros dos autores de uma página
//! de histórico que o app ainda não conhece, para as mensagens antigas ganharem o
//! apelido, a foto do servidor e a cor do cargo (o histórico do REST não traz o
//! `member`). Sem rede, para dar para testar. Os limites, os que o usuário aceitou: no
//! máximo um pedido por página carregada, só IDs nunca pedidos nesta sessão e sem
//! membro conhecido, até 100 por pedido, sempre pela fila do gw_budget (que solta no
//! máximo um por servidor a cada 30 s, o limite do Discord), e nunca em DM ou grupo. A
//! resposta (GUILD_MEMBERS_CHUNK) passa pelo mesmo caminho dos outros `member`.
const std = @import("std");
const types = @import("../core/types.zig");
const j = @import("jsonx.zig");
const Id = types.Id;
const Value = std.json.Value;

/// O máximo de `user_ids` num op 8 (docs.discord.food, Request Guild Members).
pub const max_ids = 100;

/// Um op 8 esperando a vez.
pub const Request = struct {
    guild: Id,
    ids: [max_ids]Id = undefined,
    n: u8 = 0,

    pub fn slice(r: *const Request) []const Id {
        return r.ids[0..r.n];
    }
};

/// Teto do que o Asker lembra: passando, quem chama esquece tudo menos quem está num
/// op 8 ainda sem resposta (no pior caso alguém é pedido de novo, no ritmo da fila).
pub const max_known = 200_000;

pub const Asker = struct {
    /// (servidor, pessoa) com membro conhecido (passou algum `member` dela) ou já pedido
    /// nesta sessão: nenhum dos dois é pedido de novo.
    known: std.AutoHashMapUnmanaged([2]Id, void) = .empty,

    pub fn deinit(a: *Asker, gpa: std.mem.Allocator) void {
        a.known.deinit(gpa);
    }

    /// Passou um `member` desta pessoa neste servidor.
    pub fn see(a: *Asker, gpa: std.mem.Allocator, guild: Id, user: Id) void {
        if (guild == 0 or user == 0) return;
        a.known.put(gpa, .{ guild, user }, {}) catch {};
    }

    /// O pedido de uma página (null = nada a pedir): os autores ainda desconhecidos, sem
    /// repetir, até 100, que ficam marcados como pedidos. Sem servidor (DM, grupo), nada.
    pub fn page(a: *Asker, gpa: std.mem.Allocator, guild: Id, authors: []const Id) ?Request {
        if (guild == 0) return null;
        var r: Request = .{ .guild = guild };
        for (authors) |uid| {
            if (r.n == max_ids) break;
            // Webhook não é membro (o ID dele é inventado, ver types.webhook_id_bit).
            if (uid == 0 or uid & types.webhook_id_bit != 0) continue;
            const gop = a.known.getOrPut(gpa, .{ guild, uid }) catch continue;
            if (gop.found_existing) continue;
            r.ids[r.n] = uid;
            r.n += 1;
        }
        return if (r.n > 0) r else null;
    }

    /// Passou do teto (`max_known`)?
    pub fn full(a: *const Asker) bool {
        return a.known.count() >= max_known;
    }

    /// Quem está num pedido que ainda vai sair ou espera resposta continua marcado.
    pub fn mark(a: *Asker, gpa: std.mem.Allocator, r: *const Request) void {
        for (r.slice()) |uid| a.known.put(gpa, .{ r.guild, uid }, {}) catch {};
    }

    /// Um pedido que não vai sair (a fila cheia, a sessão nova): quem estava nele pode
    /// ser pedido de novo na próxima página.
    pub fn unmark(a: *Asker, r: *const Request) void {
        for (r.slice()) |uid| _ = a.known.remove(.{ r.guild, uid });
    }

    /// Saímos do servidor: o que ele sabia de lá não vale mais. (Remover só deixa uma
    /// lápide: a mesma volta continua sem recomeçar.)
    pub fn forgetGuild(a: *Asker, guild: Id) void {
        var it = a.known.iterator();
        while (it.next()) |e| if (e.key_ptr[0] == guild) a.known.removeByPtr(e.key_ptr);
    }
};

/// Passa para `into` os IDs de `more` do mesmo servidor que ainda não estão nele, até
/// os 100; o que não coube fica em `more` (que fica vazio se coube tudo).
pub fn mergeInto(into: *Request, more: *Request) void {
    if (into.guild != more.guild) return;
    var keep: u8 = 0;
    for (more.ids[0..more.n]) |uid| {
        if (std.mem.indexOfScalar(Id, into.slice(), uid) != null) continue;
        if (into.n < max_ids) {
            into.ids[into.n] = uid;
            into.n += 1;
        } else {
            more.ids[keep] = uid;
            keep += 1;
        }
    }
    more.n = keep;
}

/// O op 8 em JSON. O `nonce` ("m" e o número do pedido) volta no RATE_LIMITED, para o
/// mesmo pedido sair de novo depois da espera.
pub fn payload(buf: []u8, r: *const Request, seq: u32) ?[]const u8 {
    var w = std.Io.Writer.fixed(buf);
    w.print("{{\"op\":8,\"d\":{{\"guild_id\":\"{d}\",\"user_ids\":[", .{r.guild}) catch return null;
    for (r.slice(), 0..) |uid, i| w.print("{s}\"{d}\"", .{ if (i == 0) "" else ",", uid }) catch return null;
    w.print("],\"presences\":false,\"nonce\":\"m{d}\"}}}}", .{seq}) catch return null;
    return w.buffered();
}

/// O número do pedido num `nonce` nosso (null = não é de um op 8 daqui).
pub fn nonceSeq(nonce: []const u8) ?u32 {
    if (nonce.len < 2 or nonce[0] != 'm') return null;
    return std.fmt.parseInt(u32, nonce[1..], 10) catch null;
}

/// Um op 8 que saiu, guardado para um RATE_LIMITED achar (`req.guild` 0 = vaga).
pub const Sent = struct { seq: u32 = 0, req: Request = .{ .guild = 0 } };

/// O que um RATE_LIMITED diz (docs.discord.food: `retry_after` e `meta`, com o
/// `guild_id` e o `nonce` do pedido, que é opcional). 0 = não veio.
pub const Limited = struct { guild: Id = 0, seq: ?u32 = null, wait_ms: i64 = 0 };

pub fn limited(d: Value) Limited {
    const secs: f64 = switch (j.get(d, "retry_after") orelse Value.null) {
        .float => |f| f,
        .integer => |n| @floatFromInt(n),
        else => 0,
    };
    const meta = j.get(d, "meta") orelse Value.null;
    return .{
        .guild = j.id(j.get(meta, "guild_id")) orelse 0,
        .seq = if (j.str(j.get(meta, "nonce"))) |n| nonceSeq(n) else null,
        .wait_ms = @intFromFloat(std.math.clamp(secs, 0, 600) * 1000),
    };
}

/// O pedido recusado entre os que saíram: pelo nonce; sem ele (ou de um pedido que já
/// saiu do anel), o mais novo daquele servidor. null = não dá para saber.
pub fn pickSent(ring: []Sent, lim: Limited) ?*Sent {
    if (lim.seq) |seq| for (ring) |*x| if (x.req.guild != 0 and x.seq == seq) return x;
    if (lim.guild == 0) return null;
    var pick: ?*Sent = null;
    for (ring) |*x| if (x.req.guild == lim.guild) {
        if (pick == null or x.seq -% pick.?.seq < 1 << 31) pick = x;
    };
    return pick;
}

test "op 8: só quem ninguém conhece, sem repetir, nada em DM, até 100" {
    const gpa = std.testing.allocator;
    var a: Asker = .{};
    defer a.deinit(gpa);
    // O membro da lista de membros já é conhecido.
    a.see(gpa, 5, 10);
    const r1 = a.page(gpa, 5, &.{ 10, 11, 12, 11, types.webhook_id_bit | 7, 0 }).?;
    try std.testing.expectEqualSlices(Id, &.{ 11, 12 }, r1.slice());
    // A página seguinte com os mesmos autores: nada a pedir.
    try std.testing.expect(a.page(gpa, 5, &.{ 11, 12, 10 }) == null);
    // Outro servidor é outra pessoa.
    try std.testing.expectEqualSlices(Id, &.{11}, a.page(gpa, 6, &.{11}).?.slice());
    // DM e grupo (sem servidor): nunca.
    try std.testing.expect(a.page(gpa, 0, &.{ 20, 21 }) == null);
    // Página com mais de 100 autores novos: os 100 primeiros (o resto, na próxima).
    var many: [130]Id = undefined;
    for (&many, 0..) |*u, i| u.* = 1000 + i;
    const big = a.page(gpa, 7, &many).?;
    try std.testing.expectEqual(@as(u8, max_ids), big.n);
    try std.testing.expectEqualSlices(Id, many[100..][0..30], a.page(gpa, 7, &many).?.slice());
    // Pedido que não saiu: as mesmas pessoas podem ser pedidas de novo.
    a.unmark(&r1);
    try std.testing.expectEqualSlices(Id, &.{ 11, 12 }, a.page(gpa, 5, &.{ 11, 12, 10 }).?.slice());
    // Saímos do servidor 7 (130 lembrados): tudo de lá some, sem tocar no 5.
    a.forgetGuild(7);
    try std.testing.expectEqual(@as(u8, 2), a.page(gpa, 7, &.{ 1000, 1129 }).?.n);
    try std.testing.expect(a.page(gpa, 5, &.{ 11, 12 }) == null);
}

fn req(guild: Id, from: Id, n: u8) Request {
    var r: Request = .{ .guild = guild, .n = n };
    for (r.ids[0..n], 0..) |*u, i| u.* = from + i;
    return r;
}

test "op 8: juntar dois pedidos que esperam, passando dos 100, e o JSON" {
    var r = req(5, 11, 1);
    var b = req(5, 12, 1);
    mergeInto(&r, &b);
    try std.testing.expectEqualSlices(Id, &.{ 11, 12 }, r.slice());
    try std.testing.expectEqual(@as(u8, 0), b.n);
    // Outro servidor não junta.
    var other = req(6, 30, 2);
    mergeInto(&r, &other);
    try std.testing.expectEqual(@as(u8, 2), r.n);
    try std.testing.expectEqual(@as(u8, 2), other.n);
    // 70 + 60 (10 repetidos): 100 juntos, sem repetir, e os 20 que sobraram ficam.
    var big = req(7, 1000, 70);
    var more = req(7, 1060, 60);
    mergeInto(&big, &more);
    try std.testing.expectEqual(@as(u8, max_ids), big.n);
    try std.testing.expectEqual(@as(Id, 1099), big.ids[99]);
    const rest = req(7, 1100, 20);
    try std.testing.expectEqualSlices(Id, rest.slice(), more.slice());
    // Cheio: nada entra, nada se perde.
    var filled = req(7, 2000, 100);
    var late = req(7, 3000, 5);
    mergeInto(&filled, &late);
    try std.testing.expectEqual(@as(u8, 5), late.n);
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("{\"op\":8,\"d\":{\"guild_id\":\"5\",\"user_ids\":[\"11\",\"12\"],\"presences\":false,\"nonce\":\"m3\"}}", payload(&buf, &r, 3).?);
    try std.testing.expectEqual(@as(?u32, 3), nonceSeq("m3"));
    try std.testing.expect(nonceSeq("x3") == null and nonceSeq("m") == null and nonceSeq("m-1") == null);
    // 100 IDs de 19 dígitos cabem no buffer de quem manda (net/discord.zig).
    var full: Request = .{ .guild = std.math.maxInt(u63) };
    for (&full.ids) |*u| u.* = std.math.maxInt(u63);
    full.n = max_ids;
    var wide: [2600]u8 = undefined;
    try std.testing.expect(payload(&wide, &full, std.math.maxInt(u32)) != null);
}

test "RATE_LIMITED: com nonce, sem nonce, sem retry_after, sem servidor" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ring: [4]Sent = @splat(.{});
    ring[0] = .{ .seq = 7, .req = req(5, 10, 1) };
    ring[1] = .{ .seq = 8, .req = req(6, 20, 1) };
    ring[2] = .{ .seq = 9, .req = req(5, 30, 1) };
    const parse = struct {
        fn f(al: std.mem.Allocator, txt: []const u8) !Value {
            return std.json.parseFromSliceLeaky(Value, al, txt, .{});
        }
    }.f;
    // Com o nonce: aquele pedido, e o retry_after em ms.
    const l1 = limited(try parse(a, "{\"opcode\":8,\"retry_after\":12.5,\"meta\":{\"guild_id\":\"5\",\"nonce\":\"m7\"}}"));
    try std.testing.expectEqual(@as(Id, 5), l1.guild);
    try std.testing.expectEqual(@as(?u32, 7), l1.seq);
    try std.testing.expectEqual(@as(i64, 12_500), l1.wait_ms);
    try std.testing.expectEqual(@as(Id, 10), pickSent(&ring, l1).?.req.ids[0]);
    // Sem nonce: o mais novo daquele servidor (o 9, não o 7).
    const l2 = limited(try parse(a, "{\"opcode\":8,\"retry_after\":3,\"meta\":{\"guild_id\":\"5\"}}"));
    try std.testing.expect(l2.seq == null);
    try std.testing.expectEqual(@as(i64, 3000), l2.wait_ms);
    try std.testing.expectEqual(@as(Id, 30), pickSent(&ring, l2).?.req.ids[0]);
    // Nonce que já saiu do anel: também cai no mais novo do servidor.
    const l3 = limited(try parse(a, "{\"opcode\":8,\"meta\":{\"guild_id\":\"6\",\"nonce\":\"m1\"}}"));
    try std.testing.expectEqual(@as(i64, 0), l3.wait_ms);
    try std.testing.expectEqual(@as(Id, 20), pickSent(&ring, l3).?.req.ids[0]);
    // Sem servidor e sem nonce: ninguém (a fila segura todos).
    const l4 = limited(try parse(a, "{\"opcode\":8}"));
    try std.testing.expectEqual(@as(Id, 0), l4.guild);
    try std.testing.expect(pickSent(&ring, l4) == null);
    // Vaga (guild 0) nunca é escolhida, mesmo com o mesmo número.
    ring[3] = .{ .seq = 9 };
    try std.testing.expectEqual(@as(Id, 30), pickSent(&ring, l2).?.req.ids[0]);
}

test "teto do Asker: esquece tudo menos quem espera resposta" {
    const gpa = std.testing.allocator;
    var a: Asker = .{};
    defer a.deinit(gpa);
    const pending = req(5, 100, 2);
    _ = a.page(gpa, 5, &.{ 100, 101, 102 });
    try std.testing.expect(!a.full());
    // Como o gateway faz quando passa do teto.
    a.known.clearRetainingCapacity();
    a.mark(gpa, &pending);
    try std.testing.expectEqualSlices(Id, &.{102}, a.page(gpa, 5, &.{ 100, 101, 102 }).?.slice());
}
