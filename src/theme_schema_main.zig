//! `zig build theme-schema`: grava o esquema dos temas (theme/schema.zig) em JSON, no arquivo
//! que o site e os editores leem (docs/assets/site/theme-schema.json). O teste de
//! src/tests.zig falha quando o arquivo guardado não bate com as tabelas.
//!   theme_schema_main <saída>
const std = @import("std");
const schema = @import("theme/schema.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) return error.Uso;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try schema.writeJson(gpa, &out);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[1], .data = out.items });
}
