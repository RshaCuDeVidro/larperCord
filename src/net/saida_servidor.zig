//! A conta saiu de um servidor (kick, ban, ou saiu ela mesma): nada mais vai para lá.
//! Com a conexão de pé, quem avisa é o GUILD_DELETE (sem `unavailable`); com ela caída,
//! uma sessão nova (READY) simplesmente não traz o servidor, e GUILD_DELETE nenhum vem.
//! Uma lista de membros (op 14), o começo das calls (op 43) ou uma entrada na call
//! (op 4) para um servidor de que a conta não faz parte não é coisa que um cliente
//! normal mande. Lógica pura: quem usa é net/discord.zig.
const std = @import("std");
const j = @import("jsonx.zig");
const Value = std.json.Value;
const types = @import("../core/types.zig");
const Id = types.Id;
const Command = @import("../core/event.zig").Command;

/// O READY traz todos os servidores da conta (os fora do ar também, só com o id e
/// `unavailable`): o que não está nele a conta deixou.
pub fn readyHas(d: Value, guild: Id) bool {
    for (j.array(j.get(d, "guilds"))) |gv| if (j.id(j.get(gv, "id")) == guild) return true;
    return false;
}

/// O servidor de um pedido que esperava a conexão voltar (null: não é de servidor).
pub fn heldGuild(cmd: Command) ?Id {
    const gid: Id = switch (cmd) {
        .subscribe_guild => |sg| sg.guild,
        .channel_info => |g| g,
        .join_voice => |v| v.guild,
        else => 0,
    };
    return if (gid != 0) gid else null;
}

const t = std.testing;

test "o READY traz todos os servidores, fora do ar também" {
    const raw =
        \\{"guilds":[{"id":"10","name":"a"},{"id":"20","unavailable":true}]}
    ;
    const p = try std.json.parseFromSlice(Value, t.allocator, raw, .{});
    defer p.deinit();
    try t.expect(readyHas(p.value, 10));
    try t.expect(readyHas(p.value, 20));
    // Kick ou ban com a conexão caída: o servidor não vem.
    try t.expect(!readyHas(p.value, 30));
    const empty = try std.json.parseFromSlice(Value, t.allocator, "{}", .{});
    defer empty.deinit();
    try t.expect(!readyHas(empty.value, 10));
}

test "pedidos guardados sem conexão: só os de servidor têm servidor" {
    try t.expectEqual(@as(?Id, 5), heldGuild(.{ .subscribe_guild = .{ .guild = 5, .channel = 6, .thread = 0 } }));
    try t.expectEqual(@as(?Id, 5), heldGuild(.{ .channel_info = 5 }));
    try t.expectEqual(@as(?Id, 5), heldGuild(.{ .join_voice = .{ .guild = 5, .channel = null } }));
    // Call de DM (servidor 0) e o status não são de servidor nenhum.
    try t.expectEqual(@as(?Id, null), heldGuild(.{ .join_voice = .{ .guild = 0, .channel = 7 } }));
    try t.expectEqual(@as(?Id, null), heldGuild(.{ .voice_flags = .{ .mute = true, .deaf = false } }));
}
