//! "Jogando …" pelo processo aberto (o jeito do Discord do computador, sem o
//! discord-ipc: o Dota 2 não fala com ele, #36). A lista de jogos de
//! Configurações → Privacidade, como achar um deles entre os processos que estão
//! rodando, o nome que cada um ganha ao entrar na lista, quando a atividade
//! começa, muda e acaba, e o ritmo dos envios (o mesmo do Rich Presence).
//!
//! Lógica pura: quem varre os processos é platform/processos.zig, quem decide
//! quando olhar é app_presenca.zig, e o op 3 sai por net/discord.zig junto com a
//! atividade do Rich Presence (net/rpc_proto.zig `Presence`), sem uma tomar o
//! lugar da outra.
const std = @import("std");
const builtin = @import("builtin");
const kdl = @import("../theme/kdl.zig");
const quoted = @import("filtros.zig").quoted;
const Throttle = @import("../net/rpc_proto.zig").Throttle;

pub const Os = enum { windows, linux };
pub const native: Os = if (builtin.os.tag == .windows) .windows else .linux;

pub const max_games = 32;
/// Em bytes; o Discord aceita até 128 caracteres no nome da atividade.
pub const name_max = 128;
pub const exe_max = 255;
/// Caminho mais comprido que isto fica sem a opção "só este arquivo".
pub const path_max = 1024;

/// Texto de tamanho fixo com o zero no fim: o campo de texto do ImGui edita aqui
/// mesmo, e a lista inteira mora numa alocação só.
pub fn Buf(comptime N: usize) type {
    return struct {
        const Self = @This();
        buf: [N + 1]u8 = @splat(0),

        pub fn slice(s: *const Self) []const u8 {
            return std.mem.sliceTo(&s.buf, 0);
        }

        pub fn len(s: *const Self) usize {
            return s.slice().len;
        }

        /// Corta em N bytes sem partir um caractere no meio.
        pub fn set(s: *Self, v: []const u8) void {
            const n = utf8Cut(v, N);
            // `v` pode ser o próprio texto: copia antes de zerar.
            var tmp: [N]u8 = undefined;
            @memcpy(tmp[0..n], v[0..n]);
            s.buf = @splat(0);
            @memcpy(s.buf[0..n], tmp[0..n]);
        }
    };
}

fn utf8Cut(s: []const u8, max: usize) usize {
    var n = @min(s.len, max);
    while (n > 0 and n < s.len and (s[n] & 0xC0) == 0x80) n -= 1;
    // Um zero no meio cortaria o texto ao ler de volta.
    if (std.mem.indexOfScalar(u8, s[0..n], 0)) |z| n = z;
    return n;
}

/// Até onde `s` tem só caracteres inteiros (o último pode ter sido cortado no meio).
fn completeChars(s: []const u8) usize {
    var start = s.len;
    while (start > 0 and (s[start - 1] & 0xC0) == 0x80) start -= 1;
    if (start == 0) return s.len;
    const lead = start - 1;
    const want = std.unicode.utf8ByteSequenceLength(s[lead]) catch return lead;
    return if (lead + want > s.len) lead else s.len;
}

pub const Entry = struct {
    /// O que aparece depois de "Jogando".
    name: Buf(name_max) = .{},
    /// O nome do arquivo do executável ("dota2", "Game.exe").
    exe: Buf(exe_max) = .{},
    /// Onde ele estava ao entrar na lista ("" = não se sabe).
    path: Buf(path_max) = .{},
    /// Só vale este arquivo (o caminho inteiro), não qualquer um com o mesmo nome.
    exact: bool = false,
    on: bool = true,
    /// Quem é quem enquanto o app está aberto: tirar outra da lista não recomeça
    /// o tempo de jogo desta. Não vai para o arquivo.
    id: u32 = 0,
};

/// Um processo aberto, como a varredura viu.
pub const Proc = struct {
    pid: u32 = 0,
    /// O nome do arquivo do executável.
    name: []const u8,
    /// O caminho inteiro ("" = não deu para ler).
    path: []const u8 = "",
};

// --- Achar o jogo -----------------------------------------------------------------

/// O nome depois da última barra (as duas: um .exe do Wine vem com "\").
pub fn baseName(path: []const u8) []const u8 {
    const i = std.mem.lastIndexOfAny(u8, path, "/\\") orelse return path;
    return path[i + 1 ..];
}

