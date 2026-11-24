//! Comprime um arquivo em deflate puro (sem cabeçalho), no nível mais alto, na hora do
//! build: os textos grandes que vão dentro do executável (as traduções, o changelog,
//! a tabela de emoji) entram assim e só abrem quando alguém precisa (core/embutido.zig).
//!   comprimir <entrada> <saída>
//!   comprimir --i18n <entrada> <saída>   um arquivo de tradução: o cabeçalho dele (quem é o
//!                                         idioma) vai antes, sem comprimir (core/i18n_cabecalho.zig)
const std = @import("std");
const flate = std.compress.flate;
const cabecalho = @import("cabecalho");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const all = try init.minimal.args.toSlice(init.arena.allocator());
    const i18n = all.len == 4 and std.mem.eql(u8, all[1], "--i18n");
    const args = if (i18n) all[1..] else all;
    if (args.len != 3) return error.Uso;
    const cwd = std.Io.Dir.cwd();
    const data = try cwd.readFileAlloc(io, args[1], gpa, .unlimited);
    defer gpa.free(data);

    // O Compress exige espaço no escritor desde o começo.
    var out = try std.Io.Writer.Allocating.initCapacity(gpa, data.len / 2 + 64);
    defer out.deinit();
    if (i18n) {
        const head_buf = try gpa.alloc(u8, data.len);
        defer gpa.free(head_buf);
        const head = cabecalho.extract(data, head_buf);
        try out.writer.writeInt(u32, @intCast(head.len), .little);
        try out.writer.writeAll(head);
    }
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    var c = try flate.Compress.init(&out.writer, window, .raw, .best);
    try c.writer.writeAll(data);
    try c.finish();
    try cwd.writeFile(io, .{ .sub_path = args[2], .data = out.written() });
}
