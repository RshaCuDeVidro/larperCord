//! QA do renderizador (Configurações → Desempenho): a lista tem o automático e os do
//! SDL, escolher grava o nome e voltar ao automático limpa, e um renderizador que não
//! abre não impede o app de abrir (fica o automático, com o aviso).
//! QA_SUITE=render e QA_SUITE=render-falha (esta com um settings.kdl que pede um
//! renderizador que não existe; ver tools/qa.sh).
const std = @import("std");
const App = @import("app.zig").App;
const R = @import("qa_runner.zig");
const Op = R.Op;
const qa = @import("ui/qa.zig");
const win = @import("platform/window.zig");

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

fn ready(app: *App) bool {
    return app.store.ready;
}
fn openPerf(app: *App) void {
    app.st.settings.open = true;
    app.st.settings.page = .desempenho;
}
fn closeSettings(app: *App) void {
    app.st.settings.open = false;
}
fn listed(app: *App) bool {
    const active = std.mem.sliceTo(&win.active_renderer, 0);
    var b: [64]u8 = undefined;
    const mark = std.fmt.bufPrint(&b, "renderer-active:{s}", .{active}) catch return false;
    return active.len > 0 and qa.find("radio:Automático") != null and qa.find("radio:Software (lento, sem placa de vídeo)") != null and
        qa.find(mark) != null and app.st.settings.renderer.slice().len == 0 and !win.renderer_fallback;
}
fn pickedSoftware(app: *App) bool {
    return std.mem.eql(u8, app.st.settings.renderer.slice(), "software");
}
fn backToAuto(app: *App) bool {
    return app.st.settings.renderer.slice().len == 0;
}
fn fellBack(_: *App) bool {
    return win.renderer_fallback and std.mem.sliceTo(&win.active_renderer, 0).len > 0;
}
fn fallbackShown(_: *App) bool {
    return qa.find("renderer-fallback") != null;
}

pub const ops = [_]Op{
    s("renderizador"),
    expect("pronto", ready),
    run(openPerf),
    expect("Desempenho lista o automático e os renderizadores do SDL, e diz qual está em uso", listed),
    .{ .shot = "renderizador" },
    click("radio:Software (lento, sem placa de vídeo)"),
    expect("escolher um grava o nome dele (vale no próximo início)", pickedSoftware),
    click("radio:Automático"),
    expect("voltar ao automático limpa a escolha", backToAuto),
    run(closeSettings),
};

pub const ops_fail = [_]Op{
    s("renderizador que não abre"),
    expect("pronto", ready),
    expect("o settings.kdl pede um renderizador que não existe: o app abre no automático", fellBack),
    run(openPerf),
    expect("e Desempenho avisa que ficou o automático", fallbackShown),
    .{ .shot = "renderizador-falha" },
    run(closeSettings),
};
