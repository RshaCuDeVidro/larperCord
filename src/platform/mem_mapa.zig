//! A memória do processo por tipo de mapeamento, lida do /proc/self/smaps (Linux): cada KB
//! do PSS cai em exatamente uma parte, e as partes somam o PSS do processo. Quem é o dono
//! de cada mapeamento sai do nome dele (o executável, uma biblioteca, uma fonte, o driver
//! de vídeo, o heap do malloc); o que não tem nome é memória anônima, que o resto do
//! relatório divide (core/mem_partes.zig). Fora do Linux, `ler` devolve null.
const std = @import("std");
const builtin = @import("builtin");

pub const Parte = enum(u8) {
    /// O código e os dados do próprio executável.
    programa,
    /// Bibliotecas do sistema (.so), o vDSO.
    bibliotecas,
    /// Arquivos de fonte mapeados (fonts.zig mapeia cada um uma vez).
    fontes,
    /// O driver de vídeo: /dev/dri, /dev/nvidia*, memfd e anon_inode (buffers da GPU).
    driver,
    /// Outros arquivos mapeados (o cache do fontconfig, a localidade...).
    arquivos,
    /// O heap do malloc: o [heap] da thread principal e as arenas das outras threads.
    heap,
    /// As pilhas das threads.
    pilhas,
    /// Memória anônima sem nome: os blocos grandes do malloc (cada um é um mmap próprio),
    /// o que bibliotecas pedem direto ao sistema (o driver de vídeo pede muito assim).
    anonima,
};

pub const n_partes = std.enums.values(Parte).len;

pub const Mapa = struct {
    kb: [n_partes]u32 = @splat(0),
    /// SwapPss: o que foi para o swap (não está no PSS).
    swap_kb: u32 = 0,
    /// Quantos mapeamentos foram lidos (0 = não leu nada).
    mapeamentos: u32 = 0,

    pub fn get(m: *const Mapa, p: Parte) u32 {
        return m.kb[@intFromEnum(p)];
    }

    pub fn total(m: *const Mapa) u32 {
        var t: u32 = 0;
        for (m.kb) |k| t += k;
        return t;
    }
};

/// As arenas do malloc das outras threads (glibc): reservas de 64 MiB alinhadas em 64 MiB
/// (HEAP_MAX_SIZE), das quais só o começo é rw-p.
const arena_align: u64 = 64 * 1024 * 1024;

const Cabecalho = struct { inicio: u64, rw: bool, caminho: []const u8 };

fn cabecalho(line: []const u8) ?Cabecalho {
    // "55d0c0a00000-55d0c0a21000 rw-p 00000000 00:00 0      [heap]"
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    const range = it.next() orelse return null;
    const dash = std.mem.indexOfScalar(u8, range, '-') orelse return null;
    const inicio = std.fmt.parseInt(u64, range[0..dash], 16) catch return null;
    _ = std.fmt.parseInt(u64, range[dash + 1 ..], 16) catch return null;
    const perms = it.next() orelse return null;
    if (perms.len != 4) return null;
    _ = it.next() orelse return null; // offset
    _ = it.next() orelse return null; // dispositivo
    _ = it.next() orelse return null; // inode
    const resto = std.mem.trim(u8, it.rest(), " \t");
    return .{ .inicio = inicio, .rw = perms[0] == 'r' and perms[1] == 'w', .caminho = resto };
}

fn fonte(path: []const u8) bool {
    const exts = [_][]const u8{ ".ttf", ".otf", ".ttc", ".otc", ".pcf", ".pcf.gz", ".woff", ".woff2", ".pfb" };
    for (exts) |e| if (std.ascii.endsWithIgnoreCase(path, e)) return true;
    return false;
}

fn biblioteca(path: []const u8) bool {
    if (std.mem.endsWith(u8, path, ".so")) return true;
    const base = path[(std.mem.lastIndexOfScalar(u8, path, '/') orelse 0)..];
    return std.mem.indexOf(u8, base, ".so.") != null;
}

