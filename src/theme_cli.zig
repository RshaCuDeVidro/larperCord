//! Os temas pela linha de comando, sem janela e sem SDL_Init (só o SDL_LoadFile para ler):
//!   --theme-schema              o esquema em JSON (theme/schema.zig)
//!   --theme-check [--strict] ARQ…  carrega cada arquivo com o carregador do app, nos dois
//!                               modos e com as opções ligadas e desligadas, e mostra
//!                               `arquivo:linha:coluna: error|warning: mensagem`
//! Sai com 1 quando há erro (com --strict, também com aviso).
const std = @import("std");
const c = @import("c");
const theme = @import("theme/theme.zig");
const schema = @import("theme/schema.zig");
const bases = @import("theme/bases.zig");
const manager = @import("theme/manager.zig");
const ctl_cli = @import("ctl_cli.zig");

const gpa = std.heap.c_allocator;

pub fn printSchema() u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    schema.writeJson(gpa, &out) catch return 1;
    return if (ctl_cli.write(.out, out.items)) 0 else 1;
}

pub fn check(paths: []const [:0]const u8, strict: bool) u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var errors: usize = 0;
    var warnings: usize = 0;
    for (paths) |path| {
        var report: schema.Report = .{ .gpa = gpa };
        defer report.deinit();
        checkFile(path, &report) catch report.add(.{ .severity = .@"error", .line = 0, .col = 0, .message = "out of memory" }) catch {};
        std.mem.sort(schema.Issue, report.items.items, {}, before);
        for (report.items.items) |it| {
            if (it.severity == .@"error") errors += 1 else warnings += 1;
            out.print(gpa, "{s}:{d}:{d}: {s}: {s}\n", .{ if (it.file.len > 0) it.file else path, it.line, it.col, if (it.severity == .@"error") "error" else "warning", it.message }) catch {};
        }
    }
    if (paths.len == 0) out.appendSlice(gpa, "larpercord --theme-check [--strict] ARQUIVO.kdl…\n") catch {};
    _ = ctl_cli.write(.out, out.items);
    if (paths.len == 0) return 2;
    return if (errors > 0 or (strict and warnings > 0)) 1 else 0;
}

fn before(_: void, a: schema.Issue, b: schema.Issue) bool {
    const f = std.mem.order(u8, a.file, b.file);
    if (f != .eq) return f == .lt;
    if (a.line != b.line) return a.line < b.line;
    return a.col < b.col;
}

/// As bases de `extends`: a pasta do arquivo, a de temas do usuário, ./themes e os embutidos.
fn baseDirs(path: []const u8, config: ?[]const u8, order: *[3][]const u8) bases.Dirs {
    order.* = .{ std.fs.path.dirname(path) orelse ".", config orelse "", "themes" };
    return .{ .dirs = order, .read = manager.readFile };
}

/// Os dois modos, e as opções no padrão, todas ligadas e todas desligadas: um bloco
/// `colors when=opcao` com uma cor errada também aparece.
fn checkFile(path: [:0]const u8, report: *schema.Report) !void {
    var size: usize = 0;
    const data = c.SDL_LoadFile(path.ptr, &size) orelse
        return report.add(.{ .severity = .@"error", .line = 0, .col = 0, .message = "can't read the file" });
    defer c.SDL_free(data);
    const src = @as([*]const u8, @ptrCast(data))[0..size];
    const config = manager.configDir(gpa);
    defer if (config) |cfg| gpa.free(cfg);
    var order: [3][]const u8 = undefined;
    const dirs = baseDirs(path, config, &order);
    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }
    for ([_]theme.Mode{ .dark, .light }) |mode| for (0..3) |round| {
        var ov: std.StringHashMapUnmanaged(bool) = .empty;
        defer ov.deinit(gpa);
        if (round > 0) for (names.items) |n| try ov.put(gpa, n, round == 1);
        var diag: theme.Diagnostic = .{};
        var t = theme.loadWith(gpa, src, .{ .mode = mode, .overrides = &ov, .report = report, .bases = dirs.bases(), .self = path }, &diag) catch |err| {
            if (err == error.OutOfMemory) return err;
            try report.add(.{ .severity = .@"error", .file = diag.file, .line = diag.line, .col = diag.column, .message = diag.message });
            if (names.items.len == 0) break;
            continue;
        };
        defer t.deinit();
        if (names.items.len == 0) for (t.options) |o| try names.append(gpa, try gpa.dupe(u8, o.name));
        // Sem opções, as outras duas voltas seriam iguais à primeira.
        if (names.items.len == 0) break;
    };
}
