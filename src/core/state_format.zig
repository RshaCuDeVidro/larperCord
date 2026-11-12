//! Retrato da conta em disco: o que a abertura precisa para desenhar a tela antes
//! do READY (servidores, canais, DMs, cargos, o que foi lido, pastas e amigos).
//! Binário simples e little-endian, como o cache de mensagens (core/cache_format.zig):
//!
//!   "LCS1"
//!   u64 eu, str @usuário, u8 premium
//!   u32 usuários; cada um: u64 id, str nome, str foto, str decoração, u8 flags
//!   u32 servidores; cada um: u64 id, str nome, str sigla, u8 cor, str ícone,
//!     u64 dono, u64 entrada, str banner, str descrição, u8 flags, u16 menções
//!   u32 canais; cada um: u64 id, u64 servidor, u64 pai (0 = sem), u8 tipo,
//!     str nome, str tópico, u16 posição, u64 destinatário, ids participantes,
//!     str ícone, u8 flags, u32 exceções (u64 id, u8 pessoa, u64 permite, u64 nega),
//!     u64 última mensagem, u8 pedido, u64 dono, u32 modo lento,
//!     u32 tags (u64 id, str nome, str emoji, u8 moderada),
//!     e, se é thread: u64 dono, u8 flags, u32 mensagens, u32 membros,
//!     u64 última, i64 arquivada, u16 arquivar em, ids das tags
//!   u32 cargos; cada um: u64 id, u64 servidor, str nome, u32 cor, i32 posição,
//!     u64 permissões, u8 flags
//!   u32 nossos cargos; cada um: u64 servidor, ids
//!   u32 leituras; cada uma: u64 canal, u64 lida, u16 menções, u64 última
//!   u32 pastas; cada uma: u64 id, str nome, u32 cor, ids
//!   u32 relações; cada uma: u64 pessoa, u8 tipo, i64 desde
//!   ids dos canais silenciados
//!   u32 perfis de servidor; cada um: u64 servidor, u64 pessoa, str apelido, str foto
//!   str = u32 tamanho + bytes; ids = u32 quantos + u64 cada
//!
//! A leitura confere cada tamanho contra o que sobrou: um arquivo estragado vira
//! "sem retrato" (a abertura espera o READY, como antes), nunca uma leitura fora do
//! lugar. Nada de mensagens, presença ou quem está em call: isso muda o tempo todo.
const std = @import("std");
const types = @import("types.zig");
const Id = types.Id;

pub const magic = "LCS1";

const max_str: u32 = 1 << 16;
const max_count: u32 = 200_000;

pub const MyRoles = struct { guild: Id, roles: []const Id };
/// Apelido e foto de alguém num servidor (vazio = não tem).
pub const ServerFace = struct { guild: Id, user: Id, face: types.Face };
/// Teto de perfis de servidor no retrato (os mais vistos cabem; o resto vem depois).
pub const max_faces = 20_000;
pub const Relation = struct { user: Id, kind: types.Relationship, since_ms: i64 = 0 };

pub const Snapshot = struct {
    me: Id,
    username: []const u8 = "",
    premium_type: u8 = 0,
    users: []const types.User = &.{},
    guilds: []const types.Guild = &.{},
    channels: []const types.Channel = &.{},
    roles: []const types.Role = &.{},
    my_roles: []const MyRoles = &.{},
    reads: []const types.ReadEntry = &.{},
    folders: []const types.GuildFolder = &.{},
    relations: []const Relation = &.{},
    /// Canais silenciados (os servidores e categorias já abertos em canais).
    muted: []const Id = &.{},
    /// O nome de cada um nas mensagens e listas já sai com o apelido do servidor.
    faces: []const ServerFace = &.{},
};

// --- Escrita ------------------------------------------------------------------

const W = struct {
    out: *std.ArrayList(u8),
    gpa: std.mem.Allocator,

    fn int(w: W, comptime T: type, v: T) !void {
        var b: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &b, v, .little);
        try w.out.appendSlice(w.gpa, &b);
    }
    fn byte(w: W, v: u8) !void {
        try w.out.append(w.gpa, v);
    }
    fn str(w: W, s: []const u8) !void {
        const n: u32 = @intCast(@min(s.len, max_str));
        try w.int(u32, n);
        try w.out.appendSlice(w.gpa, s[0..n]);
    }
    fn opt(w: W, s: ?[]const u8) !void {
        try w.str(s orelse "");
    }
    fn ids(w: W, list: []const Id) !void {
        try w.int(u32, @intCast(list.len));
        for (list) |id| try w.int(u64, id);
    }
};

