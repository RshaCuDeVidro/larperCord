//! Os textos grandes de dentro do executável (as traduções em japonês e russo, o
//! changelog, a tabela de emoji) entram comprimidos em deflate (tools/comprimir.zig, na
//! hora do build) e abrem aqui quando alguém precisa: ~580 KB de texto viram ~170 KB no
//! binário. Um texto aberto fica aberto até o app fechar (quem o usa guarda pedaços dele).
const std = @import("std");
const flate = std.compress.flate;

/// O texto de `packed` (deflate puro), num buffer novo de `gpa`.
pub fn inflate(gpa: std.mem.Allocator, packed_text: []const u8) ![]u8 {
    var in: std.Io.Reader = .fixed(packed_text);
    var window: [flate.max_window_len]u8 = undefined;
    var d: flate.Decompress = .init(&in, .raw, &window);
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    _ = d.reader.streamRemaining(&out.writer) catch |e| switch (e) {
        error.ReadFailed => return d.err orelse error.ReadFailed,
        error.WriteFailed => return error.OutOfMemory,
    };
    return out.toOwnedSlice();
}

/// Um texto aberto uma vez só, na primeira vez que alguém pede (de qualquer thread).
/// Sem memória ou com o texto estragado (não acontece com o do build), fica vazio.
pub fn Lazy(comptime packed_text: []const u8) type {
    return struct {
        var state: std.atomic.Value(u8) = .init(0);
        var text: []const u8 = "";

        pub fn get() []const u8 {
            if (state.load(.acquire) == 2) return text;
            if (state.cmpxchgStrong(0, 1, .acquire, .monotonic) == null) {
                text = inflate(std.heap.page_allocator, packed_text) catch "";
                state.store(2, .release);
                return text;
            }
            while (state.load(.acquire) != 2) std.atomic.spinLoopHint();
            return text;
        }
    };
}

const t = std.testing;

fn pack(gpa: std.mem.Allocator, data: []const u8) ![]u8 {
    var out = try std.Io.Writer.Allocating.initCapacity(gpa, data.len / 2 + 64);
    errdefer out.deinit();
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    var c = try flate.Compress.init(&out.writer, window, .raw, .best);
    try c.writer.writeAll(data);
    try c.finish();
    return out.toOwnedSlice();
}

test "comprime e abre de volta, igual, também maior que a janela" {
    const big = try t.allocator.alloc(u8, 200_000);
    defer t.allocator.free(big);
    for (big, 0..) |*b, i| b.* = "texto de exemplo|palavras|emoji\n"[i % 32] +% @as(u8, @intCast(i / 70_000));
    const p = try pack(t.allocator, big);
    defer t.allocator.free(p);
    try t.expect(p.len < big.len / 4);
    const back = try inflate(t.allocator, p);
    defer t.allocator.free(back);
    try t.expectEqualSlices(u8, big, back);
}

test "texto estragado dá erro, não lixo" {
    try t.expectError(error.EndOfStream, inflate(t.allocator, &.{0x05}));
}
