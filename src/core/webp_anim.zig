//! Animated WebP writer, no dependencies (tested in `zig build test`).
//! Used to turn an APNG sticker into an animated WebP before uploading it: an
//! uploaded APNG shows as its first frame only, while an animated WebP plays.
//!
//! libwebp already links into the app, and its simple encoder
//! (`WebPEncodeLosslessRGBA`) returns a complete single-image WebP file. This file
//! only wraps such files as the frames of one animation (RIFF/VP8X/ANIM/ANMF; see
//! the WebP container specification). Every frame is a full canvas that replaces
//! the previous one, so the result keeps exact colors and full 8-bit alpha.
const std = @import("std");

pub const Error = error{ TooBig, TooManyFrames, BadFrame, OutOfMemory };

/// The largest side VP8L (lossless WebP) can describe.
pub const max_side = 16384;

pub const Builder = struct {
    gpa: std.mem.Allocator,
    /// The ANMF chunks written so far.
    frames: std.ArrayList(u8) = .empty,
    w: u32,
    h: u32,
    count: usize = 0,
    max_bytes: usize,
    max_frames: usize,

    pub fn init(gpa: std.mem.Allocator, w: u32, h: u32, max_bytes: usize, max_frames: usize) Error!Builder {
        if (w == 0 or h == 0 or w > max_side or h > max_side) return error.BadFrame;
        return .{ .gpa = gpa, .w = w, .h = h, .max_bytes = max_bytes, .max_frames = max_frames };
    }

    pub fn deinit(b: *Builder) void {
        b.frames.deinit(b.gpa);
    }

    /// Appends one frame. `file` is a complete WebP file holding a single lossless
    /// image of exactly the canvas size, shown for `duration_ms`.
    pub fn addFrame(b: *Builder, file: []const u8, duration_ms: u32) Error!void {
        if (b.count >= b.max_frames) return error.TooManyFrames;
        const payload = try framePayload(file, b.w, b.h);
        const gpa = b.gpa;
        try b.frames.appendSlice(gpa, "ANMF");
        try putU32(&b.frames, gpa, @intCast(16 + payload.len));
        try put24(&b.frames, gpa, 0); // x / 2
        try put24(&b.frames, gpa, 0); // y / 2
        try put24(&b.frames, gpa, b.w - 1);
        try put24(&b.frames, gpa, b.h - 1);
        try put24(&b.frames, gpa, @min(duration_ms, 0xffffff));
        // Blending method 1 (do not blend: the frame replaces the canvas, alpha and
        // all), disposal method 0 (leave in place).
        try b.frames.append(gpa, 0b10);
        try b.frames.appendSlice(gpa, payload);
        b.count += 1;
        if (b.frames.items.len > b.max_bytes) return error.TooBig;
    }

    /// Ends the file and hands over its bytes (owned by the caller).
    pub fn finish(b: *Builder) Error![]u8 {
        if (b.count == 0) return error.BadFrame;
        const gpa = b.gpa;
        const riff_len = 4 + (8 + 10) + (8 + 6) + b.frames.items.len;
        if (riff_len > std.math.maxInt(u32)) return error.TooBig;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        try out.ensureTotalCapacity(gpa, 8 + riff_len);
        out.appendSliceAssumeCapacity("RIFF");
        try putU32(&out, gpa, @intCast(riff_len));
        out.appendSliceAssumeCapacity("WEBP");
        // VP8X: animation (0x02) and alpha (0x10) flags, then the canvas size minus one.
        out.appendSliceAssumeCapacity("VP8X");
        try putU32(&out, gpa, 10);
        try out.appendSlice(gpa, &.{ 0x12, 0, 0, 0 });
        try put24(&out, gpa, b.w - 1);
        try put24(&out, gpa, b.h - 1);
        // ANIM: transparent background, loop forever.
        out.appendSliceAssumeCapacity("ANIM");
        try putU32(&out, gpa, 6);
        try out.appendSlice(gpa, &.{ 0, 0, 0, 0, 0, 0 });
        try out.appendSlice(gpa, b.frames.items);
        return out.toOwnedSlice(gpa);
    }
};

