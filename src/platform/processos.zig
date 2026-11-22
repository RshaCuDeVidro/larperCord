//! Os processos abertos agora, para o "Jogando …" (core/jogos.zig): o nome do
//! executável e, quando dá, o caminho inteiro. Só lê, e só o que é nosso:
//!  - Linux: o link /proc/<pid>/exe. O de outro usuário o sistema não deixa ler
//!    (e ele fica de fora), as threads do kernel não têm (também). Um jogo do
//!    Wine/Proton aparece pelo .exe do Windows (o argv[0] que o Wine escreve), e
//!    "Z:\…" vira o caminho daqui;
//!  - Windows: a lista do Toolhelp32 (o nome vem nela), só da nossa sessão (o
//!    jogo de outro usuário do computador não é nosso). O caminho inteiro custa
//!    abrir o processo: só para quem a varredura pede.
//! Sem SDL: os testes rodam a varredura de verdade (ela acha o próprio teste). O QA
//! troca a lista por uma de mentira (`fake`).
const std = @import("std");
const builtin = @import("builtin");
const jogos = @import("../core/jogos.zig");
const Proc = jogos.Proc;

const windows = builtin.os.tag == .windows;
/// A demonstração no navegador não tem processos (nem /proc).
const supported = builtin.os.tag == .linux or windows;

/// Os processos da última varredura. Os textos moram em `text` (reaproveitado de
/// uma varredura para a outra).
pub const List = struct {
    procs: std.ArrayList(Proc) = .empty,
    raw: std.ArrayList(Raw) = .empty,
    text: std.ArrayList(u8) = .empty,

    const Raw = struct { pid: u32, name: [2]u32, path: [2]u32 };

    pub fn items(l: *const List) []const Proc {
        return l.procs.items;
    }

    pub fn deinit(l: *List, gpa: std.mem.Allocator) void {
        l.procs.deinit(gpa);
        l.raw.deinit(gpa);
        l.text.deinit(gpa);
        l.* = .{};
    }

    fn clear(l: *List) void {
        l.procs.clearRetainingCapacity();
        l.raw.clearRetainingCapacity();
        l.text.clearRetainingCapacity();
    }

    fn put(l: *List, gpa: std.mem.Allocator, s: []const u8) ![2]u32 {
        const off: u32 = @intCast(l.text.items.len);
        try l.text.appendSlice(gpa, s);
        return .{ off, @intCast(s.len) };
    }

    fn add(l: *List, gpa: std.mem.Allocator, pid: u32, name: []const u8, path: []const u8) void {
        const n = l.put(gpa, name) catch return;
        const p = l.put(gpa, path) catch return;
        l.raw.append(gpa, .{ .pid = pid, .name = n, .path = p }) catch return;
    }

    /// Os textos só param de mudar de lugar no fim: os `Proc` apontam para eles agora.
    fn finish(l: *List, gpa: std.mem.Allocator) void {
        l.procs.ensureTotalCapacity(gpa, l.raw.items.len) catch return;
        const t = l.text.items;
        for (l.raw.items) |r| l.procs.appendAssumeCapacity(.{
            .pid = r.pid,
            .name = t[r.name[0]..][0..r.name[1]],
            .path = t[r.path[0]..][0..r.path[1]],
        });
    }
};

/// O que a varredura precisa: tudo, com o caminho (a lista para escolher um
/// processo aberto), ou só os candidatos aos jogos ligados (a de 15 em 15 s).
pub const Want = union(enum) {
    all,
    games: []const jogos.Entry,
};

/// QA: no lugar dos processos de verdade (os do computador variam de uma máquina para
/// a outra e não são da conta de ninguém).
pub var fake: ?[]const Proc = null;

pub fn scan(l: *List, gpa: std.mem.Allocator, want: Want) void {
    l.clear();
    if (fake) |list| {
        for (list) |p| if (want == .all or jogos.wanted(want.games, p.name, jogos.native)) l.add(gpa, p.pid, p.name, p.path);
    } else if (comptime windows) {
        scanWindows(l, gpa, want);
    } else if (comptime supported) {
        scanLinux(l, gpa, want);
    }
    l.finish(gpa);
}

// --- Linux ---------------------------------------------------------------------

/// Um jogo do Wine/Proton: o executável é o carregador do Wine (wine, wine64,
/// wine64-preloader…), e o .exe de verdade está no argv[0].
fn isWine(base: []const u8) bool {
    return std.mem.startsWith(u8, base, "wine") and !std.mem.eql(u8, base, "wineserver");
}

/// "Z:\home\u\jogo.exe" → "/home/u/jogo.exe" (o Z: do Wine é a raiz daqui). Outra
/// letra fica como veio: ela aponta para dentro do prefixo, que daqui não se sabe.
fn winePath(buf: []u8, argv0: []const u8) []const u8 {
    if (argv0.len < 3 or !(argv0[0] == 'Z' or argv0[0] == 'z') or argv0[1] != ':' or argv0[2] != '\\') return argv0;
    const rest = argv0[2..];
    if (rest.len > buf.len) return argv0;
    for (rest, 0..) |ch, i| buf[i] = if (ch == '\\') '/' else ch;
    return buf[0..rest.len];
}