fn isExe(name: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(name, ".exe");
}

fn eq(a: []const u8, b: []const u8, ci: bool) bool {
    return if (ci) std.ascii.eqlIgnoreCase(a, b) else std.mem.eql(u8, a, b);
}

/// O mesmo arquivo pelo nome. No Windows (e num .exe, que no Linux roda pelo
/// Wine) sem diferenciar maiúsculas; sem extensão na lista, "dota2" também acha
/// "dota2.exe".
pub fn sameName(want: []const u8, got: []const u8, os: Os) bool {
    if (want.len == 0) return false;
    const ci = os == .windows or isExe(want) or isExe(got);
    if (eq(want, got, ci)) return true;
    if (std.mem.indexOfScalar(u8, want, '.') == null and isExe(got)) return eq(want, got[0 .. got.len - 4], true);
    return false;
}

/// O mesmo caminho: no Windows sem diferenciar maiúsculas, com "/" e "\" iguais.
pub fn samePath(want: []const u8, got: []const u8, os: Os) bool {
    if (os == .linux) return std.mem.eql(u8, want, got);
    if (want.len != got.len) return false;
    for (want, got) |a, b| {
        const x = if (a == '/') '\\' else std.ascii.toLower(a);
        const y = if (b == '/') '\\' else std.ascii.toLower(b);
        if (x != y) return false;
    }
    return true;
}

/// O processo é este jogo da lista (ligado ou não: quem chama decide).
pub fn matches(e: *const Entry, p: Proc, os: Os) bool {
    if (!sameName(e.exe.slice(), p.name, os)) return false;
    if (e.exact and e.path.len() > 0) return p.path.len > 0 and samePath(e.path.slice(), p.path, os);
    return true;
}

/// O primeiro jogo ligado da lista (na ordem dela) que está aberto.
pub fn firstRunning(entries: []const Entry, procs: []const Proc, os: Os) ?usize {
    for (entries, 0..) |*e, i| {
        if (!e.on) continue;
        for (procs) |p| if (matches(e, p, os)) return i;
    }
    return null;
}

/// Algum jogo ligado tem esse nome de arquivo? (A varredura do Windows só olha
/// mais de perto quem passa por aqui.)
pub fn wanted(entries: []const Entry, name: []const u8, os: Os) bool {
    for (entries) |*e| if (e.on and sameName(e.exe.slice(), name, os)) return true;
    return false;
}

/// E precisa do caminho inteiro para saber (a opção "só este arquivo")?
pub fn wantsPath(entries: []const Entry, name: []const u8, os: Os) bool {
    for (entries) |*e| if (e.on and e.exact and e.path.len() > 0 and sameName(e.exe.slice(), name, os)) return true;
    return false;
}

// --- Nome que o jogo ganha ----------------------------------------------------------

/// Extensões de executável que saem do nome ("Celeste.bin.x86_64" → "Celeste").
const exe_exts = [_][]const u8{ "exe", "x86_64", "x86", "x64", "amd64", "i386", "bin", "sh", "appimage", "elf", "run" };

fn stripExts(s: []const u8) []const u8 {
    var out = s;
    while (std.mem.lastIndexOfScalar(u8, out, '.')) |i| {
        if (i == 0) break;
        const ext = out[i + 1 ..];
        var known = false;
        for (exe_exts) |x| {
            if (std.ascii.eqlIgnoreCase(ext, x)) known = true;
        }
        if (!known) break;
        out = out[0..i];
    }
    return out;
}

