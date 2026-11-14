//! Emoji and stickers the account can't send natively (no Nitro, from another
//! server...) go out as images instead: the draft carries a named link
//! `[name](https://cdn.discordapp.com/...)` and, when the draft is nothing but
//! such links, the app downloads the images from the CDN and sends them as
//! ordinary attachments. With text alongside, the link stays in the message.
//! This file is the pure part only: the URLs, the link, and recognising a
//! draft that is artwork and nothing else.
const std = @import("std");

/// Discord allows up to 10 attachments per message.
pub const max_items = 10;
/// Cap on one downloaded file: emoji and stickers are small; anything bigger isn't artwork.
pub const max_bytes: usize = 2 * 1024 * 1024;
/// ATTACH_FILES (Permissions).
pub const attach_files: u64 = 1 << 15;

/// Sticker format types, as in core/stickers.zig.
const format_png = 1;
const format_apng = 2;
const format_lottie = 3;
const format_gif = 4;

pub const Asset = union(enum) {
    emoji: struct { id: u64, animated: bool },
    sticker: struct { id: u64, format: u8 },

    pub fn eql(a: Asset, b: Asset) bool {
        return switch (a) {
            .emoji => |x| switch (b) {
                .emoji => |y| x.id == y.id and x.animated == y.animated,
                else => false,
            },
            .sticker => |x| switch (b) {
                .sticker => |y| x.id == y.id and x.format == y.format,
                else => false,
            },
        };
    }

    pub fn id(a: Asset) u64 {
        return switch (a) {
            .emoji => |e| e.id,
            .sticker => |s| s.id,
        };
    }

    /// Extension of the file the CDN returns.
    pub fn ext(a: Asset) []const u8 {
        return switch (a) {
            .emoji => |e| if (e.animated) "gif" else "png",
            .sticker => |s| if (s.format == format_gif) "gif" else "png",
        };
    }

    /// The attachment's name on Discord: neutral, nothing that identifies the app.
    pub fn fileName(a: Asset, buf: []u8) ?[]const u8 {
        return std.fmt.bufPrint(buf, "{s}-{d}.{s}", .{ if (a == .emoji) "emoji" else "sticker", a.id(), a.ext() }) catch null;
    }
};

/// The public address of the artwork. Only Discord's CDN and media proxy, never
/// a host from outside. Null for a zero id or an unknown format.
pub fn url(buf: []u8, a: Asset) ?[]const u8 {
    if (a.id() == 0) return null;
    return switch (a) {
        .emoji => |e| std.fmt.bufPrint(buf, "https://cdn.discordapp.com/emojis/{d}.{s}?size=64", .{ e.id, if (e.animated) "gif" else "png" }) catch null,
        .sticker => |s| switch (s.format) {
            format_png, format_apng => std.fmt.bufPrint(buf, "https://cdn.discordapp.com/stickers/{d}.png", .{s.id}) catch null,
            // Lottie isn't an image: the proxy renders its first frame.
            format_lottie => std.fmt.bufPrint(buf, "https://media.discordapp.net/stickers/{d}.png?passthrough=false", .{s.id}) catch null,
            format_gif => std.fmt.bufPrint(buf, "https://media.discordapp.net/stickers/{d}.gif", .{s.id}) catch null,
            else => null,
        },
    };
}

/// Recognises exactly the addresses `url` produces, and nothing else.
pub fn fromUrl(link: []const u8) ?Asset {
    if (link.len > 160) return null;
    var buf: [200]u8 = undefined;
    const emoji_prefix = "https://cdn.discordapp.com/emojis/";
    const cdn_sticker = "https://cdn.discordapp.com/stickers/";
    const proxy_sticker = "https://media.discordapp.net/stickers/";
    var found: ?Asset = null;
    if (std.mem.startsWith(u8, link, emoji_prefix)) {
        const rest = link[emoji_prefix.len..];
        const dot = std.mem.indexOfScalar(u8, rest, '.') orelse return null;
        const id = std.fmt.parseInt(u64, rest[0..dot], 10) catch return null;
        const animated = if (std.mem.eql(u8, rest[dot..], ".gif?size=64")) true else if (std.mem.eql(u8, rest[dot..], ".png?size=64")) false else return null;
        found = .{ .emoji = .{ .id = id, .animated = animated } };
    } else if (std.mem.startsWith(u8, link, cdn_sticker)) {
        const rest = link[cdn_sticker.len..];
        if (!std.mem.endsWith(u8, rest, ".png")) return null;
        const id = std.fmt.parseInt(u64, rest[0 .. rest.len - 4], 10) catch return null;
        found = .{ .sticker = .{ .id = id, .format = format_png } };
    } else if (std.mem.startsWith(u8, link, proxy_sticker)) {
        const rest = link[proxy_sticker.len..];
        const dot = std.mem.indexOfScalar(u8, rest, '.') orelse return null;
        const id = std.fmt.parseInt(u64, rest[0..dot], 10) catch return null;
        const format: u8 = if (std.mem.eql(u8, rest[dot..], ".png?passthrough=false")) format_lottie else if (std.mem.eql(u8, rest[dot..], ".gif")) format_gif else return null;
        found = .{ .sticker = .{ .id = id, .format = format } };
    }
    const a = found orelse return null;
    // Round trip: `0123.png` or `1.gif?x=1` don't pass.
    const back = url(&buf, a) orelse return null;
    return if (std.mem.eql(u8, back, link)) a else null;
}

