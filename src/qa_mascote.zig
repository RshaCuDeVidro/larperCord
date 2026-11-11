//! QA do mascote (Configurações → Aparência → Mascote): os dois cartões aparecem
//! com a prévia, o clique troca a escolha e os ícones seguem (janela, bandeja e
//! avisos; a pasta de ícones do usuário fica fora do QA), a tela de abertura
//! desenha o Terminal em cada fase (abertura, conectando, erro, saída) e o
//! Clássico continua o de antes, e a abertura do demo espera a animação inteira
//! antes de sair para o app. Sozinho: QA_SUITE=mascote.
const std = @import("std");
const App = @import("app.zig").App;
const R = @import("qa_runner.zig");
const Op = R.Op;
const qa = @import("ui/qa.zig");
const platform = @import("platform/window.zig");

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

var sets_before: u32 = 0;

fn openAppearance(app: *App) void {
    app.st.settings.page = .aparencia;
    app.handle(.open_settings);
}
fn closeSettings(app: *App) void {
    app.handle(.close_settings);
}
fn terminalIsDefault(app: *App) bool {
    return app.st.settings.mascot == 0 and app.mascot_applied == .terminal;
}
fn cardsShown(_: *App) bool {
    return qa.find("mascot:0") != null and qa.find("mascot:1") != null;
}
fn noteIcons(_: *App) void {
    sets_before = platform.icon_sets;
}
fn classicChosen(app: *App) bool {
    return app.st.settings.mascot == 1 and app.mascot_applied == .classico and platform.icon_sets > sets_before;
}
fn terminalBack(app: *App) bool {
    return app.st.settings.mascot == 0 and app.mascot_applied == .terminal and platform.icon_sets > sets_before;
}

// --- A tela de abertura, em cada fase -----------------------------------------

fn loginForm(app: *App) void {
    app.login.begin(.form);
}
fn at(app: *App, t: f32) void {
    app.login.t = t;
    app.login.err_at = -10;
}
fn atCursor(app: *App) void {
    at(app, 0.3);
}
fn atOpen(app: *App) void {
    at(app, 0.72);
}
fn atEars(app: *App) void {
    at(app, 1.05);
}
fn atFace(app: *App) void {
    at(app, 1.45);
}
fn atIdle(app: *App) void {
    at(app, 3.2);
}
fn connecting(app: *App) void {
    // O demo do QA já está conectado: sem isto a abertura sairia na hora.
    app.login_min_t = 1000;
    app.login.setPhase(.connecting);
    app.login.t = 3.2;
}
fn stillConnecting(app: *App) bool {
    return app.login.phase == .connecting;
}
fn failed(app: *App) void {
    app.login_min_t = 0;
    app.login.fail("QA");
    app.login.t = app.login.err_at + 0.12;
}
fn leaving(app: *App) void {
    app.login.setPhase(.leaving);
    app.login.t = app.login.phase_at + 0.3;
}
fn loginShown(app: *App) bool {
    return app.login.visible();
}
fn loginGone(app: *App) bool {
    return !app.login.visible();
}
fn chooseClassic(app: *App) void {
    app.st.settings.mascot = 1;
    app.login.begin(.form);
    app.login.t = 3.2;
}
fn chooseTerminal(app: *App) void {
    app.st.settings.mascot = 0;
    app.login.phase = .hidden;
}

// --- As outras aberturas -----------------------------------------------------------

/// Escolhe a abertura `n` e mostra a tela no instante `t` dela.
fn openingAt(comptime n: u8, comptime t: f32) fn (*App) void {
    return struct {
        fn f(app: *App) void {
            app.st.settings.mascot = 0;
            app.st.settings.mascot_opening = n;
            if (!app.login.visible()) app.login.begin(.form);
            app.login.t = t;
            app.login.err_at = -10;
        }
    }.f;
}
fn openingBack(app: *App) void {
    app.st.settings.mascot_opening = 0;
    app.login.phase = .hidden;
}

// --- A abertura do demo ----------------------------------------------------------