fn bits(flags: []const bool) u8 {
    var b: u8 = 0;
    for (flags, 0..) |f, i| b |= @as(u8, @intFromBool(f)) << @intCast(i);
    return b;
}

pub fn encode(out: *std.ArrayList(u8), gpa: std.mem.Allocator, s: *const Snapshot) !void {
    const w: W = .{ .out = out, .gpa = gpa };
    try out.appendSlice(gpa, magic);
    try w.int(u64, s.me);
    try w.str(s.username);
    try w.byte(s.premium_type);
    try w.int(u32, @intCast(s.users.len));
    for (s.users) |u| {
        try w.int(u64, u.id);
        try w.str(u.name);
        try w.opt(u.avatar);
        try w.opt(u.decoration);
        try w.byte(bits(&.{ u.bot, u.verified_bot }));
    }
    try w.int(u32, @intCast(s.guilds.len));
    for (s.guilds) |g| {
        try w.int(u64, g.id);
        try w.str(g.name);
        try w.str(g.acronym);
        try w.byte(g.color);
        try w.opt(g.icon);
        try w.int(u64, g.owner);
        try w.int(u64, g.joined_id);
        try w.opt(g.banner);
        try w.str(g.description);
        try w.byte(bits(&.{ g.can_banner, g.onboarding, g.unread }));
        try w.int(u16, g.mentions);
    }
    try w.int(u32, @intCast(s.channels.len));
    for (s.channels) |ch| {
        try w.int(u64, ch.id);
        try w.int(u64, ch.guild);
        try w.int(u64, ch.parent orelse 0);
        try w.byte(@intFromEnum(ch.kind));
        try w.str(ch.name);
        try w.str(ch.topic);
        try w.int(u16, ch.position);
        try w.int(u64, ch.recipient);
        try w.ids(ch.recipients);
        try w.opt(ch.icon);
        try w.byte(bits(&.{ ch.group, ch.media, ch.require_tag, ch.unread, ch.thread != null }));
        try w.int(u32, @intCast(ch.overwrites.len));
        for (ch.overwrites) |o| {
            try w.int(u64, o.id);
            try w.byte(@intFromBool(o.member));
            try w.int(u64, o.allow);
            try w.int(u64, o.deny);
        }
        try w.int(u64, ch.last_message);
        try w.byte(@intFromEnum(ch.request));
        try w.int(u64, ch.owner);
        try w.int(u32, ch.rate_limit_per_user);
        try w.int(u32, @intCast(ch.tags.len));
        for (ch.tags) |t| {
            try w.int(u64, t.id);
            try w.str(t.name);
            try w.str(t.emoji);
            try w.byte(@intFromBool(t.moderated));
        }
        if (ch.thread) |t| {
            try w.int(u64, t.owner);
            try w.byte(bits(&.{ t.archived, t.locked, t.private, t.joined, t.joined_known }));
            try w.int(u32, t.message_count);
            try w.int(u32, t.member_count);
            try w.int(u64, t.last_message);
            try w.int(i64, t.archive_ts);
            try w.int(u16, t.auto_archive);
            try w.ids(t.tags);
        }
    }
    try w.int(u32, @intCast(s.roles.len));
    for (s.roles) |r| {
        try w.int(u64, r.id);
        try w.int(u64, r.guild);
        try w.str(r.name);
        try w.int(u32, r.color);
        try w.int(i32, r.position);
        try w.int(u64, r.permissions);
        try w.byte(bits(&.{ r.managed, r.mentionable }));
    }
    try w.int(u32, @intCast(s.my_roles.len));
    for (s.my_roles) |m| {
        try w.int(u64, m.guild);
        try w.ids(m.roles);
    }
    try w.int(u32, @intCast(s.reads.len));
    for (s.reads) |e| {
        try w.int(u64, e.channel);
        try w.int(u64, e.last_read);
        try w.int(u16, e.mentions);
        try w.int(u64, e.last_message);
    }
    try w.int(u32, @intCast(s.folders.len));
    for (s.folders) |f| {
        try w.int(u64, f.id);
        try w.str(f.name);
        try w.int(u32, f.color);
        try w.ids(f.guilds);
    }
    try w.int(u32, @intCast(s.relations.len));
    for (s.relations) |r| {
        try w.int(u64, r.user);
        try w.byte(@intFromEnum(r.kind));
        try w.int(i64, r.since_ms);
    }
    try w.ids(s.muted);
    const nf = @min(s.faces.len, max_faces);
    try w.int(u32, @intCast(nf));
    for (s.faces[0..nf]) |f| {
        try w.int(u64, f.guild);
        try w.int(u64, f.user);
        try w.opt(f.face.nick);
        try w.opt(f.face.avatar);
    }
}

