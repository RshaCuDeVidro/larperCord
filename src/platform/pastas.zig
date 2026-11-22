//! Pastas do sistema para salvar arquivos: a Downloads (o user-dirs.dirs do XDG no
//! Linux, a Known Folder no Windows) e abrir um arquivo ou a pasta dele no
//! gerenciador de arquivos.
const std = @import("std");
const c = @import("c");
const sys = @import("sys.zig");
const salvar = @import("../core/salvar.zig");

/// O QA troca a casa e as configurações por pastas dele (qa-out/…): a Downloads de
/// verdade nunca recebe nada dos testes.
pub var qa_home: ?[]const u8 = null;
pub var qa_config: ?[]const u8 = null;

fn env(name: [*:0]const u8) ?[]const u8 {
    const v = c.SDL_getenv(name) orelse return null;
    const s = std.mem.span(v);
    return if (s.len > 0) s else null;
}

/// A pasta Downloads da pessoa (criada se ainda não existe). null = não deu.
pub fn downloads(buf: []u8) ?[]const u8 {
    if (sys.windows and qa_home == null) return windowsDownloads(buf);
    const home = qa_home orelse env("HOME") orelse return null;
    var cb: [512]u8 = undefined;
    const config = qa_config orelse env("XDG_CONFIG_HOME") orelse (std.fmt.bufPrint(&cb, "{s}/.config", .{home}) catch return null);
    var pb: [600]u8 = undefined;
    const dirs_file = std.fmt.bufPrintSentinel(&pb, "{s}/user-dirs.dirs", .{config}, 0) catch return null;
    var size: usize = 0;
    const found: ?[]const u8 = if (c.SDL_LoadFile(dirs_file.ptr, &size)) |data| blk: {
        defer c.SDL_free(data);
        const text = @as([*]const u8, @ptrCast(data))[0..size];
        var tmp: [512]u8 = undefined;
        const d = salvar.downloadsFromUserDirs(&tmp, text, home) orelse break :blk null;
        if (d.len > buf.len) break :blk null;
        @memcpy(buf[0..d.len], d);
        break :blk buf[0..d.len];
    } else null;
    const dir = found orelse (std.fmt.bufPrint(buf, "{s}/Downloads", .{std.mem.trimEnd(u8, home, "/")}) catch return null);
    return if (ensure(dir)) dir else null;
}

/// Cria a pasta e as de cima que faltarem (com a permissão de sempre: é pasta da
/// pessoa, não nossa).
fn ensure(dir: []const u8) bool {
    var b: [600]u8 = undefined;
    if (dir.len == 0 or dir.len >= b.len) return false;
    @memcpy(b[0..dir.len], dir);
    b[dir.len] = 0;
    return c.SDL_CreateDirectory(@ptrCast(&b));
}

/// FOLDERID_Downloads {374DE290-123F-4565-9164-39C4925E467B}: escrito aqui para não
/// depender do uuid.lib ter o símbolo.
const folderid_downloads = if (sys.windows) c.GUID{
    .Data1 = 0x374DE290,
    .Data2 = 0x123F,
    .Data3 = 0x4565,
    .Data4 = .{ 0x91, 0x64, 0x39, 0xC4, 0x92, 0x5E, 0x46, 0x7B },
} else {};

fn windowsDownloads(buf: []u8) ?[]const u8 {
    if (!sys.windows) return null;
    var wide: c.PWSTR = null;
    // A Known Folder: segue a pasta mesmo se a pessoa mudou de lugar (outro disco).
    if (c.SHGetKnownFolderPath(&folderid_downloads, 0, null, &wide) == 0) {
        defer c.CoTaskMemFree(@ptrCast(wide));
        const n = c.WideCharToMultiByte(c.CP_UTF8, 0, wide, -1, buf.ptr, @intCast(buf.len), null, null);
        if (n > 1) {
            const dir = buf[0..@intCast(n - 1)];
            if (ensure(dir)) return dir;
        }
    }
    // Sem a Known Folder: %USERPROFILE%\Downloads.
    const profile = env("USERPROFILE") orelse return null;
    const dir = std.fmt.bufPrint(buf, "{s}\\Downloads", .{profile}) catch return null;
    return if (ensure(dir)) dir else null;
}

/// O que o QA pediu para abrir (no QA nada abre de verdade).
pub var qa_opened: [600]u8 = undefined;
pub var qa_opened_len: usize = 0;
pub var qa_opens: u32 = 0;

/// Abre o arquivo no programa padrão, ou a pasta no gerenciador de arquivos.
pub fn open(path: []const u8, qa_mode: bool) void {
    if (qa_mode) {
        const n = @min(path.len, qa_opened.len);
        @memcpy(qa_opened[0..n], path[0..n]);
        qa_opened_len = n;
        qa_opens += 1;
        return;
    }
    var ub: [1400]u8 = undefined;
    const url = fileUrl(&ub, path) orelse return;
    _ = c.SDL_OpenURL(url.ptr);
}

/// A pasta onde o arquivo está.
pub fn dirOf(path: []const u8) []const u8 {
    const i = std.mem.lastIndexOfAny(u8, path, "/\\") orelse return ".";
    return if (i == 0) path[0..1] else path[0..i];
}

/// file:///caminho, com o que não pode ir num endereço em %xx (espaço, #, ?, %, acentos).
pub fn fileUrl(buf: []u8, path: []const u8) ?[:0]const u8 {
    var n: usize = 0;
    const head: []const u8 = if (path.len > 0 and path[0] != '/') "file:///" else "file://";
    if (head.len >= buf.len) return null;
    @memcpy(buf[0..head.len], head);
    n = head.len;
    for (path) |ch0| {
        const ch: u8 = if (ch0 == '\\') '/' else ch0;
        const plain = std.ascii.isAlphanumeric(ch) or std.mem.indexOfScalar(u8, "/-._~:()", ch) != null;
        if (plain) {
            if (n + 2 > buf.len) return null;
            buf[n] = ch;
            n += 1;
        } else {
            if (n + 4 > buf.len) return null;
            _ = std.fmt.bufPrint(buf[n .. n + 3], "%{X:0>2}", .{ch}) catch return null;
            n += 3;
        }
    }
    buf[n] = 0;
    return buf[0..n :0];
}

test "endereço file:// de um caminho com espaço e acento" {
    var b: [256]u8 = undefined;
    try std.testing.expectEqualStrings("file:///home/ana/Downloads/foto%20(1).png", fileUrl(&b, "/home/ana/Downloads/foto (1).png").?);
    try std.testing.expectEqualStrings("file:///home/ana/a%C3%A7a%C3%AD%23.txt", fileUrl(&b, "/home/ana/açaí#.txt").?);
    try std.testing.expectEqualStrings("file:///C:/Users/Ana/Downloads/x.gif", fileUrl(&b, "C:\\Users\\Ana\\Downloads\\x.gif").?);
    try std.testing.expectEqualStrings("/home/ana", dirOf("/home/ana/x.png"));
    try std.testing.expectEqualStrings("C:\\Users", dirOf("C:\\Users\\x.png"));
}