/// O nome que o jogo ganha ao entrar na lista: o do arquivo sem a extensão, com
/// espaço no lugar de "_", "-" e ".", e as palavras com maiúscula quando o
/// arquivo é todo minúsculo ("minecraft-launcher" → "Minecraft Launcher";
/// "RobloxPlayerBeta.exe" fica "RobloxPlayerBeta").
pub fn defaultName(buf: *[name_max]u8, file: []const u8) []const u8 {
    const base = baseName(file);
    const stem = stripExts(base);
    var n: usize = 0;
    var space = true;
    for (stem) |ch| {
        if (n == buf.len) break;
        const sep = ch == '_' or ch == '-' or ch == '.' or ch == ' ';
        if (sep) {
            if (!space) {
                buf[n] = ' ';
                n += 1;
            }
            space = true;
            continue;
        }
        buf[n] = ch;
        n += 1;
        space = false;
    }
    n = completeChars(buf[0..n]);
    while (n > 0 and buf[n - 1] == ' ') n -= 1;
    if (n == 0) {
        const k = utf8Cut(base, buf.len);
        @memcpy(buf[0..k], base[0..k]);
        return buf[0..k];
    }
    var upper = false;
    for (buf[0..n]) |ch| {
        if (std.ascii.isUpper(ch)) upper = true;
    }
    if (!upper) {
        var start = true;
        for (buf[0..n]) |*ch| {
            if (start) ch.* = std.ascii.toUpper(ch.*);
            start = ch.* == ' ';
        }
    }
    return buf[0..n];
}

/// O nome que vai para o Discord: o escolhido, ou o do arquivo quando ficou
/// curto demais (o Discord recusa atividade com menos de 2 caracteres).
pub fn shownName(e: *const Entry, buf: *[name_max]u8) []const u8 {
    const t = std.mem.trim(u8, e.name.slice(), " \t");
    if ((std.unicode.utf8CountCodepoints(t) catch 0) >= 2) return t;
    return defaultName(buf, e.exe.slice());
}

// --- A lista para escolher um processo aberto ----------------------------------------

/// Programas do sistema e de fundo que não são jogo: ficam fora da lista de
/// processos abertos (dá para escolher o executável à mão se for o caso).
const hidden_names = [_][]const u8{
    "systemd",        "(sd-pam)",           "sd-pam",         "dbus-daemon",   "dbus-broker",  "dbus-broker-launch",
    "pipewire",       "pipewire-pulse",     "wireplumber",    "pulseaudio",    "Xwayland",     "Xorg",
    "sh",             "bash",               "zsh",            "fish",          "dash",         "tmux",
    "screen",         "sudo",               "ssh-agent",      "gpg-agent",     "kwin_wayland", "kwin_x11",
    "plasmashell",    "gnome-shell",        "ksmserver",      "kded5",         "kded6",        "kaccess",
    "kglobalaccel",   "kglobalacceld",      "xembedsniproxy", "dconf-service", "gamescope",    "gamescopereaper",
    "steamwebhelper", "wineserver",         "larpercord",     "conhost.exe",   "svchost.exe",  "RuntimeBroker.exe",
    "dllhost.exe",    "sihost.exe",         "taskhostw.exe",  "ctfmon.exe",    "explorer.exe", "SearchHost.exe",
    "larpercord.exe", "steamwebhelper.exe",
};
/// Começos de nome de programas de fundo (gvfsd-trash, xdg-desktop-portal-kde…).
const hidden_prefixes = [_][]const u8{ "gvfs", "at-spi", "xdg-", "gsd-", "ibus", "fcitx", "polkit", "evolution-", "goa-", "tracker-miner", "baloo", "kwalletd", "obex", "mutter-", "gnome-session" };

/// Fica fora da lista de processos abertos?
pub fn hidden(p: Proc, os: Os) bool {
    if (p.name.len == 0) return true;
    for (hidden_names) |n| if (eq(n, p.name, os == .windows or isExe(n))) return true;
    for (hidden_prefixes) |pre| if (std.mem.startsWith(u8, p.name, pre)) return true;
    // Linux: os ajudantes que moram em /usr/lib e /usr/libexec.
    if (std.mem.startsWith(u8, p.path, "/usr/lib/") or std.mem.startsWith(u8, p.path, "/usr/libexec/") or std.mem.startsWith(u8, p.path, "/lib/")) return true;
    // Windows (e o Wine): o que mora na pasta do sistema.
    if (p.path.len >= 3 and p.path[1] == ':' and std.ascii.startsWithIgnoreCase(p.path[2..], "\\windows\\")) return true;
    // Windows: sem o caminho, é do sistema ou de outro usuário (não deu para abrir).
    if (os == .windows and p.path.len == 0) return true;
    return false;
}

fn lessByName(_: void, a: Proc, b: Proc) bool {
    return switch (std.ascii.orderIgnoreCase(a.name, b.name)) {
        .lt => true,
        .gt => false,
        .eq => std.mem.lessThan(u8, a.path, b.path),
    };
}

