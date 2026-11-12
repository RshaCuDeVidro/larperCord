//! QA dos atalhos personalizáveis (#18, Configurações → Atalhos de teclado): trocar o
//! atalho da paleta faz a combinação nova abrir e a velha não; o que não pode
//! (já usado, fixo do app, sem Ctrl/Alt) é recusado com o motivo; Esc cancela a troca
//! sem fechar as Configurações; "Padrão" volta, mas não por cima de outra ação;
//! segurar a tecla nova não a repete logo depois; e as dicas do mudo mostram a
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

// Segurar a tecla que termina a troca: o ImGui repete depois de ~0,3 s, e o próximo
// tema (que repete) trocaria de tema sem parar atrás das Configurações.
var theme_before: usize = 0;
fn rememberTheme(app: *App) void {
    theme_before = app.themes.current;
}
fn capturingNextTheme(_: *App) bool {
    return teclas.capturing == .proximo_tema;
}
fn holdF6(app: *App) void {
    c.ImGuiIO_AddKeyEvent(app.io, c.ImGuiKey_F6, true);
}
fn releaseF6(app: *App) void {
    c.ImGuiIO_AddKeyEvent(app.io, c.ImGuiKey_F6, false);
}
fn heldNoRepeat(app: *App) bool {
    var b: [32]u8 = undefined;
    return teclas.capturing == null and std.mem.eql(u8, teclas.label(&app.st.teclas, .proximo_tema, &b), "F6") and
        app.themes.current == theme_before and app.st.settings.open;
}
fn themeSame(app: *App) bool {
    return app.themes.current == theme_before;
}
fn themeChanged(app: *App) bool {
    return app.themes.current != theme_before;
}
fn resetNextTheme(app: *App) void {
    app.st.teclas.set(.proximo_tema, null);
}

// "Padrão" de uma ação cuja tecla de fábrica outra pegou.
fn takeCtrlT(app: *App) void {
    app.st.teclas.set(.proximo_tema, Combinacao.parse("F5").?);
    app.st.teclas.set(.paleta, Combinacao.parse("Ctrl+T").?);
}
fn resetRefused(app: *App) bool {
    return app.st.teclas.trocado(.proximo_tema) and qa.find("keybind-problem") != null and app.st.teclas.donoDoPadrao(.proximo_tema) == .paleta;
}
fn undoCtrlT(app: *App) void {
    app.st.teclas.set(.proximo_tema, null);
    app.st.teclas.set(.paleta, null);
}
fn defaultsBack(app: *App) bool {
    return !app.st.teclas.trocado(.proximo_tema) and !app.st.teclas.trocado(.paleta);
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
    key(c.ImGuiKey_C, true, true, false),
    expect("Ctrl+Shift+C também (o copiar olha só o Ctrl): recusa", stillCapturingNoChange),
    key(c.ImGuiKey_RightArrow, true, false, false),
    expect("Ctrl+→ anda por palavra no texto: recusa", stillCapturingNoChange),
    key(c.ImGuiKey_Q, true, false, true),
    expect("Ctrl+Alt+Q é o AltGr+Q (\"/\" no ABNT2): recusa", stillCapturingNoChange),
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
    .{ .wait = 100 },

    s("segurar a tecla nova"),
    run(openKeys),
    .{ .wait = 100 },
    run(rememberTheme),
    click("keybind:proximo_tema"),
    expect("trocar o do próximo tema", capturingNextTheme),
    run(holdF6),
    .{ .wait = 800 },
    expect("segurar o F6 grava, e não troca de tema enquanto ele está apertado", heldNoRepeat),
    run(releaseF6),
    .{ .wait = 100 },
    expect("soltou: o tema continua o mesmo", themeSame),
    run(closeSettings),
    .{ .wait = 100 },
    key(c.ImGuiKey_F6, false, false, false),
    expect("e apertar o F6 troca o tema", themeChanged),
    key(c.ImGuiKey_F2, false, true, false),
    expect("Shift+F2 volta o tema de antes", themeSame),
    run(resetNextTheme),

    s("Padrão por cima de outra ação"),
    run(takeCtrlT),
    run(openKeys),
    .{ .wait = 100 },
    click("keybind-reset:proximo_tema"),
    expect("o padrão do próximo tema (F2 / Ctrl+T) bate na paleta, agora no Ctrl+T: não volta e diz por quê", resetRefused),
    .{ .shot = "atalhos-padrao-em-uso" },
    run(undoCtrlT),
    expect("de volta ao de fábrica", defaultsBack),
    run(closeSettings),
};
