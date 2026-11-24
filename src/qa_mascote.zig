//! QA do mascote (Configurações → Aparência → Mascote): os dois cartões aparecem
//! com a prévia, o clique troca a escolha e os ícones seguem (janela, bandeja e
//! avisos; a pasta de ícones do usuário fica fora do QA), a tela de abertura
//! desenha o Terminal em cada fase (abertura, conectando, erro, saída) e o
//! Clássico continua o de antes, e a abertura do demo espera a animação inteira
//! antes de sair para o app. O mascote do canto parado, repetido sem refazer e igual
//! pixel a pixel, fica em qa_mascote_repete.zig. Sozinho: QA_SUITE=mascote.
const std = @import("std");
const c = @import("c");
const App = @import("app.zig").App;
const Id = @import("core/types.zig").Id;
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
    app.st.settings.page = .mascote;
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
    // A caixa (o campo do ImGui) passa a mostrar o texto novo.
    app.st.input_sync = true;
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
// --- Vida própria -----------------------------------------------------------------

fn lifeToggles(_: *App) bool {
    return qa.find("toggle:Passeia pela janela") != null and qa.find("toggle:Brinca com a interface") != null and
        qa.find("toggle:Brinca com o mouse") != null and qa.find("toggle:Espera você voltar") != null and qa.find("toggle:Plantinha") != null;
}
/// As reações de antes, sem a vida própria no meio (ela tem os testes dela).
fn quietLife(app: *App) void {
    app.st.settings.mascot_life = 0;
    app.st.settings.mascot_cursor = false;
}
fn lifeReset(app: *App) void {
    pet.qaLifeReset(app.images.now_ms);
    app.qa_blur = false;
    const set = &app.st.settings;
    set.mascot_life = 2;
    set.mascot_roam = true;
    set.mascot_ui = true;
    set.mascot_cursor = true;
    set.mascot_away = true;
    set.mascot_plant = true;
}
fn roamOff(app: *App) void {
    app.st.settings.mascot_roam = false;
}
fn idleShort(app: *App) void {
    pet.qaIdleFor(10_000, app.images.now_ms);
}
fn lifeNow(_: *App) void {
    pet.qaLifeNow();
}
fn doingSomething(_: *App) bool {
    return pet.activity() != .none;
}
fn actFn(comptime a: pet.Act, comptime v: u8) *const fn (*App) void {
    return struct {
        fn f(app: *App) void {
            pet.qaAct(a, v, app.images.now_ms);
        }
    }.f;
}
fn isAct(comptime a: pet.Act) *const fn (*App) bool {
    return struct {
        fn f(_: *App) bool {
            return pet.activity() == a;
        }
    }.f;
}
fn goFn(comptime g: pet.Goal) *const fn (*App) void {
    return struct {
        fn f(_: *App) void {
            pet.qaGo(g);
        }
    }.f;
}
fn perchedAt(comptime g: pet.Goal) *const fn (*App) bool {
    return struct {
        fn f(_: *App) bool {
            return pet.mode() == .perch and pet.goalNow() == g;
        }
    }.f;
}
fn towerUp(_: *App) bool {
    return pet.hasTower() and pet.activity() == .none;
}
fn doodleOn(_: *App) bool {
    return pet.doodleKind() != 0;
}
fn doodleGone(_: *App) bool {
    return pet.doodleKind() == 0;
}
fn someoneTyping(app: *App) void {
    const ch = app.st.activeChannel() orelse return;
    app.store.apply(.{ .typing_start = .{ .channel = ch, .user = 1001 } }, app.images.now_ms) catch {};
}
fn toTop(app: *App) void {
    const sc = app.st.scrollOf(app.st.activeChannel() orelse return);
    sc.stick_bottom = false;
    sc.target = 0;
}
fn toBottom(app: *App) void {
    if (app.st.activeChannel()) |id| app.st.scrollOf(id).stick_bottom = true;
}
fn dmArrives(app: *App) void {
    // Como o app avisa: o susto da menção e, sendo DM, a cartinha.
    pet.onPing(app.images.now_ms);
    pet.onDm();
}
fn carryingLetter(_: *App) bool {
    return pet.goalNow() == .dm and pet.mode() == .trip;
}
fn msgDeleted(_: *App) void {
    pet.onMessageDeleted();
}
fn msgEdited(_: *App) void {
    pet.onMessageEdited();
}
fn heldOrFell(_: *App) bool {
    return pet.activity() == .hold or pet.mode() == .flying or pet.mode() == .dizzy or pet.mode() == .walking;
}
fn fell(_: *App) bool {
    return pet.mode() == .flying or pet.mode() == .dizzy or pet.mode() == .walking;
}
fn plantTree(app: *App) void {
    app.st.settings.mascot_plant_days = 30;
}
fn plantSprout(app: *App) void {
    app.st.settings.mascot_plant_days = 3;
}
fn plantWilt(app: *App) void {
    app.st.settings.mascot_plant_wilted = true;
}
fn plantWatered(app: *App) bool {
    return !app.st.settings.mascot_plant_wilted and pet.activity() == .none;
}
fn blur(app: *App) void {
    app.qa_blur = true;
}
fn unblur(app: *App) void {
    app.qa_blur = false;
}
fn awayLong(app: *App) void {
    pet.qaAwayFor(25 * 60 * 1000, app.images.now_ms);
}
fn awayHours(app: *App) void {
    pet.qaAwayFor(3 * 60 * 60 * 1000, app.images.now_ms);
}
fn camped(_: *App) bool {
    return pet.isCamped();
}
fn balloon(app: *App) bool {
    return pet.balloonOn(app.images.now_ms);
}
fn ranToMouse(_: *App) bool {
    return pet.goalNow() == .mouse;
}
fn lifeOff(app: *App) void {
    app.st.settings.mascot_life = 0;
}
fn uiOff(app: *App) void {
    app.st.settings.mascot_ui = false;
}
fn mouseAway(app: *App) void {
    R.mouse_out = true;
    c.ImGuiIO_AddMousePosEvent(app.io, -std.math.floatMax(f32), -std.math.floatMax(f32));
}
fn homeNoTrip(_: *App) bool {
    return pet.mode() == .home and pet.goalNow() == .none and pet.activity() == .none;
}
fn resizeNow(_: *App) void {
    pet.onResize();
}
var plant_days_before: u8 = 0;
fn plantYesterday(app: *App) void {
    var wall: c.SDL_Time = 0;
    _ = c.SDL_GetCurrentTime(&wall);
    const today = @import("ui/widgets.zig").localTime(@divTrunc(wall, 1_000_000_000)).day_index;
    app.st.settings.mascot_plant_day = @intCast(today - 1);
    app.st.settings.mascot_plant_days = 5;
    plant_days_before = 5;
}
fn plantGrew(app: *App) bool {
    return app.st.settings.mascot_plant_days == plant_days_before + 1;
}
fn nudgeChat(app: *App) void {
    const sc = app.st.scrollOf(app.st.activeChannel() orelse return);
    sc.stick_bottom = false;
    sc.target = @max(0, sc.pos - 60);
}
fn leftPerch(_: *App) bool {
    return pet.mode() != .perch;
}
fn stillHome(_: *App) bool {
    return pet.activity() == .none and pet.mode() == .home;
}
fn otherChannel(_: *App, b: []u8) []const u8 {
    return std.fmt.bufPrint(b, "channel:500006", .{}) catch "";
}
fn backToGeral(app: *App) void {
    app.actions.append(app.gpa, .{ .select_channel = 500005 }) catch {};
}
/// Abre uma thread aberta, sempre a mesma (a de menor id, com o canal pai de texto): uma
/// arquivada ou trancada não tem caixa de mensagem, e sem caixa ele não aparece. (As
/// threads do demo moram no servidor delas.)
fn openAThread(app: *App) void {
    var best: ?Id = null;
    var it = app.store.channels.iterator();
    while (it.next()) |e| {
        const info = &e.value_ptr.*.info;
        const t = info.thread orelse continue;
        if (t.archived or t.locked) continue;
        const parent = app.store.channel(info.parent orelse continue) orelse continue;
        if (parent.info.kind != .text) continue;
        if (best == null or e.key_ptr.* < best.?) best = e.key_ptr.*;
    }
    if (best) |id| app.actions.append(app.gpa, .{ .select_channel = id }) catch {};
}
fn stopTyping(app: *App) void {
    const ch = app.st.activeChannel() orelse return;
    if (app.store.channel(ch)) |cs| cs.typing.clearRetainingCapacity();
}

