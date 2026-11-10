//! QA do volume de cada pessoa no menu do botão direito (QA_SUITE=voice, junto com
//! o mixer): só aparece para os outros da call em que estamos, arrastar muda o
//! mesmo valor do mixer sem fechar o menu, e "Silenciar para mim" zera e volta.
//! Na demonstração, a call da madrugada (500014) tem 1001, 1005 e 1003; o 1002
//! está no canal "Jogando" (500015).
const std = @import("std");
const c = @import("c");
const App = @import("app.zig").App;
const R = @import("qa_runner.zig");
const Op = R.Op;
const qa = @import("ui/qa.zig");
const popup = @import("ui/popup.zig");
const Id = @import("core/types.zig").Id;

const me: Id = 1000;
const friend: Id = 1001;
const elsewhere: Id = 1002;

fn s(name: []const u8) Op {
    return .{ .section = name };
}
fn click(k: []const u8) Op {
    return .{ .click = .{ .mark = k } };
}
fn rclick(k: []const u8) Op {
    return .{ .rclick = .{ .mark = k } };
}
fn expect(name: []const u8, f: *const fn (*App) bool) Op {
    return .{ .expect = .{ .name = name, .check = f } };
}
fn shot(name: []const u8) Op {
    return .{ .shot = name };
}
const esc: Op = .{ .key = .{ .key = c.ImGuiKey_Escape } };
/// Um ponto do controle de volume do menu (frações da área de arrastar).
fn slider(fx: f32) R.Target {
    return .{ .at = .{ .key = "menu-volume:1001", .fx = fx, .fy = 0.5 } };
}

fn volume(app: *App) f32 {
    return app.st.voice_volumes.get(friend) orelse 1.0;
}

/// O menu de `uid` aberto e desenhado.
fn userMenu(app: *App, uid: Id) bool {
    return switch (app.st.popup) {
        .menu => |m| m.kind == .user and m.id == uid and qa.find("menu:Perfil") != null,
        else => false,
    };
}
fn hasVolumeRows() bool {
    return qa.find("menu:Volume do usuário") != null and qa.find("menu:Silenciar para mim") != null and qa.find("menu-volume:1001") != null;
}
fn noVolumeRows() bool {
    return qa.find("menu:Volume do usuário") == null and qa.find("menu:Silenciar para mim") == null;
}
/// O número ao lado do controle (`prefix`: o do menu ou o do mixer) é o volume de agora.
fn shows(app: *App, comptime prefix: []const u8) bool {
    var b: [48]u8 = undefined;
    return qa.find(std.fmt.bufPrint(&b, prefix ++ ":{d}:{d}", .{ friend, popup.volumePct(volume(app)) }) catch return false) != null;
}

fn friendNoVolume(app: *App) bool {
    return userMenu(app, friend) and noVolumeRows();
}
fn friendVolume(app: *App) bool {
    return userMenu(app, friend) and hasVolumeRows() and shows(app, "menu-volume-pct");
}
fn friendVolumeNormal(app: *App) bool {
    return friendVolume(app) and volume(app) == 1.0 and qa.find("menu-on:Silenciar para mim") == null;
}
fn draggedOutside(app: *App) bool {
    return userMenu(app, friend) and volume(app) == 2.0 and shows(app, "menu-volume-pct");
}
fn draggedDown(app: *App) bool {
    const v = volume(app);
    return userMenu(app, friend) and v > 0.4 and v < 0.75 and shows(app, "menu-volume-pct");
}
fn closed(app: *App) bool {
    return app.st.popup == .none;
}
fn mixerSame(app: *App) bool {
    return app.st.popup == .mixer and volume(app) > 0.4 and volume(app) < 0.75 and shows(app, "voice-volume-pct");
}
fn mutedForMe(app: *App) bool {
    return volume(app) <= 0.001 and app.st.popup == .none;
}
fn mutedChecked(app: *App) bool {
    return userMenu(app, friend) and qa.find("menu-on:Silenciar para mim") != null and qa.find("menu-volume-pct:1001:0") != null;
}
fn backToNormal(app: *App) bool {
    return volume(app) == 1.0 and app.st.popup == .none;
}
fn selfNoVolume(app: *App) bool {
    return userMenu(app, me) and noVolumeRows();
}
fn elsewhereNoVolume(app: *App) bool {
    return app.store.voiceChannelOf(elsewhere, 500000) == 500015 and userMenu(app, elsewhere) and noVolumeRows();
}

/// Antes de entrar na call.
pub const fora = [_]Op{
    rclick("voice-member:500014:1001"),
    expect("fora da call: o menu de quem está num canal de voz não tem volume", friendNoVolume),
    esc,
};

/// Na call, depois do mixer.
pub const na_call = [_]Op{
    s("volume no menu"),
    rclick("voice-member:500014:1001"),
    expect("botão direito em quem está na call: Volume do usuário (100%) e Silenciar para mim", friendVolumeNormal),
    .{ .drag = .{ .from = slider(0.5), .to = slider(1.7) } },
    expect("arrastar até fora do menu: 200% e o menu continua aberto", draggedOutside),
    .{ .drag = .{ .from = slider(0.9), .to = slider(0.3) } },
    expect("arrastar para a esquerda baixa o volume dela (o número acompanha)", draggedDown),
    shot("voz-menu-volume"),
    esc,
    expect("Esc fecha o menu", closed),
    click("voice-mixer"),
    expect("o mixer mostra o mesmo volume que o menu deixou", mixerSame),
    click("voice-mixer-close"),
    expect("fechar o mixer", closed),
    rclick("voice-member:500014:1001"),
    click("menu:Silenciar para mim"),
    expect("Silenciar para mim deixa a pessoa em 0%", mutedForMe),
    rclick("voice-member:500014:1001"),
    expect("silenciada: o visto em Silenciar para mim e 0% no controle", mutedChecked),
    click("menu:Silenciar para mim"),
    expect("de novo: volta a 100%", backToNormal),
    rclick("member:1001"),
    expect("na lista de membros, em call: o volume também", friendVolume),
    esc,
    // Na lista de membros: na de canais, a nossa linha da call fica embaixo da faixa
    // "Voz conectada" e o canal "Jogando" passa da tela.
    rclick("member:1000"),
    expect("no próprio nome: sem volume", selfNoVolume),
    esc,
    rclick("member:1002"),
    expect("quem está em outro canal de voz: sem volume", elsewhereNoVolume),
    esc,
};

/// Depois de sair da call.
pub const depois = [_]Op{
    rclick("voice-member:500014:1001"),
    expect("fora da call de novo: sem volume", friendNoVolume),
    esc,
};
