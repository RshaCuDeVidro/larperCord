//! As bases de `extends` (heranca.zig): os temas embutidos e os das pastas de temas, na
//! mesma ordem em que o app escolhe um tema pelo nome (a pasta do usuário vence a do
//! repositório, que vence os embutidos).
const std = @import("std");
const builtin_themes = @import("builtin_themes");
const heranca = @import("heranca.zig");

const Base = heranca.Base;

/// Só os embutidos.
pub const builtin: heranca.Bases = .{ .ctx = &builtin_themes.list, .find = findBuiltin };

fn findBuiltin(_: *const anyopaque, a: std.mem.Allocator, name: []const u8, i: usize) ?Base {
    return if (i == 0) builtinBase(a, name) else null;
}

/// O id de um tema embutido (o `self` dele ao carregar).
pub fn builtinId(buf: []u8, name: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "builtin:{s}", .{name}) catch "";
}

pub fn builtinBase(a: std.mem.Allocator, name: []const u8) ?Base {
    for (builtin_themes.list) |b| if (std.mem.eql(u8, b.name, name)) return .{
        .src = b.source,
        .id = std.fmt.allocPrint(a, "builtin:{s}", .{name}) catch return null,
        .label = std.fmt.allocPrint(a, "{s}.kdl (built-in)", .{name}) catch return null,
    };
    return null;
}

/// Só um nome de tema: nada de `../` nem de outra pasta.
fn plainName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64 or name[0] == '.') return false;
    for (name) |ch| if (ch == '/' or ch == '\\' or ch == ':' or ch == 0) return false;
    return true;
}

/// Pastas (da que vence para a de baixo) e, depois delas, os embutidos.
pub const Dirs = struct {
    dirs: []const []const u8,
    /// Lê um arquivo inteiro para a arena do tema (null = não existe ou não abre).
    read: *const fn (a: std.mem.Allocator, path: []const u8) ?[]const u8,

    pub fn bases(d: *const Dirs) heranca.Bases {
        return .{ .ctx = d, .find = find };
    }

    fn find(ctx: *const anyopaque, a: std.mem.Allocator, name: []const u8, i: usize) ?Base {
        const d: *const Dirs = @ptrCast(@alignCast(ctx));
        if (!plainName(name)) return null;
        var k: usize = 0;
        for (d.dirs) |dir| {
            if (dir.len == 0) continue;
            const path = std.fmt.allocPrint(a, "{s}/{s}.kdl", .{ dir, name }) catch return null;
            const src = d.read(a, path) orelse continue;
            if (k == i) return .{ .src = src, .id = path, .label = path };
            k += 1;
        }
        return if (k == i) builtinBase(a, name) else null;
    }
};

test "nome de base não sai da pasta" {
    try std.testing.expect(plainName("classico"));
    try std.testing.expect(!plainName("../segredo"));
    try std.testing.expect(!plainName("a/b"));
    try std.testing.expect(!plainName("C:x"));
    try std.testing.expect(!plainName(""));
}
