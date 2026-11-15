//! An animated PNG (APNG) as an animated WebP. Discord shows an uploaded APNG as
//! its first frame only, while an animated WebP plays, so an APNG sticker is
//! converted before it is sent. Decoding each frame's PNG and encoding each frame
//! as lossless WebP are left to the caller (`codecs`), which keeps this file free
//! of C and lets a test stand in for both.
const std = @import("std");
const apng = @import("apng.zig");
const webp_anim = @import("../core/webp_anim.zig");

/// Larger canvases than this aren't stickers.
pub const max_side = 1024;

/// `codecs.decode(png, w, h, rgba_out) bool` turns one frame's PNG into RGBA, as
/// `apng.play` wants. `codecs.encode(rgba, w, h) ?[]u8` returns a complete lossless
/// WebP file of that RGBA frame, allocated with `gpa`. Returns the animated WebP
/// (owned by the caller, allocated with `gpa`), or null when `data` isn't an
/// animation, can't be converted, or doesn't fit in `max_bytes` or `max_frames`: the
/// caller then sends the PNG as it is.
pub fn toWebp(gpa: std.mem.Allocator, data: []const u8, codecs: anytype, max_bytes: usize, max_frames: usize) ?[]u8 {
    if (!apng.isAnimated(data)) return null;
    const head = apng.Frames.init(data) catch return null;
    if (head.w > max_side or head.h > max_side) return null;
    var builder = webp_anim.Builder.init(gpa, head.w, head.h, max_bytes, max_frames) catch return null;
    defer builder.deinit();

    const Ctx = struct {
        codecs: @TypeOf(codecs),
        gpa: std.mem.Allocator,
        builder: *webp_anim.Builder,
        failed: bool = false,

        pub fn decode(x: *@This(), png: []const u8, w: u32, h: u32, out: []u8) bool {
            return x.codecs.decode(png, w, h, out);
        }

        pub fn emit(x: *@This(), rgba: []const u8, w: u32, h: u32, delay_ms: u32) bool {
            const file = x.codecs.encode(rgba, w, h) orelse {
                x.failed = true;
                return false;
            };
            defer x.gpa.free(file);
            // The same timing rule as the app's own player: 10 ms or less means 100 ms.
            x.builder.addFrame(file, if (delay_ms <= 10) 100 else @min(delay_ms, 60_000)) catch {
                x.failed = true;
                return false;
            };
            return true;
        }
    };
    var ctx: Ctx = .{ .codecs = codecs, .gpa = gpa, .builder = &builder };
    const frames = apng.play(gpa, data, max_side, &ctx) catch return null;
    // One frame is a still picture: the PNG already is that.
    if (ctx.failed or frames < 2) return null;
    return builder.finish() catch null;
}
