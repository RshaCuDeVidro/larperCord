//! O op 8 (REQUEST_GUILD_MEMBERS com `user_ids`): os membros dos autores de uma página
//! de histórico que o app ainda não conhece, para as mensagens antigas ganharem o
//! apelido, a foto do servidor e a cor do cargo (o histórico do REST não traz o
//! `member`). Sem rede, para dar para testar. Os limites, os que o usuário aceitou: no
//! máximo um pedido por página carregada, só IDs nunca pedidos nesta sessão e sem
//! membro conhecido, até 100 por pedido, sempre pela fila do gw_budget, e nunca em DM ou
//! grupo. A resposta (GUILD_MEMBERS_CHUNK) passa pelo mesmo caminho dos outros `member`.
const std = @import("std");
const types = @import("../core/types.zig");
const Id = types.Id;

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

    /// Saímos do servidor: o que ele sabia de lá não vale mais.
    pub fn forgetGuild(a: *Asker, guild: Id) void {
        var it = a.known.iterator();
        while (it.next()) |e| {
            if (e.key_ptr[0] != guild) continue;
            a.known.removeByPtr(e.key_ptr);
            it = a.known.iterator();
        }
    }
};

/// Junta dois pedidos do mesmo servidor que ainda não saíram (cabendo nos 100). false:
/// não cabe, e cada um sai no seu.
pub fn merge(into: *Request, more: *const Request) bool {
    if (into.guild != more.guild or @as(usize, into.n) + more.n > max_ids) return false;
    @memcpy(into.ids[into.n..][0..more.n], more.ids[0..more.n]);
    into.n += more.n;
    return true;
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
}

test "op 8: juntar dois pedidos que esperam, e o JSON" {
    var r: Request = .{ .guild = 5 };
    r.ids[0] = 11;
    r.n = 1;
    var b: Request = .{ .guild = 5 };
    b.ids[0] = 12;
    b.n = 1;
    try std.testing.expect(merge(&r, &b));
    try std.testing.expectEqualSlices(Id, &.{ 11, 12 }, r.slice());
    const other: Request = .{ .guild = 6 };
    try std.testing.expect(!merge(&r, &other));
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("{\"op\":8,\"d\":{\"guild_id\":\"5\",\"user_ids\":[\"11\",\"12\"],\"presences\":false,\"nonce\":\"m3\"}}", payload(&buf, &r, 3).?);
    try std.testing.expectEqual(@as(?u32, 3), nonceSeq("m3"));
    try std.testing.expect(nonceSeq("x3") == null and nonceSeq("m") == null and nonceSeq("m-1") == null);
    // 100 IDs de 19 dígitos cabem no buffer de quem manda (net/discord.zig).
    var full: Request = .{ .guild = std.math.maxInt(u63) };
    for (&full.ids) |*u| u.* = std.math.maxInt(u63);
    full.n = max_ids;
    var big: [2600]u8 = undefined;
    try std.testing.expect(payload(&big, &full, std.math.maxInt(u32)) != null);
}
