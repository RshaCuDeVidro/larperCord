//! QA do volume de cada pessoa no menu do botão direito (QA_SUITE=voice, junto com
//! o mixer): só aparece para os outros da call em que estamos, arrastar muda o
//! mesmo valor do mixer sem fechar o menu, e "Silenciar para mim" (no menu e no
//! mixer) corta o som sem mexer no volume guardado: tirar o silêncio volta para ele,
//! e voltar à call com ela silenciada já entra sem o som dela.
//! Na demonstração, a call da madrugada (500014) tem 1001, 1005 e 1003; o 1002
//! está no canal "Jogando" (500015).
const std = @import("std");
const c = @import("c");
const App = @import("app.zig").App;
const R = @import("qa_runner.zig");
const Op = R.Op;
const qa = @import("ui/qa.zig");
const popup = @import("ui/popup.zig");
const gw = @import("net/fake_gateway.zig");
const kdl = @import("theme/kdl.zig");
const Volumes = @import("core/volumes.zig").Volumes;
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
fn run(f: *const fn (*App) void) Op {
    return .{ .run = f };
}
fn shot(name: []const u8) Op {
    return .{ .shot = name };
}
const esc: Op = .{ .key = .{ .key = c.ImGuiKey_Escape } };
/// Um ponto do controle de volume do menu (frações da área de arrastar).
fn slider(fx: f32) R.Target {
    return .{ .at = .{ .key = "menu-volume:1001", .fx = fx, .fy = 0.5 } };
}

/// O volume guardado (o do controle), silenciada ou não.
fn volume(app: *App) f32 {
    return app.st.volumes.volume(friend);
}
fn muted(app: *App) bool {
    return app.st.volumes.isMuted(friend);
}
/// O volume que silenciar e tirar o silêncio não podem mudar: 57%, depois o do último
/// arraste.
var kept: f32 = 1.0;
fn keep(app: *App) void {
    kept = volume(app);
}
/// 57%, um nível que não é o normal nem um extremo (o controle anda de 1 em 1%).
fn to57(app: *App) void {
    app.handle(.{ .set_voice_volume = .{ .user = friend, .volume = 0.57 } });
    kept = 0.57;
}
/// Esquece o último ganho mandado, para ver o que a volta à call manda.
fn forgetGain(_: *App) void {
    gw.sent.gain_user.store(0, .release);
    gw.sent.gain_milli.store(0, .release);
}
fn isKept(app: *App) bool {
    return @abs(volume(app) - kept) < 0.0001;
}
/// O último ganho que foi para o motor de voz (a demonstração guarda) é `g`.
fn engineGain(g: f32) bool {
    return gw.sent.gain_user.load(.acquire) == friend and gw.sent.gain_milli.load(.acquire) == @as(u64, @intFromFloat(@round(g * 1000)));
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
/// O número ao lado do controle (`prefix`: o do menu ou o do mixer) é o volume guardado.
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
    return friendVolume(app) and volume(app) == 1.0 and !muted(app) and qa.find("menu-on:Silenciar para mim") == null;
}
fn draggedOutside(app: *App) bool {
    return userMenu(app, friend) and volume(app) == 2.0 and shows(app, "menu-volume-pct") and engineGain(2.0);
}
fn draggedDown(app: *App) bool {
    const v = volume(app);
    return userMenu(app, friend) and v > 0.4 and v < 0.75 and shows(app, "menu-volume-pct") and engineGain(v);
}
fn menuAt57(app: *App) bool {
    return userMenu(app, friend) and !muted(app) and isKept(app) and qa.find("menu-volume-pct:1001:57") != null and engineGain(0.57);
}
fn closed(app: *App) bool {
    return app.st.popup == .none;
}
fn mixerSame(app: *App) bool {
    return app.st.popup == .mixer and isKept(app) and qa.find("voice-volume-pct:1001:57") != null and qa.find("voice-muted:1001") == null;
}
fn mixerMuted(app: *App) bool {
    return app.st.popup == .mixer and muted(app) and isKept(app) and qa.find("voice-volume-pct:1001:57") != null and qa.find("voice-muted:1001") != null and engineGain(0);
}
fn mixerUnmuted(app: *App) bool {
    return app.st.popup == .mixer and !muted(app) and isKept(app) and qa.find("voice-volume-pct:1001:57") != null and qa.find("voice-muted:1001") == null and engineGain(0.57);
}
fn mutedKept(app: *App) bool {
    return app.st.popup == .none and muted(app) and isKept(app) and engineGain(0);
}
fn mutedChecked(app: *App) bool {
    return userMenu(app, friend) and muted(app) and qa.find("menu-on:Silenciar para mim") != null and shows(app, "menu-volume-pct");
}
/// Escreve como no settings.kdl e lê de volta pelas mesmas funções do app (o QA não
/// grava o arquivo de verdade).
fn persists(app: *App) bool {
    const gpa = std.heap.c_allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    app.st.volumes.write(&out, gpa) catch return false;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const nodes = kdl.parse(arena.allocator(), out.items, null) catch return false;
    var back: Volumes = .{};
    defer back.deinit(gpa);
    for (nodes) |*n| _ = back.applyNode(gpa, n);
    return back.isMuted(friend) and back.gain(friend) == 0 and @abs(back.volume(friend) - kept) < 0.001;
}
fn unmutedMenu(app: *App) bool {
    return userMenu(app, friend) and !muted(app) and isKept(app) and qa.find("menu-on:Silenciar para mim") == null and shows(app, "menu-volume-pct");
}
fn draggedWhileMuted(app: *App) bool {
    return userMenu(app, friend) and muted(app) and volume(app) > 1.3 and volume(app) < 1.8 and shows(app, "menu-volume-pct") and engineGain(0);
}
fn unmutedKept(app: *App) bool {
    return app.st.popup == .none and !muted(app) and isKept(app) and engineGain(kept);
}
fn rejoinedMuted(app: *App) bool {
    return app.st.voice == 500014 and muted(app) and isKept(app) and engineGain(0);
}
fn outOfCall(app: *App) bool {
    return app.st.voice == null;
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
    expect("arrastar para a esquerda baixa o volume dela (o número e o motor de voz acompanham)", draggedDown),
    run(to57),
    expect("em 57%: o número do menu e o motor de voz", menuAt57),
    shot("voz-menu-volume"),
    esc,
    expect("Esc fecha o menu", closed),
    click("voice-mixer"),
    expect("o mixer mostra os mesmos 57% do menu", mixerSame),
    click("voice-mute:1001"),
    expect("silenciar no mixer: sem som, e continua em 57%", mixerMuted),
    click("voice-mute:1001"),
    expect("tirar o silêncio no mixer volta para 57%", mixerUnmuted),
    click("voice-mixer-close"),
    expect("fechar o mixer", closed),
    rclick("voice-member:500014:1001"),
    click("menu:Silenciar para mim"),
    expect("Silenciar para mim: sem som, e os 57% ficam guardados", mutedKept),
    rclick("voice-member:500014:1001"),
    expect("silenciada: o visto em Silenciar para mim, e o controle mostra 57%", mutedChecked),
    expect("o volume e o silêncio vão e voltam pelo settings.kdl", persists),
    shot("voz-menu-volume-mudo"),
    click("menu:Silenciar para mim"),
    expect("tirar o silêncio pelo menu volta para 57%", unmutedKept),
    rclick("voice-member:500014:1001"),
    expect("sem o visto, e o controle em 57%", unmutedMenu),
    click("menu:Silenciar para mim"),
    expect("silenciar de novo", mutedKept),
    rclick("voice-member:500014:1001"),
    .{ .drag = .{ .from = slider(0.75), .to = slider(0.76) } },
    expect("mexer no volume silenciada muda o volume, mas continua sem som", draggedWhileMuted),
    run(keep),
    click("menu:Silenciar para mim"),
    expect("tirar o silêncio pelo menu volta para o volume guardado", unmutedKept),
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
    // Desliga com ela silenciada: a volta à call (depois) já entra sem o som dela.
    rclick("voice-member:500014:1001"),
    click("menu:Silenciar para mim"),
    expect("silenciar antes de desligar", mutedKept),
};