fn readSmall(path: [*:0]const u8, buf: []u8) []const u8 {
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    if (fd < 0) return "";
    defer _ = std.c.close(fd);
    const n = std.c.read(fd, buf.ptr, buf.len);
    return if (n > 0) buf[0..@intCast(n)] else "";
}

fn scanLinux(l: *List, gpa: std.mem.Allocator, want: Want) void {
    const dir = std.c.opendir("/proc") orelse return;
    defer _ = std.c.closedir(dir);
    var pb: [48]u8 = undefined;
    var link: [4096]u8 = undefined;
    var cmd: [1024]u8 = undefined;
    var conv: [1024]u8 = undefined;
    while (std.c.readdir(dir)) |ent| {
        const dname = std.mem.sliceTo(&ent.name, 0);
        if (dname.len == 0 or dname[0] < '0' or dname[0] > '9') continue;
        const pid = std.fmt.parseInt(u32, dname, 10) catch continue;
        const p = std.fmt.bufPrintSentinel(&pb, "/proc/{s}/exe", .{dname}, 0) catch continue;
        // De outro usuário (sem permissão), do kernel (sem executável) ou já saiu: fora.
        const n = std.c.readlink(p.ptr, &link, link.len);
        if (n <= 0) continue;
        var path: []const u8 = link[0..@intCast(n)];
        // Atualizado com o jogo aberto, o link ganha " (deleted)" no fim.
        if (std.mem.endsWith(u8, path, " (deleted)")) path = path[0 .. path.len - 10];
        var name = jogos.baseName(path);
        if (isWine(name)) {
            const cp = std.fmt.bufPrintSentinel(&pb, "/proc/{s}/cmdline", .{dname}, 0) catch continue;
            const args = readSmall(cp.ptr, &cmd);
            const argv0 = std.mem.sliceTo(args, 0);
            if (argv0.len > 0) {
                path = winePath(&conv, argv0);
                name = jogos.baseName(argv0);
            }
        }
        if (want == .games and !jogos.wanted(want.games, name, .linux)) continue;
        l.add(gpa, pid, name, path);
    }
}

// --- Windows -------------------------------------------------------------------

const DWORD = u32;
const BOOL = c_int;
const HANDLE = ?*anyopaque;
const invalid_handle: usize = std.math.maxInt(usize);
const th32cs_snapprocess: DWORD = 0x00000002;
const process_query_limited_information: DWORD = 0x1000;

/// PROCESSENTRY32W (tlhelp32.h): o `usize` no meio dá o mesmo alinhamento do C em 32 e 64 bits.
const ProcessEntry = extern struct {
    dwSize: DWORD,
    cntUsage: DWORD,
    th32ProcessID: DWORD,
    th32DefaultHeapID: usize,
    th32ModuleID: DWORD,
    cntThreads: DWORD,
    th32ParentProcessID: DWORD,
    pcPriClassBase: c_long,
    dwFlags: DWORD,
    szExeFile: [260]u16,
};

const k32 = struct {
    extern "kernel32" fn CreateToolhelp32Snapshot(flags: DWORD, pid: DWORD) callconv(.winapi) HANDLE;
    extern "kernel32" fn Process32FirstW(snap: HANDLE, pe: *ProcessEntry) callconv(.winapi) BOOL;
    extern "kernel32" fn Process32NextW(snap: HANDLE, pe: *ProcessEntry) callconv(.winapi) BOOL;
    extern "kernel32" fn OpenProcess(access: DWORD, inherit: BOOL, pid: DWORD) callconv(.winapi) HANDLE;
    extern "kernel32" fn QueryFullProcessImageNameW(h: HANDLE, flags: DWORD, name: [*]u16, size: *DWORD) callconv(.winapi) BOOL;
    extern "kernel32" fn ProcessIdToSessionId(pid: DWORD, session: *DWORD) callconv(.winapi) BOOL;
    extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) DWORD;
    extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) BOOL;
};

/// UTF-16 do Windows para UTF-8 (um surrogate solto vira o "?" de sempre do WTF-8).
fn utf8(buf: []u8, w: []const u16) []const u8 {
    // No pior caso cada unidade vira 3 bytes.
    const max = @min(w.len, buf.len / 3);
    return buf[0..std.unicode.wtf16LeToWtf8(buf, w[0..max])];
}

fn fullPath(buf: []u8, pid: DWORD) []const u8 {
    const h = k32.OpenProcess(process_query_limited_information, 0, pid) orelse return "";
    defer _ = k32.CloseHandle(h);
    var wb: [1024]u16 = undefined;
    var size: DWORD = wb.len;
    if (k32.QueryFullProcessImageNameW(h, 0, &wb, &size) == 0) return "";
    return utf8(buf, wb[0..@min(size, wb.len)]);
}

