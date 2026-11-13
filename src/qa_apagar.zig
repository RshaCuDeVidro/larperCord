//! QA do "Apagar todos os dados" (Configurações → Avançado, platform/apagar.zig).
//! QA_SUITE=apagar, sempre por tools/qa_apagar.sh: ele monta as pastas de mentira em
//! qa-out/apagar (HOME, XDG_CONFIG_HOME e XDG_CACHE_HOME só desta bateria). Aqui: o
//! botão, a pergunta com o que sai, Cancelar e sair da página não apagam nada, e
//! confirmar pede para fechar. O que sumiu e o que tinha que ficar, o script confere
//! de fora, com o processo já encerrado.
const std = @import("std");
const c = @import("c");
const App = @import("app.zig").App;
const R = @import("qa_runner.zig");
const Op = R.Op;
const qa = @import("ui/qa.zig");
const fsutil = @import("platform/fsutil.zig");
const sys = @import("platform/sys.zig");

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

/// O que o script deixou nas pastas continua lá.
fn seeded(_: *App) bool {
    var b: [512]u8 = undefined;
    const settings = fsutil.configPath(&b, "settings.kdl") orelse return false;
    var cb: [512]u8 = undefined;
    const base = sys.cacheHome(&cb) orelse return false;
    var pb: [600]u8 = undefined;
    const log = std.fmt.bufPrintSentinel(&pb, "{s}/larpercord/debug.log", .{base}, 0) catch return false;
    return sys.exists(settings.ptr) and sys.exists(log.ptr);
}
fn openAdvanced(app: *App) void {
    app.st.settings.open = true;
    app.st.settings.page = .avancado;
}
fn wheelDown(app: *App) void {
    c.ImGuiIO_AddMouseWheelEvent(app.io, 0, -60);
}
fn buttonShown(_: *App) bool {
    return qa.visiblePart("button:Apagar todos os dados…") != null and qa.find("wipe-confirm") == null;
}
fn asks(app: *App) bool {
    return qa.find("wipe-confirm") != null and qa.visiblePart("button:Cancelar") != null and
        qa.visiblePart("button:Apagar tudo e fechar") != null and !app.wipe_wanted;
}
fn cancelled(app: *App) bool {
    return qa.find("wipe-confirm") == null and qa.find("button:Apagar todos os dados…") != null and !app.wipe_wanted and seeded(app);
}
fn wipeWanted(app: *App) bool {
    return app.wipe_wanted;
}

pub const ops = [_]Op{
    s("apagar todos os dados"),
    expect("as pastas de mentira estão lá", seeded),
    run(openAdvanced),
    .{ .wait = 150 },
    .{ .hover = .{ .mark = "toggle:Modo desenvolvedor" } },
    run(wheelDown),
    .{ .expect = .{ .name = "o botão fica no fim de Avançado", .check = buttonShown, .timeout_ms = 2500 } },
    .{ .shot = "apagar-botao" },
    click("button:Apagar todos os dados…"),
    expect("pergunta antes, com Cancelar e o botão de apagar", asks),
    run(wheelDown),
    .{ .wait = 200 },
    expect("nada se sobrepõe na pergunta", @import("qa_paineis.zig").noOverlap),
    .{ .shot = "apagar-pergunta" },
    click("button:Cancelar"),
    expect("Cancelar fecha a pergunta e não apaga nada", cancelled),
    click("button:Apagar todos os dados…"),
    expect("pergunta de novo", asks),
    click("settings:Chat"),
    click("settings:Avançado"),
    .{ .wait = 150 },
    .{ .hover = .{ .mark = "toggle:Modo desenvolvedor" } },
    run(wheelDown),
    .{ .expect = .{ .name = "saindo da página, a pergunta volta fechada", .check = cancelled, .timeout_ms = 2500 } },
    click("button:Apagar todos os dados…"),
    expect("pergunta outra vez", asks),
    run(wheelDown),
    .{ .wait = 200 },
    click("button:Apagar tudo e fechar"),
    expect("confirmar pede para apagar e fechar o app", wipeWanted),
};
