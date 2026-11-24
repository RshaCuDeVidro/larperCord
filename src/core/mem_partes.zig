//! A RAM do processo dividida em partes que somam o total (Configurações → Desempenho e o
//! `--stats`). Só conta: quem lê os números é app_memoria.zig.
//!
//! No Linux o total é o PSS do mapa de memória (platform/mem_mapa.zig), e o mapa já separa os
//! arquivos (o executável, as bibliotecas, as fontes, o driver de vídeo), as pilhas, o heap
//! do malloc e a memória anônima sem nome. O heap se divide em ocupado e livre (o que o malloc
//! informa, platform/mem_tune.zig), e o ocupado em quem pediu: as bibliotecas que alocam pelas
//! funções que contam (platform/mem_contas.zig), os plugins, os dados da conta (estimativa,
//! core/mem_use.zig) e o resto. Fora do Linux não há mapa: o total é a memória privada, e o
//! que não tem conta própria fica no resto.
//!
//! Cada parte sai do que ainda sobra (nunca passa do que existe), e o resto é o que ninguém
//! reclamou: as partes sempre somam o total, sem número inventado.
const std = @import("std");
const mem_mapa = @import("../platform/mem_mapa.zig");

pub const Parte = enum(u8) {
    programa,
    bibliotecas,
    fontes,
    driver,
    arquivos,
    pilhas,
    /// O heap ocupado, dividido nas próximas (até `resto_heap`).
    sdl,
    imgui,
    freetype,
    curl,
    openssl,
    lua,
    mensagens,
    pessoas,
    lugares,
    resto_heap,
    heap_livre,
    /// Memória anônima fora do malloc (o driver de vídeo pede muito assim). Fora do Linux,
    /// tudo o que não tem conta própria.
    anonima,

    pub fn doHeap(p: Parte) bool {
        return @intFromEnum(p) >= @intFromEnum(Parte.sdl) and @intFromEnum(p) <= @intFromEnum(Parte.resto_heap);
    }
};

pub const n_partes = std.enums.values(Parte).len;

/// As bibliotecas contadas, na ordem de `Parte.sdl`..`Parte.lua`.
pub const n_libs = 6;

pub const Entrada = struct {
    /// Total quando não há mapa (Windows: a memória privada), em KB.
    total_kb: u32 = 0,
    mapa: ?mem_mapa.Mapa = null,
    /// O que o malloc informa (KB); null = este sistema não informa.
    heap_usado_kb: ?u32 = null,
    heap_livre_kb: ?u32 = null,
    /// Dos ocupados, os blocos grandes que são um mmap próprio (glibc).
    heap_mmap_kb: u32 = 0,
    /// Bytes de cada biblioteca contada (null = ela não aceitou as funções que contam).
    libs: [n_libs]?u64 = @splat(null),
    /// Estimativas dos dados da conta (bytes; core/mem_use.zig).
    mensagens: u64 = 0,
    pessoas: u64 = 0,
    lugares: u64 = 0,
};

pub const Partes = struct {
    kb: [n_partes]u32 = @splat(0),
    /// A parte existe aqui (as que não existem não aparecem, em vez de aparecer zeradas).
    tem: [n_partes]bool = @splat(false),
    total_kb: u32 = 0,

    pub fn get(p: *const Partes, x: Parte) u32 {
        return p.kb[@intFromEnum(x)];
    }

    pub fn soma(p: *const Partes) u32 {
        var t: u32 = 0;
        for (p.kb, p.tem) |k, t_| {
            if (t_) t += k;
        }
        return t;
    }

    pub fn heapUsado(p: *const Partes) u32 {
        var t: u32 = 0;
        for (std.enums.values(Parte)) |x| if (x.doHeap() and p.tem[@intFromEnum(x)]) {
            t += p.kb[@intFromEnum(x)];
        };
        return t;
    }

    fn por(p: *Partes, x: Parte, kb: u32) void {
        p.kb[@intFromEnum(x)] = kb;
        p.tem[@intFromEnum(x)] = true;
    }
};

fn kbDe(bytes: u64) u32 {
    return @intCast(@min(bytes / 1024, std.math.maxInt(u32)));
}

/// Tira de `sobra` a parte `x` (no máximo o que sobra).
fn tira(p: *Partes, x: Parte, kb: u32, sobra: *u32) void {
    const k = @min(kb, sobra.*);
    p.por(x, k);
    sobra.* -= k;
}

