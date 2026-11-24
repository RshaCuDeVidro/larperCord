//! Devolver memória ao sistema: com a glibc no Linux, e no Windows ao ir para a bandeja
//! (`giveBack`). Em outro sistema, nada aqui faz efeito. Com -Dmimalloc o malloc é o dele
//! (build.zig), e devolver e contar passam por ele (src/platform/mem_mi.c).
//! (Limitar as arenas com M_ARENA_MAX foi medido e não ganhou além do ruído.)
const std = @import("std");
const builtin = @import("builtin");
const c = @import("c");

pub const mimalloc = @import("build_options").mimalloc;
const glibc = builtin.os.tag == .linux and builtin.abi.isGnu() and !mimalloc;

extern fn larper_mi_trim() void;
extern fn larper_mi_heap(used: *usize, committed: *usize) c_int;

/// No começo do `main`, antes de qualquer thread. O limite de mmap da glibc é
/// dinâmico: um bloco grande liberado o faz subir, e daí em diante os buffers de
/// pixels das threads de mídia saem das arenas delas e ficam presos lá. Na conta
/// real, depois de 4h30: 190 MB livres sem voltar ao sistema, em 4 arenas de
/// ~40 MB (uma por thread de mídia), com só 43 MB em uso; o malloc_trim não
/// resolvia. Um valor fixo desliga o ajuste: bloco de 128 KiB ou mais vira um
/// mmap próprio, que volta ao sistema no free.
pub fn init() void {
    if (glibc) _ = c.mallopt(c.M_MMAP_THRESHOLD, 128 * 1024);
}

/// Devolve ao sistema o que está livre no meio das arenas (só o topo volta
/// sozinho). Leva milissegundos: fora da thread da UI.
pub fn trim() void {
    if (mimalloc) larper_mi_trim();
    if (glibc) _ = c.malloc_trim(0);
}

/// A janela foi para a bandeja (App.releaseGpu): além do `trim` (que o tique já faz
/// junto), no Windows cada heap do processo se compacta e o conjunto de trabalho
/// esvazia: o que não é usado sai da RAM, e o que for usado volta sozinho. Fora da
/// thread da UI, e não em call (a voz não pode esperar uma página voltar).
pub fn giveBack() void {
    if (builtin.os.tag != .windows) return;
    var heaps: [64]c.HANDLE = undefined;
    const n = c.GetProcessHeaps(heaps.len, &heaps);
    for (heaps[0..@min(n, heaps.len)]) |h| _ = c.HeapCompact(h, 0);
    _ = c.SetProcessWorkingSetSize(c.GetCurrentProcess(), std.math.maxInt(usize), std.math.maxInt(usize));
}

pub const Heap = struct {
    used_kb: u32,
    free_kb: u32,
    /// Dos que estão em uso, os blocos grandes que são um mmap próprio cada (glibc: a partir
    /// de 128 KiB, ver `init`): eles aparecem no mapa de memória como anônimos sem nome.
    mmap_kb: u32 = 0,
};

/// O que o malloc tem em uso e o que tem livre sem ter devolvido. Também percorre as
/// arenas: fora da thread da UI, e não em call (ver `App.tick`).
pub fn heap() ?Heap {
    if (mimalloc) {
        var used: usize = 0;
        var committed: usize = 0;
        if (larper_mi_heap(&used, &committed) == 0) return null;
        return .{ .used_kb = @intCast(used / 1024), .free_kb = @intCast((committed -| used) / 1024) };
    }
    if (glibc) {
        const m = c.mallinfo2();
        return .{ .used_kb = @intCast((m.uordblks + m.hblkhd) / 1024), .free_kb = @intCast(m.fordblks / 1024), .mmap_kb = @intCast(m.hblkhd / 1024) };
    }
    return null;
}
