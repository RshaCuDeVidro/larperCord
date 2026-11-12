//! Os atalhos personalizáveis na hora de apertar: liga cada combinação
//! (core/combinacao.zig) a uma tecla do ImGui, diz se a combinação de uma ação foi
//! apertada neste quadro e escreve o texto que aparece nas dicas. As trocas ficam em
//! `State.teclas` (ui/atalhos.zig `Personalizados`), salvas no settings.kdl.
const std = @import("std");
const c = @import("c");
const atalhos = @import("atalhos.zig");
const comb = @import("../core/combinacao.zig");

pub const Acao = atalhos.Acao;
pub const Combinacao = comb.Combinacao;

/// Em Configurações → Atalhos de teclado, esperando a combinação nova de uma ação:
/// enquanto isso, nenhum atalho dispara.
pub var capturing: ?Acao = null;
/// O quadro em que uma troca terminou (gravou ou o Esc cancelou): a tecla que a
/// terminou é dela, e não dispara mais nada nesse quadro (nem abre a paleta, nem fecha
/// as Configurações).
pub var capture_end_frame: c_int = -1;

/// Uma troca está esperando tecla, ou acabou de terminar neste quadro.
pub fn busy() bool {
    return capturing != null or capture_end_frame == c.ImGui_GetFrameCount();
}

pub fn endCapture() void {
    capturing = null;
    capture_end_frame = c.ImGui_GetFrameCount();
}

pub fn imguiKey(key: comb.Key) c_int {
    return switch (key) {
        inline .a, .b, .c, .d, .e, .f, .g, .h, .i, .j, .k, .l, .m, .n, .o, .p, .q, .r, .s, .t, .u, .v, .w, .x, .y, .z => |k| @field(c, "ImGuiKey_" ++ upperOne(@tagName(k))),
        inline .@"0", .@"1", .@"2", .@"3", .@"4", .@"5", .@"6", .@"7", .@"8", .@"9" => |k| @field(c, "ImGuiKey_" ++ @tagName(k)),
        inline .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12 => |k| @field(c, "ImGuiKey_F" ++ @tagName(k)[1..]),
        .tab => c.ImGuiKey_Tab,
        .enter => c.ImGuiKey_Enter,
        .space => c.ImGuiKey_Space,
        .backspace => c.ImGuiKey_Backspace,
        .delete => c.ImGuiKey_Delete,
        .insert => c.ImGuiKey_Insert,
        .home => c.ImGuiKey_Home,
        .end => c.ImGuiKey_End,
        .pageup => c.ImGuiKey_PageUp,
        .pagedown => c.ImGuiKey_PageDown,
        .up => c.ImGuiKey_UpArrow,
        .down => c.ImGuiKey_DownArrow,
        .left => c.ImGuiKey_LeftArrow,
        .right => c.ImGuiKey_RightArrow,
        .comma => c.ImGuiKey_Comma,
        .period => c.ImGuiKey_Period,
        .slash => c.ImGuiKey_Slash,
        .semicolon => c.ImGuiKey_Semicolon,
        .minus => c.ImGuiKey_Minus,
        .equal => c.ImGuiKey_Equal,
        .backslash => c.ImGuiKey_Backslash,
        .apostrophe => c.ImGuiKey_Apostrophe,
        .grave => c.ImGuiKey_GraveAccent,
        .escape => c.ImGuiKey_Escape,
    };
}

fn upperOne(comptime s: []const u8) []const u8 {
    return &[_]u8{std.ascii.toUpper(s[0])};
}

/// A combinação foi apertada neste quadro (os modificadores exatos: Ctrl+Shift+T não
/// dispara o Ctrl+T). `repeat`: segurar repete.
pub fn hit(io: *const c.ImGuiIO, cb: Combinacao, repeat: bool) bool {
    if (io.KeyCtrl != cb.ctrl or io.KeyShift != cb.shift or io.KeyAlt != cb.alt) return false;
    if (c.ImGui_IsKeyPressedEx(imguiKey(cb.key), repeat)) return true;
    // Enter do teclado numérico vale como Enter.
    return cb.key == .enter and c.ImGui_IsKeyPressedEx(c.ImGuiKey_KeypadEnter, repeat);
}

/// Alguma combinação de `acao` foi apertada neste quadro.
pub fn pressed(p: *const atalhos.Personalizados, io: *const c.ImGuiIO, acao: Acao, repeat: bool) bool {
    if (busy()) return false;
    var buf: [4]Combinacao = undefined;
    for (p.de(acao, &buf)) |cb| if (hit(io, cb, repeat)) return true;
    return false;
}

/// "Ctrl+Shift+M", ou as alternativas do padrão ("F2 / Ctrl+T").
pub fn label(p: *const atalhos.Personalizados, acao: Acao, out: []u8) []const u8 {
    var buf: [4]Combinacao = undefined;
    var n: usize = 0;
    for (p.de(acao, &buf), 0..) |cb, i| {
        if (i > 0) {
            if (n + 3 > out.len) break;
            @memcpy(out[n..][0..3], " / ");
            n += 3;
        }
        var one: [32]u8 = undefined;
        const t = cb.format(&one);
        if (n + t.len > out.len) break;
        @memcpy(out[n..][0..t.len], t);
        n += t.len;
    }
    return out[0..n];
}

/// A combinação apertada neste quadro (para a troca), ou null. Só teclas que um
/// atalho pode usar; os modificadores sozinhos não contam.
pub fn captured(io: *const c.ImGuiIO) ?Combinacao {
    inline for (@typeInfo(comb.Key).@"enum".field_names) |name| {
        const key = @field(comb.Key, name);
        if (c.ImGui_IsKeyPressedEx(imguiKey(key), false))
            return .{ .key = key, .ctrl = io.KeyCtrl, .shift = io.KeyShift, .alt = io.KeyAlt };
    }
    return null;
}