/// A parte de um mapeamento pelo cabeçalho dele. `exe`: o caminho do executável.
pub fn classificar(h: Cabecalho, exe: []const u8) Parte {
    const p = h.caminho;
    if (p.len == 0) {
        // Arena de outra thread (glibc): começa alinhada em 64 MiB.
        if (h.rw and h.inicio % arena_align == 0) return .heap;
        return .anonima;
    }
    if (std.mem.eql(u8, p, "[heap]")) return .heap;
    if (std.mem.eql(u8, p, "[stack]") or std.mem.startsWith(u8, p, "[stack:")) return .pilhas;
    if (std.mem.startsWith(u8, p, "[anon:")) {
        // Com GLIBC_TUNABLES=glibc.mem.decorate_maps=1 (ou o mimalloc) os nomes dizem o dono.
        if (std.mem.indexOf(u8, p, "pthread stack") != null or std.mem.indexOf(u8, p, "stack") != null) return .pilhas;
        if (std.mem.indexOf(u8, p, "malloc") != null) return .heap;
        return .anonima;
    }
    if (std.mem.eql(u8, p, "[vdso]") or std.mem.eql(u8, p, "[vvar]") or std.mem.eql(u8, p, "[vvar_vclock]") or std.mem.eql(u8, p, "[vsyscall]")) return .bibliotecas;
    if (std.mem.startsWith(u8, p, "/dev/") or std.mem.startsWith(u8, p, "/memfd:") or std.mem.startsWith(u8, p, "anon_inode:") or
        std.mem.startsWith(u8, p, "/drm") or std.mem.startsWith(u8, p, "/SYSV")) return .driver;
    if (p[0] == '[') return .anonima;
    // " (deleted)": o executável trocado por uma atualização com o app aberto continua o mesmo.
    const sem = if (std.mem.endsWith(u8, p, " (deleted)")) p[0 .. p.len - " (deleted)".len] else p;
    if (exe.len > 0 and std.mem.eql(u8, sem, exe)) return .programa;
    if (fonte(sem)) return .fontes;
    if (biblioteca(sem)) return .bibliotecas;
    return .arquivos;
}

fn campoKb(line: []const u8, nome: []const u8) ?u32 {
    if (!std.mem.startsWith(u8, line, nome)) return null;
    var it = std.mem.tokenizeAny(u8, line[nome.len..], " \t");
    const num = it.next() orelse return null;
    return std.fmt.parseInt(u32, num, 10) catch null;
}

/// Lê o texto de um smaps aos pedaços (`alimentar`), sem guardar o arquivo inteiro.
pub const Leitor = struct {
    mapa: Mapa = .{},
    exe: []const u8,
    atual: ?Parte = null,
    linha: [512]u8 = undefined,
    n: usize = 0,
    /// A linha passou do buffer: o resto dela é ignorado.
    cortada: bool = false,

    pub fn alimentar(l: *Leitor, dados: []const u8) void {
        for (dados) |ch| {
            if (ch == '\n') {
                if (!l.cortada) l.processar(l.linha[0..l.n]);
                l.n = 0;
                l.cortada = false;
                continue;
            }
            if (l.n == l.linha.len) {
                l.cortada = true;
                continue;
            }
            l.linha[l.n] = ch;
            l.n += 1;
        }
    }

    pub fn fim(l: *Leitor) Mapa {
        if (l.n > 0 and !l.cortada) l.processar(l.linha[0..l.n]);
        l.n = 0;
        return l.mapa;
    }

    fn processar(l: *Leitor, line: []const u8) void {
        if (campoKb(line, "Pss:")) |kb| {
            if (l.atual) |p| l.mapa.kb[@intFromEnum(p)] += kb;
            return;
        }
        if (campoKb(line, "SwapPss:")) |kb| {
            l.mapa.swap_kb += kb;
            return;
        }
        // Linhas de campo começam com letra e têm ":"; o cabeçalho começa com o endereço.
        if (line.len > 0 and std.ascii.isHex(line[0])) if (cabecalho(line)) |h| {
            l.atual = classificar(h, l.exe);
            l.mapa.mapeamentos += 1;
        };
    }
};

/// Lê o /proc/self/smaps inteiro (milissegundos: fora da thread da UI). null fora do Linux.
pub fn ler() ?Mapa {
    if (builtin.os.tag != .linux) return null;
    const c = @import("c");
    var exe_buf: [1024]u8 = undefined;
    const exe_len = c.readlink("/proc/self/exe", &exe_buf, exe_buf.len);
    const exe: []const u8 = if (exe_len > 0) exe_buf[0..@intCast(exe_len)] else "";
    // Executável atualizado com o app aberto: o link termina em " (deleted)".
    const exe_limpo = if (std.mem.endsWith(u8, exe, " (deleted)")) exe[0 .. exe.len - " (deleted)".len] else exe;
    const fd = c.open("/proc/self/smaps", c.O_RDONLY);
    if (fd < 0) return null;
    defer _ = c.close(fd);
    var l: Leitor = .{ .exe = exe_limpo };
    var buf: [16 * 1024]u8 = undefined;
    while (true) {
        const n = c.read(fd, &buf, buf.len);
        if (n <= 0) break;
        l.alimentar(buf[0..@intCast(n)]);
    }
    const m = l.fim();
    return if (m.mapeamentos == 0) null else m;
}

