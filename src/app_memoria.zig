//! Para onde vai a RAM do processo: Configurações → Desempenho, o `--stats` e o QA da conta
//! grande. A divisão em si é a de core/mem_partes.zig; aqui se juntam os números.
//!
//! O mapa de memória e o heap custam milissegundos e são lidos fora da thread da UI, no tique
//! (`medir`, só com a página na tela ou com o `--stats`); a UI junta a última medida com o que
//! as bibliotecas contam e a estimativa da conta (`partes`). O `logar` lê tudo na hora.
const std = @import("std");
const App = @import("app.zig").App;
const Store = @import("core/store.zig").Store;
const mem_mapa = @import("platform/mem_mapa.zig");
const mem_tune = @import("platform/mem_tune.zig");
const mem_contas = @import("platform/mem_contas.zig");
const mem_use = @import("core/mem_use.zig");
const mem_partes = @import("core/mem_partes.zig");
const engine = @import("plugins/engine.zig");
const Parte = mem_partes.Parte;

const Medida = struct {
    mapa: ?mem_mapa.Mapa = null,
    heap: ?mem_tune.Heap = null,
    /// Sem mapa (Windows): a memória privada.
    total_kb: u32 = 0,
};

/// Duas medidas: o tique escreve numa enquanto a UI lê a outra.
var medidas: [2]Medida = .{ .{}, .{} };
var atual: std.atomic.Value(u8) = .init(0);

/// No tique (fora da thread da UI). `com_heap` = pode percorrer as arenas do malloc (não em
/// call: quem pede memória espera a varredura); sem isso fica o heap da medida anterior.
pub fn medir(com_heap: bool, total_kb: u32) void {
    const prev = atual.load(.acquire);
    const i: u8 = 1 - prev;
    medidas[i] = .{
        .mapa = mem_mapa.ler(),
        .heap = if (com_heap) mem_tune.heap() else medidas[prev].heap,
        .total_kb = total_kb,
    };
    atual.store(i, .release);
}

/// Os bytes de Lua de todos os plugins.
fn luaBytes() ?u64 {
    if (comptime @import("builtin").os.tag == .emscripten) return null;
    const e = engine.current orelse return null;
    var t: u64 = 0;
    for (e.list.items) |p| t += p.memBytes();
    return t;
}

fn entrada(m: Medida, conta: mem_use.MemUse) mem_partes.Entrada {
    var e: mem_partes.Entrada = .{ .total_kb = m.total_kb, .mapa = m.mapa };
    if (m.heap) |h| {
        e.heap_usado_kb = h.used_kb;
        e.heap_livre_kb = h.free_kb;
        e.heap_mmap_kb = h.mmap_kb;
    }
    for ([_]mem_contas.Lib{ .sdl, .imgui, .freetype, .curl, .openssl }, 0..) |l, i| e.libs[i] = mem_contas.bytes(l);
    e.libs[5] = luaBytes();
    e.mensagens = conta.messages;
    e.pessoas = conta.people;
    e.lugares = conta.places;
    return e;
}

/// A divisão com a última medida do tique (na thread da UI). Total 0 = ainda não mediu.
pub fn partes(conta: mem_use.MemUse) mem_partes.Partes {
    return mem_partes.dividir(entrada(medidas[atual.load(.acquire)], conta));
}

/// Tudo lido agora (na thread da UI: leva milissegundos), uma linha por parte no log
/// (`ram[rótulo] ...`): o --stats e o QA da conta grande, para quem mede comparar.
pub fn logar(app: *App, rotulo: []const u8) void {
    const conta = mem_use.of(&app.store);
    const m: Medida = .{ .mapa = mem_mapa.ler(), .heap = mem_tune.heap(), .total_kb = @import("platform/window.zig").selfMemKb().pss };
    const p = mem_partes.dividir(entrada(m, conta));
    const mb = struct {
        fn f(kb: u32) f64 {
            return @as(f64, @floatFromInt(kb)) / 1024;
        }
    }.f;
    std.log.info("ram[{s}] total {d:.1} MB ({s}), heap em uso {d:.1} MB; {d} mensagens, {d} pessoas, {d} canais, {d} imagens ({d:.1} MB de textura)", .{
        rotulo, mb(p.total_kb), if (m.mapa != null) "PSS do mapa" else "memória privada", mb(p.heapUsado()), conta.n_messages, conta.n_people, conta.n_channels, app.images.readyCount(), mb(@intCast(app.images.bytes / 1024)),
    });
    for (std.enums.values(Parte)) |x| if (p.tem[@intFromEnum(x)]) {
        std.log.info("ram[{s}]   {s}{s} {d:.1} MB", .{ rotulo, if (x.doHeap()) "  " else "", @tagName(x), mb(p.get(x)) });
    };
}