/// A lista para escolher: sem os do sistema, sem repetir (o navegador abre vinte
/// processos do mesmo arquivo), em ordem de nome. `out` aponta para os textos
/// de `procs`.
pub fn pickable(gpa: std.mem.Allocator, procs: []const Proc, os: Os, out: *std.ArrayList(Proc)) !void {
    out.clearRetainingCapacity();
    for (procs) |p| {
        if (hidden(p, os)) continue;
        try out.append(gpa, p);
    }
    std.mem.sort(Proc, out.items, {}, lessByName);
    var n: usize = 0;
    for (out.items) |p| {
        if (n > 0) {
            const last = out.items[n - 1];
            if (std.mem.eql(u8, last.name, p.name) and (std.mem.eql(u8, last.path, p.path) or p.path.len == 0)) continue;
        }
        out.items[n] = p;
        n += 1;
    }
    out.shrinkRetainingCapacity(n);
}

fn containsIgnoreCase(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > hay.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(hay[i .. i + needle.len], needle)) return true;
    }
    return false;
}

/// A caixa de filtro da lista: um pedaço do nome ou do caminho, sem diferenciar maiúsculas.
pub fn filterMatch(p: Proc, query: []const u8) bool {
    const q = std.mem.trim(u8, query, " \t");
    return containsIgnoreCase(p.name, q) or containsIgnoreCase(p.path, q);
}

// --- A lista de jogos ------------------------------------------------------------------

pub const Lista = struct {
    items: [max_games]Entry = undefined,
    len: usize = 0,
    next_id: u32 = 1,
    /// Mudou algo que vai para o settings.kdl (o app grava no fim do quadro).
    save: bool = false,
    /// Muda a cada mudança (nome, ligar, tirar…): a presença olha de novo.
    gen: u32 = 0,

    pub fn slice(l: *Lista) []Entry {
        return l.items[0..l.len];
    }

    pub fn constSlice(l: *const Lista) []const Entry {
        return l.items[0..l.len];
    }

    pub fn changed(l: *Lista) void {
        l.save = true;
        l.gen +%= 1;
    }

    pub const AddResult = enum { added, empty, exists, full };

    /// Um jogo novo pelo arquivo (`path` pode ser "": só o nome). O nome que
    /// aparece começa como o do arquivo (`defaultName`).
    pub fn add(l: *Lista, exe_or_path: []const u8, path: []const u8, os: Os) AddResult {
        const exe = baseName(exe_or_path);
        if (exe.len == 0) return .empty;
        for (l.constSlice()) |*e| if (sameName(e.exe.slice(), exe, os) and sameName(exe, e.exe.slice(), os)) return .exists;
        if (l.len == max_games) return .full;
        var e: Entry = .{ .id = l.next_id };
        l.next_id +%= 1;
        var nb: [name_max]u8 = undefined;
        e.name.set(defaultName(&nb, exe));
        e.exe.set(exe);
        if (path.len <= path_max) e.path.set(path);
        l.items[l.len] = e;
        l.len += 1;
        l.changed();
        return .added;
    }

    pub fn remove(l: *Lista, i: usize) void {
        if (i >= l.len) return;
        std.mem.copyForwards(Entry, l.items[i .. l.len - 1], l.items[i + 1 .. l.len]);
        l.len -= 1;
        l.changed();
    }

    /// `game "Dota 2" exe="dota2" path="/home/…/dota2" exact=#false on=#true`
    pub fn write(l: *const Lista, out: *std.ArrayList(u8), gpa: std.mem.Allocator) !void {
        for (l.constSlice()) |*e| {
            try out.appendSlice(gpa, "game ");
            try quoted(out, gpa, e.name.slice());
            try out.appendSlice(gpa, " exe=");
            try quoted(out, gpa, e.exe.slice());
            if (e.path.len() > 0) {
                try out.appendSlice(gpa, " path=");
                try quoted(out, gpa, e.path.slice());
            }
            try out.print(gpa, " exact={s} on={s}\n", .{ if (e.exact) "#true" else "#false", if (e.on) "#true" else "#false" });
        }
    }

    /// Lê um nó do settings.kdl. false = não é nosso.
    pub fn applyNode(l: *Lista, n: *const kdl.Node) bool {
        if (!std.mem.eql(u8, n.name, "game")) return false;
        const exe = n.str("exe") orelse return true;
        if (exe.len == 0 or l.len == max_games) return true;
        var e: Entry = .{ .id = l.next_id };
        l.next_id +%= 1;
        e.exe.set(baseName(exe));
        const name = if (n.arg(0)) |a| a.asString() orelse "" else "";
        if (name.len > 0) e.name.set(name) else {
            var nb: [name_max]u8 = undefined;
            e.name.set(defaultName(&nb, exe));
        }
        if (n.str("path")) |p| if (p.len <= path_max) e.path.set(p);
        e.exact = (n.flag("exact") orelse false) and e.path.len() > 0;
        e.on = n.flag("on") orelse true;
        l.items[l.len] = e;
        l.len += 1;
        return true;
    }
};

