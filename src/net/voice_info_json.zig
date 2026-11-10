//! O começo da call de cada canal de voz (o tempo ao lado do canal na lista,
//! core/voice_timer.zig), pelo gateway (docs.discord.food, "Gateway Events"):
//!  - op 43 Request Channel Info: `{ guild_id, fields: ["status", "voice_start_time"] }`,
//!    como o cliente oficial manda;
//!  - CHANNEL_INFO, a resposta: `{ guild_id, channels: [{ id, status?, voice_start_time? }] }`;
//!  - VOICE_CHANNEL_START_TIME_UPDATE: `{ id, guild_id, voice_start_time }`, null quando
//!    a call acaba.
//! A doc diz "unix timestamp (in seconds)" no texto e ISO8601 no tipo do CHANNEL_INFO:
//! aceita os dois, e também em ms ou como texto com o número.
const std = @import("std");
const j = @import("jsonx.zig");
const Value = std.json.Value;
const types = @import("../core/types.zig");
const Id = types.Id;
const VoiceStart = @import("../core/event.zig").VoiceStart;

/// O pedido do op 43 de um servidor.
pub fn request(buf: []u8, guild: Id) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{{\"op\":43,\"d\":{{\"guild_id\":\"{d}\",\"fields\":[\"status\",\"voice_start_time\"]}}}}", .{guild}) catch null;
}

/// Começo plausível de uma call (s Unix): de 2015, quando o Discord surgiu, até o
/// limite de core/voice_timer.zig. Fora disso é lixo.
const min_s: i64 = 1_420_070_400;
const max_s: i64 = @import("../core/voice_timer.zig").max_start_s;

/// Número já lido: em segundos, ou em ms (grande demais para ser segundos).
fn fromNumber(n: i64) i64 {
    const s = if (n >= 100_000_000_000) @divFloor(n, 1000) else n;
    return if (s >= min_s and s <= max_s) s else 0;
}

/// "2026-11-10T13:04:05.123+00:00" (ou com Z, sem fração, com espaço no lugar do T).
fn fromIso(s: []const u8) i64 {
    if (s.len < 19) return 0;
    if (s[4] != '-' or s[7] != '-' or (s[10] != 'T' and s[10] != 't' and s[10] != ' ') or s[13] != ':' or s[16] != ':') return 0;
    for ([_]usize{ 0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18 }) |i| if (!std.ascii.isDigit(s[i])) return 0;
    return fromNumber(j.isoTime(s));
}

/// `voice_start_time` de um canal: segundos Unix, ou 0 (sem call, null ou valor que
/// não faz sentido). Ausente também é 0: o CHANNEL_INFO só traz o campo onde há call.
pub fn startOf(v: ?Value) i64 {
    const x = v orelse return 0;
    return switch (x) {
        .integer => |n| fromNumber(n),
        .float => |f| if (std.math.isFinite(f) and f > 0 and f < 1e15) fromNumber(@intFromFloat(f)) else 0,
        .number_string => |s| fromText(s),
        .string => |s| fromText(s),
        else => 0,
    };
}

fn fromText(s: []const u8) i64 {
    const txt = std.mem.trim(u8, s, " ");
    if (txt.len > 0 and txt.len <= 16) {
        if (std.fmt.parseInt(i64, txt, 10)) |n| return fromNumber(n) else |_| {}
        if (std.fmt.parseFloat(f64, txt)) |f| return startOf(Value{ .float = f }) else |_| {}
    }
    return fromIso(txt);
}

pub const ChannelInfo = struct { guild: Id, starts: []VoiceStart };

/// CHANNEL_INFO -> os canais que têm call agora (a lista é alocada com `gpa`; vazia
/// quando nenhum tem). null = sem servidor.
pub fn channelInfo(gpa: std.mem.Allocator, d: Value) !?ChannelInfo {
    const guild = j.id(j.get(d, "guild_id")) orelse return null;
    const list = j.array(j.get(d, "channels"));
    var out: std.ArrayList(VoiceStart) = .empty;
    errdefer out.deinit(gpa);
    for (list) |cv| {
        const id = j.id(j.get(cv, "id")) orelse continue;
        const st = startOf(j.get(cv, "voice_start_time"));
        if (st != 0) try out.append(gpa, .{ .channel = id, .start_s = st });
    }
    return .{ .guild = guild, .starts = try out.toOwnedSlice(gpa) };
}

pub const StartUpdate = struct { guild: Id, channel: Id, start_s: i64 };

/// VOICE_CHANNEL_START_TIME_UPDATE (`start_s` 0 = a call acabou).
pub fn startUpdate(d: Value) ?StartUpdate {
    const id = j.id(j.get(d, "id")) orelse j.id(j.get(d, "channel_id")) orelse return null;
    return .{ .guild = j.id(j.get(d, "guild_id")) orelse 0, .channel = id, .start_s = startOf(j.get(d, "voice_start_time")) };
}

// --- Testes -------------------------------------------------------------------

const t = std.testing;

fn parse(a: std.mem.Allocator, text: []const u8) !Value {
    return (try std.json.parseFromSliceLeaky(Value, a, text, .{}));
}

