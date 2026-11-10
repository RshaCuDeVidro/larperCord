//! QA do tempo da call nos canais de voz: o op 43 sai uma vez por servidor (o
//! gateway de mentira responde com o CHANNEL_INFO), o tempo aparece com o texto
//! certo, some quando a call acaba (VOICE_CHANNEL_START_TIME_UPDATE, inclusive o
//! que a demonstração manda ao entrar e sair do AFK), muda com o formato escolhido
//! nas Configurações, e o app só marca acordar na virada certa (segundo ou minuto
//! cheio) com a linha na tela e a opção ligada. Sozinho: QA_SUITE=cronometro.
const std = @import("std");
const c = @import("c");
const App = @import("app.zig").App;
const R = @import("qa_runner.zig");
const Op = R.Op;
const qa = @import("ui/qa.zig");
const gw = @import("net/fake_gateway.zig");
const anim = @import("ui/anim.zig");
const vt = @import("core/voice_timer.zig");
const timer_ui = @import("ui/voice_timer.zig");
const platform = @import("platform/window.zig");
const Id = @import("core/types.zig").Id;

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

const g0: Id = 500_000;
const g1: Id = 501_000;
/// Os canais de voz do primeiro servidor: com call e três pessoas, com call e uma,
/// e o AFK, vazio.
const call3: Id = 500_014;
const call1: Id = 500_015;
const afk: Id = 500_016;

var infos_before: usize = 0;
var saved_start: i64 = 0;

fn infos() usize {
    return gw.sent.channel_infos.load(.acquire);
}

fn timerShown(id: Id) ?[]const u8 {
    var b: [40]u8 = undefined;
    if (qa.find(std.fmt.bufPrint(&b, "voice-timer:{d}", .{id}) catch return null) == null) return null;
    return timer_ui.shownText(id);
}

/// O que o canal deveria mostrar no quadro que acabou de sair.
fn expected(app: *App, id: Id, buf: []u8) ?[]const u8 {
    const cs = app.store.channel(id) orelse return null;
    const e = vt.elapsed(timer_ui.scheduled_at_ms, cs.voice_start_s) orelse return null;
    return timer_ui.format(&app.st.settings).text(buf, e);
}

fn showsExpected(app: *App, id: Id) bool {
    var b: [128]u8 = undefined;
    const want = expected(app, id, &b) orelse return false;
    const got = timerShown(id) orelse return false;
    return std.mem.eql(u8, want, got);
}

// --- Abertura ------------------------------------------------------------------

fn openGuild0(app: *App) void {
    app.st.settings.voice_timer = true;
    app.st.settings.voice_timer_format = 0;
    app.st.settings.voice_timer_pattern = .{};
    app.handle(.{ .select_guild = g0 });
}
fn askedOnce(app: *App) bool {
    _ = app;
    return infos() >= 1 and gw.sent.channel_info_guild.load(.acquire) == g0;
}
fn noteInfos(_: *App) void {
    infos_before = infos();
}
fn startsKnown(app: *App) bool {
    const a = app.store.channel(call3) orelse return false;
    const b = app.store.channel(call1) orelse return false;
    const z = app.store.channel(afk) orelse return false;
    return a.voice_start_s > 0 and b.voice_start_s > 0 and z.voice_start_s == 0;
}
fn timerRight(app: *App) bool {
    var b: [128]u8 = undefined;
    const want = expected(app, call3, &b) orelse return false;
    // A demonstração começa em 16:42:14 (mais o tempo do QA até aqui).
    return showsExpected(app, call3) and showsExpected(app, call1) and std.mem.startsWith(u8, want, "16:4");
}
fn afkNoTimer(_: *App) bool {
    return timerShown(afk) == null;
}
fn nextSecond(_: *App) bool {
    return anim.clock_wake_ms == (@divFloor(timer_ui.scheduled_at_ms, 1000) + 1) * 1000;
}
fn noOverlap(_: *App) bool {
    return qa.find("vt-name:500014") != null and qa.overlapping(&.{ "vt-name:", "voice-timer:" }) == null;
}