// --- Quando começa, muda e acaba ----------------------------------------------------

/// O que está sendo mostrado: o jogo da lista, o nome e desde quando (ms Unix).
pub const Playing = struct {
    id: u32,
    name: Buf(name_max) = .{},
    start_ms: i64,

    pub fn eql(a: *const Playing, b: *const Playing) bool {
        return a.id == b.id and a.start_ms == b.start_ms and std.mem.eql(u8, a.name.slice(), b.name.slice());
    }
};

/// Acompanha o jogo aberto entre uma varredura e outra: o mesmo jogo continua
/// com a hora em que foi visto pela primeira vez (o "há 1 h" do Discord), outro
/// jogo começa a contar de novo, e nenhum limpa.
pub const Tracker = struct {
    now: ?Playing = null,

    /// `e`: o jogo aberto agora (null = nenhum); `now_ms`: hora Unix.
    pub fn update(t: *Tracker, e: ?*const Entry, now_ms: i64) ?*const Playing {
        const entry = e orelse {
            t.now = null;
            return null;
        };
        var nb: [name_max]u8 = undefined;
        const name = shownName(entry, &nb);
        if (t.now) |*p| if (p.id == entry.id) {
            p.name.set(name);
            return p;
        };
        t.now = .{ .id = entry.id, .start_ms = now_ms };
        t.now.?.name.set(name);
        return &t.now.?;
    }

    pub fn reset(t: *Tracker) void {
        t.now = null;
    }
};

/// O ritmo dos envios: o mesmo `Throttle` do Rich Presence (um a cada ~15 s, o
/// mais novo vence e a limpeza final sempre vai), e repetir não gasta envio.
pub const Pace = struct {
    throttle: Throttle,
    sent: ?Playing = null,
    want: ?Playing = null,

    pub const Send = struct { game: ?Playing };

    pub fn set(p: *Pace, want: ?*const Playing) void {
        p.want = if (want) |w| w.* else null;
        const same = if (p.want) |*w| (p.sent != null and w.eql(&p.sent.?)) else p.sent == null;
        p.throttle.dirty = !same;
    }

    /// O que mandar agora, se o ritmo deixa (null = nada).
    pub fn take(p: *Pace, now_ms: i64) ?Send {
        if (!p.throttle.take(now_ms)) return null;
        p.sent = p.want;
        return .{ .game = p.want };
    }

    pub fn waitMs(p: *const Pace, now_ms: i64) ?i64 {
        return p.throttle.waitMs(now_ms);
    }

    /// Desligou ou trocou de conta: começa do zero (o próximo envio sai na hora).
    pub fn reset(p: *Pace) void {
        p.* = .{ .throttle = .{ .interval_ms = p.throttle.interval_ms } };
    }
};

// --- Testes -----------------------------------------------------------------------

const testing = std.testing;

fn testEntry(exe: []const u8, path: []const u8, exact: bool) Entry {
    var e: Entry = .{ .exact = exact, .id = 1 };
    e.exe.set(exe);
    e.path.set(path);
    var nb: [name_max]u8 = undefined;
    e.name.set(defaultName(&nb, exe));
    return e;
}