// --- O que você digita e as brincadeiras ---------------------------------------------

const reacoes = @import("ui/mascote_reacoes.zig");
const types = @import("core/types.zig");

/// Tudo ligado e do começo: a vida própria normal, as duas chaves, a caixa vazia e ele
/// em casa, sem esperar o Esc de antes.
fn playReset(app: *App) void {
    lifeReset(app);
    const set = &app.st.settings;
    set.mascot_typing = true;
    set.mascot_games = true;
    set.reduce_motion = false;
    set.mascot_cursor = false;
    pet.qaHome();
    pet.qaEscReset();
    app.st.popup = .none;
    app.st.reply_to = 0;
    @memset(&app.st.input, 0);
    app.st.input_sync = true;
}
fn poseIs(comptime p: reacoes.Pose) *const fn (*App) bool {
    return struct {
        fn f(_: *App) bool {
            return pet.boxPose() == p;
        }
    }.f;
}
fn reactIs(comptime r: pet.Reaction) *const fn (*App) bool {
    return struct {
        fn f(_: *App) bool {
            return pet.reaction() == r;
        }
    }.f;
}
fn notReact(comptime r: pet.Reaction) *const fn (*App) bool {
    return struct {
        fn f(_: *App) bool {
            return pet.reaction() != r;
        }
    }.f;
}
/// A caixa com um texto (o que não dá para digitar de uma vez: 1850 bytes).
fn setInput(comptime len: usize) *const fn (*App) void {
    return struct {
        fn f(app: *App) void {
            @memset(&app.st.input, 0);
            for (0..len) |i| app.st.input[i] = if (i % 7 == 6) ' ' else 'a';
            app.st.input_sync = true;
        }
    }.f;
}
fn scrollHalf(_: *App) bool {
    const b = pet.boxNow();
    return pet.boxPose() == .long and b.unroll > 0.3 and b.unroll < 0.7;
}
fn inputEmpty(app: *App) bool {
    return app.st.input[0] == 0;
}
fn d20Next(comptime face: u8) *const fn (*App) void {
    return struct {
        fn f(_: *App) void {
            pet.qaD20(face);
        }
    }.f;
}
fn rolled(comptime face: u8) *const fn (*App) bool {
    return struct {
        fn f(_: *App) bool {
            return pet.reaction() == .d20 and pet.d20Face() == face;
        }
    }.f;
}
fn paletteOpenPortal(app: *App) bool {
    return app.st.palette.open and (pet.activity() == .portal or pet.qa_portal);
}
fn portalReset(_: *App) void {
    pet.qa_portal = false;
}
/// O portal dura 0,8 s: num quadro lento (o CI) ele já pode ter acabado quando o QA olha.
fn portalStarted(_: *App) bool {
    return pet.activity() == .portal or pet.qa_portal;
}
fn paletteClosed(app: *App) bool {
    return !app.st.palette.open;
}
fn saveNoPopup(app: *App) bool {
    return pet.reaction() == .save and app.st.popup == .none and !app.st.palette.open;
}
fn printNoPalette(app: *App) bool {
    return pet.reaction() == .print and !app.st.palette.open;
}
fn cutDone(app: *App) bool {
    const clip = c.SDL_GetClipboardText() orelse return false;
    defer c.SDL_free(clip);
    return pet.reaction() == .cut and app.st.input[0] == 0 and std.mem.eql(u8, std.mem.span(clip), "recorta isso");
}
fn pasteDone(app: *App) bool {
    return pet.reaction() == .paste and std.mem.eql(u8, std.mem.sliceTo(&app.st.input, 0), "recorta isso");
}
fn clearAndBlur(app: *App) void {
    @memset(&app.st.input, 0);
    app.st.input_sync = true;
    pet.qaHome();
}
fn replyToLast(app: *App) void {
    const ch = app.st.activeChannel() orelse return;
    const cs = app.store.channel(ch) orelse return;
    const items = cs.messages.items;
    if (items.len > 0) app.st.reply_to = items[items.len - 1].msg.id;
}
fn replyCanceledNoDuck(app: *App) bool {
    return app.st.reply_to == 0 and pet.reaction() != .duck;
}
fn popupClosedNoDuck(app: *App) bool {
    return app.st.popup == .none and pet.reaction() != .duck;
}
fn reactLast(app: *App) void {
    const ch = app.st.activeChannel() orelse return;
    const cs = app.store.channel(ch) orelse return;
    const items = cs.messages.items;
    if (items.len == 0) return;
    app.actions.append(app.gpa, .{ .react = .{ .id = items[items.len - 1].msg.id, .emoji = types.Reaction.init("🍕") } }) catch {};
}
/// O chip do 🍕 na última mensagem (posto por `reactLast`).
fn chipPizza(app: *App, b: []u8) []const u8 {
    const ch = app.st.activeChannel() orelse return "";
    const cs = app.store.channel(ch) orelse return "";
    const items = cs.messages.items;
    if (items.len == 0) return "";
    const m = &items[items.len - 1];
    for (m.reactionSlice(), 0..) |*r, i| if (std.mem.eql(u8, r.text(), "🍕")) return std.fmt.bufPrint(b, "chip:{d}:{d}", .{ m.msg.id, i }) catch "";
    return "";
}
fn pizzaChipShown(app: *App) bool {
    var b: [64]u8 = undefined;
    const k = chipPizza(app, &b);
    return k.len > 0 and qa.find(k) != null;
}
fn ateEmoji(comptime e: []const u8) *const fn (*App) bool {
    return struct {
        fn f(_: *App) bool {
            return pet.reaction() == .treat and std.mem.eql(u8, pet.treatEaten(), e);
        }
    }.f;
}
fn ateSomething(_: *App) bool {
    return pet.reaction() == .treat and pet.treatEaten().len > 0;
}
/// A primeira célula de emoji Unicode à vista no seletor.
fn firstEmojiCell(_: *App, b: []u8) []const u8 {
    var keys: [64][56]u8 = undefined;
    var lens: [64]u8 = undefined;
    const n = qa.keysWith(&.{"emoji:"}, &keys, &lens);
    if (n == 0) return "";
    const k = keys[0][0..lens[0]];
    @memcpy(b[0..k.len], k);
    return b[0..k.len];
}
fn pickerOpen(_: *App) bool {
    return qa.find("emoji-picker") != null;
}
fn closePicker(app: *App) void {
    app.st.popup = .none;
}
/// Solta um texto ou um arquivo em cima dele, como o SDL avisa (o ponto em pixels).
var link_text = "https://ziglang.org".*;
var image_path = "assets/icon-128.png".*;
var uploads_before: usize = 0;
fn dropOnPet(app: *App, kind: c_uint, data: [*c]u8) void {
    const h = pet.qaHit();
    const sc = app.uiScale();
    var e = std.mem.zeroes(c.SDL_Event);
    e.type = kind;
    e.drop.x = (h.x + h.w / 2) * sc;
    e.drop.y = (h.y + h.h / 2) * sc;
    e.drop.data = data;
    _ = c.SDL_PushEvent(&e);
}
fn dropLink(app: *App) void {
    dropOnPet(app, c.SDL_EVENT_DROP_TEXT, &link_text);
}
fn dropImage(app: *App) void {
    uploads_before = app.st.uploads.items.len;
    dropOnPet(app, c.SDL_EVENT_DROP_FILE, &image_path);
}
fn framedAndAttached(app: *App) bool {
    return pet.reaction() == .picture and app.st.uploads.items.len == uploads_before + 1;
}
fn dropTextAway(_: *App) void {
    var e = std.mem.zeroes(c.SDL_Event);
    e.type = c.SDL_EVENT_DROP_TEXT;
    e.drop.x = 5;
    e.drop.y = 5;
    e.drop.data = &link_text;
    _ = c.SDL_PushEvent(&e);
}
fn removeUploads(app: *App) void {
    var i = app.st.uploads.items.len;
    while (i > uploads_before) {
        i -= 1;
        app.actions.append(app.gpa, .{ .remove_upload = i }) catch {};
    }
}
fn seekNow(_: *App) void {
    pet.qaSeek();
}
fn hiding(_: *App) bool {
    return pet.isHiding();
}
fn seekExpire(app: *App) void {
    pet.qaSeekExpire(app.images.now_ms);
}
fn backNotFound(_: *App) bool {
    return pet.mode() == .home and pet.reaction() != .found;
}
fn tellSmall(_: *App) bool {
    // Só as pontinhas das orelhas pegam o clique (não o corpo inteiro).
    const h = pet.qaHit();
    return pet.isHiding() and h.w < 20 and h.h < 40 and pet.qaVisibleWidth() < 10;
}
fn playToggles(_: *App) bool {
    return qa.find("toggle:Reage ao que você digita") != null and qa.find("toggle:Brincadeiras") != null;
}
fn playTogglesOff(_: *App) bool {
    return qa.find("toggle-off:Reage ao que você digita") != null and qa.find("toggle-off:Brincadeiras") != null;
}
fn petClassic(app: *App) void {
    app.st.settings.mascot = 1;
}
fn typingOff(app: *App) void {
    app.st.settings.mascot_typing = false;
}
fn gamesOff(app: *App) void {
    app.st.settings.mascot_games = false;
}
fn reduceOn(app: *App) void {
    app.st.settings.reduce_motion = true;
}
fn noPose(_: *App) bool {
    return pet.boxPose() == .none;
}

