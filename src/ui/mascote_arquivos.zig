//! Os arquivos de mascote: <config>/larpercord/mascots/*.kdl (~/.config/larpercord/mascots
//! no Linux, ou $XDG_CONFIG_HOME/larpercord/mascots; %APPDATA%\larpercord\mascots no
//! Windows). Aqui ficam a lista, a leitura (ui/mascote_visual.zig confere cada arquivo
//! e diz arquivo:linha:coluna do que não deu), o "Salvar como arquivo", o "Abrir pasta"
//! e o vigia que relê a pasta quando algo muda nela (platform/vigia.zig, o mesmo dos
//! temas). A pasta só é lida quando alguém precisa: com um arquivo escolhido, ou a
//! página do mascote aberta.
const std = @import("std");
const c = @import("c");
const v = @import("mascote_visual.zig");
const fsutil = @import("../platform/fsutil.zig");
const sys = @import("../platform/sys.zig");
const vigia = @import("../platform/vigia.zig");

/// Quantos arquivos a lista mostra (os primeiros pelo nome).
pub const max_files = 48;

pub const Entry = struct {
    /// O nome do arquivo sem o ".kdl" (é o que o settings.kdl guarda).
    name: v.Name = .{},
    title: v.Name = .{},
    author: v.Name = .{},
    look: v.Look = .{},
    drawing: ?*v.Drawing = null,
    problem: ?v.Problem = null,
};

var entries: [max_files]Entry = undefined;
var count: usize = 0;
/// Muda a cada leitura da pasta: os desenhos de antes deixam de valer.
pub var generation: u32 = 0;
var scanned = false;
var watching = false;
/// Reler a pasta no começo do próximo quadro: reler no meio de um quadro soltaria os
/// desenhos que o visual de agora ainda usa.
var want_reload = false;
var wake_fn: ?*const fn () void = null;

pub fn dir(buf: []u8) ?[:0]const u8 {
    return fsutil.configPath(buf, "mascots");
}

fn isDir(path: [:0]const u8) bool {
    var info: c.SDL_PathInfo = undefined;
    return c.SDL_GetPathInfo(path.ptr, &info) and info.type == c.SDL_PATHTYPE_DIRECTORY;
}

/// Na abertura do app: guarda quem acordar e, se a pasta já existe, começa a vigiar
/// (sem ler nada ainda).
pub fn setup(wake: *const fn () void) void {
    wake_fn = wake;
    startWatch();
}

fn startWatch() void {
    if (watching) return;
    const w = wake_fn orelse return;
    var buf: [512]u8 = undefined;
    const d = dir(&buf) orelse return;
    if (!isDir(d)) return;
    watching = vigia.watch(&.{d}, null, w, "mascot-watch");
}

pub fn list() []const Entry {
    return entries[0..count];
}

pub fn find(name: []const u8) ?*const Entry {
    for (entries[0..count]) |*e| if (std.mem.eql(u8, e.name.slice(), name)) return e;
    return null;
}

/// Lê a pasta na primeira vez que alguém precisa.
pub fn ensure() void {
    if (!scanned) reload();
}

/// Pede para reler a pasta antes do próximo quadro (a página abriu, um arquivo foi salvo).
pub fn requestReload() void {
    want_reload = true;
}

/// No começo do quadro, antes de qualquer desenho (ui/mascote.zig `sync`).
pub fn frame() void {
    if (!want_reload) return;
    want_reload = false;
    reload();
}