// --- Leitura ------------------------------------------------------------------

const R = struct {
    b: []const u8,
    a: std.mem.Allocator,
    i: usize = 0,

    fn need(r: *R, n: usize) ![]const u8 {
        if (n > r.b.len - r.i) return error.Corrupt;
        const s = r.b[r.i .. r.i + n];
        r.i += n;
        return s;
    }
    fn int(r: *R, comptime T: type) !T {
        const s = try r.need(@sizeOf(T));
        return std.mem.readInt(T, s[0..@sizeOf(T)], .little);
    }
    fn byte(r: *R) !u8 {
        return (try r.need(1))[0];
    }
    fn bit(v: u8, i: u3) bool {
        return v & (@as(u8, 1) << i) != 0;
    }
    fn count(r: *R) !u32 {
        const n = try r.int(u32);
        if (n > max_count) return error.Corrupt;
        return n;
    }
    /// Quantos itens de pelo menos `min` bytes: um número enorme num arquivo curto é
    /// estrago (e não uma alocação enorme antes de descobrir).
    fn items(r: *R, min: usize) !u32 {
        const n = try r.count();
        if (@as(usize, n) * min > r.b.len - r.i) return error.Corrupt;
        return n;
    }
    fn str(r: *R) ![]const u8 {
        const n = try r.int(u32);
        if (n > max_str) return error.Corrupt;
        return try r.a.dupe(u8, try r.need(n));
    }
    /// Vazio = não tem.
    fn opt(r: *R) !?[]const u8 {
        const s = try r.str();
        return if (s.len == 0) null else s;
    }
    fn ids(r: *R) ![]const Id {
        const n = try r.items(8);
        const out = try r.a.alloc(Id, n);
        for (out) |*id| id.* = try r.int(u64);
        return out;
    }
    fn enumOf(r: *R, comptime T: type) !T {
        return std.enums.fromInt(T, try r.byte()) orelse error.Corrupt;
    }
};

