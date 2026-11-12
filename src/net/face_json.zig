//! O perfil do servidor nos objetos do gateway (sem rede, para dar para testar com o
//! JSON de verdade): o apelido e a foto de cada `member`, o que já foi mandado ao
//! Store (para não mandar de novo o mesmo a cada mensagem), a ordem dos
//! `merged_members` do READY_SUPPLEMENTAL e a bio, os pronomes e o banner do
//! `guild_member_profile`.
const std = @import("std");
const types = @import("../core/types.zig");
const j = @import("jsonx.zig");
const user_json = @import("user_json.zig");
const Id = types.Id;
const Value = std.json.Value;

/// Um campo de um `member`: ausente mantém o que havia (um GUILD_MEMBER_UPDATE pode
/// trazer só o que mudou), null ou vazio limpa, um valor troca.
pub const Field = union(enum) {
    keep,
    clear,
    set: []const u8,

    fn of(v: ?Value) Field {
        const x = v orelse return .keep;
        const t = j.str(x) orelse return .clear;
        return if (t.len > 0) .{ .set = t } else .clear;
    }
};

/// O que um objeto `member` diz do perfil do servidor. `avatar` já é o caminho no CDN
/// (em `buf`).
pub const Change = struct {
    nick: Field = .keep,
    avatar: Field = .keep,

    pub fn known(c: Change) bool {
        return c.nick != .keep and c.avatar != .keep;
    }
};

/// null: o objeto não fala de apelido nem de foto.
pub fn read(buf: []u8, guild: Id, user: Id, m: Value) ?Change {
    var out: Change = .{ .nick = Field.of(j.get(m, "nick")), .avatar = Field.of(j.get(m, "avatar")) };
    if (out.nick == .keep and out.avatar == .keep) return null;
    // Hash que não é hash não vira caminho (fica como sem foto).
    if (out.avatar == .set) out.avatar = if (user_json.guildPath(buf, guild, user, "avatars", out.avatar.set)) |p| .{ .set = p } else .clear;
    return out;
}

fn hashOf(c: Change) u64 {
    var h = std.hash.Wyhash.init(0);
    h.update(if (c.nick == .set) c.nick.set else "\x00");
    h.update("\x01");
    h.update(if (c.avatar == .set) c.avatar.set else "\x00");
    return h.final() | 1;
}

/// O que já foi mandado ao Store, por (servidor, pessoa): quem nunca teve apelido nem
/// foto (quase todo mundo) não vira evento, e o mesmo de novo também não.
pub const Tracker = struct {
    /// O hash do último apelido e foto completos mandados; 0 = parte desconhecida
    /// (veio um pedaço só).
    sent: std.AutoHashMapUnmanaged([2]Id, u64) = .empty,

    pub fn deinit(t: *Tracker, gpa: std.mem.Allocator) void {
        t.sent.deinit(gpa);
    }

    /// A mudança a mandar ao Store, ou null.
    pub fn filter(t: *Tracker, gpa: std.mem.Allocator, guild: Id, user: Id, c: Change) ?Change {
        if (guild == 0 or user == 0) return null;
        const key: [2]Id = .{ guild, user };
        const prev = t.sent.get(key);
        const sets = c.nick == .set or c.avatar == .set;
        // Só limpando quem nunca teve nada: não há o que dizer.
        if (!sets and prev == null) return null;
        if (c.known()) {
            const h = hashOf(c);
            if (prev == h) return null;
            if (sets) t.sent.put(gpa, key, h) catch {} else _ = t.sent.remove(key);
            return c;
        }
        // Um pedaço só: o Store junta com o que tem; o todo fica desconhecido aqui.
        t.sent.put(gpa, key, 0) catch {};
        return c;
    }

    /// A pessoa saiu do servidor (o Store soltou o apelido dela): se voltar com o
    /// mesmo, ele vai de novo.
    pub fn forget(t: *Tracker, guild: Id, user: Id) void {
        _ = t.sent.remove(.{ guild, user });
    }

    /// Saímos do servidor: esquece o que foi mandado dele.
    pub fn forgetGuild(t: *Tracker, guild: Id) void {
        // Remover só deixa uma lápide: a mesma volta continua sem recomeçar (recomeçar a
        // cada remoção, num servidor grande, segurava a thread de rede).
        var it = t.sent.iterator();
        while (it.next()) |e| if (e.key_ptr[0] == guild) t.sent.removeByPtr(e.key_ptr);
    }
};