// --- Uma vez por servidor ----------------------------------------------------------

fn toText(app: *App) void {
    app.handle(.{ .select_channel = gw.channelId(0, 5) });
}
fn toText2(app: *App) void {
    app.handle(.{ .select_channel = gw.channelId(0, 9) });
}
fn sameCount(_: *App) bool {
    return infos() == infos_before;
}
fn toGuild1(app: *App) void {
    app.handle(.{ .select_guild = g1 });
}
fn askedGuild1(_: *App) bool {
    return infos() == infos_before + 1 and gw.sent.channel_info_guild.load(.acquire) == g1;
}
fn backGuild0(app: *App) void {
    app.handle(.{ .select_guild = g0 });
}
fn oneMore(_: *App) bool {
    return infos() == infos_before + 1;
}

// --- A call começa e acaba ---------------------------------------------------------

fn joinAfk(app: *App) void {
    app.handle(.{ .toggle_voice = afk });
}
fn afkStarted(app: *App) bool {
    const cs = app.store.channel(afk) orelse return false;
    const t = timerShown(afk) orelse return false;
    return cs.voice_start_s > 0 and std.mem.startsWith(u8, t, "0:00:") and showsExpected(app, afk);
}
fn leaveAfk(app: *App) void {
    app.handle(.leave_voice);
}
fn afkEnded(app: *App) bool {
    const cs = app.store.channel(afk) orelse return false;
    return cs.voice_start_s == 0 and timerShown(afk) == null;
}
fn endCall1(app: *App) void {
    saved_start = app.store.channel(call1).?.voice_start_s;
    app.events.push(.{ .voice_start = .{ .guild = g0, .channel = call1, .start_s = 0 } });
    platform.Window.wake(app.win.wake_type, .gateway);
}
fn call1Ended(app: *App) bool {
    const cs = app.store.channel(call1) orelse return false;
    // Ainda tem gente na lista; quem manda é o fim da call.
    return cs.voice_members.items.len > 0 and cs.voice_start_s == 0 and timerShown(call1) == null and timerShown(call3) != null;
}
fn restartCall1(app: *App) void {
    app.events.push(.{ .voice_start = .{ .guild = g0, .channel = call1, .start_s = saved_start } });
    platform.Window.wake(app.win.wake_type, .gateway);
}
fn call1Back(app: *App) bool {
    return showsExpected(app, call1);
}

// --- O formato nas Configurações ------------------------------------------------------

fn openAppearance(app: *App) void {
    app.st.settings.page = .aparencia;
    app.handle(.open_settings);
}
fn closeSettings(app: *App) void {
    app.handle(.close_settings);
}
fn formatIsHmm(app: *App) bool {
    return app.st.settings.voice_timer_format == 4;
}
fn minutesShown(app: *App) bool {
    const t = timerShown(call3) orelse return false;
    // "16:42": sem os segundos, e igual ao que o formato dá.
    return !app.st.settings.open and std.mem.count(u8, t, ":") == 1 and showsExpected(app, call3) and showsExpected(app, call1);
}
fn nextMinute(app: *App) bool {
    const w = anim.clock_wake_ms;
    const now = timer_ui.scheduled_at_ms;
    if (w == std.math.maxInt(i64) or @mod(w, 60_000) != 0 or w <= now or w > now + 120_000) return false;
    // A mais cedo das viradas dos canais na tela, cada uma no minuto cheio seguinte.
    const f = timer_ui.format(&app.st.settings);
    var want: i64 = std.math.maxInt(i64);
    for ([_]Id{ call3, call1 }) |id| {
        const cs = app.store.channel(id) orelse return false;
        want = @min(want, vt.nextChange(f, now, cs.voice_start_s) orelse return false);
    }
    return w == want;
}
fn customPrefilled(app: *App) bool {
    // Escolher "Personalizado" começa do formato que estava (h:mm).
    return app.st.settings.voice_timer_format == vt.custom_index and std.mem.eql(u8, app.st.settings.voice_timer_pattern.slice(), vt.presets[4].pattern);
}
const custom_pattern = "{ss}s {mm}m {H}h {x}";
fn customTyped(app: *App) bool {
    if (!std.mem.eql(u8, app.st.settings.voice_timer_pattern.slice(), custom_pattern)) return false;
    // A prévia muda enquanto se escreve, e o campo desconhecido avisa.
    var b: [64]u8 = undefined;
    const want = vt.resolve(vt.custom_index, custom_pattern).text(&b, 60134);
    return std.mem.eql(u8, want, "14s 42m 16h {x}") and qa.find("vt-preview:60134") != null and qa.find("vt-unknown") != null;
}
fn customShown(app: *App) bool {
    const t = timerShown(call3) orelse return false;
    return !app.st.settings.open and std.mem.endsWith(u8, t, "h {x}") and showsExpected(app, call3);
}
fn backToDefault(app: *App) void {
    app.st.settings.voice_timer_format = 0;
    app.st.settings.voice_timer_pattern = .{};
}