/// Depois de sair da call.
pub const depois = [_]Op{
    rclick("voice-member:500014:1001"),
    expect("fora da call de novo: sem volume", friendNoVolume),
    esc,
    run(forgetGain),
    click("channel:500014"),
    expect("de volta à call: o motor de voz já recebe zero dela, e o volume guardado fica", rejoinedMuted),
    rclick("voice-member:500014:1001"),
    expect("o visto continua em Silenciar para mim", mutedChecked),
    click("menu:Silenciar para mim"),
    expect("tirar o silêncio volta para o volume guardado", unmutedKept),
    click("hangup"),
    expect("sair da call de novo", outOfCall),
};

// --- Tirar ruído e igualar volume, por pessoa no mixer --------------------------

fn dspSent(user: Id, bits: u64) bool {
    return gw.sent.dsp_user.load(.acquire) == user and gw.sent.dsp_bits.load(.acquire) == bits;
}
fn dspOffByDefault(app: *App) bool {
    return qa.find("voice-denoise:1001") != null and qa.find("voice-level:1001") != null and
        qa.find("voice-denoise-on:1001") == null and qa.find("voice-level-on:1001") == null and
        !app.st.volumes.denoiseOn(1001) and !app.st.volumes.levelOn(1001);
}
fn denoiseOnly(app: *App) bool {
    return app.st.volumes.denoiseOn(1001) and !app.st.volumes.levelOn(1001) and qa.find("voice-denoise-on:1001") != null and dspSent(1001, 1);
}
fn bothOn(app: *App) bool {
    return app.st.volumes.denoiseOn(1001) and app.st.volumes.levelOn(1001) and qa.find("voice-level-on:1001") != null and dspSent(1001, 3);
}
fn levelOnly(app: *App) bool {
    return !app.st.volumes.denoiseOn(1001) and app.st.volumes.levelOn(1001) and qa.find("voice-denoise-on:1001") == null and dspSent(1001, 2);
}
fn dspAllOff(app: *App) bool {
    return !app.st.volumes.denoiseOn(1001) and !app.st.volumes.levelOn(1001) and dspSent(1001, 0);
}
/// Só a pessoa escolhida: as outras continuam sem nada.
fn othersUntouched(app: *App) bool {
    var it = app.st.volumes.denoise.keyIterator();
    while (it.next()) |u| if (u.* != 1001) return false;
    var lt = app.st.volumes.leveled.keyIterator();
    while (lt.next()) |u| if (u.* != 1001) return false;
    return true;
}

/// Com o mixer aberto na call.
pub const dsp = [_]Op{
    expect("no mixer, \"Tirar ruído\" e \"Igualar volume\" começam desligados", dspOffByDefault),
    click("voice-denoise:1001"),
    expect("tirar ruído só desta pessoa: liga e vai para a voz", denoiseOnly),
    click("voice-level:1001"),
    expect("igualar volume também, sem desligar o outro", bothOn),
    expect("as outras pessoas continuam sem nada", othersUntouched),
    .{ .shot = "voz-mixer-ruido" },
    click("voice-denoise:1001"),
    expect("desligar o tirar ruído deixa o igualar volume", levelOnly),
    click("voice-level:1001"),
    expect("desligados os dois, a voz recebe que não há nada", dspAllOff),
};
