//! O retrato da conta (core/state_format.zig) em disco, na pasta da conta do cache de
//! mensagens: $XDG_CACHE_HOME/larpercord/messages/<conta>/conta.lcs (600, na pasta 700).
//! Segue "Guardar mensagens no disco" e vai junto com "Apagar cache" e com a conta
//! removida (é a mesma pasta). Gravado depois que o READY assenta e ao sair da conta ou
//! fechar o app; lido na abertura, antes de o chaveiro responder, para a tela aparecer
//! na hora com servidores, canais e conversas (app.zig, `openFromCache`). O READY de
//! verdade passa por cima e tira o que sumiu (core/store.zig, `dropStale`).
const std = @import("std");
const c = @import("c");
const types = @import("../core/types.zig");
const format = @import("../core/state_format.zig");
const snapshot = @import("../core/state_snapshot.zig");
const Store = @import("../core/store.zig").Store;
const msg_cache = @import("msg_cache.zig");
const fsutil = @import("../platform/fsutil.zig");
const Id = types.Id;

const file_name = "conta.lcs";

/// Quanto depois do READY grava: o que chega logo atrás dele (pastas, cargos, threads)
/// já entrou.
pub const settle_ms: i64 = 10_000;

fn path(buf: []u8) ?[:0]const u8 {
    return msg_cache.accountFile(buf, file_name);
}

// --- Gravar ------------------------------------------------------------------------

/// Grava o retrato da conta conectada (nada fora de uma sessão pronta, nem com o cache
/// desligado). Num .tmp e depois troca de nome: nunca fica um arquivo pela metade.
pub fn save(s: *const Store) bool {
    if (!s.ready or s.me == 0) return false;
    var pbuf: [512]u8 = undefined;
    const p = path(&pbuf) orelse return false;
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const snap = snapshot.collect(arena.allocator(), s) catch return false;
    var out: std.ArrayList(u8) = .empty;
    format.encode(&out, arena.allocator(), &snap) catch return false;
    if (!msg_cache.ensureAccountDir()) return false;
    return fsutil.replacePrivate(p, out.items);
}

// --- Abrir -------------------------------------------------------------------------

/// O retrato da conta atual (null = não tem, cache desligado, ou estragado: apagado).
/// Tudo em `a` (uma arena).
pub fn load(a: std.mem.Allocator) ?format.Snapshot {
    var pbuf: [512]u8 = undefined;
    const p = path(&pbuf) orelse return null;
    var size: usize = 0;
    const data = c.SDL_LoadFile(p.ptr, &size) orelse return null;
    defer c.SDL_free(data);
    return format.decode(a, @as([*]const u8, @ptrCast(data))[0..size]) catch {
        // Gravação interrompida ou versão de outro jeito: sai do caminho.
        _ = c.unlink(p.ptr);
        return null;
    };
}

/// Apaga o retrato da conta atual (o token foi recusado: o que ele mostra não vale).
pub fn forget() void {
    var pbuf: [512]u8 = undefined;
    const p = path(&pbuf) orelse return;
    _ = c.unlink(p.ptr);
}
