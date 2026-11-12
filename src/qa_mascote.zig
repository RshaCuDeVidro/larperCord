//! QA do mascote (Configurações → Aparência → Mascote): os dois cartões aparecem
//! com a prévia, o clique troca a escolha e os ícones seguem (janela, bandeja e
//! avisos; a pasta de ícones do usuário fica fora do QA), a tela de abertura
//! desenha o Terminal em cada fase (abertura, conectando, erro, saída) e o
//! Clássico continua o de antes, e a abertura do demo espera a animação inteira
//! antes de sair para o app. Sozinho: QA_SUITE=mascote.
const std = @import("std");
const c = @import("c");
const App = @import("app.zig").App;
const R = @import("qa_runner.zig");
const Op = R.Op;
const qa = @import("ui/qa.zig");
const mascote = @import("ui/mascote.zig");
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

// --- Dentro do app ------------------------------------------------------------------

fn openSaved(app: *App) void {
    app.handle(.toggle_saved);
}
fn savedSleeps(_: *App) bool {
    return qa.find("saved-empty") != null;
}
fn closeSaved(app: *App) void {
    app.handle(.toggle_saved);
}
fn dropConnection(app: *App) void {
    @import("ui/root.zig").qa_banner = true;
    app.store.connection = .reconnecting;
}
fn bannerShown(_: *App) bool {
    return qa.find("conn-banner") != null;
}
fn goOffline(app: *App) void {
    app.store.connection = .offline;
}
fn restoreConnection(app: *App) void {
    app.store.connection = .ready;
    @import("ui/root.zig").qa_banner = false;
}
fn bannerGone(_: *App) bool {
    return qa.find("conn-banner") == null;
}
var history_was: @import("core/store.zig").History = .loaded;
fn historyLoading(app: *App) void {
    const ch = app.st.activeChannel() orelse return;
    const cs = app.store.channel(ch) orelse return;
    history_was = cs.history;
    cs.history = .loading;
}
fn historyBack(app: *App) void {
    const ch = app.st.activeChannel() orelse return;
    const cs = app.store.channel(ch) orelse return;
    cs.history = history_was;
}
fn openAbout(app: *App) void {
    app.st.settings.page = .sobre;
    app.handle(.open_settings);
}
var about_before: u8 = 0;
fn noteAbout(_: *App) void {
    about_before = @import("ui/settings.zig").aboutClicks();
}
fn aboutReacted(_: *App) bool {
    return @import("ui/settings.zig").aboutClicks() != about_before;
}
var login_before: u8 = 0;
fn loginIdle(app: *App) void {
    app.login.begin(.form);
    app.login.t = 3.0;
    login_before = app.login.react_n;
}
fn loginReacted(app: *App) bool {
    return app.login.react_n != login_before;
}
fn loginHide(app: *App) void {
    app.login.phase = .hidden;
}

// --- O mascote do canto ------------------------------------------------------------

const pet = @import("ui/mascote_pet.zig");