/// `[name](url)`; the name loses control characters and gets markdown characters escaped.
pub fn markdown(out: []u8, a: Asset, name: []const u8) ?[]const u8 {
    var ub: [200]u8 = undefined;
    const link = url(&ub, a) orelse return null;
    var n: usize = 0;
    if (out.len < 4) return null;
    out[n] = '[';
    n += 1;
    var label: usize = 0;
    var it = std.unicode.Utf8View.initUnchecked(name).iterator();
    while (it.nextCodepointSlice()) |cp| {
        if (label >= 100) break;
        if (cp.len == 1 and (cp[0] < 0x20 or cp[0] == 0x7f)) continue;
        const esc = cp.len == 1 and std.mem.indexOfScalar(u8, "\\[]()*_~`", cp[0]) != null;
        if (n + cp.len + @intFromBool(esc) + 4 + link.len > out.len) return null;
        if (esc) {
            out[n] = '\\';
            n += 1;
        }
        @memcpy(out[n..][0..cp.len], cp);
        n += cp.len;
        label += 1;
    }
    if (label == 0) {
        const fallback = if (a == .emoji) "emoji" else "sticker";
        if (n + fallback.len + 4 + link.len > out.len) return null;
        @memcpy(out[n..][0..fallback.len], fallback);
        n += fallback.len;
    }
    const tail = std.fmt.bufPrint(out[n..], "]({s})", .{link}) catch return null;
    return out[0 .. n + tail.len];
}

/// Is the draft nothing but artwork links, with no text at all (whitespace between
/// them is fine)? Returns the list (up to `max_items`); text alongside, more than
/// `max_items`, or any other link gives null.
pub fn onlyLinks(text: []const u8, out: *[max_items]Asset) ?[]const Asset {
    var rest = std.mem.trim(u8, text, " \t\r\n");
    var n: usize = 0;
    while (rest.len > 0) {
        if (n == max_items or rest[0] != '[') return null;
        var escaped = false;
        var close: ?usize = null;
        for (rest[1..], 1..) |ch, i| {
            if (i > 400 or ch < 0x20) return null;
            if (!escaped and ch == ']') {
                close = i;
                break;
            }
            escaped = !escaped and ch == '\\';
        }
        const end_label = close orelse return null;
        if (end_label == 1) return null;
        const after = rest[end_label + 1 ..];
        if (!std.mem.startsWith(u8, after, "(")) return null;
        const paren = std.mem.indexOfScalar(u8, after, ')') orelse return null;
        out[n] = fromUrl(after[1..paren]) orelse return null;
        n += 1;
        rest = std.mem.trimStart(u8, after[paren + 1 ..], " \t\r\n");
    }
    return if (n == 0) null else out[0..n];
}

test "artwork addresses" {
    var b: [200]u8 = undefined;
    try std.testing.expectEqualStrings("https://cdn.discordapp.com/emojis/12.png?size=64", url(&b, .{ .emoji = .{ .id = 12, .animated = false } }).?);
    try std.testing.expectEqualStrings("https://cdn.discordapp.com/emojis/12.gif?size=64", url(&b, .{ .emoji = .{ .id = 12, .animated = true } }).?);
    try std.testing.expectEqualStrings("https://cdn.discordapp.com/stickers/7.png", url(&b, .{ .sticker = .{ .id = 7, .format = 1 } }).?);
    try std.testing.expectEqualStrings("https://cdn.discordapp.com/stickers/7.png", url(&b, .{ .sticker = .{ .id = 7, .format = 2 } }).?);
    try std.testing.expectEqualStrings("https://media.discordapp.net/stickers/7.png?passthrough=false", url(&b, .{ .sticker = .{ .id = 7, .format = 3 } }).?);
    try std.testing.expectEqualStrings("https://media.discordapp.net/stickers/7.gif", url(&b, .{ .sticker = .{ .id = 7, .format = 4 } }).?);
    try std.testing.expect(url(&b, .{ .sticker = .{ .id = 7, .format = 9 } }) == null);
    try std.testing.expect(url(&b, .{ .emoji = .{ .id = 0, .animated = false } }) == null);
}

