//! Aperte para falar com outra janela em foco. No Windows a thread de voz lê a
//! tecla com o GetAsyncKeyState a cada quadro de 20 ms da call: sem gancho de
//! teclado (é o que antivírus e anti-cheat procuram), sem administrador, e o
//! outro programa continua recebendo a tecla. No Linux, por enquanto, só com a
//! janela em foco (os eventos do SDL, em net/voz_audio.zig).
const builtin = @import("builtin");
const voz = @import("../core/voz.zig");

pub const supported = builtin.os.tag == .windows;

/// O código virtual da tecla do atalho, ou 0 se não der para ler sem foco. Na
/// thread da interface: o de uma tecla de caractere depende do layout de agora
/// (por isso também muda com SDL_EVENT_KEYMAP_CHANGED, em net/voz_audio.zig).
pub fn vkOf(b: voz.Binding) u8 {
    if (comptime supported) {
        return switch (voz.winKey(b)) {
            .none => 0,
            .vk => |v| v,
            .scan => |sc| blk: {
                const MapVirtualKeyW = @extern(*const fn (u32, u32) callconv(.winapi) u32, .{ .name = "MapVirtualKeyW", .library_name = "user32" });
                const map_vsc_to_vk_ex = 3;
                const vk = MapVirtualKeyW(sc, map_vsc_to_vk_ex);
                break :blk if (vk > 0 and vk <= 0xFF) @intCast(vk) else 0;
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