fn petShown(_: *App) bool {
    return qa.find("pet") != null and pet.mode() == .home;
}
fn sendLaugh(app: *App) void {
    pet.onSend("KKKKKKK", app.images.now_ms);
}
fn laughing(_: *App) bool {
    return pet.reaction() == .laugh;
}
fn sendGg(app: *App) void {
    pet.onSend("gg wp", app.images.now_ms);
}
fn celebrating(_: *App) bool {
    return pet.reaction() == .gg;
}
fn sendSad(app: *App) void {
    pet.onSend("que triste :(", app.images.now_ms);
}
fn ping(app: *App) void {
    pet.onPing(app.images.now_ms);
}
fn pinged(_: *App) bool {
    return pet.reaction() == .ping;
}
fn fled(_: *App) bool {
    return pet.mode() == .away;
}
fn home(_: *App) void {
    pet.qaHome();
}
var start_pos: [2]f32 = .{ 0, 0 };
fn notePos(_: *App) void {
    start_pos = pet.position();
}
fn thrown(_: *App) bool {
    return pet.mode() != .home and pet.mode() != .grabbed;
}
fn backHome(_: *App) bool {
    return pet.mode() == .home;
}
fn idleLong(app: *App) void {
    pet.qaIdleFor(4 * 60 * 1000, app.images.now_ms);
}
fn sleeping(app: *App) bool {
    return pet.isAsleep(app.images.now_ms);
}
fn petOff(app: *App) void {
    app.st.settings.mascot_pet = false;
}
fn petGone(_: *App) bool {
    return qa.find("pet") == null;
}
fn petOn(app: *App) void {
    app.st.settings.mascot_pet = true;
}
fn tricked(_: *App) bool {
    return pet.reaction() == .trick;
}
fn typeOne(app: *App) void {
    const n = std.mem.indexOfScalar(u8, &app.st.input, 0) orelse return;
    if (n + 1 >= app.st.input.len) return;
    app.st.input[n] = 'a';
    app.st.input[n + 1] = 0;
}
fn clearInput(app: *App) void {
    @memset(&app.st.input, 0);
    app.st.input_sync = true;
}
fn onFire(app: *App) bool {
    return pet.onFire(app.images.now_ms);
}
fn wheelFast(app: *App) void {
    c.ImGuiIO_AddMouseWheelEvent(app.io, 0, -20);
}
fn dizzyReact(_: *App) bool {
    return pet.reaction() == .dizzy;
}
fn pushDrop(kind: c_uint) void {
    var e = std.mem.zeroes(c.SDL_Event);
    e.type = kind;
    _ = c.SDL_PushEvent(&e);
}
fn dragOver(_: *App) void {
    pushDrop(c.SDL_EVENT_DROP_POSITION);
}
fn dropIt(_: *App) void {
    pushDrop(c.SDL_EVENT_DROP_FILE);
}
fn eating(_: *App) bool {
    return pet.reaction() == .eat;
}
fn sendBlocked(app: *App) void {
    pet.onSendBlocked(app.images.now_ms);
}
fn worried(_: *App) bool {
    return pet.reaction() == .worried;
}
fn joinCall(app: *App) void {
    app.actions.append(app.gpa, .{ .toggle_voice = 500014 }) catch {};
}
fn inCall(app: *App) bool {
    return app.st.voice != null;
}
fn muteMic(app: *App) void {
    app.st.muted = true;
}
fn leaveCall(app: *App) void {
    app.st.muted = false;
    app.actions.append(app.gpa, .{ .toggle_voice = 500014 }) catch {};
}
fn outOfCall(app: *App) bool {
    return app.st.voice == null;
}
fn sulkSink(_: *App) bool {
    return pet.mode() == .away and pet.sulkKind() == .sink;
}
fn sulkInflate(_: *App) bool {
    return pet.mode() == .away and pet.sulkKind() == .inflate;
}
fn sulkBack(_: *App) bool {
    return pet.mode() == .away and pet.sulkKind() == .back;
}
fn napping(app: *App) bool {
    return pet.isAsleep(app.images.now_ms);
}
fn awake(app: *App) bool {
    return !pet.isAsleep(app.images.now_ms);
}
fn petHidden(app: *App) bool {
    return pet.isHidden(app.images.now_ms) and qa.find("pet") == null;
}
fn unhide(_: *App) void {
    pet.qaUnhide();
}
fn isClassic(app: *App) bool {
    return mascote.Kind.of(app.st.settings.mascot) == .classico;
}
fn backToTerminal(app: *App) void {
    app.st.settings.mascot = 0;
}
fn emojiLaugh(app: *App) void {
    pet.onEmoji("😂", app.images.now_ms);
}
fn emojiFire(app: *App) void {
    pet.onEmoji("🔥", app.images.now_ms);
}
fn statusDnd(app: *App) void {
    app.st.settings.my_status = 2;
}
fn statusInvisible(app: *App) void {
    app.st.settings.my_status = 3;
}
fn statusOnline(app: *App) void {
    app.st.settings.my_status = 0;
}
fn noMention(app: *App) void {
    pet.onPing(app.images.now_ms);
}
fn notStartled(_: *App) bool {
    return pet.reaction() != .ping;
}
fn cloned(_: *App) bool {
    return pet.reaction() == .clone;
}
fn walkedBack(_: *App) bool {
    return pet.reaction() == .undo;
}
fn wheelSoft(app: *App) void {
    c.ImGuiIO_AddMouseWheelEvent(app.io, 0, -1);
}
fn tickled(_: *App) bool {
    return pet.reaction() == .tickle;
}
fn openStatusMenu(app: *App) void {
    app.st.popup = .{ .menu = .{ .kind = .status, .id = 0, .x = 300, .y = 420 } };
}
fn petUnderPopup(app: *App) bool {
    return app.st.popup != .none and qa.find("pet") != null and qa.find("menu:◐  Ausente") != null;
}
fn closePopup(app: *App) void {
    app.st.popup = .none;
}
fn dropTarget(_: *App, b: []u8) []const u8 {
    return std.fmt.bufPrint(b, "composer", .{}) catch "";
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

    s("mascote dentro do app"),
    run(openSaved),
    expect("sem mensagens salvas: o mascote dorme em cima do aviso", savedSleeps),
    .{ .wait = 700 },
    .{ .shot = "mascote-app-dormindo" },
    run(closeSaved),
    run(historyLoading),
    .{ .wait = 400 },
    .{ .shot = "mascote-app-carregando" },
    run(historyBack),
    run(dropConnection),
    .{ .expect = .{ .name = "caiu a conexão: o aviso com o mascote aparece depois de 1,5 s", .check = bannerShown, .timeout_ms = 3500 } },
    .{ .shot = "mascote-app-reconectando" },
    run(goOffline),
    .{ .wait = 600 },
    .{ .shot = "mascote-app-sem-conexao" },
    run(restoreConnection),
    expect("conectou de novo: o aviso some", bannerGone),
    run(openAbout),
    run(noteAbout),
    click("about-mascot"),
    expect("clicar no mascote do Sobre faz ele reagir", aboutReacted),
    .{ .wait = 250 },
    .{ .shot = "mascote-app-sobre-reagindo" },
    run(closeSettings),
    run(loginIdle),
    click("login-mascot"),
    expect("clicar no mascote da abertura também", loginReacted),
    .{ .wait = 200 },
    .{ .shot = "mascote-app-abertura-reagindo" },
    run(loginHide),

    s("mascote no canto"),
    expect("o mascote senta em cima da caixa de mensagem", petShown),
    .{ .shot = "pet-casa" },
    run(openStatusMenu),
    expect("com um popup aberto, ele continua lá (por baixo do popup)", petUnderPopup),
    .{ .shot = "pet-com-popup" },
    run(closePopup),
    run(sendLaugh),
    expect("\"KKKKKKK\": ele ri", laughing),
    .{ .wait = 250 },
    .{ .shot = "pet-rindo" },
    run(sendGg),
    expect("\"gg\": comemora com confete", celebrating),
    .{ .wait = 350 },
    .{ .shot = "pet-gg" },
    run(sendSad),
    .{ .wait = 300 },
    .{ .shot = "pet-triste" },
    run(ping),
    expect("chegou menção: ele se assusta", pinged),
    .{ .wait = 150 },
    .{ .shot = "pet-mencao" },
    run(home),
    click("pet"),
    click("pet"),
    click("pet"),
    click("pet"),
    click("pet"),
    expect("cutucado cinco vezes: fica bravo e emburra", fled),
    .{ .wait = 500 },
    .{ .shot = "pet-bravo" },
    run(home),
    click("pet"),
    click("pet"),
    click("pet"),
    click("pet"),
    click("pet"),
    expect("emburrado de novo: agora afunda na caixa, só as orelhas de fora", sulkSink),
    .{ .wait = 600 },
    .{ .shot = "pet-emburrado-afunda" },
    run(home),
    click("pet"),
    click("pet"),
    click("pet"),
    click("pet"),
    click("pet"),
    expect("e na terceira infla vermelho soltando fumaça", sulkInflate),
    .{ .wait = 600 },
    .{ .shot = "pet-emburrado-infla" },
    run(home),
    click("pet"),
    click("pet"),
    click("pet"),
    click("pet"),
    click("pet"),
    expect("e na quarta vira de costas", sulkBack),
    .{ .hover = .{ .mark = "pet" } },
    .{ .wait = 400 },
    .{ .shot = "pet-emburrado-costas" },
    run(home),
    .{ .wait = 100 },
    .{ .dclick = .{ .mark = "pet" } },
    expect("dois cliques: um truque", tricked),
    .{ .wait = 500 },
    .{ .shot = "pet-truque" },
    run(home),
    run(typeOne),
    run(typeOne),
    run(typeOne),
    run(typeOne),
    run(typeOne),
    run(typeOne),
    run(typeOne),
    run(typeOne),
    run(typeOne),
    expect("digitando muito rápido: pega fogo", onFire),
    .{ .shot = "pet-fogo" },
    run(clearInput),
    run(home),
    .{ .hover = .{ .at = .{ .key = "composer", .fx = 0.2, .fy = 0.5 } } },
    run(wheelFast),
    expect("a conversa rolando rápido demais: fica tonto", dizzyReact),
    .{ .wait = 300 },
    .{ .shot = "pet-tonto" },
    run(home),
    run(dragOver),
    .{ .wait = 150 },
    .{ .shot = "pet-boca-aberta" },
    run(dropIt),
    expect("soltou o arquivo na janela: ele come", eating),
    run(home),
    run(sendBlocked),
    expect("a mensagem não pôde sair: fica preocupado", worried),
    .{ .wait = 600 },
    .{ .shot = "pet-preocupado" },
    run(home),
    run(joinCall),
    expect("em call: fone de ouvido", inCall),
    run(muteMic),
    .{ .wait = 150 },
    .{ .shot = "pet-call-mudo" },
    run(leaveCall),
    expect("saiu da call", outOfCall),
    run(home),
    run(emojiLaugh),
    expect("reagiu com 😂 numa mensagem: ele ri", laughing),
    run(home),
    run(emojiFire),
    expect("reagiu com 🔥: pega fogo", onFire),
    run(home),
    run(statusDnd),
    run(noMention),
    expect("no não perturbe, menção não assusta", notStartled),
    .{ .wait = 100 },
    .{ .shot = "pet-nao-perturbe" },
    run(statusInvisible),
    .{ .wait = 100 },
    .{ .shot = "pet-invisivel" },
    run(statusOnline),
    run(home),
    .{ .key = .{ .key = c.ImGuiKey_C, .ctrl = true } },
    expect("Ctrl+C: faz um clone", cloned),
    .{ .wait = 300 },
    .{ .shot = "pet-clone" },
    run(home),
    .{ .key = .{ .key = c.ImGuiKey_Z, .ctrl = true } },
    expect("Ctrl+Z: anda para trás", walkedBack),
    run(home),
    .{ .hover = .{ .mark = "pet" } },
    run(wheelSoft),
    expect("a roda do mouse em cima dele: cócegas", tickled),
    run(home),
    .{ .rclick = .{ .mark = "pet" } },
    click("menu:Fazer um truque"),
    expect("botão direito → Fazer um truque", tricked),
    run(home),
    .{ .rclick = .{ .mark = "pet" } },
    .{ .wait = 150 },
    .{ .shot = "pet-menu" },
    click("menu:Dormir"),
    .{ .hover = .{ .at = .{ .key = "composer", .fx = 0.2, .fy = 0.5 } } },
    expect("botão direito → Dormir: dorme, e mexer o mouse não acorda", napping),
    click("pet"),
    expect("um clique nele acorda", awake),
    .{ .rclick = .{ .mark = "pet" } },
    click("menu:Esconder por 1 hora"),
    expect("botão direito → Esconder por 1 hora: some", petHidden),
    run(unhide),
    .{ .wait = 100 },
    .{ .rclick = .{ .mark = "pet" } },
    click("menu:Trocar de mascote"),
    expect("botão direito → Trocar de mascote: vira o Clássico", isClassic),
    run(backToTerminal),
    .{ .wait = 100 },
    run(notePos),
    .{ .drag = .{ .from = .{ .mark = "pet" }, .to = .{ .at = .{ .key = "composer", .fx = 0.3, .fy = -6 } } } },
    expect("pegar e soltar no ar: ele voa (e cai)", thrown),
    .{ .shot = "pet-voando" },
    .{ .expect = .{ .name = "depois de quicar e ficar tonto, volta andando para casa", .check = backHome, .timeout_ms = 9000 } },
    run(idleLong),
    expect("ninguém mexe há uns minutos: ele dorme", sleeping),
    .{ .shot = "pet-dormindo" },
    run(petOff),
    expect("desligado nas Configurações, ele some", petGone),
    run(petOn),

    s("abertura do demo"),
    run(demoOpening),
    expect("conectado, a abertura espera a animação acabar", waitsForIntro),
    .{ .expect = .{ .name = "depois da animação, sai para o app", .check = leftAfterIntro, .timeout_ms = 4000 } },
    .{ .expect = .{ .name = "e a tela some no fim da saída", .check = loginGone, .timeout_ms = 3000 } },
    run(reduceOpening),
    expect("com \"Reduzir animações\", nada de abertura", reduceSkips),
    run(reduceOff),
};