/// A mudança com os textos copiados (para o evento, que o Store assume).
pub const Owned = struct { face: types.Face, keep_nick: bool, keep_avatar: bool };

pub fn owned(gpa: std.mem.Allocator, c: Change) Owned {
    return .{
        .face = .{
            .nick = if (c.nick == .set) gpa.dupe(u8, c.nick.set) catch null else null,
            .avatar = if (c.avatar == .set) gpa.dupe(u8, c.avatar.set) catch null else null,
        },
        .keep_nick = c.nick == .keep,
        .keep_avatar = c.avatar == .keep,
    };
}

/// O dono de um objeto `member`: `user_id` no formato sem repetição, ou `user`.
pub fn ownerOf(m: Value) ?Id {
    if (j.id(j.get(m, "user_id"))) |id| return id;
    const u = j.get(m, "user") orelse return null;
    return j.id(j.get(u, "id"));
}

/// Os `merged_members` (do READY ou do READY_SUPPLEMENTAL) vêm na ordem de `guilds`:
/// o servidor da lista `gi`, ou null.
pub fn mergedGuild(d: Value, gi: usize) ?Id {
    const gs = j.array(j.get(d, "guilds"));
    if (gi >= gs.len) return null;
    return j.id(j.get(gs[gi], "id"));
}

/// Os textos do perfil (GET /users/{id}/profile): os globais (de `user_profile`, ou do
/// `user`) e os do servidor (`guild_member_profile`), que nunca entram no lugar deles.
pub const ProfileTexts = struct { bio: []const u8, pronouns: []const u8, server: ServerProfile };

pub fn profileTexts(v: Value) ProfileTexts {
    const u = j.get(v, "user");
    const up = j.get(v, "user_profile");
    return .{
        .bio = (if (up) |p| j.str(j.get(p, "bio")) else null) orelse (if (u) |x| j.str(j.get(x, "bio")) else null) orelse "",
        .pronouns = (if (up) |p| j.str(j.get(p, "pronouns")) else null) orelse "",
        .server = serverProfile(v),
    };
}

/// A bio, os pronomes e o hash do banner do perfil do servidor (vazio = não tem).
pub const ServerProfile = struct { bio: []const u8 = "", pronouns: []const u8 = "", banner: []const u8 = "" };

pub fn serverProfile(v: Value) ServerProfile {
    const gp = j.get(v, "guild_member_profile") orelse return .{};
    return .{
        .bio = j.str(j.get(gp, "bio")) orelse "",
        .pronouns = j.str(j.get(gp, "pronouns")) orelse "",
        .banner = j.str(j.get(gp, "banner")) orelse "",
    };
}

fn parse(arena: *std.heap.ArenaAllocator, text: []const u8) !Value {
    return std.json.parseFromSliceLeaky(Value, arena.allocator(), text, .{});
}

test "member: apelido e foto, o que falta mantém, null e vazio limpam" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var pb: [128]u8 = undefined;
    // MESSAGE_CREATE: o `member` (sem `user`) com os dois campos.
    const msg = try parse(&arena, "{\"guild_id\":\"5\",\"author\":{\"id\":\"7\"},\"member\":{\"nick\":\"Aninha\",\"avatar\":\"a_0f\",\"roles\":[]}}");
    const c1 = read(&pb, 5, 7, j.get(msg, "member").?).?;
    try std.testing.expectEqualStrings("Aninha", c1.nick.set);
    try std.testing.expectEqualStrings("guilds/5/users/7/avatars/a_0f", c1.avatar.set);
    // GUILD_MEMBER_UPDATE parcial (ganhou um cargo): sem `nick`, o apelido fica.
    const upd = try parse(&arena, "{\"guild_id\":\"5\",\"user\":{\"id\":\"7\"},\"roles\":[\"9\"],\"avatar\":null}");
    const c2 = read(&pb, 5, 7, upd).?;
    try std.testing.expect(c2.nick == .keep and c2.avatar == .clear);
    // Tirou o apelido: null e "" limpam.
    try std.testing.expect(read(&pb, 5, 7, try parse(&arena, "{\"nick\":null}")).?.nick == .clear);
    try std.testing.expect(read(&pb, 5, 7, try parse(&arena, "{\"nick\":\"\"}")).?.nick == .clear);
    // Nada sobre apelido nem foto (uma presença, por exemplo).
    try std.testing.expect(read(&pb, 5, 7, try parse(&arena, "{\"roles\":[]}")) == null);
    // Hash estranho vira "sem foto".
    try std.testing.expect(read(&pb, 5, 7, try parse(&arena, "{\"avatar\":\"../x\"}")).?.avatar == .clear);
}

