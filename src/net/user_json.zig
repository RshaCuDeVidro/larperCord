//! Quem é quem no JSON do Discord: bots e autores de webhook (sem rede, para dar
//! para testar).
const std = @import("std");
const types = @import("../core/types.zig");
const j = @import("jsonx.zig");
const Id = types.Id;
const Value = std.json.Value;

pub fn isBot(u: Value) bool {
    const v = j.get(u, "bot") orelse return false;
    return v == .bool and v.bool;
}

/// O bit VERIFIED_BOT das `public_flags`.
pub fn isVerifiedBot(u: Value) bool {
    const f = j.int(j.get(u, "public_flags")) orelse return false;
    return f & (1 << 16) != 0;
}

/// Autor de uma mensagem. Num webhook de verdade (o autor tem o ID do próprio
/// webhook; resposta de comando tem `webhook_id` mas o autor é o bot), cada nome
/// e foto é uma "pessoa": mensagens com nomes diferentes não se juntam.
pub fn authorId(m: Value) Id {
    const a = j.get(m, "author") orelse return 0;
    const id = j.id(j.get(a, "id")) orelse return 0;
    if (j.id(j.get(m, "webhook_id")) != id) return id;
    var h = std.hash.Wyhash.init(id);
    h.update(j.str(j.get(a, "username")) orelse "");
    h.update(j.str(j.get(a, "avatar")) orelse "");
    return h.final() | types.webhook_id_bit;
}

/// A foto de um webhook fica no ID dele, não no da "pessoa": vai a URL inteira.
pub fn webhookAvatar(buf: []u8, author: Value) ?[]const u8 {
    const hash = j.str(j.get(author, "avatar")) orelse return null;
    const hook = j.id(j.get(author, "id")) orelse return null;
    return std.fmt.bufPrint(buf, "https://cdn.discordapp.com/avatars/{d}/{s}.png?size=128", .{ hook, hash }) catch null;
}

/// O perfil do servidor num objeto `member`: o apelido e o caminho da foto no CDN
/// (que fica em `buf`). Vazio vira null (não tem). null no lugar do resultado: o
/// objeto nem tem os campos, e não diz nada.
pub const MemberFace = struct { nick: ?[]const u8, avatar: ?[]const u8 };

pub fn memberFace(buf: []u8, guild: Id, user: Id, m: Value) ?MemberFace {
    if (j.get(m, "nick") == null and j.get(m, "avatar") == null) return null;
    const nick = j.str(j.get(m, "nick")) orelse "";
    return .{
        .nick = if (nick.len > 0) nick else null,
        .avatar = if (j.str(j.get(m, "avatar"))) |h| guildPath(buf, guild, user, "avatars", h) else null,
    };
}

/// "guilds/{servidor}/users/{pessoa}/{avatars|banners}/{hash}": onde o CDN guarda a
/// foto e o banner do perfil de um servidor. Hash estranho (vazio, comprido, com
/// algo além de letras, números e _) fica de fora.
pub fn guildPath(buf: []u8, guild: Id, user: Id, comptime kind: []const u8, hash: []const u8) ?[]const u8 {
    if (hash.len == 0 or hash.len > 64) return null;
    for (hash) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_') return null;
    return std.fmt.bufPrint(buf, "guilds/{d}/users/{d}/" ++ kind ++ "/{s}", .{ guild, user, hash }) catch null;
}

fn parseValue(arena: *std.heap.ArenaAllocator, text: []const u8) !Value {
    return std.json.parseFromSliceLeaky(Value, arena.allocator(), text, .{});
}

test "bot e bot verificado" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const verified = try parseValue(&arena, "{\"id\":\"1\",\"bot\":true,\"public_flags\":65536}");
    try std.testing.expect(isBot(verified) and isVerifiedBot(verified));
    const plain = try parseValue(&arena, "{\"id\":\"1\",\"bot\":true,\"public_flags\":0}");
    try std.testing.expect(isBot(plain) and !isVerifiedBot(plain));
    // Gente comum: o Discord nem manda o campo.
    const person = try parseValue(&arena, "{\"id\":\"1\",\"username\":\"ana\",\"public_flags\":64}");
    try std.testing.expect(!isBot(person) and !isVerifiedBot(person));
    const off = try parseValue(&arena, "{\"id\":\"1\",\"bot\":false}");
    try std.testing.expect(!isBot(off));
}

