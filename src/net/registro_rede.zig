//! O que sai para o Discord, no registro de depuração (Configurações → Avançado): cada
//! pedido da API (método, caminho sem a query, status) e cada op do gateway (o número e
//! o servidor, quando tem). Nada do conteúdo: nem token, nem texto, nem o que se buscou.
//! Se a conta for desativada de novo, dá para ver o que o app mandou antes. O heartbeat
//! (op 1) fica de fora: sai a cada ~40 s e não diz nada. Lógica pura: quem usa é
//! net/discord.zig.
const std = @import("std");

/// "op 14 servidor 123", "op 2"… null: o heartbeat, ou algo que não começa com o op.
pub fn opLine(buf: []u8, payload: []const u8) ?[]const u8 {
    const head = "{\"op\":";
    if (!std.mem.startsWith(u8, payload, head)) return null;
    var end = head.len;
    while (end < payload.len and std.ascii.isDigit(payload[end])) end += 1;
    const op = payload[head.len..end];
    if (op.len == 0 or std.mem.eql(u8, op, "1")) return null;
    if (guildOf(payload)) |gid| return std.fmt.bufPrint(buf, "op {s} servidor {s}", .{ op, gid }) catch null;
    return std.fmt.bufPrint(buf, "op {s}", .{op}) catch null;
}

/// O `guild_id` do pedido, só se for um número (nada mais do payload sai daqui).
fn guildOf(payload: []const u8) ?[]const u8 {
    const key = "\"guild_id\":\"";
    const i = std.mem.indexOf(u8, payload, key) orelse return null;
    const from = i + key.len;
    var end = from;
    while (end < payload.len and std.ascii.isDigit(payload[end])) end += 1;
    if (end == from or end >= payload.len or payload[end] != '"') return null;
    return payload[from..end];
}

/// O caminho sem a query (a busca leva o que a pessoa digitou).
pub fn pathOnly(path: []const u8) []const u8 {
    return path[0 .. std.mem.indexOfScalar(u8, path, '?') orelse path.len];
}

const t = std.testing;

test "op do gateway: o número e o servidor, nada do conteúdo" {
    var b: [64]u8 = undefined;
    try t.expectEqualStrings("op 14 servidor 123", opLine(&b, "{\"op\":14,\"d\":{\"guild_id\":\"123\",\"typing\":true}}").?);
    try t.expectEqualStrings("op 4 servidor 9", opLine(&b, "{\"op\":4,\"d\":{\"guild_id\":\"9\",\"channel_id\":null}}").?);
    // O IDENTIFY leva o token: só o número sai.
    const line = opLine(&b, "{\"op\":2,\"d\":{\"token\":\"segredo.abc\",\"properties\":{}}}").?;
    try t.expectEqualStrings("op 2", line);
    try t.expect(std.mem.indexOf(u8, line, "segredo") == null);
    // Heartbeat e lixo: nada.
    try t.expectEqual(@as(?[]const u8, null), opLine(&b, "{\"op\":1,\"d\":42}"));
    try t.expectEqual(@as(?[]const u8, null), opLine(&b, "oi"));
    // Um guild_id que não é número não sai.
    try t.expectEqualStrings("op 8", opLine(&b, "{\"op\":8,\"d\":{\"guild_id\":\"1\\\"x\"}}").?);
}

test "caminho da API sem a query" {
    try t.expectEqualStrings("/guilds/1/messages/search", pathOnly("/guilds/1/messages/search?content=oi"));
    try t.expectEqualStrings("/users/@me", pathOnly("/users/@me"));
}