// --- Fora da tela e desligado -------------------------------------------------------

fn noWake(_: *App) bool {
    return anim.clock_wake_ms == std.math.maxInt(i64);
}
fn offScreen(app: *App) bool {
    return noWake(app) and qa.visiblePart("voice-timer:500014") == null and qa.visiblePart("voice-timer:500015") == null;
}
fn wheelDown(app: *App) void {
    c.ImGuiIO_AddMouseWheelEvent(app.io, 0, -40);
}
fn backOnScreen(app: *App) bool {
    return qa.visiblePart("voice-timer:500014") != null and nextSecond(app);
}
fn turnOff(app: *App) void {
    app.st.settings.voice_timer = false;
}
fn offNothing(app: *App) bool {
    return noWake(app) and qa.find("voice-timer:500014") == null and qa.find("voice-timer:500015") == null;
}
fn turnOn(app: *App) void {
    app.st.settings.voice_timer = true;
}
fn onAgain(app: *App) bool {
    return showsExpected(app, call3) and nextSecond(app);
}

pub const ops = [_]Op{
    s("tempo da call: op 43 e o texto"),
    run(openGuild0),
    expect("abrir o servidor manda o op 43 (Request Channel Info) dele", askedOnce),
    expect("o CHANNEL_INFO da demonstração chega: duas calls, o AFK sem", startsKnown),
    expect("o tempo aparece ao lado das calls com o texto certo (16:42:…)", timerRight),
    expect("canal de voz sem call não mostra tempo", afkNoTimer),
    expect("com segundos, a próxima virada marcada é a do segundo seguinte", nextSecond),
    expect("o nome do canal corta antes do tempo, sem sobrepor", noOverlap),
    .{ .shot = "tempo-call" },

    s("tempo da call: uma vez por servidor"),
    run(noteInfos),
    run(toText),
    .{ .wait = 200 },
    run(toText2),
    .{ .wait = 300 },
    expect("trocar de canal no mesmo servidor não pede de novo", sameCount),
    run(toGuild1),
    expect("outro servidor pede uma vez o dele", askedGuild1),
    run(backGuild0),
    .{ .wait = 300 },
    expect("voltar ao primeiro não pede de novo", oneMore),

    s("tempo da call: começo e fim"),
    run(joinAfk),
    // Em call, a faixa de voz empurra o fim da lista para baixo: rola até o AFK.
    .{ .hover = .{ .mark = "channel:500005" } },
    run(wheelDown),
    expect("entrar no AFK vazio começa a call dele (VOICE_CHANNEL_START_TIME_UPDATE) e o tempo aparece em 0:00:…", afkStarted),
    run(leaveAfk),
    expect("sair do AFK acaba a call e o tempo some", afkEnded),
    run(endCall1),
    expect("a call que acaba some da lista, mesmo com gente no canal", call1Ended),
    run(restartCall1),
    expect("e volta quando a call começa de novo", call1Back),

    s("tempo da call: formato nas Configurações"),
    run(openAppearance),
    click("vt-format"),
    click("vt-preset:4"),
    expect("escolher h:mm muda o formato", formatIsHmm),
    run(closeSettings),
    expect("a lista mostra só horas e minutos", minutesShown),
    expect("só minutos: a próxima virada marcada é um minuto cheio", nextMinute),
    run(openAppearance),
    click("vt-format"),
    click("vt-preset:10"),
    expect("\"Personalizado\" começa do formato escolhido antes", customPrefilled),
    click("vt-pattern"),
    .{ .key = .{ .key = c.ImGuiKey_A, .ctrl = true } },
    .{ .text = custom_pattern },
    expect("o formato escrito vale na hora, com prévia e aviso do campo desconhecido", customTyped),
    // Até o fim da página: os campos, o aviso e a prévia no print.
    run(wheelDown),
    .{ .wait = 300 },
    .{ .shot = "tempo-call-config" },
    run(closeSettings),
    expect("a lista usa o formato escrito ({x} aparece como texto)", customShown),
    expect("com segundos no formato escrito, acorda no segundo seguinte", nextSecond),
    run(backToDefault),

    s("tempo da call: fora da tela e desligado"),
    .{ .resize = .{ 1280, 460 } },
    .{ .wait = 300 },
    expect("com as calls fora da tela, nada marca acordar", offScreen),
    .{ .hover = .{ .mark = "channel:500005" } },
    run(wheelDown),
    expect("rolando até elas, volta a marcar a virada do segundo", backOnScreen),
    .{ .resize = .{ 1280, 800 } },
    run(turnOff),
    expect("desligado: sem tempo na lista e sem acordar", offNothing),
    run(turnOn),
    expect("ligado de novo, volta", onAgain),
};