/// Lê o retrato inteiro, tudo alocado em `a` (uma arena: quem guarda copia).
pub fn decode(a: std.mem.Allocator, bytes: []const u8) !Snapshot {
    var r: R = .{ .b = bytes, .a = a };
    if (!std.mem.eql(u8, try r.need(4), magic)) return error.Corrupt;
    var s: Snapshot = .{ .me = try r.int(u64) };
    s.username = try r.str();
    s.premium_type = try r.byte();

    const users = try a.alloc(types.User, try r.items(21));
    for (users) |*u| {
        u.* = .{ .id = try r.int(u64), .name = try r.str() };
        u.avatar = try r.opt();
        u.decoration = try r.opt();
        const f = try r.byte();
        u.bot = R.bit(f, 0);
        u.verified_bot = R.bit(f, 1);
    }
    s.users = users;

    const guilds = try a.alloc(types.Guild, try r.items(48));
    for (guilds) |*g| {
        g.* = .{ .id = try r.int(u64), .name = try r.str(), .acronym = try r.str() };
        g.color = try r.byte();
        g.icon = try r.opt();
        g.owner = try r.int(u64);
        g.joined_id = try r.int(u64);
        g.banner = try r.opt();
        g.description = try r.str();
        const f = try r.byte();
        g.can_banner = R.bit(f, 0);
        g.onboarding = R.bit(f, 1);
        g.unread = R.bit(f, 2);
        g.mentions = try r.int(u16);
    }
    s.guilds = guilds;

    const channels = try a.alloc(types.Channel, try r.items(81));
    for (channels) |*ch| {
        const id = try r.int(u64);
        const guild = try r.int(u64);
        const parent = try r.int(u64);
        const kind = try r.enumOf(types.ChannelKind);
        ch.* = .{ .id = id, .guild = guild, .parent = if (parent == 0) null else parent, .kind = kind, .name = try r.str() };
        ch.topic = try r.str();
        ch.position = try r.int(u16);
        ch.recipient = try r.int(u64);
        ch.recipients = try r.ids();
        ch.icon = try r.opt();
        const f = try r.byte();
        ch.group = R.bit(f, 0);
        ch.media = R.bit(f, 1);
        ch.require_tag = R.bit(f, 2);
        ch.unread = R.bit(f, 3);
        const ows = try a.alloc(types.Overwrite, try r.items(25));
        for (ows) |*o| {
            o.* = .{ .id = try r.int(u64) };
            o.member = try r.byte() != 0;
            o.allow = try r.int(u64);
            o.deny = try r.int(u64);
        }
        ch.overwrites = ows;
        ch.last_message = try r.int(u64);
        ch.request = try r.enumOf(types.DmRequest);
        ch.owner = try r.int(u64);
        ch.rate_limit_per_user = try r.int(u32);
        const tags = try a.alloc(types.ForumTag, try r.items(17));
        for (tags) |*t| {
            t.* = .{ .id = try r.int(u64), .name = try r.str() };
            t.emoji = try r.str();
            t.moderated = try r.byte() != 0;
        }
        ch.tags = tags;
        if (R.bit(f, 4)) {
            var t: types.ThreadInfo = .{ .owner = try r.int(u64) };
            const tf = try r.byte();
            t.archived = R.bit(tf, 0);
            t.locked = R.bit(tf, 1);
            t.private = R.bit(tf, 2);
            t.joined = R.bit(tf, 3);
            t.joined_known = R.bit(tf, 4);
            t.message_count = try r.int(u32);
            t.member_count = try r.int(u32);
            t.last_message = try r.int(u64);
            t.archive_ts = try r.int(i64);
            t.auto_archive = try r.int(u16);
            t.tags = try r.ids();
            ch.thread = t;
        }
    }
    s.channels = channels;

    const roles = try a.alloc(types.Role, try r.items(37));
    for (roles) |*ro| {
        ro.* = .{ .id = try r.int(u64), .guild = try r.int(u64), .name = try r.str() };
        ro.color = try r.int(u32);
        ro.position = try r.int(i32);
        ro.permissions = try r.int(u64);
        const f = try r.byte();
        ro.managed = R.bit(f, 0);
        ro.mentionable = R.bit(f, 1);
    }
    s.roles = roles;

    const mine = try a.alloc(MyRoles, try r.items(12));
    for (mine) |*m| m.* = .{ .guild = try r.int(u64), .roles = try r.ids() };
    s.my_roles = mine;

    const reads = try a.alloc(types.ReadEntry, try r.items(26));
    for (reads) |*e| e.* = .{ .channel = try r.int(u64), .last_read = try r.int(u64), .mentions = try r.int(u16), .last_message = try r.int(u64) };
    s.reads = reads;

    const folders = try a.alloc(types.GuildFolder, try r.items(20));
    for (folders) |*f| {
        const fid = try r.int(u64);
        const name = try r.str();
        f.* = .{ .id = fid, .name = name, .color = try r.int(u32), .guilds = try r.ids() };
    }
    s.folders = folders;

    const rels = try a.alloc(Relation, try r.items(17));
    for (rels) |*x| x.* = .{ .user = try r.int(u64), .kind = try r.enumOf(types.Relationship), .since_ms = try r.int(i64) };
    s.relations = rels;
    s.muted = try r.ids();
    const faces = try a.alloc(ServerFace, try r.items(24));
    for (faces) |*f| f.* = .{ .guild = try r.int(u64), .user = try r.int(u64), .face = .{ .nick = try r.opt(), .avatar = try r.opt() } };
    s.faces = faces;
    return s;
}