test "pedido do op 43, igual ao do cliente oficial" {
    var b: [160]u8 = undefined;
    const p = request(&b, 1234567890123456789).?;
    try t.expectEqualStrings("{\"op\":43,\"d\":{\"guild_id\":\"1234567890123456789\",\"fields\":[\"status\",\"voice_start_time\"]}}", p);
    var a = std.heap.ArenaAllocator.init(t.allocator);
    defer a.deinit();
    const v = try parse(a.allocator(), p);
    try t.expectEqual(@as(?i64, 43), j.int(j.get(v, "op")));
    var small: [10]u8 = undefined;
    try t.expectEqual(@as(?[]const u8, null), request(&small, 1));
}

test "voice_start_time em segundos, ms, texto e ISO8601" {
    var a = std.heap.ArenaAllocator.init(t.allocator);
    defer a.deinit();
    const al = a.allocator();
    try t.expectEqual(@as(i64, 1_762_780_000), startOf(try parse(al, "1762780000")));
    try t.expectEqual(@as(i64, 1_762_780_000), startOf(try parse(al, "1762780000123")));
    try t.expectEqual(@as(i64, 1_762_780_000), startOf(try parse(al, "1762780000.5")));
    try t.expectEqual(@as(i64, 1_762_780_000), startOf(try parse(al, "\"1762780000\"")));
    try t.expectEqual(@as(i64, 1_762_780_000), startOf(try parse(al, "\"1762780000123\"")));
    // 2025-11-10T13:06:40 UTC = 1762780000.
    try t.expectEqual(@as(i64, 1_762_780_000), startOf(try parse(al, "\"2025-11-10T13:06:40+00:00\"")));
    try t.expectEqual(@as(i64, 1_762_780_000), startOf(try parse(al, "\"2025-11-10T13:06:40.123000+00:00\"")));
    try t.expectEqual(@as(i64, 1_762_780_000), startOf(try parse(al, "\"2025-11-10T13:06:40Z\"")));
    try t.expectEqual(@as(i64, 1_762_780_000), startOf(try parse(al, "\"2025-11-10T10:06:40-03:00\"")));
    try t.expectEqual(@as(i64, 1_762_780_000), startOf(try parse(al, "\"2025-11-10 13:06:40\"")));
}

test "voice_start_time sem call, nulo, ausente ou lixo vira 0" {
    var a = std.heap.ArenaAllocator.init(t.allocator);
    defer a.deinit();
    const al = a.allocator();
    try t.expectEqual(@as(i64, 0), startOf(null));
    for ([_][]const u8{ "null", "0", "-5", "true", "\"\"", "\"agora\"", "\"2025-13\"", "\"2025/11/10 13:06:40\"", "\"xxxx-11-10T13:06:40\"", "[]", "{}", "99999999999999999", "1e300", "12" }) |txt|
        try t.expectEqual(@as(i64, 0), startOf(try parse(al, txt)));
}

test "CHANNEL_INFO: só os canais com call, nos dois formatos" {
    var a = std.heap.ArenaAllocator.init(t.allocator);
    defer a.deinit();
    const al = a.allocator();
    const d = try parse(al,
        \\{"guild_id":"77","channels":[
        \\ {"id":"1","status":"jogando","voice_start_time":1762780000},
        \\ {"id":"2","voice_start_time":null},
        \\ {"id":"3","status":null},
        \\ {"id":"4","voice_start_time":"2025-11-10T13:06:40.000000+00:00"},
        \\ {"voice_start_time":1762780000},
        \\ {"id":"x","voice_start_time":1762780000}
        \\]}
    );
    const ci = (try channelInfo(t.allocator, d)).?;
    defer t.allocator.free(ci.starts);
    try t.expectEqual(@as(Id, 77), ci.guild);
    try t.expectEqual(@as(usize, 2), ci.starts.len);
    try t.expectEqual(@as(Id, 1), ci.starts[0].channel);
    try t.expectEqual(@as(i64, 1_762_780_000), ci.starts[0].start_s);
    try t.expectEqual(@as(Id, 4), ci.starts[1].channel);
    try t.expectEqual(@as(i64, 1_762_780_000), ci.starts[1].start_s);
    // Sem servidor: nada. Sem lista: lista vazia.
    try t.expectEqual(@as(?ChannelInfo, null), try channelInfo(t.allocator, try parse(al, "{\"channels\":[]}")));
    const empty = (try channelInfo(t.allocator, try parse(al, "{\"guild_id\":\"5\"}"))).?;
    try t.expectEqual(@as(usize, 0), empty.starts.len);
}

test "VOICE_CHANNEL_START_TIME_UPDATE: começou e acabou" {
    var a = std.heap.ArenaAllocator.init(t.allocator);
    defer a.deinit();
    const al = a.allocator();
    const on = startUpdate(try parse(al, "{\"id\":\"9\",\"guild_id\":\"77\",\"voice_start_time\":1762780000}")).?;
    try t.expectEqual(@as(Id, 9), on.channel);
    try t.expectEqual(@as(Id, 77), on.guild);
    try t.expectEqual(@as(i64, 1_762_780_000), on.start_s);
    const off = startUpdate(try parse(al, "{\"id\":\"9\",\"guild_id\":\"77\",\"voice_start_time\":null}")).?;
    try t.expectEqual(@as(i64, 0), off.start_s);
    try t.expectEqual(@as(?StartUpdate, null), startUpdate(try parse(al, "{\"guild_id\":\"77\"}")));
}
