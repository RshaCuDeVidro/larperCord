//! O ícone do larperCord no menu de aplicativos do Linux, que também é o das
//! barras de tarefas do Wayland (elas acham o ícone pelo app_id, no arquivo
//! .desktop, `Icon=larpercord`). O install.sh deixa o desenho em
//! ~/.local/share/icons/hicolor/128x128/apps/larpercord.png; o pacote do AUR
//! instala em /usr/share/pixmaps, e um arquivo com o mesmo nome na pasta do
//! usuário passa na frente. Ao trocar o mascote, o app grava ali o escolhido.
const std = @import("std");
const c = @import("c");
const sys = @import("sys.zig");
const fsutil = @import("fsutil.zig");

const linux = @import("builtin").os.tag == .linux;
const rel_dir = "icons/hicolor/128x128/apps";

fn env(name: [*:0]const u8) ?[]const u8 {
    const v = c.getenv(name) orelse return null;
    const s = std.mem.span(v);
    return if (s.len > 0) s else null;
}

/// $XDG_DATA_HOME ou ~/.local/share.
fn dataHome(buf: []u8) ?[]const u8 {
    if (env("XDG_DATA_HOME")) |x| return x;
    const home = env("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.local/share", .{home}) catch null;
}

/// O arquivo tem exatamente estes bytes?
fn same(path: [*:0]const u8, want: []const u8) bool {
    const fd = c.open(path, c.O_RDONLY | c.O_CLOEXEC);
    if (fd < 0) return false;
    defer _ = c.close(fd);
    var buf: [4096]u8 = undefined;
    var off: usize = 0;
    while (true) {
        const n = c.read(fd, &buf, buf.len);
        if (n < 0) return false;
        if (n == 0) return off == want.len;
        const got = buf[0..@intCast(n)];
        if (off + got.len > want.len or !std.mem.eql(u8, got, want[off .. off + got.len])) return false;
        off += got.len;
    }
}

/// Grava `png` como o ícone do usuário se ele já existe (veio do install.sh ou de
/// uma troca antes) ou se o mascote não é o principal (`create`). O mesmo
/// desenho que já está lá não é regravado. Fora do Linux, nada.
pub fn sync(png: []const u8, create: bool) bool {
    if (!linux or sys.web) return false;
    var hb: [512]u8 = undefined;
    const base = dataHome(&hb) orelse return false;
    var db: [640]u8 = undefined;
    const dir = std.fmt.bufPrint(&db, "{s}/{s}", .{ base, rel_dir }) catch return false;
    var pb: [700]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&pb, "{s}/larpercord.png", .{dir}, 0) catch return false;
    if (sys.exists(path)) {
        if (same(path, png)) return false;
    } else if (!create) return false;
    if (!fsutil.ensureDir(dir)) return false;
    var tb: [710]u8 = undefined;
    const tmp = std.fmt.bufPrintSentinel(&tb, "{s}.tmp", .{path}, 0) catch return false;
    if (!sys.writeNew(tmp, png, false) or !sys.replaceFile(tmp, path)) return false;
    // O ícone é lido pelo painel e pelo menu (do mesmo usuário), mas o padrão de
    // `writeNew` é só do dono: aqui pode ser lido por todos, como os outros ícones.
    _ = c.chmod(path.ptr, 0o644);
    // Pasta com data nova: o cache de ícones do GTK vê que ficou velho.
    var hdb: [600]u8 = undefined;
    if (std.fmt.bufPrintSentinel(&hdb, "{s}/icons/hicolor", .{base}, 0)) |hicolor| {
        _ = c.utimensat(c.AT_FDCWD, hicolor.ptr, null, 0);
    } else |_| {}
    return true;
}