test "tracker: sem nada não vira evento, o igual de novo também não, o pedaço passa" {
    const gpa = std.testing.allocator;
    var t: Tracker = .{};
    defer t.deinit(gpa);
    // Quem nunca teve apelido: o member de cada mensagem não vira evento.
    try std.testing.expect(t.filter(gpa, 5, 8, .{ .nick = .clear, .avatar = .clear }) == null);
    const full: Change = .{ .nick = .{ .set = "Aninha" }, .avatar = .clear };
    try std.testing.expect(t.filter(gpa, 5, 7, full) != null);
    // A mesma coisa na próxima mensagem: nada.
    try std.testing.expect(t.filter(gpa, 5, 7, full) == null);
    // Outro servidor é outra pessoa.
    try std.testing.expect(t.filter(gpa, 6, 7, full) != null);
    // Um pedaço (GUILD_MEMBER_UPDATE sem `nick`) passa, e o próximo completo também.
    try std.testing.expect(t.filter(gpa, 5, 7, .{ .avatar = .{ .set = "guilds/5/users/7/avatars/b" } }) != null);
    try std.testing.expect(t.filter(gpa, 5, 7, full) != null);
    // Tirou tudo: passa uma vez (para limpar) e depois nada.
    try std.testing.expect(t.filter(gpa, 5, 7, .{ .nick = .clear, .avatar = .clear }) != null);
    try std.testing.expect(t.filter(gpa, 5, 7, .{ .nick = .clear, .avatar = .clear }) == null);
    // Saímos do servidor 6: o que foi mandado dele é esquecido.
    t.forgetGuild(6);
    try std.testing.expect(t.filter(gpa, 6, 7, full) != null);
    // Saiu do servidor (GUILD_MEMBER_REMOVE) e voltou com o mesmo apelido: vai de novo.
    try std.testing.expect(t.filter(gpa, 6, 7, full) == null);
    t.forget(6, 7);
    try std.testing.expect(t.filter(gpa, 6, 7, full) != null);
}

test "merged_members na ordem de guilds, com user_id ou user" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const d = try parse(&arena,
        \\{"guilds":[{"id":"5","voice_states":[]},{"id":"6"}],
        \\ "merged_members":[[{"user_id":"7","nick":"Aninha"}],[{"user":{"id":"8"},"nick":"Kaká"}]]}
    );
    const mm = j.array(j.get(d, "merged_members"));
    try std.testing.expectEqual(@as(?Id, 5), mergedGuild(d, 0));
    try std.testing.expectEqual(@as(?Id, 6), mergedGuild(d, 1));
    try std.testing.expectEqual(@as(?Id, null), mergedGuild(d, 2));
    try std.testing.expectEqual(@as(?Id, 7), ownerOf(j.array(mm[0])[0]));
    try std.testing.expectEqual(@as(?Id, 8), ownerOf(j.array(mm[1])[0]));
}

test "perfil do servidor no GET /users/{id}/profile" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try parse(&arena,
        \\{"user":{"id":"7"},"user_profile":{"bio":"global","pronouns":"ela"},
        \\ "guild_member":{"nick":"Aninha","avatar":null,"joined_at":"2024-01-01T00:00:00+00:00"},
        \\ "guild_member_profile":{"guild_id":"5","bio":"no servidor","pronouns":"","banner":"b1"}}
    );
    // Os globais continuam os globais (Configurações → Minha conta grava estes).
    const tx = profileTexts(v);
    try std.testing.expectEqualStrings("global", tx.bio);
    try std.testing.expectEqualStrings("ela", tx.pronouns);
    try std.testing.expectEqualStrings("no servidor", tx.server.bio);
    const sp = serverProfile(v);
    try std.testing.expectEqualStrings("no servidor", sp.bio);
    try std.testing.expectEqualStrings("", sp.pronouns);
    try std.testing.expectEqualStrings("b1", sp.banner);
    try std.testing.expectEqualStrings("", serverProfile(try parse(&arena, "{\"user\":{\"id\":\"7\"}}")).bio);
}