test "smaps: cada mapeamento cai numa parte e as partes somam o PSS" {
    const t = std.testing;
    const texto =
        \\55d0c0a00000-55d0c0a21000 r-xp 00000000 103:02 1234                    /opt/larpercord/larpercord
        \\Size:                132 kB
        \\Pss:                 100 kB
        \\SwapPss:               0 kB
        \\55d0c1000000-55d0c2000000 rw-p 00000000 00:00 0                          [heap]
        \\Pss:               20000 kB
        \\7f0000000000-7f0002000000 rw-p 00000000 00:00 0
        \\Pss:                5000 kB
        \\7f0002000000-7f0004000000 ---p 00000000 00:00 0
        \\Pss:                   0 kB
        \\7f0004001000-7f0004101000 rw-p 00000000 00:00 0
        \\Pss:                 300 kB
        \\SwapPss:              12 kB
        \\7f1000000000-7f1000100000 r--p 00000000 103:02 77                      /usr/lib/libSDL3.so.0.2.10
        \\Pss:                 250 kB
        \\7f1000100000-7f1000200000 r--p 00000000 103:02 78                      /usr/share/fonts/noto/NotoColorEmoji.ttf
        \\Pss:                 900 kB
        \\7f1000200000-7f1000300000 rw-s 00000000 00:05 9                        /dev/dri/renderD128
        \\Pss:                  64 kB
        \\7f1000300000-7f1000400000 rw-s 00000000 00:01 10                       /memfd:mesa-shader (deleted)
        \\Pss:                  16 kB
        \\7f1000400000-7f1000500000 r--p 00000000 103:02 79                      /var/cache/fontconfig/abc-le64.cache-10
        \\Pss:                  30 kB
        \\7f1000500000-7f1000600000 rw-p 00000000 00:00 0                        [anon: glibc: pthread stack: 4242]
        \\Pss:                  40 kB
        \\7f1000600000-7f1000700000 rw-p 00000000 00:00 0                        [anon: glibc: malloc]
        \\Pss:                 512 kB
        \\7ffd00000000-7ffd00021000 rw-p 00000000 00:00 0                        [stack]
        \\Pss:                  48 kB
        \\7ffd00100000-7ffd00102000 r-xp 00000000 00:00 0                        [vdso]
        \\Pss:                   2 kB
    ;
    var l: Leitor = .{ .exe = "/opt/larpercord/larpercord" };
    // Aos pedaços, cortando linhas no meio, como o read() entrega.
    var i: usize = 0;
    while (i < texto.len) : (i += 7) l.alimentar(texto[i..@min(texto.len, i + 7)]);
    const m = l.fim();
    try t.expectEqual(@as(u32, 14), m.mapeamentos);
    try t.expectEqual(@as(u32, 100), m.get(.programa));
    try t.expectEqual(@as(u32, 20000 + 5000 + 512), m.get(.heap));
    try t.expectEqual(@as(u32, 300), m.get(.anonima));
    try t.expectEqual(@as(u32, 252), m.get(.bibliotecas));
    try t.expectEqual(@as(u32, 900), m.get(.fontes));
    try t.expectEqual(@as(u32, 80), m.get(.driver));
    try t.expectEqual(@as(u32, 30), m.get(.arquivos));
    try t.expectEqual(@as(u32, 88), m.get(.pilhas));
    try t.expectEqual(@as(u32, 12), m.swap_kb);
    try t.expectEqual(@as(u32, 100 + 25512 + 300 + 252 + 900 + 80 + 30 + 88), m.total());
}

test "smaps: o executável atualizado com o app aberto continua sendo o programa" {
    const h = cabecalho("5600-5700 r-xp 00000000 103:02 1 /usr/bin/larpercord (deleted)").?;
    try std.testing.expectEqual(Parte.programa, classificar(h, "/usr/bin/larpercord"));
    try std.testing.expectEqual(Parte.bibliotecas, classificar(cabecalho("5600-5700 r-xp 0 0:0 1 /usr/lib/libz.so.1.3").?, ""));
    try std.testing.expectEqual(Parte.arquivos, classificar(cabecalho("5600-5700 r--p 0 0:0 1 /usr/lib/locale/locale-archive").?, ""));
}