test "autor: pessoa, resposta de comando e webhook" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const person = try parseValue(&arena, "{\"author\":{\"id\":\"42\",\"username\":\"ana\"}}");
    try std.testing.expectEqual(@as(Id, 42), authorId(person));
    // Resposta de comando: `webhook_id` é o da aplicação, e o autor é o bot.
    const command = try parseValue(&arena, "{\"webhook_id\":\"7\",\"author\":{\"id\":\"42\",\"username\":\"bot\",\"bot\":true}}");
    try std.testing.expectEqual(@as(Id, 42), authorId(command));

    const a = try parseValue(&arena, "{\"webhook_id\":\"7\",\"author\":{\"id\":\"7\",\"username\":\"GitHub\",\"avatar\":\"abc\",\"bot\":true}}");
    const again = try parseValue(&arena, "{\"webhook_id\":\"7\",\"author\":{\"id\":\"7\",\"username\":\"GitHub\",\"avatar\":\"abc\",\"bot\":true}}");
    const other = try parseValue(&arena, "{\"webhook_id\":\"7\",\"author\":{\"id\":\"7\",\"username\":\"Sentry\",\"avatar\":\"abc\",\"bot\":true}}");
    // O mesmo nome e foto é sempre a mesma "pessoa"; outro nome, outra.
    try std.testing.expectEqual(authorId(a), authorId(again));
    try std.testing.expect(authorId(a) != authorId(other));
    try std.testing.expect(authorId(a) & types.webhook_id_bit != 0);
    try std.testing.expect(authorId(other) & types.webhook_id_bit != 0);

    var ub: [160]u8 = undefined;
    try std.testing.expectEqualStrings("https://cdn.discordapp.com/avatars/7/abc.png?size=128", webhookAvatar(&ub, j.get(a, "author").?).?);
    const no_pic = try parseValue(&arena, "{\"id\":\"7\",\"username\":\"x\",\"avatar\":null}");
    try std.testing.expect(webhookAvatar(&ub, no_pic) == null);
}

test "perfil do servidor no objeto member" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var pb: [128]u8 = undefined;
    const full = try parseValue(&arena, "{\"nick\":\"Aninha\",\"avatar\":\"a_0f3c\",\"roles\":[]}");
    const f = memberFace(&pb, 5, 7, full).?;
    try std.testing.expectEqualStrings("Aninha", f.nick.?);
    try std.testing.expectEqualStrings("guilds/5/users/7/avatars/a_0f3c", f.avatar.?);
    // Sem apelido nem foto (tirou os dois): os dois null, para limpar o que havia.
    const none = memberFace(&pb, 5, 7, try parseValue(&arena, "{\"nick\":null,\"avatar\":null,\"roles\":[]}")).?;
    try std.testing.expect(none.nick == null and none.avatar == null);
    const empty = memberFace(&pb, 5, 7, try parseValue(&arena, "{\"nick\":\"\"}")).?;
    try std.testing.expect(empty.nick == null and empty.avatar == null);
    // Objeto que nem tem os campos: não diz nada.
    try std.testing.expect(memberFace(&pb, 5, 7, try parseValue(&arena, "{\"roles\":[]}")) == null);
    // Hash que não é hash não vira caminho.
    const odd = memberFace(&pb, 5, 7, try parseValue(&arena, "{\"avatar\":\"../x\"}")).?;
    try std.testing.expect(odd.avatar == null);
    try std.testing.expectEqualStrings("guilds/5/users/7/banners/b1", guildPath(&pb, 5, 7, "banners", "b1").?);
}

test "mensagem sem autor" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqual(@as(Id, 0), authorId(try parseValue(&arena, "{\"id\":\"1\"}")));
}
