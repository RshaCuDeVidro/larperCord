//! Presença do Spotify: o que está tocando no Spotify do computador vira a
//! nossa atividade ("Listening to …"), sem aplicação nenhuma. A detecção fica
//! em platform/spotify.zig (thread de 2 s em 2 s); aqui é o colar: opção
//! ligada, a faixa nova (mudou, e só ela) vai para a conta como atividade
//! nossa (app 0, o nome vem dela — net/app_presenca.zig). Desligada, a
//! detecção para e a atividade limpa. No QA, a detecção é injetada (não há
//! thread: o Spotify de quem testa não entra no caminho).
const std = @import("std");
const App = @import("../app.zig").App;
const proto = @import("rpc_proto.zig");
const spotify = @import("../platform/spotify.zig");
const app_presenca = @import("../app_presenca.zig");
const nowMs = @import("fake_gateway.zig").nowMs;

/// A última atividade mandada era do Spotify (ao desligar, manda limpar).
var showing = false;

/// Uma vez por quadro: começa e para a detecção, e leva a faixa nova adiante.
pub fn frame(app: *App) void {
    const want = app.st.settings.spotify_presence and app.store.ready;
    if (!want) {
        if (spotify.running()) spotify.stop();
        if (showing) {
            showing = false;
            app_presenca.sendSpotify(app, null);
        }
        return;
    }
    // O QA injeta (spotify.qaInject): a thread de verdade encontraria o
    // Spotify de quem testa e disputaria com a injeção.
    if (!spotify.running() and !app.opts.qa) _ = spotify.start();
    var novo: ?spotify.Track = null;
    if (!spotify.take(&novo)) return;
    if (novo) |*t| {
        var act: proto.Activity = .{};
        spotify.buildActivity(t, nowMs(), &act);
        const copy = std.heap.c_allocator.create(proto.Activity) catch return;
        copy.* = act;
        app_presenca.sendSpotify(app, copy);
        showing = true;
    } else if (showing) {
        showing = false;
        app_presenca.sendSpotify(app, null);
    }
}

/// Ao fechar o app: para a detecção (a atividade morre com a sessão).
pub fn shutdown() void {
    spotify.stop();
}