fn scanWindows(l: *List, gpa: std.mem.Allocator, want: Want) void {
    const snap = k32.CreateToolhelp32Snapshot(th32cs_snapprocess, 0) orelse return;
    if (@intFromPtr(snap) == invalid_handle) return;
    defer _ = k32.CloseHandle(snap);
    var mine: DWORD = 0;
    const by_session = k32.ProcessIdToSessionId(k32.GetCurrentProcessId(), &mine) != 0;
    var pe = std.mem.zeroes(ProcessEntry);
    pe.dwSize = @sizeOf(ProcessEntry);
    var nb: [260 * 3]u8 = undefined;
    var pb: [1024 * 3]u8 = undefined;
    var ok = k32.Process32FirstW(snap, &pe);
    while (ok != 0) : (ok = k32.Process32NextW(snap, &pe)) {
        const pid = pe.th32ProcessID;
        // 0 é o Idle e 4 o System: nunca são jogo.
        if (pid == 0 or pid == 4) continue;
        const name = utf8(&nb, std.mem.sliceTo(&pe.szExeFile, 0));
        if (name.len == 0) continue;
        if (want == .games and !jogos.wanted(want.games, name, .windows)) continue;
        if (by_session) {
            var s: DWORD = 0;
            if (k32.ProcessIdToSessionId(pid, &s) == 0 or s != mine) continue;
        }
        const path = if (want == .all or jogos.wantsPath(want.games, name, .windows)) fullPath(&pb, pid) else "";
        l.add(gpa, pid, name, path);
    }
}

// --- Testes -----------------------------------------------------------------------

const testing = std.testing;

fn monoUs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000 + @as(u64, @intCast(ts.nsec)) / 1000;
}

test "varredura de verdade: acha o próprio teste, com o caminho, e é rápida" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var self_buf: [4096]u8 = undefined;
    const n = std.c.readlink("/proc/self/exe", &self_buf, self_buf.len);
    try testing.expect(n > 0);
    const self_path = self_buf[0..@intCast(n)];
    const self_name = jogos.baseName(self_path);
    const me: u32 = @intCast(std.c.getpid());

    var l: List = .{};
    defer l.deinit(testing.allocator);
    const t0 = monoUs();
    scan(&l, testing.allocator, .all);
    const took = monoUs() - t0;
    var found = false;
    for (l.items()) |p| if (p.pid == me) {
        found = true;
        try testing.expectEqualStrings(self_name, p.name);
        try testing.expectEqualStrings(self_path, p.path);
    };
    try testing.expect(found);
    // Só os processos deste usuário (os de outros não deixam ler o link).
    try testing.expect(l.items().len >= 1);
    // (O tempo de cada varredura sai no registro do QA, no passo da varredura de verdade.)
    // Folga grande para a CI lenta: o que importa é não ser coisa de segundos.
    try testing.expect(took < 500_000);

    // Só os candidatos a um jogo da lista: o próprio teste, pelo nome.
    var games: jogos.Lista = .{};
    _ = games.add(self_path, self_path, .linux);
    games.items[0].exact = true;
    scan(&l, testing.allocator, .{ .games = games.slice() });
    try testing.expectEqual(@as(?usize, 0), jogos.firstRunning(games.slice(), l.items(), .linux));
    for (l.items()) |p| try testing.expectEqualStrings(self_name, p.name);
    // Outro caminho com o mesmo nome não serve na opção "só este arquivo".
    games.items[0].path.set("/outro/lugar/nada");
    try testing.expectEqual(@as(?usize, null), jogos.firstRunning(games.slice(), l.items(), .linux));
}

test "Wine: Z: vira a raiz daqui, outra letra fica como veio" {
    var b: [256]u8 = undefined;
    try testing.expectEqualStrings("/home/u/Games/x/Game.exe", winePath(&b, "Z:\\home\\u\\Games\\x\\Game.exe"));
    try testing.expectEqualStrings("C:\\Games\\Game.exe", winePath(&b, "C:\\Games\\Game.exe"));
    try testing.expect(isWine("wine64-preloader") and isWine("wine") and !isWine("wineserver") and !isWine("dota2"));
}

test "a lista de mentira do QA no lugar da varredura" {
    const list = [_]Proc{ .{ .pid = 7, .name = "fakegame.exe", .path = "C:\\Games\\fakegame.exe" }, .{ .pid = 8, .name = "outro" } };
    fake = &list;
    defer fake = null;
    var l: List = .{};
    defer l.deinit(testing.allocator);
    scan(&l, testing.allocator, .all);
    try testing.expectEqual(@as(usize, 2), l.items().len);
    try testing.expectEqualStrings("C:\\Games\\fakegame.exe", l.items()[0].path);
    var games: jogos.Lista = .{};
    _ = games.add("FakeGame.exe", "", jogos.native);
    scan(&l, testing.allocator, .{ .games = games.slice() });
    try testing.expectEqual(@as(usize, 1), l.items().len);
    try testing.expectEqual(@as(u32, 7), l.items()[0].pid);
}
