//! Qual mascote o app usa (Configurações → Aparência): o Terminal, o principal,
//! ou o Clássico, o da cara de deboche. Daqui saem o desenho animado da abertura,
//! o parado do "Sobre" e a prévia das Configurações; os ícones da janela, da
//! bandeja e do sistema trocam junto (ver App.applyMascot).
const c = @import("c");
const logo = @import("logo.zig");
const terminal = @import("mascote_terminal.zig");

pub const Kind = @import("mascote_contas.zig").Kind;

/// Parado e pequeno ("Sobre", barra de título).
pub fn still(kind: Kind, dl: *c.ImDrawList, cx: f32, cy: f32, size: f32) void {
    switch (kind) {
        .terminal => terminal.still(dl, cx, cy, size),
        .classico => logo.still(dl, cx, cy, size),
    }
}

/// A abertura sozinha, sem a tela de login (a prévia das Configurações): `t` em
/// segundos desde o começo.
pub fn preview(kind: Kind, dl: *c.ImDrawList, cx: f32, cy: f32, size: f32, t: f32, light: bool, reduce: bool) void {
    switch (kind) {
        .terminal => terminal.draw(dl, cx, cy, size, .{ .t = t, .light = light, .reduce = reduce }),
        .classico => logo.draw(dl, cx, cy, size, if (reduce) .{} else logo.introPose(t)),
    }
}

/// Quanto dura a abertura de cada um (depois disso, a prévia pode parar).
pub fn introSeconds(kind: Kind) f32 {
    return switch (kind) {
        .terminal => 3.4,
        .classico => 1.5,
    };
}