/// What goes inside an ANMF chunk after its 16-byte header: the frame's image data
/// chunk, exactly as the encoder wrote it (padding included). Only a lossless
/// (VP8L) image of the right size is accepted.
fn framePayload(file: []const u8, w: u32, h: u32) Error![]const u8 {
    if (file.len < 12 + 8 + 5 or !std.mem.eql(u8, file[0..4], "RIFF") or !std.mem.eql(u8, file[8..12], "WEBP")) return error.BadFrame;
    const end = @as(usize, 8) + std.mem.readInt(u32, file[4..8], .little);
    if (end > file.len or end < 12 + 8 + 5) return error.BadFrame;
    const payload = file[12..end];
    if (!std.mem.eql(u8, payload[0..4], "VP8L")) return error.BadFrame;
    // A single chunk and nothing else (no ICC profile, EXIF...).
    const size: usize = std.mem.readInt(u32, payload[4..8], .little);
    if (8 + size + (size & 1) != payload.len or size < 5) return error.BadFrame;
    // VP8L header: signature 0x2f, then 14 bits of width-1 and 14 bits of height-1.
    if (payload[8] != 0x2f) return error.BadFrame;
    const bits = std.mem.readInt(u32, payload[9..13], .little);
    if ((bits & 0x3fff) + 1 != w or ((bits >> 14) & 0x3fff) + 1 != h) return error.BadFrame;
    return payload;
}

fn putU32(list: *std.ArrayList(u8), gpa: std.mem.Allocator, v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    try list.appendSlice(gpa, &b);
}

fn put24(list: *std.ArrayList(u8), gpa: std.mem.Allocator, v: u32) !void {
    try list.appendSlice(gpa, &.{ @truncate(v), @truncate(v >> 8), @truncate(v >> 16) });
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

/// A stand-in for what `WebPEncodeLosslessRGBA` returns: RIFF, WEBP, one VP8L chunk
/// whose header carries the size. The rest of the bitstream is arbitrary bytes.
fn fakeFrame(gpa: std.mem.Allocator, w: u32, h: u32, body_len: usize, fill: u8) ![]u8 {
    const chunk_len = 5 + body_len;
    const padded = chunk_len + (chunk_len & 1);
    var f: std.ArrayList(u8) = .empty;
    errdefer f.deinit(gpa);
    try f.appendSlice(gpa, "RIFF");
    try putU32(&f, gpa, @intCast(4 + 8 + padded));
    try f.appendSlice(gpa, "WEBPVP8L");
    try putU32(&f, gpa, @intCast(chunk_len));
    try f.append(gpa, 0x2f);
    var hdr: [4]u8 = undefined;
    std.mem.writeInt(u32, &hdr, (w - 1) | ((h - 1) << 14), .little);
    try f.appendSlice(gpa, &hdr);
    try f.appendNTimes(gpa, fill, body_len);
    if (chunk_len & 1 == 1) try f.append(gpa, 0);
    return f.toOwnedSlice(gpa);
}

test "frames are wrapped into a well-formed animation" {
    const gpa = testing.allocator;
    var b = try Builder.init(gpa, 300, 200, 1 << 20, 10);
    defer b.deinit();
    const f1 = try fakeFrame(gpa, 300, 200, 40, 0xa1); // even chunk
    defer gpa.free(f1);
    const f2 = try fakeFrame(gpa, 300, 200, 41, 0xb2); // odd chunk: padded
    defer gpa.free(f2);
    try b.addFrame(f1, 100);
    try b.addFrame(f2, 0x2000000); // clamped to 24 bits
    const out = try b.finish();
    defer gpa.free(out);

    // RIFF header and sizes.
    try testing.expectEqualStrings("RIFF", out[0..4]);
    try testing.expectEqual(out.len - 8, std.mem.readInt(u32, out[4..8], .little));
    try testing.expectEqualStrings("WEBP", out[8..12]);
    // VP8X: animation + alpha, canvas 300x200.
    try testing.expectEqualStrings("VP8X", out[12..16]);
    try testing.expectEqual(@as(u32, 10), std.mem.readInt(u32, out[16..20], .little));
    try testing.expectEqual(@as(u8, 0x12), out[20]);
    try testing.expectEqual(@as(u32, 299), @as(u32, out[24]) | @as(u32, out[25]) << 8 | @as(u32, out[26]) << 16);
    try testing.expectEqual(@as(u32, 199), @as(u32, out[27]) | @as(u32, out[28]) << 8 | @as(u32, out[29]) << 16);
    // ANIM: transparent background, loop forever.
    try testing.expectEqualStrings("ANIM", out[30..34]);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 0 }, out[38..44]);
    // The two ANMF frames, with the encoder's chunk copied untouched.
    var pos: usize = 44;
    const want = [_]struct { src: []const u8, dur: u32 }{ .{ .src = f1, .dur = 100 }, .{ .src = f2, .dur = 0xffffff } };
    for (want) |w| {
        try testing.expectEqualStrings("ANMF", out[pos..][0..4]);
        const size = std.mem.readInt(u32, out[pos + 4 ..][0..4], .little);
        const body = out[pos + 8 ..][0..size];
        try testing.expectEqual(@as(u32, 0), @as(u32, body[0]) | @as(u32, body[1]) << 8 | @as(u32, body[2]) << 16);
        try testing.expectEqual(@as(u32, 299), @as(u32, body[6]) | @as(u32, body[7]) << 8 | @as(u32, body[8]) << 16);
        try testing.expectEqual(@as(u32, 199), @as(u32, body[9]) | @as(u32, body[10]) << 8 | @as(u32, body[11]) << 16);
        try testing.expectEqual(w.dur, @as(u32, body[12]) | @as(u32, body[13]) << 8 | @as(u32, body[14]) << 16);
        try testing.expectEqual(@as(u8, 0b10), body[15]);
        try testing.expectEqualSlices(u8, w.src[12..], body[16..]);
        try testing.expect(size % 2 == 0);
        pos += 8 + size;
    }
    try testing.expectEqual(out.len, pos);
}