test "retrato da conta: ida e volta com tudo, e estragado vira erro" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const ow = [_]types.Overwrite{.{ .id = 5, .deny = types.perm.view_channel }};
    const tags = [_]types.ForumTag{.{ .id = 70, .name = "Bug", .emoji = "🐛", .moderated = true }};
    const ttags = [_]Id{70};
    const parts = [_]Id{ 11, 12 };
    const fguilds = [_]Id{ 5, 6 };
    const snap: Snapshot = .{
        .me = 10,
        .username = "rsha",
        .premium_type = 2,
        .users = &.{ .{ .id = 11, .name = "ana", .avatar = "abc" }, .{ .id = 12, .name = "bot", .bot = true, .verified_bot = true, .decoration = "deco" } },
        .guilds = &.{.{ .id = 5, .name = "Zig Brasil", .acronym = "ZB", .color = 3, .icon = "ic", .owner = 11, .joined_id = 99, .unread = true, .mentions = 2, .onboarding = true }},
        .channels = &.{
            .{ .id = 50, .guild = 5, .name = "geral", .topic = "papo", .position = 1, .overwrites = &ow, .last_message = 900, .rate_limit_per_user = 30 },
            .{ .id = 51, .guild = 5, .kind = .forum, .name = "ajuda", .tags = &tags, .require_tag = true },
            .{ .id = 52, .guild = 5, .parent = 51, .name = "post", .thread = .{ .owner = 11, .joined = true, .joined_known = true, .message_count = 4, .archive_ts = -3, .auto_archive = 1440, .tags = &ttags } },
            .{ .id = 60, .guild = 0, .name = "ana, bot", .group = true, .recipients = &parts, .icon = "g", .owner = 11, .request = .pending },
        },
        .roles = &.{.{ .id = 7, .guild = 5, .name = "Moderação", .color = 0x3BA55C, .position = -1, .permissions = 8, .mentionable = true }},
        .my_roles = &.{.{ .guild = 5, .roles = &.{7} }},
        .reads = &.{.{ .channel = 50, .last_read = 800, .mentions = 1 }},
        .folders = &.{.{ .id = 1, .name = "dev", .color = 0xFF0000, .guilds = &fguilds }},
        .relations = &.{.{ .user = 11, .kind = .friend, .since_ms = 1234 }},
        .muted = &.{ 50, 51 },
        .faces = &.{ .{ .guild = 5, .user = 11, .face = .{ .nick = "Aninha" } }, .{ .guild = 5, .user = 12, .face = .{ .avatar = "guilds/5/users/12/avatars/x" } } },
    };
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try encode(&out, gpa, &snap);
    const d = try decode(arena.allocator(), out.items);
    try std.testing.expectEqual(@as(Id, 10), d.me);
    try std.testing.expectEqualStrings("rsha", d.username);
    try std.testing.expectEqual(@as(u8, 2), d.premium_type);
    try std.testing.expectEqualStrings("abc", d.users[0].avatar.?);
    try std.testing.expect(d.users[0].decoration == null and d.users[1].bot and d.users[1].verified_bot);
    try std.testing.expectEqualStrings("deco", d.users[1].decoration.?);
    try std.testing.expectEqualStrings("ZB", d.guilds[0].acronym);
    try std.testing.expect(d.guilds[0].unread and d.guilds[0].onboarding and !d.guilds[0].can_banner and d.guilds[0].banner == null);
    try std.testing.expectEqual(@as(u16, 2), d.guilds[0].mentions);
    try std.testing.expectEqual(types.perm.view_channel, d.channels[0].overwrites[0].deny);
    try std.testing.expectEqual(@as(u32, 30), d.channels[0].rate_limit_per_user);
    try std.testing.expect(d.channels[0].parent == null and d.channels[0].thread == null);
    try std.testing.expectEqual(types.ChannelKind.forum, d.channels[1].kind);
    try std.testing.expectEqualStrings("🐛", d.channels[1].tags[0].emoji);
    try std.testing.expect(d.channels[1].require_tag and d.channels[1].tags[0].moderated);
    try std.testing.expectEqual(@as(?Id, 51), d.channels[2].parent);
    const t = d.channels[2].thread.?;
    try std.testing.expect(t.joined and t.joined_known and !t.archived);
    try std.testing.expectEqual(@as(i64, -3), t.archive_ts);
    try std.testing.expectEqualSlices(Id, &ttags, t.tags);
    try std.testing.expectEqualSlices(Id, &parts, d.channels[3].recipients);
    try std.testing.expect(d.channels[3].group and d.channels[3].request == .pending);
    try std.testing.expectEqual(@as(i32, -1), d.roles[0].position);
    try std.testing.expect(d.roles[0].mentionable and !d.roles[0].managed);
    try std.testing.expectEqualSlices(Id, &.{7}, d.my_roles[0].roles);
    try std.testing.expectEqual(@as(Id, 800), d.reads[0].last_read);
    try std.testing.expectEqualSlices(Id, &fguilds, d.folders[0].guilds);
    try std.testing.expectEqual(types.Relationship.friend, d.relations[0].kind);
    try std.testing.expectEqual(@as(i64, 1234), d.relations[0].since_ms);
    try std.testing.expectEqualSlices(Id, &.{ 50, 51 }, d.muted);
    try std.testing.expectEqualStrings("Aninha", d.faces[0].face.nick.?);
    try std.testing.expect(d.faces[0].face.avatar == null and d.faces[1].face.nick == null);
    try std.testing.expectEqualStrings("guilds/5/users/12/avatars/x", d.faces[1].face.avatar.?);
    // Cortado em qualquer ponto: erro, nunca leitura fora do lugar.
    var cut: usize = 0;
    while (cut < out.items.len) : (cut += 7) try std.testing.expectError(error.Corrupt, decode(arena.allocator(), out.items[0..cut]));
    // Assinatura de outra coisa, e um número de usuários enorme num arquivo curto.
    try std.testing.expectError(error.Corrupt, decode(arena.allocator(), "XXXX"));
    const huge = "LCS1".* ++ @as([13]u8, @splat(0)) ++ [_]u8{ 0xff, 0xff, 0x02, 0x00 };
    try std.testing.expectError(error.Corrupt, decode(arena.allocator(), &huge));
}
