//! Aperte para falar com outra janela em foco. No Windows a thread de voz lê a
//! tecla com o GetAsyncKeyState a cada quadro de 20 ms da call: sem gancho de
//! teclado (é o que antivírus e anti-cheat procuram), sem administrador, e o
//! outro programa continua recebendo a tecla. No Linux, por enquanto, só com a
//! janela em foco (os eventos do SDL, em net/voz_audio.zig).
const builtin = @import("builtin");
const c = @import("c");
const voz = @import("../core/voz.zig");

pub const supported = builtin.os.tag == .windows;

/// O código virtual da tecla do atalho, ou 0 se não der para ler sem foco. Na
/// thread da interface: o de uma tecla de caractere depende do layout de agora.
pub fn vkOf(b: voz.Binding) u8 {
    if (comptime supported) {
        return switch (voz.winKey(b)) {
            .none => 0,
            .vk => |v| v,
            .layout => blk: {
                const key = c.SDL_GetKeyFromScancode(@intCast(b.key), c.SDL_KMOD_NONE, false);
                if (key == 0 or key > 0xFFFF) break :blk 0;
                const VkKeyScanW = @extern(*const fn (u16) callconv(.winapi) i16, .{ .name = "VkKeyScanW", .library_name = "user32" });
                const r = VkKeyScanW(@intCast(key));
                // Byte baixo: o código virtual; -1: nenhuma tecla do layout dá esse caractere.
                break :blk if (r == -1) 0 else @truncate(@as(u16, @bitCast(r)));
            },
        };
    } else return 0;
}

/// A tecla está apertada agora, com ou sem foco? Qualquer thread.
pub fn down(vk: u8) bool {
    if (comptime supported) {
        if (vk == 0) return false;
        const GetAsyncKeyState = @extern(*const fn (c_int) callconv(.winapi) i16, .{ .name = "GetAsyncKeyState", .library_name = "user32" });
        // Bit mais alto: apertada agora.
        return GetAsyncKeyState(vk) < 0;
    } else return false;
}