pub fn dividir(e: Entrada) Partes {
    var p: Partes = .{};
    // O que vai ser dividido entre as bibliotecas, a conta e o resto.
    var ocupado: u32 = 0;
    if (e.mapa) |m| {
        p.total_kb = m.total();
        p.por(.programa, m.get(.programa));
        p.por(.bibliotecas, m.get(.bibliotecas));
        p.por(.fontes, m.get(.fontes));
        p.por(.driver, m.get(.driver));
        p.por(.arquivos, m.get(.arquivos));
        p.por(.pilhas, m.get(.pilhas));
        // Os blocos grandes do malloc são mmaps sem nome: saem da anônima para o heap.
        const blocos = @min(e.heap_mmap_kb, m.get(.anonima));
        const heap_total = m.get(.heap) + blocos;
        p.por(.anonima, m.get(.anonima) - blocos);
        ocupado = if (e.heap_usado_kb) |u| @min(u, heap_total) else heap_total;
        p.por(.heap_livre, heap_total - ocupado);
    } else {
        // Sem mapa: o total inteiro passa pela divisão, e o que ninguém reclamar fica na
        // anônima ("o resto do app e do sistema").
        p.total_kb = e.total_kb;
        ocupado = e.total_kb;
        if (e.heap_livre_kb) |l| {
            const k = @min(l, ocupado);
            p.por(.heap_livre, k);
            ocupado -= k;
        }
    }
    var sobra = ocupado;
    const libs = [_]Parte{ .sdl, .imgui, .freetype, .curl, .openssl, .lua };
    for (libs, e.libs) |x, b| if (b) |bytes| tira(&p, x, kbDe(bytes), &sobra);
    tira(&p, .mensagens, kbDe(e.mensagens), &sobra);
    tira(&p, .pessoas, kbDe(e.pessoas), &sobra);
    tira(&p, .lugares, kbDe(e.lugares), &sobra);
    if (e.mapa != null) {
        p.por(.resto_heap, sobra);
    } else {
        // Fora do Linux não se sabe o que é heap e o que não é.
        p.por(.anonima, sobra);
    }
    return p;
}

test "as partes somam o PSS do mapa, e o heap ocupado se divide sem passar do que existe" {
    const t = std.testing;
    var m: mem_mapa.Mapa = .{};
    m.kb[@intFromEnum(mem_mapa.Parte.programa)] = 9000;
    m.kb[@intFromEnum(mem_mapa.Parte.bibliotecas)] = 20000;
    m.kb[@intFromEnum(mem_mapa.Parte.fontes)] = 3000;
    m.kb[@intFromEnum(mem_mapa.Parte.driver)] = 20000;
    m.kb[@intFromEnum(mem_mapa.Parte.pilhas)] = 300;
    m.kb[@intFromEnum(mem_mapa.Parte.heap)] = 30000;
    m.kb[@intFromEnum(mem_mapa.Parte.anonima)] = 15000;
    var e: Entrada = .{ .mapa = m, .heap_usado_kb = 36000, .heap_livre_kb = 2000, .heap_mmap_kb = 8000 };
    e.libs[0] = 4 * 1024 * 1024; // SDL
    e.libs[1] = 3 * 1024 * 1024; // ImGui
    e.mensagens = 2 * 1024 * 1024;
    const p = dividir(e);
    try t.expectEqual(m.total(), p.total_kb);
    try t.expectEqual(p.total_kb, p.soma());
    // 8 MB de blocos grandes saíram da anônima para o heap: 38 MB de heap, 36 ocupados.
    try t.expectEqual(@as(u32, 7000), p.get(.anonima));
    try t.expectEqual(@as(u32, 2000), p.get(.heap_livre));
    try t.expectEqual(@as(u32, 36000), p.heapUsado());
    try t.expectEqual(@as(u32, 4096), p.get(.sdl));
    try t.expectEqual(@as(u32, 36000 - 4096 - 3072 - 2048), p.get(.resto_heap));
    // O curl não aceitou as funções: a linha dele não existe.
    try t.expect(!p.tem[@intFromEnum(Parte.curl)] and p.tem[@intFromEnum(Parte.sdl)]);

    // Uma biblioteca que diz ter mais do que o heap ocupado não passa dele.
    e.libs[0] = 100 * 1024 * 1024;
    const q = dividir(e);
    try t.expectEqual(q.total_kb, q.soma());
    try t.expectEqual(@as(u32, 36000), q.get(.sdl));
    try t.expectEqual(@as(u32, 0), q.get(.resto_heap));
}

test "sem mapa (Windows): o total é a memória privada e o resto fica sem dono" {
    const t = std.testing;
    var e: Entrada = .{ .total_kb = 90000 };
    e.libs[1] = 5 * 1024 * 1024;
    e.pessoas = 1024 * 1024;
    const p = dividir(e);
    try t.expectEqual(@as(u32, 90000), p.soma());
    try t.expectEqual(@as(u32, 90000 - 5120 - 1024), p.get(.anonima));
    try t.expect(!p.tem[@intFromEnum(Parte.programa)] and !p.tem[@intFromEnum(Parte.heap_livre)]);
}
