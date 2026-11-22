//! Rich Presence do lado da interface: liga e desliga o servidor IPC conforme a
//! opção (com a conta aberta) e leva a atividade que ele entrega para a conta
//! conectada. Desligado, custa uma comparação por quadro.
//!
//! E o "Jogando …" pelo processo aberto (a outra opção, `show_game`): de 15 em 15 s
//! olha os processos (platform/processos.zig) atrás dos jogos da lista
//! (core/jogos.zig) e manda o jogo aberto, no mesmo ritmo do Rich Presence e ao
//! lado da atividade dele no op 3. Desligada, não há timer nem varredura.
const std = @import("std");
const c = @import("c");
const App = @import("app.zig").App;
const ev = @import("core/event.zig");
const platform = @import("platform/window.zig");
const rpc = @import("net/rpc_ipc.zig");
const proto = @import("net/rpc_proto.zig");
const jogos = @import("core/jogos.zig");
const processos = @import("platform/processos.zig");
const nowMs = @import("net/fake_gateway.zig").nowMs;

/// O último comando mandado tinha atividade (ao desligar, manda limpar).
var showing = false;
/// Não deu para abrir o socket: não tenta a cada quadro até a opção mudar.
var failed = false;

/// Uma vez por quadro: só compara (ligar e desligar acontecem uma vez).
pub fn frame(app: *App) void {
    gameFrame(app);
    const want = app.st.settings.rich_presence and app.store.ready;
    if (!want) {
        failed = false;
        if (rpc.running()) stop(app);
        return;
    }
    if (rpc.running() or failed) return;
    if (!start(app)) {
        failed = true;
        app.st.showToast(nowMs(), true, "Rich Presence: não deu para abrir o discord-ipc (o Discord oficial está usando todos?)", "Rich Presence: couldn't open discord-ipc (is the official Discord using all of them?)", .{});
    }
}

fn start(app: *App) bool {
    var who: proto.Me = .{ .id = app.store.me };
    if (app.store.user(app.store.me)) |u| {
        who.global_name.set(u.name, 64);
        if (u.avatar) |a| if (!std.mem.startsWith(u8, a, "demo:")) who.avatar.set(a, 64);
    }
    who.username.set(app.store.me_username orelse who.global_name.slice(), 64);
    // O QA não espera 15 s entre um passo e outro (o ritmo tem teste próprio).
    if (app.opts.qa) rpc.throttle_ms = 300;
    return rpc.start(who, .{ .ctx = app, .f = wake });
}

fn stop(app: *App) void {
    rpc.stop();
    if (showing) send(app, 0, null);
}

/// Ao fechar o app (a sessão do gateway acaba junto, e a atividade com ela).
pub fn shutdown() void {
    rpc.stop();
    stopTimers();
    procs.deinit(std.heap.c_allocator);
}

/// Thread do servidor: acorda a interface, que passa a atividade adiante.
fn wake(ctx: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(ctx));
    if (!app.gw_signaled.swap(true, .acq_rel)) platform.Window.wake(app.win.wake_type, .gateway);
}

/// Junto com os eventos da rede: a atividade nova, se houver.
pub fn pump(app: *App) void {
    const u = rpc.take() orelse return;
    send(app, u.app, u.activity);
}

fn send(app: *App, client: u64, act: ?*proto.Activity) void {
    const command: ev.Command = .{ .set_activity = .{ .app = client, .activity = act } };
    switch (app.net) {
        .none => {
            if (act) |a| std.heap.c_allocator.destroy(a);
            showing = false;
            return;
        },
        .fake => |*g| g.commands.push(command),
        .real => |*g| g.commands.push(command),
    }
    showing = act != null;
}

// --- O jogo aberto ---------------------------------------------------------------

/// De quanto em quanto tempo olha os processos. O QA encurta (e o ritmo dos envios,
/// `rpc.throttle_ms`, junto).
pub var scan_ms: u32 = 15_000;
/// Depois de mexer na lista (nome, ligar, tirar, acrescentar), olha de novo logo.
pub var settle_ms: u32 = 400;
/// Quantas varreduras e quanto a última levou (QA e registro).
pub var scans: u32 = 0;
pub var last_scan_us: u64 = 0;

/// O timer que acorda a interface de 15 em 15 s (0 = desligado: nada roda).
var scan_timer: c.SDL_TimerID = 0;
/// Acordou por ele: é hora de olhar (o outro motivo é só o ritmo dos envios).
var scan_due = std.atomic.Value(bool).init(false);
/// Um timer de uma vez só já está marcado (olhar de novo logo, ou mandar o que esperava a vez).
var kick_pending = std.atomic.Value(bool).init(false);
var rescan = false;
var seen_gen: u32 = 0;
var procs: processos.List = .{};
var tracker: jogos.Tracker = .{};
var pace: jogos.Pace = .{ .throttle = .{ .interval_ms = 15_000 } };
/// O último envio tinha jogo (ao desligar, manda limpar).
var game_showing = false;
/// Quem os timers acordam.
var timer_app: ?*App = null;