test "nome do arquivo: maiúsculas no Windows e nos .exe, extensão opcional" {
    try testing.expect(sameName("Dota2.exe", "dota2.exe", .windows));
    try testing.expect(sameName("dota2", "DOTA2.EXE", .windows));
    try testing.expect(sameName("dota2", "dota2", .linux));
    try testing.expect(!sameName("dota2", "Dota2", .linux));
    try testing.expect(sameName("Dota2", "dota2", .windows));
    // No Linux, o .exe roda pelo Wine, que não diferencia maiúsculas.
    try testing.expect(sameName("Game.exe", "game.EXE", .linux));
    try testing.expect(sameName("game", "Game.exe", .linux));
    // Extensão diferente não é o mesmo arquivo; vazio não acha nada.
    try testing.expect(!sameName("dota2.sh", "dota2", .linux));
    try testing.expect(!sameName("dota", "dota2.exe", .windows));
    try testing.expect(!sameName("", "dota2", .linux));
}

test "caminho inteiro: só com a opção, e com as regras de cada sistema" {
    const win = testEntry("Game.exe", "C:\\Games\\Foo\\Game.exe", true);
    try testing.expect(matches(&win, .{ .name = "game.exe", .path = "c:/games/foo/GAME.EXE" }, .windows));
    try testing.expect(!matches(&win, .{ .name = "Game.exe", .path = "D:\\Outro\\Game.exe" }, .windows));
    // Sem conseguir ler o caminho, a opção "só este arquivo" não arrisca.
    try testing.expect(!matches(&win, .{ .name = "Game.exe" }, .windows));
    var loose = win;
    loose.exact = false;
    try testing.expect(matches(&loose, .{ .name = "Game.exe", .path = "D:\\Outro\\Game.exe" }, .windows));
    const lin = testEntry("dota2", "/home/u/.steam/dota2", true);
    try testing.expect(matches(&lin, .{ .name = "dota2", .path = "/home/u/.steam/dota2" }, .linux));
    try testing.expect(!matches(&lin, .{ .name = "dota2", .path = "/HOME/u/.steam/dota2" }, .linux));
    // A opção sem caminho guardado vale como só o nome.
    const nopath = testEntry("dota2", "", true);
    try testing.expect(matches(&nopath, .{ .name = "dota2", .path = "/x/dota2" }, .linux));
}

test "o primeiro ligado da lista vence; desligado não conta" {
    var l: Lista = .{};
    try testing.expectEqual(Lista.AddResult.added, l.add("/games/a/alpha", "/games/a/alpha", .linux));
    try testing.expectEqual(Lista.AddResult.added, l.add("beta.exe", "", .linux));
    try testing.expectEqual(Lista.AddResult.exists, l.add("/outro/Beta.EXE", "", .linux));
    try testing.expectEqual(Lista.AddResult.empty, l.add("", "", .linux));
    const procs = [_]Proc{ .{ .name = "beta.exe", .pid = 2 }, .{ .name = "alpha", .path = "/games/a/alpha", .pid = 1 } };
    try testing.expectEqual(@as(?usize, 0), firstRunning(l.slice(), &procs, .linux));
    l.items[0].on = false;
    try testing.expectEqual(@as(?usize, 1), firstRunning(l.slice(), &procs, .linux));
    try testing.expect(wanted(l.slice(), "BETA.exe", .linux));
    try testing.expect(!wanted(l.slice(), "alpha", .linux));
    try testing.expect(!wantsPath(l.slice(), "beta.exe", .linux));
    l.items[1].on = false;
    try testing.expectEqual(@as(?usize, null), firstRunning(l.slice(), &procs, .linux));
    // Cheia.
    var full: Lista = .{};
    var nb: [16]u8 = undefined;
    for (0..max_games) |i| try testing.expectEqual(Lista.AddResult.added, full.add(std.fmt.bufPrint(&nb, "g{d}", .{i}) catch unreachable, "", .linux));
    try testing.expectEqual(Lista.AddResult.full, full.add("mais", "", .linux));
    full.remove(0);
    try testing.expectEqualStrings("g1", full.items[0].exe.slice());
    try testing.expectEqual(@as(usize, max_games - 1), full.len);
}