test "only the addresses we generate come back as artwork" {
    try std.testing.expect(fromUrl("https://cdn.discordapp.com/emojis/9.gif?size=64").?.emoji.animated);
    try std.testing.expectEqual(@as(u8, 4), fromUrl("https://media.discordapp.net/stickers/5.gif").?.sticker.format);
    try std.testing.expect(fromUrl("https://cdn.discordapp.com/emojis/9.gif?size=64&extra=1") == null);
    try std.testing.expect(fromUrl("https://cdn.discordapp.com/emojis/09.gif?size=64") == null);
    try std.testing.expect(fromUrl("https://evil.example/emojis/9.gif?size=64") == null);
    try std.testing.expect(fromUrl("https://cdn.discordapp.com.evil.example/emojis/9.png?size=64") == null);
    try std.testing.expect(fromUrl("http://cdn.discordapp.com/emojis/9.png?size=64") == null);
    try std.testing.expect(fromUrl("https://cdn.discordapp.com/stickers/5.gif") == null);
}

test "named link and artwork-only draft" {
    var b: [400]u8 = undefined;
    const e1: Asset = .{ .emoji = .{ .id = 10, .animated = false } };
    const s1: Asset = .{ .sticker = .{ .id = 20, .format = 4 } };
    const m1 = markdown(&b, e1, "wave_hi").?;
    try std.testing.expectEqualStrings("[wave\\_hi](https://cdn.discordapp.com/emojis/10.png?size=64)", m1);
    var list: [max_items]Asset = undefined;
    const got = onlyLinks(m1, &list).?;
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expect(got[0].eql(e1));
    // Two links with a space and a line break between them (separate buffers:
    // `m1` points into `b`).
    var b2: [400]u8 = undefined;
    var two: [800]u8 = undefined;
    const t = std.fmt.bufPrint(&two, "{s} \n{s}", .{ m1, markdown(&b2, s1, "party").? }) catch unreachable;
    const got2 = onlyLinks(t, &list).?;
    try std.testing.expectEqual(@as(usize, 2), got2.len);
    try std.testing.expect(got2[1].eql(s1));
    // Text alongside, a foreign link, empty, or an empty name: no attachment.
    try std.testing.expect(onlyLinks("hi [a](https://cdn.discordapp.com/emojis/10.png?size=64)", &list) == null);
    try std.testing.expect(onlyLinks("[a](https://cdn.discordapp.com/emojis/10.png?size=64) hi", &list) == null);
    try std.testing.expect(onlyLinks("[a](https://example.com/x.png)", &list) == null);
    try std.testing.expect(onlyLinks("[](https://cdn.discordapp.com/emojis/10.png?size=64)", &list) == null);
    try std.testing.expect(onlyLinks("   ", &list) == null);
    // An empty name becomes a fallback name; control characters are dropped.
    try std.testing.expectEqualStrings("[emoji](https://cdn.discordapp.com/emojis/10.png?size=64)", markdown(&b, e1, "\n\t").?);
}

test "at most ten attachments" {
    var one: [200]u8 = undefined;
    const link = markdown(&one, .{ .emoji = .{ .id = 1, .animated = false } }, "a").?;
    var big: [4096]u8 = undefined;
    var n: usize = 0;
    var list: [max_items]Asset = undefined;
    for (0..max_items) |_| {
        @memcpy(big[n..][0..link.len], link);
        n += link.len;
    }
    try std.testing.expectEqual(@as(usize, max_items), onlyLinks(big[0..n], &list).?.len);
    @memcpy(big[n..][0..link.len], link);
    n += link.len;
    try std.testing.expect(onlyLinks(big[0..n], &list) == null);
}

test "attachment file name" {
    var b: [64]u8 = undefined;
    try std.testing.expectEqualStrings("emoji-10.gif", (Asset{ .emoji = .{ .id = 10, .animated = true } }).fileName(&b).?);
    try std.testing.expectEqualStrings("sticker-20.png", (Asset{ .sticker = .{ .id = 20, .format = 3 } }).fileName(&b).?);
}
