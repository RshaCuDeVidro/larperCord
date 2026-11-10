//! Ordem da lista de DMs, a do Discord: a conversa com a atividade mais recente
//! em cima. A atividade é a última mensagem ou, numa conversa sem nenhuma, o
//! próprio ID (quando foi criada: uma DM nova entra no topo). A lista é
//! ajustada a cada evento (mensagem nova, conversa nova, READY), nunca
//! reordenada a cada quadro.
const std = @import("std");
const types = @import("types.zig");
const sort = @import("sort.zig");
const Id = types.Id;

/// A chave da ordem: maior = mais recente.
pub fn activity(ch: *const types.Channel) Id {
    return @max(ch.id, ch.last_message);
}

/// Mais recente primeiro (para `sort.stable`).
pub fn newerFirst(_: void, a: types.Channel, b: types.Channel) bool {
    return activity(&a) > activity(&b);
}

/// DM ou grupo (o que vai na lista de mensagens diretas).
pub fn isDm(ch: *const types.Channel) bool {
    return ch.guild == 0 and ch.thread == null;
}

/// Sobe a conversa em `at` para cima da primeira com atividade menor que `key`
/// (as de mesma atividade continuam antes dela). Nunca desce: apagar a última
/// mensagem não reordena, como no Discord. Retorna se mudou de lugar.
pub fn raise(list: []Id, at: usize, key: Id, ctx: anytype, comptime keyOf: fn (@TypeOf(ctx), Id) Id) bool {
    var to: usize = 0;
    while (to < at and keyOf(ctx, list[to]) >= key) to += 1;
    return moveUp(list, at, to);
}

/// Vai para o topo: acabamos de mandar uma mensagem (a confirmação, com o ID
/// de verdade, chega depois).
pub fn toFront(list: []Id, at: usize) bool {
    return moveUp(list, at, 0);
}

fn moveUp(list: []Id, at: usize, to: usize) bool {
    if (to >= at) return false;
    const id = list[at];
    std.mem.copyBackwards(Id, list[to + 1 .. at + 1], list[to..at]);
    list[to] = id;
    return true;
}

/// READY: a lista passa a seguir a ordem dele (as DMs abertas, já ordenadas
/// pelo gateway). As que ele não trouxe ficam no fim, na ordem em que estavam.
pub fn adopt(gpa: std.mem.Allocator, list: []Id, ready: []const types.Channel) !void {
    var rank: std.AutoHashMapUnmanaged(Id, u32) = .empty;
    defer rank.deinit(gpa);
    try rank.ensureTotalCapacity(gpa, @intCast(ready.len));
    var n: u32 = 0;
    for (ready) |*ch| if (isDm(ch)) {
        const gop = rank.getOrPutAssumeCapacity(ch.id);
        if (!gop.found_existing) gop.value_ptr.* = n;
        n += 1;
    };
    const Ctx = struct {
        rank: *const std.AutoHashMapUnmanaged(Id, u32),
        fn of(c: @This(), id: Id) u32 {
            return c.rank.get(id) orelse std.math.maxInt(u32);
        }
        fn lt(c: @This(), a: Id, b: Id) bool {
            return c.of(a) < c.of(b);
        }
    };
    sort.stable(Id, list, Ctx{ .rank = &rank }, Ctx.lt);
}

// --- Testes -----------------------------------------------------------------

const Keys = struct {
    ids: []const Id,
    keys: []const Id,
    fn of(k: *Keys, id: Id) Id {
        for (k.ids, k.keys) |i, v| if (i == id) return v;
        return 0;
    }
};

test "atividade: a última mensagem, ou quando a conversa foi criada" {
    try std.testing.expectEqual(@as(Id, 500), activity(&.{ .id = 100, .guild = 0, .name = "", .last_message = 500 }));
    try std.testing.expectEqual(@as(Id, 100), activity(&.{ .id = 100, .guild = 0, .name = "" }));
    try std.testing.expect(isDm(&.{ .id = 1, .guild = 0, .name = "" }));
    try std.testing.expect(!isDm(&.{ .id = 1, .guild = 5, .name = "" }));
    try std.testing.expect(!isDm(&.{ .id = 1, .guild = 0, .name = "", .thread = .{} }));
    // O READY do gateway: mais recente primeiro, a sem mensagem pelo próprio ID.
    var chs = [_]types.Channel{
        .{ .id = 10, .guild = 0, .name = "", .last_message = 300 },
        .{ .id = 400, .guild = 0, .name = "" },
        .{ .id = 20, .guild = 0, .name = "", .last_message = 900 },
        .{ .id = 30, .guild = 0, .name = "" },
    };
    sort.stable(types.Channel, &chs, {}, newerFirst);
    try std.testing.expectEqual(@as(Id, 20), chs[0].id);
    try std.testing.expectEqual(@as(Id, 400), chs[1].id);
    try std.testing.expectEqual(@as(Id, 10), chs[2].id);
    try std.testing.expectEqual(@as(Id, 30), chs[3].id);
}

test "subir: só para cima, acima da primeira menos recente" {
    var list = [_]Id{ 1, 2, 3, 4 };
    var keys = Keys{ .ids = &.{ 1, 2, 3, 4 }, .keys = &.{ 90, 80, 70, 60 } };
    // Mensagem nova em 4: vai para o topo.
    keys.keys = &.{ 90, 80, 70, 100 };
    try std.testing.expect(raise(&list, 3, 100, &keys, Keys.of));
    try std.testing.expectEqualSlices(Id, &.{ 4, 1, 2, 3 }, &list);
    // 3 passa de 2, mas não de 1 (empate fica depois de quem já estava).
    keys.keys = &.{ 90, 80, 90, 100 };
    try std.testing.expect(raise(&list, 3, 90, &keys, Keys.of));
    try std.testing.expectEqualSlices(Id, &.{ 4, 1, 3, 2 }, &list);
    // Atividade menor (a última mensagem apagada): não desce.
    keys.keys = &.{ 10, 80, 90, 100 };
    try std.testing.expect(!raise(&list, 1, 10, &keys, Keys.of));
    try std.testing.expectEqualSlices(Id, &.{ 4, 1, 3, 2 }, &list);
    // Já no topo: nada muda.
    try std.testing.expect(!raise(&list, 0, 100, &keys, Keys.of));
    // A nossa mensagem acabou de sair: topo, mesmo sem o ID ainda.
    try std.testing.expect(toFront(&list, 3));
    try std.testing.expectEqualSlices(Id, &.{ 2, 4, 1, 3 }, &list);
    try std.testing.expect(!toFront(&list, 0));
}

test "READY: a ordem dele vale; as que não vieram vão para o fim" {
    var list = [_]Id{ 7, 1, 2, 3, 9 };
    const ready = [_]types.Channel{
        .{ .id = 500, .guild = 5, .name = "" },
        .{ .id = 3, .guild = 0, .name = "" },
        .{ .id = 1, .guild = 0, .name = "" },
        .{ .id = 501, .guild = 0, .name = "", .thread = .{} },
        .{ .id = 2, .guild = 0, .name = "" },
    };
    try adopt(std.testing.allocator, &list, &ready);
    try std.testing.expectEqualSlices(Id, &.{ 3, 1, 2, 7, 9 }, &list);
}