test "nome que o jogo ganha: sem extensão, separadores e maiúsculas" {
    var b: [name_max]u8 = undefined;
    try testing.expectEqualStrings("Dota2", defaultName(&b, "dota2"));
    try testing.expectEqualStrings("Dota2", defaultName(&b, "C:\\Steam\\dota 2 beta\\game\\bin\\win64\\dota2.exe"));
    try testing.expectEqualStrings("Minecraft Launcher", defaultName(&b, "/usr/bin/minecraft-launcher"));
    try testing.expectEqualStrings("RobloxPlayerBeta", defaultName(&b, "RobloxPlayerBeta.exe"));
    try testing.expectEqualStrings("Celeste", defaultName(&b, "Celeste.bin.x86_64"));
    try testing.expectEqualStrings("Hl2 Linux", defaultName(&b, "hl2_linux"));
    try testing.expectEqualStrings("Factorio", defaultName(&b, "factorio.AppImage"));
    // Ponto que não é extensão de executável fica (como espaço).
    try testing.expectEqualStrings("Game V2", defaultName(&b, "game.v2"));
    // Só separadores: fica o nome como veio.
    try testing.expectEqualStrings("__", defaultName(&b, "__"));
    // Comprido: corta sem partir um caractere.
    var long: [200]u8 = undefined;
    for (0..100) |i| @memcpy(long[i * 2 ..][0..2], "á");
    const cut = defaultName(&b, &long);
    try testing.expect(cut.len <= name_max and std.unicode.utf8ValidateSlice(cut));
    // Apagou o nome: vai o do arquivo.
    var e = testEntry("eldenring.exe", "", false);
    e.name.set(" x ");
    try testing.expectEqualStrings("Eldenring", shownName(&e, &b));
    e.name.set("Elden Ring");
    try testing.expectEqualStrings("Elden Ring", shownName(&e, &b));
}

test "lista de processos abertos: sem os do sistema, sem repetir, por nome" {
    const procs = [_]Proc{
        .{ .name = "zeta", .path = "/opt/zeta/zeta" },
        .{ .name = "pipewire", .path = "/usr/bin/pipewire" },
        .{ .name = "xdg-desktop-portal-kde", .path = "/usr/bin/xdg-desktop-portal-kde" },
        .{ .name = "polkit-agent", .path = "/usr/lib/polkit-agent" },
        .{ .name = "Alpha.exe", .path = "Z:\\home\\u\\alpha\\Alpha.exe" },
        .{ .name = "services.exe", .path = "C:\\windows\\system32\\services.exe" },
        .{ .name = "zeta", .path = "/opt/zeta/zeta" },
        .{ .name = "bash", .path = "/usr/bin/bash" },
        .{ .name = "beta", .path = "/opt/beta/beta" },
    };
    var out: std.ArrayList(Proc) = .empty;
    defer out.deinit(testing.allocator);
    try pickable(testing.allocator, &procs, .linux, &out);
    try testing.expectEqual(@as(usize, 3), out.items.len);
    try testing.expectEqualStrings("Alpha.exe", out.items[0].name);
    try testing.expectEqualStrings("beta", out.items[1].name);
    try testing.expectEqualStrings("zeta", out.items[2].name);
    try testing.expect(filterMatch(out.items[0], "  ALPHA "));
    try testing.expect(filterMatch(out.items[2], "opt/z"));
    try testing.expect(!filterMatch(out.items[1], "zeta"));
    // Windows: sem caminho é do sistema (ou de outro usuário); C:\Windows também.
    try testing.expect(hidden(.{ .name = "game.exe" }, .windows));
    try testing.expect(hidden(.{ .name = "Explorer.EXE", .path = "C:\\Windows\\explorer.exe" }, .windows));
    try testing.expect(hidden(.{ .name = "SVCHOST.exe", .path = "D:\\x\\svchost.exe" }, .windows));
    try testing.expect(!hidden(.{ .name = "game.exe", .path = "D:\\Games\\game.exe" }, .windows));
}

test "jogos vão e voltam pelo KDL" {
    var l: Lista = .{};
    _ = l.add("C:\\Games\\Foo \"x\"\\Game.exe", "C:\\Games\\Foo \"x\"\\Game.exe", .windows);
    _ = l.add("dota2", "", .linux);
    l.items[0].name.set("Meu Jogo ção");
    l.items[0].exact = true;
    l.items[1].on = false;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try l.write(&out, testing.allocator);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const nodes = try kdl.parse(arena.allocator(), out.items, null);
    var back: Lista = .{};
    for (nodes) |*n| try testing.expect(back.applyNode(n));
    try testing.expectEqual(@as(usize, 2), back.len);
    try testing.expectEqualStrings("Meu Jogo ção", back.items[0].name.slice());
    try testing.expectEqualStrings("Game.exe", back.items[0].exe.slice());
    try testing.expectEqualStrings("C:\\Games\\Foo \"x\"\\Game.exe", back.items[0].path.slice());
    try testing.expect(back.items[0].exact and back.items[0].on);
    try testing.expectEqualStrings("Dota2", back.items[1].name.slice());
    try testing.expect(!back.items[1].on and !back.items[1].exact);
    try testing.expect(back.items[0].id != back.items[1].id);
    // Ler não pede para gravar; nó de outro dono não é nosso.
    try testing.expect(!back.save);
    try testing.expect(!back.applyNode(&.{ .name = "focus" }));
}