// --- Em cada tema: aonde ele vai e se aparece lá ------------------------------------

/// O tema não tem o lugar (ou não tem lugar para ele): nada a conferir. Tem: ele pousa
/// lá e uma parte dele fica à vista.
fn arrivedVisible(comptime g: pet.Goal) *const fn (*App) bool {
    return struct {
        fn f(app: *App) bool {
            if (!pet.qaShown(app.images.now_ms)) return true;
            if (g == .dm) {
                // O ícone das DMs está na tela e não está atrás do véu: ele tem que chegar
                // lá (debaixo ou em cima do ícone), sem desculpa de "o tema não tem".
                // Visível de verdade (a lista pode ter rolado e deixado a marca fora da tela).
                const icon = qa.visiblePart("guild:0") orelse return true;
                if (pet.qaVeiled(.dm_icon, app.images.now_ms)) return true;
                const p = pet.position();
                return pet.mode() == .perch and pet.goalNow() == .dm and @abs(p[0] - (icon.x + icon.w / 2)) < @max(40, icon.w);
            }
            if (pet.qaGoFailed()) return true;
            return pet.mode() == .perch and pet.goalNow() == g and pet.qaVisibleWidth() > 8;
        }
    }.f;
}

pub const ops_theme = [_]Op{
    s("mascote: passeios no tema"),
    run(lifeReset),
    run(goFn(.dm)),
    .{ .expect = .{ .name = "leva a cartinha até o ícone das DMs deste tema", .check = arrivedVisible(.dm), .timeout_ms = 9000 } },
    .{ .shot = "mascote-dm" },
    run(lifeReset),
    run(goFn(.channels)),
    .{ .expect = .{ .name = "espia da lista de canais e aparece", .check = arrivedVisible(.channels), .timeout_ms = 9000 } },
    .{ .shot = "mascote-canais" },
    run(lifeReset),
    run(goFn(.members)),
    .{ .expect = .{ .name = "sobe na lista de membros", .check = arrivedVisible(.members), .timeout_ms = 9000 } },
    run(lifeReset),
    run(goFn(.header)),
    .{ .expect = .{ .name = "fica pendurado no cabeçalho", .check = arrivedVisible(.header), .timeout_ms = 9000 } },
    run(lifeReset),
};

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
    run(quietLife),
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
    .{ .expect = .{ .name = "depois de quicar e ficar tonto, volta andando para casa", .check = backHome, .timeout_ms = 15000 } },
    run(idleLong),
    expect("ninguém mexe há uns minutos: ele dorme", sleeping),
    .{ .shot = "pet-dormindo" },
    s("vida própria"),
    run(lifeReset),
    run(openAppearance),
    expect("a aba Mascote tem a vida própria, o mouse, a volta e a plantinha", lifeToggles),
    .{ .shot = "config-mascote" },
    run(closeSettings),
    run(lifeReset),
    run(roamOff),
    run(idleShort),
    run(lifeNow),
    expect("à toa, ele faz alguma coisa sozinho", doingSomething),
    run(lifeReset),
    run(actFn(.scratch, 0)),
    .{ .wait = 700 },
    .{ .shot = "vida-coca" },
    run(actFn(.char_play, 0)),
    .{ .wait = 700 },
    .{ .shot = "vida-cursor" },
    run(actFn(.coffee, 0)),
    .{ .wait = 1000 },
    .{ .shot = "vida-cafe" },
    run(actFn(.book, 0)),
    .{ .wait = 1200 },
    .{ .shot = "vida-livro" },
    run(actFn(.game, 0)),
    .{ .wait = 900 },
    .{ .shot = "vida-videogame" },
    run(actFn(.gum, 0)),
    .{ .wait = 1900 },
    .{ .shot = "vida-chiclete" },
    run(actFn(.whistle, 0)),
    .{ .wait = 1000 },
    .{ .shot = "vida-assobio" },
    run(actFn(.clean, 0)),
    .{ .wait = 700 },
    .{ .shot = "vida-limpa" },
    run(actFn(.nap_sit, 0)),
    .{ .wait = 1500 },
    .{ .shot = "vida-cochilo" },
    run(actFn(.exercise, 0)),
    .{ .wait = 900 },
    .{ .shot = "vida-flexao" },
    run(actFn(.exercise, 2)),
    .{ .wait = 900 },
    .{ .shot = "vida-polichinelo" },
    run(actFn(.fly, 0)),
    .{ .wait = 1400 },
    .{ .shot = "vida-mosquinha" },
    run(actFn(.fish, 0)),
    .{ .wait = 4300 },
    .{ .shot = "vida-pesca" },
    run(actFn(.tower, 0)),
    .{ .expect = .{ .name = "empilha os blocos e a torre fica", .check = towerUp, .timeout_ms = 6000 } },
    .{ .shot = "vida-torre" },
    .{ .hover = .{ .at = .{ .key = "composer", .fx = 0.2, .fy = 0.5 } } },
    expect("mexeu o mouse: a torre cai em cima dele", isAct(.tower_fall)),
    run(lifeReset),
    run(actFn(.doodle, 0)),
    .{ .wait = 2500 },
    expect("rabiscou um coração na caixa", doodleOn),
    .{ .shot = "vida-rabisco" },
    run(typeOne),
    expect("começou a digitar: o rabisco some", doodleGone),
    run(clearInput),
    run(plantTree),
    run(actFn(.water, 0)),
    .{ .wait = 1000 },
    .{ .shot = "vida-regando-arvore" },
    run(lifeReset),
    run(plantSprout),
    run(plantWilt),
    .{ .wait = 100 },
    .{ .shot = "vida-planta-murcha" },
    run(roamOff),
    run(idleShort),
    run(lifeNow),
    expect("murcha: a próxima coisa que ele faz é regar", isAct(.water)),
    .{ .expect = .{ .name = "regada, a planta fica de pé", .check = plantWatered, .timeout_ms = 4000 } },
    run(lifeReset),
    run(msgDeleted),
    expect("mensagem apagada: ele leva para o lixo", isAct(.trash)),
    .{ .wait = 1200 },
    .{ .shot = "vida-lixo" },
    run(lifeReset),
    run(msgEdited),
    expect("mensagem editada: passa a borracha", isAct(.erase)),
    .{ .wait = 500 },
    .{ .shot = "vida-borracha" },
    run(lifeReset),
    run(goFn(.msg)),
    .{ .expect = .{ .name = "passeio: senta em cima da última mensagem", .check = perchedAt(.msg), .timeout_ms = 5000 } },
    .{ .shot = "vida-passeio-mensagem" },
    run(lifeReset),
    run(goFn(.members)),
    .{ .expect = .{ .name = "passeio: sobe na lista de membros", .check = perchedAt(.members), .timeout_ms = 6000 } },
    .{ .shot = "vida-passeio-membros" },
    run(lifeReset),
    run(goFn(.header)),
    .{ .expect = .{ .name = "passeio: fica pendurado no cabeçalho", .check = perchedAt(.header), .timeout_ms = 6000 } },
    .{ .wait = 300 },
    .{ .shot = "vida-passeio-cabecalho" },
    run(lifeReset),
    run(goFn(.channels)),
    .{ .expect = .{ .name = "passeio: espia por trás da lista de canais", .check = perchedAt(.channels), .timeout_ms = 6000 } },
    .{ .shot = "vida-passeio-canais" },
    run(lifeReset),
    run(someoneTyping),
    .{ .expect = .{ .name = "alguém digitando: senta em cima do \"digitando…\"", .check = perchedAt(.typing), .timeout_ms = 5000 } },
    .{ .shot = "vida-digitando" },
    run(stopTyping),
    run(lifeReset),
    run(toTop),
    .{ .expect = .{ .name = "o botão de voltar ao fim apareceu: vai lá empurrar", .check = perchedAt(.jump), .timeout_ms = 6000 } },
    .{ .shot = "vida-empurra-botao" },
    run(toBottom),
    run(lifeReset),
    run(dmArrives),
    expect("chegou DM: leva a cartinha", carryingLetter),
    .{ .expect = .{ .name = "e entrega no ícone das DMs", .check = perchedAt(.dm), .timeout_ms = 8000 } },
    .{ .shot = "vida-carteiro" },
    run(lifeReset),
    .{ .resize = .{ 1180, 760 } },
    expect("a janela mudou de tamanho: se segura (ou cai)", heldOrFell),
    .{ .resize = .{ 1280, 800 } },
    .{ .wait = 300 },
    run(lifeReset),
    .{ .hover = .{ .mark = "pet" } },
    .{ .expect = .{ .name = "a setinha parada em cima dele: senta nela", .check = perchedAt(.cursor), .timeout_ms = 5000 } },
    .{ .shot = "vida-senta-na-setinha" },
    .{ .hover = .{ .at = .{ .key = "composer", .fx = 0.2, .fy = 0.5 } } },
    expect("mexeu o mouse: ele cai", fell),
    run(home),
    run(lifeReset),
    .{ .hover = .{ .at = .{ .key = "composer", .fx = 0.95, .fy = -0.6 } } },
    .{ .expect = .{ .name = "a setinha parada perto dele: tenta pegar", .check = isAct(.grab), .timeout_ms = 4000 } },
    run(lifeReset),
    run(portalReset),
    .{ .click = .{ .dyn = otherChannel } },
    expect("trocou de canal: ele passa pelo portal junto", portalStarted),
    .{ .wait = 900 },
    run(openAThread),
    expect("abriu uma thread: ele espia", isAct(.peek)),
    .{ .wait = 900 },
    run(backToGeral),
    .{ .wait = 400 },
    run(lifeReset),
    run(blur),
    .{ .wait = 100 },
    .{ .shot = "vida-esperando" },
    run(awayLong),
    expect("sem você por muito tempo: acampa", camped),
    .{ .wait = 100 },
    .{ .shot = "vida-acampado" },
    run(awayHours),
    run(unblur),
    expect("voltou: desmonta o acampamento", isAct(.pack)),
    expect("depois de horas fora, diz que sentiu saudade", balloon),
    .{ .expect = .{ .name = "e corre até o mouse", .check = ranToMouse, .timeout_ms = 3000 } },
    .{ .shot = "vida-saudade" },
    run(lifeReset),
    run(lifeOff),
    run(idleShort),
    run(lifeNow),
    .{ .wait = 500 },
    expect("vida própria desligada: ele fica quieto", stillHome),
    run(plantWilt),
    run(idleShort),
    expect("mas a plantinha murcha ele rega mesmo assim", isAct(.water)),
    .{ .expect = .{ .name = "e ela fica de pé", .check = plantWatered, .timeout_ms = 4000 } },
    run(lifeReset),
    run(uiOff),
    run(msgDeleted),
    .{ .wait = 300 },
    expect("sem \"Brinca com a interface\": mensagem apagada não mexe nele", stillHome),
    run(lifeReset),
    run(blur),
    run(msgDeleted),
    .{ .wait = 300 },
    expect("com a janela sem foco, a interface não mexe nele", stillHome),
    run(unblur),
    .{ .wait = 100 },
    run(petOff),
    .{ .wait = 100 },
    run(msgDeleted),
    .{ .wait = 100 },
    run(petOn),
    .{ .wait = 300 },
    expect("o que aconteceu com ele escondido não vale depois", stillHome),
    run(resizeNow),
    .{ .wait = 300 },
    expect("logo que aparece, a janela se ajeitando não faz ele se segurar", stillHome),
    run(lifeReset),
    run(plantYesterday),
    .{ .hover = .{ .at = .{ .key = "composer", .fx = 0.3, .fy = 0.5 } } },
    .{ .hover = .{ .at = .{ .key = "composer", .fx = 0.35, .fy = 0.5 } } },
    expect("primeiro toque de um dia novo: a plantinha cresce um dia", plantGrew),
    run(lifeReset),
    run(blur),
    run(awayLong),
    expect("acampou de novo", camped),
    run(mouseAway),
    run(unblur),
    expect("voltou pelo teclado: desmonta", isAct(.pack)),
    .{ .wait = 1700 },
    expect("e, sem o mouse na janela, fica em casa", homeNoTrip),
    run(lifeReset),
    run(uiOff),
    run(goFn(.msg)),
    .{ .expect = .{ .name = "sentado na última mensagem de novo", .check = perchedAt(.msg), .timeout_ms = 5000 } },
    run(nudgeChat),
    .{ .expect = .{ .name = "a conversa rolou e o lugar mudou: ele volta", .check = leftPerch, .timeout_ms = 2000 } },
    run(toBottom),
    run(lifeReset),
    run(petOff),
    expect("desligado nas Configurações, ele some", petGone),
    run(petOn),

    s("mascote: o que você digita"),
    run(playReset),
    run(openAppearance),
    expect("a aba Mascote tem \"Reage ao que você digita\" e \"Brincadeiras\"", playToggles),
    run(closeSettings),
    run(playReset),
    click("composer"),
    .{ .text = "PARA DE GRITAR" },
    expect("tudo em maiúsculas: tapa as orelhas", poseIs(.caps)),
    .{ .wait = 350 },
    .{ .shot = "brinca-maiusculas" },
    run(clearInput),
    expect("a caixa vazia: a pose sai", poseIs(.none)),
    .{ .text = "OK" },
    .{ .wait = 100 },
    expect("\"OK\" não é gritar", poseIs(.none)),
    run(clearInput),
    .{ .text = "o final é ||o mordomo||" },
    expect("spoiler: cobre os olhos", poseIs(.spoiler)),
    .{ .wait = 350 },
    .{ .shot = "brinca-spoiler" },
    .{ .key = .{ .key = c.ImGuiKey_Enter } },
    expect("mandou: a caixa esvazia e ele destapa os olhos", inputEmpty),
    expect("sem spoiler na caixa, sem a pose", poseIs(.none)),
    run(home),
    click("composer"),
    .{ .text = "```zig\nconst x = 1;" },
    expect("bloco de código: põe os óculos para revisar", poseIs(.code)),
    .{ .wait = 350 },
    .{ .shot = "brinca-codigo" },
    run(clearInput),
    .{ .text = "fala @" },
    expect("\"@\": aponta para a lista de membros", poseIs(.members)),
    .{ .wait = 350 },
    .{ .shot = "brinca-arroba" },
    run(clearInput),
    .{ .text = "vai no #" },
    expect("\"#\": aponta para a lista de canais", poseIs(.channels)),
    .{ .wait = 350 },
    .{ .shot = "brinca-canal" },
    run(clearInput),
    .{ .text = "/shrug" },
    expect("\"/\" no começo: abre o terminalzinho", poseIs(.slash)),
    .{ .wait = 900 },
    .{ .shot = "brinca-terminal" },
    run(clearInput),
    run(setInput(1000)),
    expect("mensagem longa: o pergaminho, meio desenrolado", scrollHalf),
    .{ .wait = 350 },
    .{ .shot = "brinca-pergaminho" },
    run(setInput(1850)),
    expect("perto do limite: se afasta preocupado", poseIs(.full)),
    .{ .wait = 350 },
    .{ .shot = "brinca-limite" },
    run(clearInput),
    run(home),
    click("composer"),
    .{ .text = "isso aqui ta tudo errado demais" },
    .{ .key = .{ .key = c.ImGuiKey_Backspace } },
    .{ .key = .{ .key = c.ImGuiKey_Backspace } },
    .{ .key = .{ .key = c.ImGuiKey_Backspace } },
    .{ .key = .{ .key = c.ImGuiKey_Backspace } },
    .{ .key = .{ .key = c.ImGuiKey_Backspace } },
    .{ .key = .{ .key = c.ImGuiKey_Backspace } },
    .{ .key = .{ .key = c.ImGuiKey_Backspace } },
    .{ .key = .{ .key = c.ImGuiKey_Backspace } },
    .{ .key = .{ .key = c.ImGuiKey_Backspace } },
    .{ .key = .{ .key = c.ImGuiKey_Backspace } },
    .{ .key = .{ .key = c.ImGuiKey_Backspace } },
    expect("onze apagadas: ainda nada", notReact(.tea)),
    .{ .key = .{ .key = c.ImGuiKey_Backspace } },
    expect("doze apagadas seguidas: oferece um chá", reactIs(.tea)),
    .{ .wait = 500 },
    .{ .shot = "brinca-cha" },
    run(clearInput),
    run(home),
    .{ .text = "miau" },
    expect("\"miau\": mia de volta", reactIs(.meow)),
    .{ .wait = 300 },
    .{ .shot = "brinca-miau" },
    run(clearInput),
    run(home),
    .{ .text = "olha ele >_" },
    expect("\">_\": reconhece o rosto dele", reactIs(.prompt)),
    run(clearInput),
    run(home),
    .{ .text = "sudo" },
    expect("\"sudo\": fica em posição de sentido (e sai um sanduíche)", reactIs(.sudo)),
    .{ .wait = 800 },
    .{ .shot = "brinca-sudo" },
    run(clearInput),
    run(home),
    .{ .text = "rm -rf /" },
    expect("\"rm -rf\": se apaga e volta", reactIs(.rm)),
    .{ .wait = 700 },
    .{ .shot = "brinca-rm-rf" },
    run(clearInput),
    run(home),

    s("mascote: brincadeiras"),
    run(playReset),
    run(d20Next(20)),
    click("composer"),
    .{ .text = "rolando" },
    .{ .key = .{ .key = c.ImGuiKey_Enter } },
    expect("o d20 do envio: 20, confete", rolled(20)),
    .{ .wait = 1200 },
    .{ .shot = "brinca-d20-vinte" },
    run(home),
    run(d20Next(1)),
    click("composer"),
    .{ .text = "de novo" },
    .{ .key = .{ .key = c.ImGuiKey_Enter } },
    expect("o d20 do envio: 1, ele cai de lado", rolled(1)),
    .{ .wait = 1500 },
    .{ .shot = "brinca-d20-um" },
    run(home),
    run(reactLast),
    .{ .expect = .{ .name = "a reação de 🍕 aparece na última mensagem", .check = pizzaChipShown, .timeout_ms = 3000 } },
    .{ .drag = .{ .from = .{ .dyn = chipPizza }, .to = .{ .mark = "pet" } } },
    expect("arrastou a reação até ele: come o 🍕", ateEmoji("🍕")),
    .{ .wait = 1000 },
    .{ .shot = "brinca-emoji-olhos" },
    run(home),
    click("composer-emoji"),
    expect("o seletor de emoji abre", pickerOpen),
    .{ .drag = .{ .from = .{ .dyn = firstEmojiCell }, .to = .{ .mark = "pet" } } },
    expect("arrastou um emoji do seletor até ele: come também", ateSomething),
    run(closePicker),
    run(home),
    run(dropLink),
    expect("um link solto em cima dele: abre um portalzinho", reactIs(.link)),
    .{ .wait = 450 },
    .{ .shot = "brinca-portal-link" },
    run(home),
    run(dropTextAway),
    .{ .wait = 200 },
    expect("texto solto longe dele não mexe nele", notReact(.link)),
    run(dropImage),
    expect("uma imagem solta em cima dele: segura num quadro (e vai para a bandeja)", framedAndAttached),
    .{ .wait = 800 },
    .{ .shot = "brinca-quadro" },
    run(removeUploads),
    run(home),
    run(seekNow),
    .{ .expect = .{ .name = "esconde-esconde: se esconde atrás de um painel", .check = hiding, .timeout_ms = 8000 } },
    expect("só a pontinha das orelhas fica para fora (e pega o clique)", tellSmall),
    .{ .wait = 300 },
    .{ .shot = "brinca-esconde" },
    click("pet"),
    .{ .expect = .{ .name = "clicou nas orelhas: achou, e ele comemora em casa", .check = reactIs(.found), .timeout_ms = 8000 } },
    .{ .wait = 300 },
    .{ .shot = "brinca-achou" },
    run(playReset),
    run(seekNow),
    .{ .expect = .{ .name = "escondido de novo", .check = hiding, .timeout_ms = 8000 } },
    run(seekExpire),
    .{ .expect = .{ .name = "ninguém achou: volta sozinho, sem comemorar", .check = backNotFound, .timeout_ms = 8000 } },

    s("mascote: as teclas"),
    run(playReset),
    run(portalReset),
    .{ .key = .{ .key = c.ImGuiKey_K, .ctrl = true } },
    expect("Ctrl+K: a paleta abre, e ele pula num portal", paletteOpenPortal),
    .{ .key = .{ .key = c.ImGuiKey_Escape } },
    expect("Esc fecha a paleta, e ele não se esconde por isso", paletteClosed),
    expect("(o Esc era da paleta)", notReact(.duck)),
    run(home),
    .{ .key = .{ .key = c.ImGuiKey_S, .ctrl = true } },
    expect("Ctrl+S: segura um disquete (nada mais abre)", saveNoPopup),
    .{ .wait = 300 },
    .{ .shot = "brinca-disquete" },
    run(home),
    .{ .key = .{ .key = c.ImGuiKey_P, .ctrl = true } },
    expect("Ctrl+P: imprime a própria pata (a paleta não abre)", printNoPalette),
    .{ .wait = 900 },
    .{ .shot = "brinca-pata" },
    run(home),
    click("composer"),
    .{ .text = "recorta isso" },
    .{ .key = .{ .key = c.ImGuiKey_A, .ctrl = true } },
    .{ .key = .{ .key = c.ImGuiKey_X, .ctrl = true } },
    expect("Ctrl+X: pega a tesoura, e o texto vai para a área de transferência", cutDone),
    .{ .wait = 250 },
    .{ .shot = "brinca-tesoura" },
    run(home),
    .{ .key = .{ .key = c.ImGuiKey_V, .ctrl = true } },
    expect("Ctrl+V: cospe um clone, e o texto volta para a caixa", pasteDone),
    .{ .wait = 350 },
    .{ .shot = "brinca-cola" },
    run(clearAndBlur),
    run(replyToLast),
    .{ .key = .{ .key = c.ImGuiKey_Escape } },
    expect("Esc cancela a resposta, e ele não se esconde por isso", replyCanceledNoDuck),
    run(openStatusMenu),
    .{ .wait = 100 },
    .{ .key = .{ .key = c.ImGuiKey_Escape } },
    expect("Esc fecha o menu, e ele não se esconde por isso", popupClosedNoDuck),
    .{ .wait = 100 },
    .{ .key = .{ .key = c.ImGuiKey_Escape } },
    expect("Esc sem nada para fechar: ele se esconde na caixa um instante", reactIs(.duck)),
    .{ .wait = 250 },
    .{ .shot = "brinca-esc" },
    .{ .wait = 1200 },
    .{ .key = .{ .key = c.ImGuiKey_Escape } },
    .{ .wait = 100 },
    expect("outro Esc logo depois: não toda hora", notReact(.duck)),

    s("mascote: o Clássico também brinca"),
    run(playReset),
    run(petClassic),
    click("composer"),
    .{ .text = "/shrug" },
    expect("no Clássico, o \"/\" também abre o terminalzinho", poseIs(.slash)),
    .{ .wait = 350 },
    .{ .shot = "brinca-classico-terminal" },
    run(clearInput),
    run(d20Next(20)),
    .{ .text = "dado" },
    .{ .key = .{ .key = c.ImGuiKey_Enter } },
    expect("e rola o d20", rolled(20)),
    .{ .wait = 1100 },
    .{ .shot = "brinca-classico-d20" },
    run(backToTerminal),

    s("mascote: as chaves das brincadeiras"),
    run(playReset),
    run(typingOff),
    click("composer"),
    .{ .text = "SEM REAGIR AGORA" },
    .{ .wait = 100 },
    expect("\"Reage ao que você digita\" desligado: nada de pose", noPose),
    .{ .text = " miau" },
    .{ .wait = 100 },
    expect("nem segredo", notReact(.meow)),
    run(clearInput),
    run(playReset),
    run(gamesOff),
    .{ .key = .{ .key = c.ImGuiKey_S, .ctrl = true } },
    .{ .wait = 100 },
    expect("\"Brincadeiras\" desligado: Ctrl+S não mexe nele", notReact(.save)),
    run(playReset),
    run(lifeOff),
    click("composer"),
    .{ .text = "VIDA PROPRIA DESLIGADA" },
    .{ .wait = 100 },
    expect("vida própria desligada: nem a caixa", noPose),
    run(clearInput),
    run(playReset),
    run(reduceOn),
    click("composer"),
    .{ .text = "REDUZIR MOVIMENTO" },
    .{ .wait = 100 },
    expect("\"Reduzir movimento\": nem a caixa", noPose),
    run(clearInput),
    run(openAppearance),
    expect("e as duas chaves ficam apagadas na aba", playTogglesOff),
    .{ .shot = "config-brincadeiras-reduzir" },
    run(closeSettings),
    run(playReset),
    run(clearInput),
} ++ @import("qa_mascote_repete.zig").ops ++ [_]Op{
    s("abertura do demo"),
    run(demoOpening),
    expect("conectado, a abertura espera a animação acabar", waitsForIntro),
    .{ .expect = .{ .name = "depois da animação, sai para o app", .check = leftAfterIntro, .timeout_ms = 4000 } },
    .{ .expect = .{ .name = "e a tela some no fim da saída", .check = loginGone, .timeout_ms = 3000 } },
    run(reduceOpening),
    expect("com \"Reduzir animações\", nada de abertura", reduceSkips),
    run(reduceOff),
};