/// O timer está de pé (a opção ligada, com a conta aberta).
pub fn gameActive() bool {
    return scan_timer != 0;
}

fn gameFrame(app: *App) void {
    const want = app.st.settings.show_game and app.store.ready and app.net != .none;
    if (!want) {
        if (scan_timer != 0 or game_showing) stopGame(app);
        return;
    }
    if (scan_timer == 0) return startGame(app);
    // Mexeu na lista: olha de novo daqui a pouco (digitar o nome não vira uma
    // varredura por tecla).
    if (app.st.jogos.gen != seen_gen and !rescan) {
        rescan = true;
        kick(settle_ms);
    }
}

fn startGame(app: *App) void {
    if (app.opts.qa) {
        rpc.throttle_ms = 300;
        scan_ms = 200;
        settle_ms = 50;
    }
    pace = .{ .throttle = .{ .interval_ms = rpc.throttle_ms } };
    tracker.reset();
    timer_app = app;
    scan_timer = c.SDL_AddTimer(scan_ms, scanTick, app);
    // Ligou: olha agora, sem esperar os primeiros 15 s.
    scanNow(app);
    flush(app);
}

fn stopTimers() void {
    if (scan_timer != 0) _ = c.SDL_RemoveTimer(scan_timer);
    scan_timer = 0;
    scan_due.store(false, .release);
    rescan = false;
}

fn stopGame(app: *App) void {
    stopTimers();
    tracker.reset();
    pace.reset();
    // Desligar limpa na hora (como o Rich Presence ao desligar), sem esperar a vez.
    if (game_showing) sendGame(app, null);
}

/// Thread dos timers do SDL: só acorda a interface.
fn scanTick(data: ?*anyopaque, _: c.SDL_TimerID, interval: u32) callconv(.c) u32 {
    scan_due.store(true, .release);
    wakeUi(data);
    return interval;
}

fn kickTick(data: ?*anyopaque, _: c.SDL_TimerID, _: u32) callconv(.c) u32 {
    kick_pending.store(false, .release);
    wakeUi(data);
    return 0;
}

fn wakeUi(data: ?*anyopaque) void {
    const app: *App = @ptrCast(@alignCast(data.?));
    platform.Window.wake(app.win.wake_type, .jogo);
}

/// Acorda a interface daqui a `ms` (um timer só por vez).
fn kick(ms: i64) void {
    if (scan_timer == 0 or kick_pending.swap(true, .acq_rel)) return;
    if (c.SDL_AddTimer(@intCast(std.math.clamp(ms, 1, 60_000)), kickTick, timer_app) == 0) kick_pending.store(false, .release);
}

/// O laço principal acordou pelo `.jogo` (sem pedir quadro: se o jogo mudar, a
/// nossa linha nova chega pelo gateway e desenha).
pub fn gameWake(app: *App) void {
    if (scan_timer == 0) return;
    if (scan_due.swap(false, .acq_rel) or rescan) scanNow(app);
    flush(app);
}

fn scanNow(app: *App) void {
    rescan = false;
    const list = &app.st.jogos;
    seen_gen = list.gen;
    const t0 = c.SDL_GetTicksNS();
    processos.scan(&procs, std.heap.c_allocator, .{ .games = list.constSlice() });
    last_scan_us = (c.SDL_GetTicksNS() - t0) / 1000;
    scans +%= 1;
    const i = jogos.firstRunning(list.constSlice(), procs.items(), jogos.native);
    const before = if (tracker.now) |p| p.id else 0;
    const playing = tracker.update(if (i) |k| &list.items[k] else null, nowMs());
    const after = if (playing) |p| p.id else 0;
    if (before != after) {
        if (playing) |p| std.log.info("jogo aberto: {s} (varredura em {d} µs)", .{ p.name.slice(), last_scan_us }) else std.log.info("jogo fechado (varredura em {d} µs)", .{last_scan_us});
    }
    pace.set(playing);
}

/// Manda o que mudou, se o ritmo deixa; senão, volta na hora em que deixar.
fn flush(app: *App) void {
    const now: i64 = @intCast(c.SDL_GetTicks());
    if (pace.take(now)) |s| return sendGame(app, if (s.game) |*g| g else null);
    if (pace.waitMs(now)) |w| kick(w);
}

fn sendGame(app: *App, game: ?*const jogos.Playing) void {
    var copy: ?*proto.Game = null;
    if (game) |g| {
        copy = std.heap.c_allocator.create(proto.Game) catch return;
        copy.?.* = .{ .start_ms = g.start_ms };
        copy.?.name.set(g.name.slice(), proto.max_text);
    }
    const command: ev.Command = .{ .set_game = copy };
    switch (app.net) {
        .none => {
            if (copy) |x| std.heap.c_allocator.destroy(x);
            game_showing = false;
            return;
        },
        .fake => |*g| g.commands.push(command),
        .real => |*g| g.commands.push(command),
    }
    game_showing = copy != null;
}