/// Relê a pasta inteira. Só fora do desenho de um quadro: o vigia avisou (os eventos vêm
/// antes do quadro) ou `frame` (o começo dele); no meio, `requestReload`.
pub fn reload() void {
    scanned = true;
    for (entries[0..count]) |*e| if (e.drawing) |dw| std.heap.c_allocator.destroy(dw);
    count = 0;
    generation +%= 1;
    // Uma pasta criada com o app aberto (pelo "Salvar como arquivo" ou à mão) passa a
    // ser vigiada quando é lida.
    startWatch();
    var buf: [512]u8 = undefined;
    const d = dir(&buf) orelse return;
    if (!isDir(d)) return;
    var n: c_int = 0;
    const flags: c.SDL_GlobFlags = if (sys.windows) c.SDL_GLOB_CASEINSENSITIVE else 0;
    const names = c.SDL_GlobDirectory(d.ptr, "*.kdl", flags, &n) orelse return;
    defer c.SDL_free(@ptrCast(names));
    // Em ordem de nome, para a lista não pular de lugar a cada leitura.
    var order: [256][]const u8 = undefined;
    var m: usize = 0;
    for (0..@intCast(n)) |i| {
        if (m == order.len) break;
        const nm = std.mem.span(names[i] orelse continue);
        // Só arquivos diretos da pasta (o glob não desce, mas confere).
        if (std.mem.indexOfAny(u8, nm, "/\\") != null) continue;
        order[m] = nm;
        m += 1;
    }
    std.mem.sort([]const u8, order[0..m], {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    for (order[0..m]) |file| {
        if (count == max_files) break;
        if (file.len <= 4 or file.len - 4 > v.Name.max_name) continue;
        var e: Entry = .{};
        e.name.set(file[0 .. file.len - 4]);
        e.title.set(e.name.slice());
        load(d, file, &e);
        entries[count] = e;
        count += 1;
    }
}

fn load(d: []const u8, file: []const u8, e: *Entry) void {
    var pb: [600]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&pb, "{s}/{s}", .{ d, file }, 0) catch return;
    // Grande demais nem é lido.
    if (sys.fileSize(path.ptr)) |size| if (size > v.max_file_bytes) {
        e.problem = .{ .line = 1, .col = 1, .issue = .too_big };
        return;
    };
    var size: usize = 0;
    const data = c.SDL_LoadFile(path.ptr, &size) orelse {
        e.problem = .{ .line = 1, .col = 1, .issue = .syntax };
        return;
    };
    defer c.SDL_free(data);
    var src: []const u8 = @as([*]const u8, @ptrCast(data))[0..size];
    // O "UTF-8 com BOM" do Bloco de Notas: três bytes que não são do texto.
    if (std.mem.startsWith(u8, src, "\xEF\xBB\xBF")) src = src[3..];
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    var pr: v.Problem = .{};
    const f = v.parseFile(std.heap.c_allocator, arena.allocator(), src, &pr) orelse {
        e.problem = pr;
        return;
    };
    e.look = f.look;
    e.drawing = f.drawing;
    if (f.drawing) |dw| {
        e.look.drawing = dw;
        e.look.draw_from = e.name;
    }
    if (f.title.len > 0) e.title.set(f.title);
    e.author.set(f.author);
}

/// O nome de arquivo (sem ".kdl") que ainda não existe, a partir de `base`: só letras,
/// números e hífen ("Meu mascote" vira "meu-mascote", e depois "meu-mascote-2"…).
fn freeName(d: []const u8, base: []const u8, out: []u8) ?[]const u8 {
    var slug: [32]u8 = undefined;
    var n: usize = 0;
    var dash = false;
    for (base) |ch| {
        if (n == slug.len) break;
        const lower = std.ascii.toLower(ch);
        if (std.ascii.isAlphanumeric(lower)) {
            slug[n] = lower;
            n += 1;
            dash = false;
        } else if (n > 0 and !dash) {
            slug[n] = '-';
            n += 1;
            dash = true;
        }
    }
    while (n > 0 and slug[n - 1] == '-') n -= 1;
    if (n == 0) {
        @memcpy(slug[0..6], "mascot");
        n = 6;
    }
    var i: usize = 1;
    while (i < 1000) : (i += 1) {
        const name = if (i == 1)
            std.fmt.bufPrint(out, "{s}", .{slug[0..n]}) catch return null
        else
            std.fmt.bufPrint(out, "{s}-{d}", .{ slug[0..n], i }) catch return null;
        var pb: [600]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&pb, "{s}/{s}.kdl", .{ d, name }, 0) catch return null;
        if (!sys.exists(path.ptr)) return name;
    }
    return null;
}

/// Grava o visual num arquivo novo da pasta e devolve o nome dele (sem ".kdl"), ou
/// null se não deu. `title` vai no nó `mascot` e dá o nome do arquivo.
pub fn save(l: *const v.Look, title: []const u8, out: []u8) ?[]const u8 {
    var buf: [512]u8 = undefined;
    const d = dir(&buf) orelse return null;
    if (!fsutil.ensureDir(d)) return null;
    var nb: [64]u8 = undefined;
    const name = freeName(d, title, &nb) orelse return null;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(std.heap.c_allocator);
    v.writeFile(l, .{ .title = title }, &text, std.heap.c_allocator) catch return null;
    var pb: [600]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&pb, "{s}/{s}.kdl", .{ d, name }, 0) catch return null;
    if (!fsutil.writePrivate(path, text.items)) return null;
    if (name.len > out.len) return null;
    @memcpy(out[0..name.len], name);
    requestReload();
    return out[0..name.len];
}

/// Abre a pasta no gerenciador de arquivos (criando se ainda não existe).
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

/// Grava um arquivo qualquer na pasta (o QA monta os de teste assim) e relê.
pub fn qaWrite(name: []const u8, text: []const u8) bool {
    var buf: [512]u8 = undefined;
    const d = dir(&buf) orelse return false;
    if (!fsutil.ensureDir(d)) return false;
    var pb: [600]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&pb, "{s}/{s}.kdl", .{ d, name }, 0) catch return false;
    return fsutil.writePrivate(path, text);
}

/// Apaga os .kdl da pasta (o QA começa do zero; a pasta dele é só dele).
pub fn qaClear() void {
    var buf: [512]u8 = undefined;
    const d = dir(&buf) orelse return;
    if (isDir(d)) {
        var n: c_int = 0;
        if (c.SDL_GlobDirectory(d.ptr, "*.kdl", 0, &n)) |names| {
            defer c.SDL_free(@ptrCast(names));
            for (0..@intCast(n)) |i| {
                const nm = std.mem.span(names[i] orelse continue);
                var pb: [600]u8 = undefined;
                const path = std.fmt.bufPrintSentinel(&pb, "{s}/{s}", .{ d, nm }, 0) catch continue;
                _ = c.SDL_RemovePath(path.ptr);
            }
        }
    }
    requestReload();
}

pub fn qaWatching() bool {
    return watching;
}
