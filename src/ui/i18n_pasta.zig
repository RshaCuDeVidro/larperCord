//! A pasta de traduções: <config>/larpercord/i18n/*.kdl (~/.config/larpercord/i18n no
//! Linux, ou $XDG_CONFIG_HOME/larpercord/i18n; %APPDATA%\larpercord\i18n no Windows). Um
//! arquivo de lá com um código novo é um idioma novo; com o código de um embutido, vale por
//! cima dele (ui/i18n.zig). O vigia (platform/vigia.zig, o mesmo dos temas) relê a pasta
//! quando um arquivo é salvo: a tradução muda na hora, sem reabrir o app.
const std = @import("std");
const c = @import("c");
const i18n = @import("i18n.zig");
const fsutil = @import("../platform/fsutil.zig");
const sys = @import("../platform/sys.zig");
const vigia = @import("../platform/vigia.zig");

/// Arquivo maior que isto nem é lido (o ja.kdl inteiro tem uns 150 KB).
pub const max_file_bytes = 2 * 1024 * 1024;
/// Quantos arquivos são lidos (os primeiros pelo nome).
const max_files = 32;

var watching = false;
var wake_fn: ?*const fn () void = null;
/// O QA lê uma pasta dele (dentro de qa-out/), nunca a de quem roda.
var override_buf: [512]u8 = undefined;
var override: ?[:0]const u8 = null;

pub fn dir(buf: []u8) ?[:0]const u8 {
    if (override) |o| {
        if (o.len >= buf.len) return null;
        @memcpy(buf[0..o.len], o);
        buf[o.len] = 0;
        return buf[0..o.len :0];
    }
    return fsutil.configPath(buf, "i18n");
}

fn isDir(path: [:0]const u8) bool {
    var info: c.SDL_PathInfo = undefined;
    return c.SDL_GetPathInfo(path.ptr, &info) and info.type == c.SDL_PATHTYPE_DIRECTORY;
}

/// Na abertura: guarda quem acordar quando a pasta mudar e, se ela existe e `watch` (fora
/// do QA e dos prints, que não leem a pasta de quem roda), vigia.
pub fn setup(wake: *const fn () void, watch: bool) void {
    wake_fn = wake;
    if (watch) startWatch();
}

fn startWatch() void {
    if (watching) return;
    const w = wake_fn orelse return;
    var buf: [512]u8 = undefined;
    const d = dir(&buf) orelse return;
    if (!isDir(d)) return;
    watching = vigia.watch(&.{d}, null, w, "i18n-watch");
}

/// Lê todos os .kdl da pasta e passa para o i18n. Verdadeiro se o texto do idioma em uso
/// mudou. Só na thread da interface, fora do desenho de um quadro.
pub fn reload() bool {
    // Uma pasta criada com o app aberto passa a ser vigiada quando é lida.
    startWatch();
    var files: [max_files]i18n.UserFile = undefined;
    var datas: [max_files]?*anyopaque = @splat(null);
    var n: usize = 0;
    defer for (datas[0..n]) |p| if (p) |q| c.SDL_free(q);
    var buf: [512]u8 = undefined;
    const d = dir(&buf) orelse return i18n.setUserFiles(&.{});
    if (!isDir(d)) return i18n.setUserFiles(&.{});
    var count: c_int = 0;
    const flags: c.SDL_GlobFlags = if (sys.windows) c.SDL_GLOB_CASEINSENSITIVE else 0;
    const names = c.SDL_GlobDirectory(d.ptr, "*.kdl", flags, &count) orelse return i18n.setUserFiles(&.{});
    defer c.SDL_free(@ptrCast(names));
    var order: [256][]const u8 = undefined;
    var m: usize = 0;
    for (0..@as(usize, @intCast(@max(count, 0)))) |i| {
        if (m == order.len) break;
        const nm = std.mem.span(names[i] orelse continue);
        if (std.mem.indexOfAny(u8, nm, "/\\") != null) continue;
        order[m] = nm;
        m += 1;
    }
    std.mem.sort([]const u8, order[0..m], {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    for (order[0..m]) |name| {
        if (n == max_files) break;
        var pb: [600]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&pb, "{s}/{s}", .{ d, name }, 0) catch continue;
        if (sys.fileSize(path.ptr)) |size| if (size > max_file_bytes) {
            std.log.warn("tradução {s}: grande demais, fica de fora", .{name});
            continue;
        };
        var size: usize = 0;
        const data = c.SDL_LoadFile(path.ptr, &size) orelse continue;
        datas[n] = data;
        var text: []const u8 = @as([*]const u8, @ptrCast(data))[0..size];
        // O "UTF-8 com BOM" do Bloco de Notas: três bytes que não são do texto.
        if (std.mem.startsWith(u8, text, "\xEF\xBB\xBF")) text = text[3..];
        files[n] = .{ .name = name, .text = text };
        n += 1;
    }
    return i18n.setUserFiles(files[0..n]);
}

/// Abre a pasta no gerenciador de arquivos (criando se ainda não existe) e passa a vigiar.
pub fn openFolder() void {
    var buf: [512]u8 = undefined;
    const d = dir(&buf) orelse return;
    if (!fsutil.ensureDir(d)) return;
    startWatch();
    var ub: [700]u8 = undefined;
    const url = std.fmt.bufPrintSentinel(&ub, "file://{s}{s}", .{ if (d.len > 0 and d[0] != '/') "/" else "", d }, 0) catch return;
    for (url) |*ch| {
        if (ch.* == '\\') ch.* = '/';
    }
    _ = c.SDL_OpenURL(url.ptr);
}

/// QA: lê e vigia `path` no lugar da pasta de quem roda.
pub fn qaUseDir(path: []const u8) bool {
    if (path.len >= override_buf.len) return false;
    @memcpy(override_buf[0..path.len], path);
    override_buf[path.len] = 0;
    override = override_buf[0..path.len :0];
    if (!fsutil.ensureDir(path)) return false;
    watching = false;
    startWatch();
    return watching;
}

/// QA: grava um arquivo na pasta (o vigia avisa o app, como ao salvar num editor).
pub fn qaWrite(name: []const u8, text: []const u8) bool {
    var buf: [512]u8 = undefined;
    const d = dir(&buf) orelse return false;
    var pb: [600]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&pb, "{s}/{s}", .{ d, name }, 0) catch return false;
    return fsutil.writePrivate(path, text);
}
