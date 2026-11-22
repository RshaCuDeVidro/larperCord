//! Comprime um arquivo em deflate puro (sem cabeçalho), no nível mais alto, na hora do
//! build: os textos grandes que vão dentro do executável (as traduções, o changelog,
//! a tabela de emoji) entram assim e só abrem quando alguém precisa (core/embutido.zig).
//!   comprimir <entrada> <saída>
const std = @import("std");
const flate = std.compress.flate;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) return error.Uso;
    const cwd = std.Io.Dir.cwd();
    const data = try cwd.readFileAlloc(io, args[1], gpa, .unlimited);
    defer gpa.free(data);

    // O Compress exige espaço no escritor desde o começo.
    var out = try std.Io.Writer.Allocating.initCapacity(gpa, data.len / 2 + 64);
    defer out.deinit();
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    var c = try flate.Compress.init(&out.writer, window, .raw, .best);
    try c.writer.writeAll(data);
    try c.finish();
    try cwd.writeFile(io, .{ .sub_path = args[2], .data = out.written() });
}