// --- Em cada tema ---------------------------------------------------------------

fn themeHasList(_: *App) bool {
    return qa.find("channel:500014") != null;
}
fn themeOk(app: *App) bool {
    // Tema sem lista de canais à vista (zen esconde a navegação): nada a conferir.
    if (!themeHasList(app)) return true;
    return showsExpected(app, call3) and qa.overlapping(&.{ "vt-name:", "voice-timer:" }) == null;
}

/// Estreita: sem lugar nem para o começo do nome, o tempo some; nunca cobre o nome.
fn themeNarrowOk(app: *App) bool {
    if (!themeHasList(app)) return true;
    if (qa.overlapping(&.{ "vt-name:", "voice-timer:" }) != null) return false;
    return timerShown(call3) == null or showsExpected(app, call3);
}

fn narrow(app: *App) void {
    // O mais estreito que a divisa deixa (ui/resize.zig).
    app.st.settings.width_channels = -80;
}
fn wide(app: *App) void {
    app.st.settings.width_channels = 0;
}

/// Nos temas de linha alta (papel, escritorio, cupertino) os canais de voz ficam
/// abaixo da dobra, e o tempo só se desenha com a linha na tela: rola até eles.
fn listMark(app: *App, _: []u8) []const u8 {
    return if (themeHasList(app)) "channel:500005" else "";
}

pub const ops_theme = [_]Op{
    s("tempo da call no tema"),
    run(openGuild0),
    .{ .wait = 300 },
    .{ .hover = .{ .dyn = listMark } },
    run(wheelDown),
    .{ .wait = 300 },
    expect("o tempo aparece ao lado da call, sem cobrir o nome", themeOk),
    .{ .shot = "tempo-call" },
    run(narrow),
    .{ .wait = 300 },
    expect("com a lista de canais estreita, o nome corta antes do tempo, sem sobrepor", themeNarrowOk),
    .{ .shot = "tempo-call-estreita" },
    run(wide),
};
