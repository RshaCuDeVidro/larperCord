//! QA dos atalhos personalizáveis (#18, Configurações → Atalhos de teclado): trocar o
//! atalho da paleta faz a combinação nova abrir e a velha não; o que não pode
//! (já usado, fixo do app, sem Ctrl/Alt) é recusado com o motivo; Esc cancela a troca
//! sem fechar as Configurações; "Padrão" volta; e as dicas do mudo mostram a
//! combinação de agora. QA_SUITE=atalhos.
const std = @import("std");
const c = @import("c");
const App = @import("app.zig").App;
const R = @import("qa_runner.zig");
const Op = R.Op;
const qa = @import("ui/qa.zig");
const teclas = @import("ui/teclas.zig");
const Combinacao = @import("core/combinacao.zig").Combinacao;

fn s(name: []const u8) Op {
    return .{ .section = name };
}
fn click(k: []const u8) Op {
    return .{ .click = .{ .mark = k } };
}
fn expect(name: []const u8, f: *const fn (*App) bool) Op {
    return .{ .expect = .{ .name = name, .check = f } };
}
fn run(f: *const fn (*App) void) Op {
    return .{ .run = f };
}
fn key(k: c_int, ctrl: bool, shift: bool, alt: bool) Op {
    return .{ .key = .{ .key = k, .ctrl = ctrl, .shift = shift, .alt = alt } };
}

fn ready(app: *App) bool {
    return app.store.ready;
}
fn openKeys(app: *App) void {
    app.st.settings.open = true;
    app.st.settings.page = .atalhos;
}
fn closeSettings(app: *App) void {
    app.st.settings.open = false;
}
fn rowShown(_: *App) bool {
    return qa.find("keybind:paleta") != null and qa.find("keybind:mutar") != null and teclas.capturing == null;
}
fn capturingPalette(_: *App) bool {
    return teclas.capturing == .paleta and qa.find("keybind-capturing:paleta") != null;
}
fn capturingMute(_: *App) bool {
    return teclas.capturing == .mutar;
}
fn paletteIsCtrlJ(app: *App) bool {
    var buf: [4]Combinacao = undefined;
    const l = app.st.teclas.de(.paleta, &buf);
    return teclas.capturing == null and l.len == 1 and l[0].eql(Combinacao.parse("Ctrl+J").?) and app.st.teclas.trocado(.paleta);
}
fn paletteOpen(app: *App) bool {
    return app.st.palette.open;
}
fn paletteClosed(app: *App) bool {
    return !app.st.palette.open;
}
fn closePalette(app: *App) void {
    app.st.palette.open = false;
}
fn refusedInUse(app: *App) bool {
    return teclas.capturing == .mutar and qa.find("keybind-problem") != null and !app.st.teclas.trocado(.mutar);
}
fn stillCapturingNoChange(app: *App) bool {
    return teclas.capturing == .mutar and qa.find("keybind-problem") != null and !app.st.teclas.trocado(.mutar);
}
fn cancelledOpen(app: *App) bool {
    return teclas.capturing == null and app.st.settings.open and !app.st.teclas.trocado(.mutar);
}
fn muteIsAltM(app: *App) bool {
    var b: [48]u8 = undefined;
    return std.mem.eql(u8, teclas.label(&app.st.teclas, .mutar, &b), "Alt+M");
}
var muted_before = false;
fn rememberMute(app: *App) void {
    muted_before = app.st.muted;
}
fn muteToggled(app: *App) bool {
    return app.st.muted != muted_before;
}
fn paletteBackToDefault(app: *App) bool {
    return !app.st.teclas.trocado(.paleta) and qa.find("keybind-reset:paleta") == null;
}
fn resetMute(app: *App) void {
    app.st.teclas.set(.mutar, null);
    if (app.st.muted != muted_before) app.st.muted = muted_before;
}

pub const ops = [_]Op{
    s("atalhos personalizáveis"),
    expect("pronto", ready),
    run(openKeys),
    expect("a página de atalhos tem os que dá para trocar", rowShown),
    click("keybind:paleta"),
    expect("clicar nas teclas espera a combinação nova", capturingPalette),
    .{ .shot = "atalhos-esperando" },
    key(c.ImGuiKey_J, true, false, false),
    expect("Ctrl+J vira o atalho da paleta", paletteIsCtrlJ),
    .{ .shot = "atalhos-trocado" },
    run(closeSettings),
    .{ .wait = 100 },
    key(c.ImGuiKey_J, true, false, false),
    expect("e Ctrl+J abre a paleta", paletteOpen),
    run(closePalette),
    .{ .wait = 100 },
    key(c.ImGuiKey_K, true, false, false),
    .{ .wait = 150 },
    expect("o Ctrl+K de antes não abre mais", paletteClosed),
    run(openKeys),
    .{ .wait = 100 },
    click("keybind:mutar"),
    expect("trocar o do mudo", capturingMute),
    key(c.ImGuiKey_F, true, false, false),
    expect("Ctrl+F já é da busca: recusa e diz de quem é", refusedInUse),
    .{ .shot = "atalhos-em-uso" },
    key(c.ImGuiKey_C, true, false, false),
    expect("Ctrl+C é fixo do app: recusa", stillCapturingNoChange),
    key(c.ImGuiKey_M, false, false, false),
    expect("uma letra sozinha: recusa (dispararia ao digitar)", stillCapturingNoChange),
    key(c.ImGuiKey_Escape, false, false, false),
    .{ .wait = 100 },
    expect("Esc cancela a troca sem fechar as Configurações", cancelledOpen),
    click("keybind:mutar"),
    key(c.ImGuiKey_M, false, false, true),
    expect("Alt+M vira o do mudo (a dica do botão mostra)", muteIsAltM),
    run(closeSettings),
    run(rememberMute),
    .{ .wait = 100 },
    key(c.ImGuiKey_M, false, false, true),
    expect("e Alt+M muta", muteToggled),
    run(resetMute),
    run(openKeys),
    .{ .wait = 100 },
    click("keybind-reset:paleta"),
    expect("\"Padrão\" volta a paleta para o Ctrl+K", paletteBackToDefault),
    run(closeSettings),
    .{ .wait = 100 },
    key(c.ImGuiKey_K, true, false, false),
    expect("e o Ctrl+K abre a paleta de novo", paletteOpen),
    run(closePalette),
};