fn demoOpening(app: *App) void {
    app.login.begin(.connecting);
    app.login_min_t = 1.0;
}
fn waitsForIntro(app: *App) bool {
    // Conectado desde o começo, mas a animação ainda não acabou: continua nela.
    return app.store.ready and app.login.phase == .connecting and app.login.t < 1.0;
}
fn leftAfterIntro(app: *App) bool {
    return (app.login.phase == .leaving or app.login.phase == .hidden) and app.login.t >= 1.0;
}
fn reduceOpening(app: *App) void {
    app.st.settings.reduce_motion = true;
    app.login.begin(.connecting);
    app.login_min_t = 5.0;
}
fn reduceSkips(app: *App) bool {
    return !app.login.visible();
}
fn reduceOff(app: *App) void {
    app.st.settings.reduce_motion = false;
}

pub const ops = [_]Op{
    s("mascote nas configurações"),
    expect("o Terminal é o mascote de quem nunca escolheu", terminalIsDefault),
    run(openAppearance),
    expect("os dois cartões aparecem, com a prévia", cardsShown),
    run(noteIcons),
    click("mascot:1"),
    expect("escolher o Clássico troca a configuração e o ícone da janela", classicChosen),
    .{ .shot = "mascote-config-classico" },
    run(noteIcons),
    click("mascot:0"),
    expect("voltar ao Terminal troca o ícone de novo", terminalBack),
    .{ .wait = 600 },
    .{ .shot = "mascote-config" },
    run(closeSettings),

    s("abertura com o Terminal"),
    run(loginForm),
    expect("a tela de abertura aparece", loginShown),
    run(atCursor),
    .{ .shot = "mascote-1-cursor" },
    run(atOpen),
    .{ .shot = "mascote-2-abrindo" },
    run(atEars),
    .{ .shot = "mascote-3-orelhas" },
    run(atFace),
    .{ .shot = "mascote-4-rosto" },
    run(atIdle),
    .{ .shot = "mascote-5-parado" },
    run(connecting),
    expect("conectando, a abertura fica (com o \"...\" no lugar do \"_\")", stillConnecting),
    .{ .shot = "mascote-6-conectando" },
    run(failed),
    .{ .shot = "mascote-7-erro" },
    run(leaving),
    .{ .shot = "mascote-8-saindo" },
    .{ .expect = .{ .name = "a saída (a TV desligando) termina e a tela some", .check = loginGone, .timeout_ms = 3000 } },
    run(chooseClassic),
    .{ .shot = "mascote-classico" },
    run(chooseTerminal),

    s("as outras aberturas do Terminal"),
    run(openingAt(1, 0.7)),
    expect("chuva de código: a tela aparece", loginShown),
    .{ .shot = "abertura-codigo-meio" },
    run(openingAt(1, 1.9)),
    .{ .shot = "abertura-codigo-fim" },
    run(openingAt(2, 0.3)),
    .{ .shot = "abertura-tv-barras" },
    run(openingAt(2, 0.8)),
    .{ .shot = "abertura-tv-rolando" },
    run(openingAt(3, 0.9)),
    .{ .shot = "abertura-pixels-meio" },
    run(openingAt(3, 1.38)),
    .{ .shot = "abertura-pixels-montado" },
    run(openingAt(4, 0.7)),
    .{ .shot = "abertura-portal-subindo" },
    run(openingAt(4, 1.0)),
    expect("portal: ainda na abertura", loginShown),
    .{ .shot = "abertura-portal-quique" },
    run(openingAt(5, 2.5)),
    expect("\"sortear\" também abre", loginShown),
    .{ .shot = "abertura-sorteada" },
    run(openingBack),

    s("abertura do demo"),
    run(demoOpening),
    expect("conectado, a abertura espera a animação acabar", waitsForIntro),
    .{ .expect = .{ .name = "depois da animação, sai para o app", .check = leftAfterIntro, .timeout_ms = 4000 } },
    .{ .expect = .{ .name = "e a tela some no fim da saída", .check = loginGone, .timeout_ms = 3000 } },
    run(reduceOpening),
    expect("com \"Reduzir animações\", nada de abertura", reduceSkips),
    run(reduceOff),
};