test "anything but a lone lossless image of the canvas size is refused" {
    const gpa = testing.allocator;
    var b = try Builder.init(gpa, 8, 8, 1 << 20, 2);
    defer b.deinit();
    const wrong_size = try fakeFrame(gpa, 9, 8, 20, 1);
    defer gpa.free(wrong_size);
    try testing.expectError(error.BadFrame, b.addFrame(wrong_size, 10));
    try testing.expectError(error.BadFrame, b.addFrame("not a webp file at all, but long enough", 10));
    const good = try fakeFrame(gpa, 8, 8, 20, 1);
    defer gpa.free(good);
    // Lossy data, an extra chunk after the image, or a truncated file.
    const lossy = try gpa.dupe(u8, good);
    defer gpa.free(lossy);
    lossy[15] = ' ';
    try testing.expectError(error.BadFrame, b.addFrame(lossy, 10));
    const extra = try gpa.alloc(u8, good.len + 8);
    defer gpa.free(extra);
    @memcpy(extra[0..good.len], good);
    @memcpy(extra[good.len..], "EXIF\x00\x00\x00\x00");
    std.mem.writeInt(u32, extra[4..8], @intCast(extra.len - 8), .little);
    try testing.expectError(error.BadFrame, b.addFrame(extra, 10));
    try testing.expectError(error.BadFrame, b.addFrame(good[0 .. good.len - 4], 10));
    try testing.expectError(error.BadFrame, b.finish()); // nothing was accepted
}

test "limits" {
    const gpa = testing.allocator;
    try testing.expectError(error.BadFrame, Builder.init(gpa, 0, 8, 100, 1));
    try testing.expectError(error.BadFrame, Builder.init(gpa, max_side + 1, 8, 100, 1));
    const f = try fakeFrame(gpa, 8, 8, 20, 1);
    defer gpa.free(f);
    var few = try Builder.init(gpa, 8, 8, 1 << 20, 1);
    defer few.deinit();
    try few.addFrame(f, 10);
    try testing.expectError(error.TooManyFrames, few.addFrame(f, 10));
    var small = try Builder.init(gpa, 8, 8, 20, 5);
    defer small.deinit();
    try testing.expectError(error.TooBig, small.addFrame(f, 10));
}
