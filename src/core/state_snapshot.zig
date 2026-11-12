//! O retrato da conta (core/state_format.zig) a partir do Store, e de volta para ele:
//! `collect` monta o que vai para o disco; `apply` põe o retrato num Store pelo mesmo
//! caminho do gateway, com o READY marcado como do cache. O disco fica em
//! net/state_cache.zig.
const std = @import("std");
const types = @import("types.zig");
const format = @import("state_format.zig");
const Store = @import("store.zig").Store;
const Event = @import("event.zig").Event;
const Id = types.Id;

/// Quem recebe os eventos (o Store) libera com este.
const ev_alloc = std.heap.c_allocator;

/// O retrato do que o Store tem agora. Os textos são os do Store (só lidos para gravar);
/// as listas saem de `a`.
pub fn collect(a: std.mem.Allocator, s: *const Store) !format.Snapshot {
    // Quem precisa de nome e foto antes do READY: nós, quem está nas DMs e nos amigos.
    // (Os autores das mensagens vêm junto com cada conversa, no cache dela.)
    var who: std.AutoArrayHashMapUnmanaged(Id, void) = .empty;
    try who.put(a, s.me, {});
    for (s.channelsOf(0)) |id| if (s.channel(id)) |cs| {
        if (cs.info.recipient != 0) try who.put(a, cs.info.recipient, {});
        for (cs.info.recipients) |r| try who.put(a, r, {});
    };
    var rel_it = s.relationships.keyIterator();
    while (rel_it.next()) |u| try who.put(a, u.*, {});
    var users: std.ArrayList(types.User) = .empty;
    for (who.keys()) |id| if (s.users.get(id)) |u| try users.append(a, u);

    // Os canais na ordem do Store (a das DMs é a da lista), as threads depois.
    var channels: std.ArrayList(types.Channel) = .empty;
    var order: std.ArrayList(Id) = .empty;
    try order.append(a, 0);
    for (s.guilds.items) |g| try order.append(a, g.id);
    for (order.items) |gid| for (s.channelsOf(gid)) |id| if (s.channel(id)) |cs| try channels.append(a, cs.info);
    var ch_it = s.channels.valueIterator();
    while (ch_it.next()) |cs| if (cs.*.info.thread != null) try channels.append(a, cs.*.info);

    var roles: std.ArrayList(types.Role) = .empty;
    var ro_it = s.roles.valueIterator();
    while (ro_it.next()) |r| try roles.append(a, r.*);
    var mine: std.ArrayList(format.MyRoles) = .empty;
    var my_it = s.my_roles.iterator();
    while (my_it.next()) |e| try mine.append(a, .{ .guild = e.key_ptr.*, .roles = e.value_ptr.* });
    var reads: std.ArrayList(types.ReadEntry) = .empty;
    var rd_it = s.read_index.valueIterator();
    while (rd_it.next()) |e| try reads.append(a, e.*);
    var muted: std.ArrayList(Id) = .empty;
    if (s.muted) |m| {
        var mit = m.keyIterator();
        while (mit.next()) |id| try muted.append(a, id.*);
    }
    var rels: std.ArrayList(format.Relation) = .empty;
    var rl_it = s.relationships.iterator();
    while (rl_it.next()) |e| try rels.append(a, .{ .user = e.key_ptr.*, .kind = e.value_ptr.*, .since_ms = s.friend_since.get(e.key_ptr.*) orelse 0 });

    return .{
        .me = s.me,
        .username = s.me_username orelse "",
        .premium_type = s.premium_type,
        .users = users.items,
        .guilds = s.guilds.items,
        .channels = channels.items,
        .roles = roles.items,
        .my_roles = mine.items,
        .reads = reads.items,
        .folders = s.folders,
        .relations = rels.items,
        .muted = muted.items,
    };
}

fn dupe(t: []const u8) ![]const u8 {
    return try ev_alloc.dupe(u8, t);
}
fn dupeOpt(t: ?[]const u8) !?[]const u8 {
    return if (t) |x| try ev_alloc.dupe(u8, x) else null;
}
/// Texto que o Store só libera quando não está vazio.
fn dupeOrEmpty(t: []const u8) ![]const u8 {
    return if (t.len == 0) "" else try ev_alloc.dupe(u8, t);
}
fn dupeIds(list: []const Id) ![]const Id {
    return if (list.len == 0) &.{} else try ev_alloc.dupe(Id, list);
}

