//! Devolver memória com a glibc. Em outro sistema, nada aqui faz efeito.
//! (Limitar as arenas com M_ARENA_MAX foi medido e não ganhou além do ruído.)
const builtin = @import("builtin");
const c = @import("c");

const glibc = builtin.os.tag == .linux and builtin.abi.isGnu();

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
    if (glibc) _ = c.malloc_trim(0);
}

pub const Heap = struct { used_kb: u32, free_kb: u32 };

/// O que o malloc tem em uso e o que tem livre sem ter devolvido. Também percorre as
/// arenas: fora da thread da UI, e não em call (ver `App.tick`).
pub fn heap() ?Heap {
    if (glibc) {
        const m = c.mallinfo2();
        return .{ .used_kb = @intCast((m.uordblks + m.hblkhd) / 1024), .free_kb = @intCast(m.fordblks / 1024) };
    }
    return null;
}