test "tempo de jogo: o mesmo jogo continua, outro recomeça, nenhum limpa" {
    var l: Lista = .{};
    _ = l.add("alpha", "", .linux);
    _ = l.add("beta", "", .linux);
    var t: Tracker = .{};
    try testing.expect(t.update(null, 1000) == null);
    const a = t.update(&l.items[0], 5000).?;
    try testing.expectEqual(@as(i64, 5000), a.start_ms);
    try testing.expectEqualStrings("Alpha", a.name.slice());
    // Ainda aberto 15 s depois: a hora do começo fica.
    try testing.expectEqual(@as(i64, 5000), t.update(&l.items[0], 20_000).?.start_ms);
    // Mudou o nome na lista: muda o nome, não o começo.
    l.items[0].name.set("Alpha Remastered");
    const renamed = t.update(&l.items[0], 35_000).?;
    try testing.expectEqual(@as(i64, 5000), renamed.start_ms);
    try testing.expectEqualStrings("Alpha Remastered", renamed.name.slice());
    // Outra entrada saiu da lista: a de cima andou de lugar, mas é a mesma.
    _ = l.add("gamma", "", .linux);
    l.remove(1);
    try testing.expectEqual(@as(i64, 5000), t.update(&l.items[0], 40_000).?.start_ms);
    // Trocou de jogo: conta de novo.
    try testing.expectEqual(@as(i64, 50_000), t.update(&l.items[1], 50_000).?.start_ms);
    // Fechou: limpa, e abrir de novo começa outra vez.
    try testing.expect(t.update(null, 60_000) == null);
    try testing.expectEqual(@as(i64, 70_000), t.update(&l.items[1], 70_000).?.start_ms);
}

test "ritmo: o primeiro vai na hora, o resto espera a vez, repetir não gasta" {
    var l: Lista = .{};
    _ = l.add("alpha", "", .linux);
    _ = l.add("beta", "", .linux);
    var t: Tracker = .{};
    var p: Pace = .{ .throttle = .{ .interval_ms = 15_000 } };
    // Nada aberto e nada mandado: não manda nada.
    p.set(t.update(null, 0));
    try testing.expect(p.take(0) == null);
    p.set(t.update(&l.items[0], 1_000_000));
    const first = p.take(100).?;
    try testing.expectEqualStrings("Alpha", first.game.?.name.slice());
    try testing.expectEqual(@as(i64, 1_000_000), first.game.?.start_ms);
    // A mesma coisa de novo: nada.
    p.set(t.update(&l.items[0], 1_015_000));
    try testing.expect(p.take(15_100) == null);
    try testing.expect(p.waitMs(15_100) == null);
    // Trocou duas vezes antes da vez: só a mais nova vai, quando o ritmo deixa.
    p.set(t.update(&l.items[1], 1_016_000));
    try testing.expect(p.take(5_000) == null);
    try testing.expectEqual(@as(?i64, 10_100), p.waitMs(5_000));
    l.items[1].name.set("Beta Final");
    p.set(t.update(&l.items[1], 1_017_000));
    const second = p.take(15_100).?;
    try testing.expectEqualStrings("Beta Final", second.game.?.name.slice());
    // Fechou: a limpeza espera a vez, mas vai.
    p.set(t.update(null, 1_020_000));
    try testing.expect(p.take(20_000) == null);
    const clear = p.take(30_100).?;
    try testing.expect(clear.game == null);
    try testing.expect(p.take(60_000) == null);
    // Desligou: começa do zero, e o próximo sai na hora.
    p.reset();
    p.set(t.update(&l.items[0], 2_000_000));
    try testing.expect(p.take(30_200) != null);
}