fn ownChannel(ch: types.Channel) !types.Channel {
    var o = ch;
    o.name = try dupe(ch.name);
    o.topic = try dupe(ch.topic);
    o.recipients = try dupeIds(ch.recipients);
    o.icon = try dupeOpt(ch.icon);
    o.overwrites = if (ch.overwrites.len == 0) &.{} else try ev_alloc.dupe(types.Overwrite, ch.overwrites);
    if (ch.tags.len > 0) {
        const tags = try ev_alloc.alloc(types.ForumTag, ch.tags.len);
        for (ch.tags, tags) |t, *d| d.* = .{ .id = t.id, .name = try dupe(t.name), .emoji = try dupeOrEmpty(t.emoji), .moderated = t.moderated };
        o.tags = tags;
    } else o.tags = &.{};
    if (ch.thread) |t| {
        o.thread = t;
        o.thread.?.tags = try dupeIds(t.tags);
    }
    return o;
}

/// Os eventos que o gateway mandaria (cada texto alocado como os dele), com o READY
/// marcado como do cache: quem os aplica (o Store, e o app depois de cada um, como faz
/// com os do gateway) mostra a tela, mas `store.ready` continua falso até o READY de
/// verdade.
pub fn events(snap: *const format.Snapshot, out: *std.ArrayList(Event), gpa: std.mem.Allocator) !void {
    // Os cargos antes do READY, como no gateway (a lista de canais já abre certa).
    if (snap.roles.len > 0) {
        const roles = try ev_alloc.alloc(types.Role, snap.roles.len);
        for (snap.roles, roles) |r, *d| {
            d.* = r;
            d.name = try dupe(r.name);
        }
        try out.append(gpa, .{ .roles = .{ .guild = 0, .roles = roles } });
    }
    const users = try ev_alloc.alloc(types.User, snap.users.len);
    for (snap.users, users) |u, *d| d.* = .{ .id = u.id, .name = try dupe(u.name), .avatar = try dupeOpt(u.avatar), .decoration = try dupeOpt(u.decoration), .bot = u.bot, .verified_bot = u.verified_bot };
    const guilds = try ev_alloc.alloc(types.Guild, snap.guilds.len);
    for (snap.guilds, guilds) |g, *d| {
        d.* = g;
        d.name = try dupe(g.name);
        d.acronym = try dupe(g.acronym);
        d.icon = try dupeOpt(g.icon);
        d.banner = try dupeOpt(g.banner);
        d.description = try dupeOrEmpty(g.description);
    }
    const channels = try ev_alloc.alloc(types.Channel, snap.channels.len);
    for (snap.channels, channels) |ch, *d| d.* = try ownChannel(ch);
    try out.append(gpa, .{ .ready = .{
        .me = snap.me,
        .users = users,
        .guilds = guilds,
        .channels = channels,
        .voice = &.{},
        .username = if (snap.username.len > 0) try dupe(snap.username) else null,
        .premium_type = snap.premium_type,
        .cached = true,
    } });
    // Os silenciados vão junto, como no READY (quem trata é o app).
    try out.append(gpa, .{ .read_states = .{ .entries = try ev_alloc.dupe(types.ReadEntry, snap.reads), .muted = if (snap.muted.len > 0) try ev_alloc.dupe(Id, snap.muted) else &.{} } });
    for (snap.relations) |r| try out.append(gpa, .{ .relationship = .{ .user = r.user, .kind = r.kind, .since_ms = r.since_ms } });
    for (snap.my_roles) |m| try out.append(gpa, .{ .my_roles = .{ .guild = m.guild, .roles = try ev_alloc.dupe(Id, m.roles) } });
    if (snap.folders.len > 0) {
        const folders = try ev_alloc.alloc(types.GuildFolder, snap.folders.len);
        for (snap.folders, folders) |f, *d| d.* = .{ .id = f.id, .name = try dupe(f.name), .color = f.color, .guilds = try dupeIds(f.guilds) };
        try out.append(gpa, .{ .guild_folders = folders });
    }
}

/// O retrato direto num Store (sem o app: os testes). Os silenciados, que o app trata,
/// ficam de fora.
pub fn apply(s: *Store, snap: *const format.Snapshot, now_ms: i64) !void {
    var list: std.ArrayList(Event) = .empty;
    defer list.deinit(s.gpa);
    try events(snap, &list, s.gpa);
    for (list.items) |e| {
        if (e == .read_states and e.read_states.muted.len > 0) ev_alloc.free(e.read_states.muted);
        try s.apply(e, now_ms);
    }
}

