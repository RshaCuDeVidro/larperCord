//! Rich Presence do lado da interface: liga e desliga o servidor IPC conforme a
//! opção (com a conta aberta) e leva a atividade que ele entrega para a conta
//! conectada. Desligado, custa uma comparação por quadro.
const std = @import("std");
const App = @import("app.zig").App;
const ev = @import("core/event.zig");
const platform = @import("platform/window.zig");
const rpc = @import("net/rpc_ipc.zig");
const proto = @import("net/rpc_proto.zig");
const spotify = @import("net/spotify_presenca.zig");
const nowMs = @import("net/fake_gateway.zig").nowMs;

/// O último comando mandado tinha atividade (ao desligar, manda limpar).
var showing = false;
/// Não deu para abrir o socket: não tenta a cada quadro até a opção mudar.
var failed = false;

/// Uma vez por quadro: só compara (ligar e desligar acontecem uma vez).
pub fn frame(app: *App) void {
    const want = app.st.settings.rich_presence and app.store.ready;
    if (!want) {
        failed = false;
        if (rpc.running()) stop(app);
    } else if (!rpc.running() and !failed) {
        if (!start(app)) {
            failed = true;
            app.st.showToast(nowMs(), true, "Rich Presence: não deu para abrir o discord-ipc (o Discord oficial está usando todos?)", "Rich Presence: couldn't open discord-ipc (is the official Discord using all of them?)", .{});
        }
    }
    // O Spotify é independente do discord-ipc: tem o quadro dele.
    spotify.frame(app);
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
    if (showing) _ = sendTo(app, 0, null);
}

/// Ao fechar o app (a sessão do gateway acaba junto, e a atividade com ela).
pub fn shutdown() void {
    rpc.stop();
    spotify.shutdown();
}

/// Thread do servidor: acorda a interface, que passa a atividade adiante.
fn wake(ctx: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(ctx));
    if (!app.gw_signaled.swap(true, .acq_rel)) platform.Window.wake(app.win.wake_type, .gateway);
}

/// Junto com os eventos da rede: a atividade nova, se houver.
pub fn pump(app: *App) void {
    const u = rpc.take() orelse return;
    showing = sendTo(app, u.app, u.activity) and u.activity != null;
}

/// Atividade nossa, sem aplicação (o Spotify, net/spotify_presenca.zig): vai
/// com app 0 e o nome da própria atividade. Quem manda guarda o estado dela.
pub fn sendSpotify(app: *App, act: ?*proto.Activity) void {
    _ = sendTo(app, 0, act);
}

/// Manda o comando para a conta conectada (limpar é `act` null). true = foi;
/// falso (sem conta) já consome a atividade que ia.
fn sendTo(app: *App, client: u64, act: ?*proto.Activity) bool {
    const command: ev.Command = .{ .set_activity = .{ .app = client, .activity = act } };
    switch (app.net) {
        .none => {
            if (act) |a| std.heap.c_allocator.destroy(a);
            return false;
        },
        .fake => |*g| g.commands.push(command),
        .real => |*g| g.commands.push(command),
    }
    return true;
}