test "retrato da conta: do Store para o disco e de volta para outro Store" {
    const gpa = std.testing.allocator;
    var a = Store.init(gpa);
    defer a.deinit();
    const ch = [_]types.Channel{
        .{ .id = 50, .guild = 5, .name = try ev_alloc.dupe(u8, "geral"), .topic = try ev_alloc.dupe(u8, ""), .last_message = 900 },
        .{ .id = 60, .guild = 0, .name = try ev_alloc.dupe(u8, "ana"), .topic = try ev_alloc.dupe(u8, ""), .recipient = 11 },
    };
    const users = try ev_alloc.alloc(types.User, 2);
    users[0] = .{ .id = 10, .name = try ev_alloc.dupe(u8, "eu") };
    users[1] = .{ .id = 11, .name = try ev_alloc.dupe(u8, "ana"), .avatar = try ev_alloc.dupe(u8, "abc") };
    const guilds = try ev_alloc.alloc(types.Guild, 1);
    guilds[0] = .{ .id = 5, .name = try ev_alloc.dupe(u8, "Zig"), .acronym = try ev_alloc.dupe(u8, "Z") };
    try a.apply(.{ .ready = .{ .me = 10, .users = users, .guilds = guilds, .channels = try ev_alloc.dupe(types.Channel, &ch), .voice = &.{} } }, 0);
    try a.apply(.{ .relationship = .{ .user = 11, .kind = .friend, .since_ms = 7 } }, 0);
    try a.apply(.{ .read_states = .{ .entries = try ev_alloc.dupe(types.ReadEntry, &[_]types.ReadEntry{.{ .channel = 50, .last_read = 800 }}) } }, 0);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const snap = try collect(arena.allocator(), &a);
    var out: std.ArrayList(u8) = .empty;
    try format.encode(&out, arena.allocator(), &snap);
    const back = try format.decode(arena.allocator(), out.items);

    var b = Store.init(gpa);
    defer b.deinit();
    try apply(&b, &back, 0);
    // A tela tem o que precisa, mas a sessão ainda não está pronta.
    try std.testing.expect(!b.ready and b.from_cache);
    try std.testing.expectEqualStrings("Zig", b.guild(5).?.name);
    try std.testing.expectEqualStrings("geral", b.channel(50).?.info.name);
    try std.testing.expectEqualSlices(Id, &.{60}, b.channelsOf(0));
    try std.testing.expectEqualStrings("abc", b.user(11).?.avatar.?);
    try std.testing.expectEqual(types.Relationship.friend, b.relationships.get(11).?);
    try std.testing.expectEqual(@as(Id, 800), b.read_index.get(50).?.last_read);
}

fn testChannel(id: Id, guild: Id) !types.Channel {
    return .{ .id = id, .guild = guild, .name = try ev_alloc.dupe(u8, "c"), .topic = try ev_alloc.dupe(u8, ""), .recipient = if (guild == 0) 11 else 0 };
}
fn testGuild(id: Id) !types.Guild {
    return .{ .id = id, .name = try ev_alloc.dupe(u8, "g"), .acronym = try ev_alloc.dupe(u8, "G") };
}

test "retrato da conta: o READY de verdade tira o que sumiu e fica com o resto" {
    const gpa = std.testing.allocator;
    var s = Store.init(gpa);
    defer s.deinit();
    // O retrato: servidores 5, 6 e 8; canais 50 e 51 (no 5), 70 (no 6), 80 (no 8) e a DM 60.
    const g1 = try ev_alloc.alloc(types.Guild, 3);
    g1[0] = try testGuild(5);
    g1[1] = try testGuild(6);
    g1[2] = try testGuild(8);
    const c1 = try ev_alloc.alloc(types.Channel, 5);
    for ([_][2]Id{ .{ 50, 5 }, .{ 51, 5 }, .{ 70, 6 }, .{ 80, 8 }, .{ 60, 0 } }, c1) |p, *d| d.* = try testChannel(p[0], p[1]);
    try s.apply(.{ .ready = .{ .me = 10, .users = try ev_alloc.alloc(types.User, 0), .guilds = g1, .channels = c1, .voice = &.{}, .cached = true } }, 0);
    try s.apply(.{ .relationship = .{ .user = 11, .kind = .friend } }, 0);
    try std.testing.expect(s.from_cache and !s.ready);
    // O READY: saímos do 6, o 51 foi apagado, a DM fechou, e o 8 veio indisponível (sem canais).
    const g2 = try ev_alloc.alloc(types.Guild, 2);
    g2[0] = try testGuild(5);
    g2[1] = try testGuild(8);
    const c2 = try ev_alloc.alloc(types.Channel, 1);
    c2[0] = try testChannel(50, 5);
    try s.apply(.{ .ready = .{ .me = 10, .users = try ev_alloc.alloc(types.User, 0), .guilds = g2, .channels = c2, .voice = &.{} } }, 0);
    try std.testing.expect(s.ready and !s.from_cache);
    try std.testing.expect(s.guild(6) == null and s.channel(70) == null);
    try std.testing.expect(s.channel(51) == null and s.channel(60) == null);
    try std.testing.expectEqual(@as(usize, 0), s.channelsOf(0).len);
    try std.testing.expect(s.channel(50) != null and s.guild(5) != null);
    // O indisponível fica como estava até o GUILD_CREATE.
    try std.testing.expect(s.guild(8) != null and s.channel(80) != null);
    // As amizades chegam de novo depois do READY.
    try std.testing.expectEqual(@as(usize, 0), s.relationships.count());
}
