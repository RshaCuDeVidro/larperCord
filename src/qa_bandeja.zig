//! QA das listas flutuantes (ui/dropdown.zig), do fechar para a bandeja (o ícone
//! fica lá da abertura até sair; na bandeja a janela, o renderizador e as texturas vão
//! embora e voltam ao mostrar), das imagens fora da tela que saem depois de um minuto e
//! do pedido de reinício. Aqui a bandeja é de mentira
//! (`tray.fake`): o ícone de verdade, o menu e o segundo larperCord quem testa é
//! tools/qa_bandeja.py, com processos reais e um painel falso no D-Bus.
//!
//! `QA_SUITE=bandeja` roda isto. As baterias `bandeja-*` terminam com o app
//! saindo no meio do roteiro: quem confere o código de saída e o tempo é
//! tools/qa_bandeja.sh.
const std = @import("std");
const c = @import("c");
const App = @import("app.zig").App;
const R = @import("qa_runner.zig");
const Op = R.Op;
const qa = @import("ui/qa.zig");
const tray = @import("platform/tray.zig");
const platform = @import("platform/window.zig");
const settings_voz = @import("ui/settings_voz.zig");
const voz_audio = @import("net/voz_audio.zig");
const Rect = @import("theme/layout.zig").Rect;
const images = @import("ui/images.zig");
const gw = @import("net/fake_gateway.zig");
const types = @import("core/types.zig");
const an = @import("app_notificacao.zig");
const notif_dbus = @import("platform/notif_dbus.zig");
const Id = types.Id;

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
fn shot(name: []const u8) Op {
    return .{ .shot = name };
}
const esc: Op = .{ .key = .{ .key = c.ImGuiKey_Escape } };

// --- Listas flutuantes -------------------------------------------------------

var page_y: f32 = 0;
var sens_before: u8 = 0;

fn openVoz(app: *App) void {
    app.st.settings.open = true;
    app.st.settings.page = .voz;
}
fn vozPage(_: *App) bool {
    return qa.find("voz-mic") != null and qa.find("voz-vol:10") != null;
}
fn rememberPage(app: *App) void {
    page_y = (qa.find("voz-vol:10") orelse return).y;
    sens_before = app.st.settings.voice_sens;
}
fn micListOpen(_: *App) bool {
    return qa.find("dropdown") != null and qa.find("voz-mic-opt:0") != null;
}
fn outListOpen(_: *App) bool {
    return qa.find("dropdown") != null and qa.find("voz-out-opt:0") != null;
}
fn pageNotPushed(_: *App) bool {
    const vol = qa.find("voz-vol:10") orelse return false;
    return vol.y == page_y and qa.find("dropdown") != null;
}
fn listClosedSettingsOpen(app: *App) bool {
    return qa.find("dropdown") == null and app.st.settings.open;
}
fn clickDidNotPassThrough(app: *App) bool {
    return qa.find("dropdown") == null and app.st.settings.voice_sens == sens_before;
}
fn manyDevices(_: *App) void {
    settings_voz.qaManyDevices(16);
}
fn restoreDevices(app: *App) void {
    settings_voz.qaManyDevices(0);
    app.st.settings.voice_mic = .{};
}

/// A lista toda dentro da janela, com o resto rolando por dentro.
fn listCapped(app: *App) bool {
    const list = qa.find("dropdown") orelse return false;
    const last = qa.find("voz-mic-opt:16") orelse return false;
    return list.bottom() <= app.io.*.DisplaySize.y and list.y >= 0 and list.h >= 60 and last.y > list.bottom();
}
fn listCoversPage(_: *App) bool {
    const list = qa.find("dropdown") orelse return false;
    const vol = qa.find("voz-vol:10") orelse return false;
    return list.contains(vol.x + 8, vol.y + 8) and vol.y == page_y;
}

var last_opt_y: f32 = 0;
fn wheelDown(app: *App) void {
    const list = qa.find("dropdown") orelse return;
    last_opt_y = (qa.find("voz-mic-opt:16") orelse return).y;
    c.ImGuiIO_AddMousePosEvent(app.io, list.x + 30, list.y + 30);
    c.ImGuiIO_AddMouseWheelEvent(app.io, 0, -3);
}
fn listScrolled(_: *App) bool {
    const y = (qa.find("voz-mic-opt:16") orelse return false).y;
    return y < last_opt_y and pageStill();
}
fn pageStill() bool {
    const vol = qa.find("voz-vol:10") orelse return false;
    return vol.y == page_y;
}
fn listFlipped(_: *App) bool {
    const list = qa.find("dropdown") orelse return false;
    const box = qa.find("voz-mic") orelse return false;
    return list.bottom() <= box.y and list.y >= 0;
}
fn picked(app: *App) bool {
    return qa.find("dropdown") == null and std.mem.eql(u8, app.st.settings.voice_mic.slice(), "Microfone de teste 1");
}

var color_y: f32 = 0;
fn openLooks(app: *App) void {
    app.st.settings.open = true;
    app.st.settings.page = .aparencia;
}
fn rememberColors(_: *App) void {
    color_y = (qa.find("theme-color:12") orelse return).y;
}
fn colorEditorOpen(_: *App) bool {
    return qa.find("dropdown") != null and qa.find("theme-color-input") != null and qa.find("button:Aplicar") != null;
}
fn colorGridStill(_: *App) bool {
    const cell = qa.find("theme-color:12") orelse return false;
    return cell.y == color_y;
}
fn colorEditorClosed(app: *App) bool {
    return qa.find("dropdown") == null and qa.find("theme-color-input") == null and app.st.settings.open;
}
fn closeSettings(app: *App) void {
    app.st.settings.open = false;
}

// O perfil de quem pode dar cargos: na demonstração, só virando dono do servidor.
const demo_guild: u64 = 500000;
var owner_before: u64 = 0;
var role_y: f32 = 0;
fn becomeOwner(app: *App) void {
    const g = @constCast(app.store.guild(demo_guild) orelse return);
    owner_before = g.owner;
    g.owner = app.store.me;
}
fn stopBeingOwner(app: *App) void {
    const g = @constCast(app.store.guild(demo_guild) orelse return);
    g.owner = owner_before;
    app.st.popup = .none;
}
fn cardOpen(_: *App) bool {
    return qa.find("role-add") != null;
}
fn rememberRoleButton(_: *App) void {
    role_y = (qa.find("role-add") orelse return).y;
}
fn roleListOpen(_: *App) bool {
    const add = qa.find("role-add") orelse return false;
    return qa.find("dropdown") != null and add.y == role_y;
}
fn roleListClosedCardOpen(app: *App) bool {
    return qa.find("dropdown") == null and app.st.popup != .none;
}

// --- Bandeja -----------------------------------------------------------------

fn pushClose(app: *App) void {
    var e = std.mem.zeroes(c.SDL_Event);
    e.type = c.SDL_EVENT_WINDOW_CLOSE_REQUESTED;
    e.window.windowID = c.SDL_GetWindowID(app.win.window);
    _ = c.SDL_PushEvent(&e);
}
fn trayOk(_: *App) void {
    // QA_TRAY_REAL: o SDL_CreateTray de verdade (com um painel falso no D-Bus).
    tray.fake = if (c.SDL_getenv("QA_TRAY_REAL") != null) null else true;
}
fn trayFails(_: *App) void {
    tray.fake = false;
    // Sem painel não há ícone (o de uma bateria anterior sai).
    tray.hide();
}
fn wakeShow(app: *App) void {
    platform.Window.wake(app.win.wake_type, .show);
}
fn wakeQuit(app: *App) void {
    platform.Window.wake(app.win.wake_type, .quit);
}
fn hiddenFlag(app: *App) bool {
    return app.win.flags() & c.SDL_WINDOW_HIDDEN != 0;
}
pub fn isHidden(app: *App) bool {
    return hiddenFlag(app) and tray.active();
}
/// A rede continua sendo atendida com a janela escondida.
fn keepsWorking(app: *App) bool {
    return hiddenFlag(app) and app.store.ready;
}
fn openAdvanced(app: *App) void {
    app.st.settings.open = true;
    app.st.settings.page = .avancado;
}
/// Opção desligada: a janela nem chega a esconder. Sem sair daqui, porque esta
/// bateria continua; o sair de verdade é da bateria `bandeja-sair`.
fn neverHere(_: *App) bool {
    return false;
}
fn inVoice(app: *App) bool {
    return app.st.voice != null;
}

// --- Fechar para a bandeja: o ícone da abertura até sair -----------------------

const option_on = "toggle:Fechar para a bandeja";
const option_off = "toggle-off:Fechar para a bandeja";

fn optionOnByDefault(app: *App) bool {
    return app.st.settings.close_to_tray;
}
fn noIcon(_: *App) bool {
    return !tray.active();
}
/// Sem painel: a opção aparece apagada, com o motivo embaixo.
fn optionUnavailable(app: *App) bool {
    return qa.find(option_off) != null and qa.find(option_on) == null and qa.find("tray-unavailable") != null and app.st.settings.close_to_tray;
}
fn clickDidNothing(app: *App) bool {
    return app.st.settings.close_to_tray and !tray.active();
}
fn optionAvailable(_: *App) bool {
    return qa.find(option_on) != null and qa.find(option_off) == null and qa.find("tray-unavailable") == null;
}
/// Desligada: nenhum ícone com a janela aberta (no Linux, nenhum processo dele).
fn offNoIcon(app: *App) bool {
    return !app.st.settings.close_to_tray and !tray.active() and !hiddenFlag(app);
}
/// O ícone de pé com a janela aberta: o que a opção promete.
fn iconWithWindowOpen(app: *App) bool {
    return app.st.settings.close_to_tray and tray.active() and !hiddenFlag(app) and !app.in_tray;
}
fn clickIcon(app: *App) void {
    platform.Window.wake(app.win.wake_type, .toggle);
}
fn clickHid(app: *App) bool {
    return app.tray_click == .para_bandeja and hiddenFlag(app) and app.in_tray and tray.active();
}
fn clickShowed(app: *App) bool {
    return app.tray_click == .mostrar and iconWithWindowOpen(app);
}
fn closeToTrayOff(app: *App) void {
    app.st.settings.close_to_tray = false;
}
fn hiddenKeepsIcon(app: *App) bool {
    return hiddenFlag(app) and app.in_tray and tray.active() and app.tray_kept;
}
/// Liga e põe o ícone já, sem esperar a próxima tentativa.
fn iconNow(app: *App) void {
    app.st.settings.close_to_tray = true;
    app.tray_retry_ms = 0;
}
fn demand(app: *App) void {
    app.restart_wanted = true;
}

// --- Na bandeja, a parte da GPU sai e volta ------------------------------------------

const geral: Id = 500005;
const texto = "rascunho que fica na bandeja";

fn openGeral(app: *App) void {
    app.handle(.{ .open_message = .{ .channel = geral, .id = 0 } });
}
fn geralLoaded(app: *App) bool {
    const cs = app.store.channel(geral) orelse return false;
    return app.st.activeChannel() == geral and cs.history == .loaded and qa.find("composer") != null;
}
/// A mensagem de `url` na conversa aberta e a marca do anexo dela.
fn attachment(app: *App, url: []const u8) ?struct { id: Id, i: usize } {
    const cs = app.store.channel(app.st.activeChannel() orelse return null) orelse return null;
    var k = cs.messages.items.len;
    while (k > 0) {
        k -= 1;
        const m = &cs.messages.items[k];
        for (m.msg.attachments, 0..) |a, i| if (std.mem.eql(u8, a.url, url)) return .{ .id = m.msg.id, .i = i };
    }
    return null;
}
fn attMark(app: *App, url: []const u8) ?Rect {
    const f = attachment(app, url) orelse return null;
    var b: [64]u8 = undefined;
    return qa.find(std.fmt.bufPrint(&b, "att:{d}:{d}", .{ f.id, f.i }) catch return null);
}
/// A imagem de `url` no cache (em qualquer tamanho), pronta.
fn imageReady(app: *App, url: []const u8) ?*images.Entry {
    var it = app.images.map.iterator();
    while (it.next()) |e| {
        const k = e.key_ptr.*;
        const at = std.mem.indexOfScalar(u8, k, ' ') orelse continue;
        if (std.mem.eql(u8, k[at + 1 ..], url) and e.value_ptr.state == .ready) return e.value_ptr;
    }
    return null;
}
fn imageCached(app: *App, url: []const u8) bool {
    var it = app.images.map.keyIterator();
    while (it.next()) |k| {
        const at = std.mem.indexOfScalar(u8, k.*, ' ') orelse continue;
        if (std.mem.eql(u8, k.*[at + 1 ..], url)) return true;
    }
    return false;
}
fn sunsetShown(app: *App) bool {
    return attMark(app, "demo:1") != null and imageReady(app, "demo:1") != null;
}
fn typeDraft(app: *App) void {
    @memset(&app.st.input, 0);
    @memcpy(app.st.input[0..texto.len], texto);
    app.st.input_sync = true;
}
fn draftKept(app: *App) bool {
    return std.mem.startsWith(u8, std.mem.sliceTo(&app.st.input, 0), texto) and qa.find("composer") != null;
}
fn clearDraft(app: *App) void {
    @memset(&app.st.input, 0);
    app.st.input_sync = true;
}

/// Os pixels do quadro (antes do present) numa área em pontos, em RGBA.
var crop_buf: [2 * 1024 * 1024]u8 = undefined;
fn readArea(app: *App, r: Rect, out: []u8) ?[]u8 {
    const ren = app.win.renderer orelse return null;
    const k = app.io.*.DisplayFramebufferScale.x;
    const area: c.SDL_Rect = .{ .x = @intFromFloat(r.x * k), .y = @intFromFloat(r.y * k), .w = @intFromFloat(@max(r.w * k, 1)), .h = @intFromFloat(@max(r.h * k, 1)) };
    const surf = c.SDL_RenderReadPixels(ren, &area) orelse return null;
    defer c.SDL_DestroySurface(surf);
    const rgba = c.SDL_ConvertSurface(surf, c.SDL_PIXELFORMAT_RGBA32) orelse return null;
    defer c.SDL_DestroySurface(rgba);
    const row: usize = @intCast(rgba.*.w * 4);
    const h: usize = @intCast(rgba.*.h);
    if (row * h > out.len) return null;
    const src: [*]const u8 = @ptrCast(rgba.*.pixels orelse return null);
    const pitch: usize = @intCast(rgba.*.pitch);
    for (0..h) |y| @memcpy(out[y * row ..][0..row], src[y * pitch ..][0..row]);
    return out[0 .. row * h];
}
/// Cores diferentes numa amostra dos pixels (tela lisa = 1).
fn colors(px: []const u8) usize {
    var seen: [64]u32 = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i + 4 <= px.len and n < seen.len) : (i += 4 * 37) {
        const v = std.mem.readInt(u32, px[i..][0..4], .little);
        if (std.mem.indexOfScalar(u32, seen[0..n], v) == null) {
            seen[n] = v;
            n += 1;
        }
    }
    return n;
}

/// Pedaços da tela que não animam, guardados antes da bandeja e comparados pixel por
/// pixel na volta: o nome de um canal (as letras: o atlas das fontes refeito) e uma
/// pessoa da lista de membros (a foto pequena, que ficou em pixels na bandeja e voltou
/// para a GPU, e o nome).
const Ref = struct {
    mark: []const u8,
    rect: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    px: [96 * 1024]u8 = undefined,
    len: usize = 0,

    fn area(r: *const Ref) ?Rect {
        const m = qa.find(r.mark) orelse return null;
        return .{ .x = m.x, .y = m.y, .w = @min(m.w, 180), .h = @min(m.h, 48) };
    }
    fn remember(r: *Ref, app: *App) void {
        r.len = 0;
        r.rect = r.area() orelse return;
        const px = readArea(app, r.rect, &r.px) orelse return;
        r.len = px.len;
    }
    /// Igual ao guardado, e com desenho (mais de uma cor).
    fn same(r: *const Ref, app: *App) bool {
        if (r.len == 0) return false;
        const now_r = r.area() orelse return false;
        if (now_r.x != r.rect.x or now_r.y != r.rect.y) return false;
        const px = readArea(app, r.rect, &crop_buf) orelse return false;
        return colors(px) >= 3 and std.mem.eql(u8, px, r.px[0..r.len]);
    }
};
var refs = [_]Ref{ .{ .mark = "channel:500005" }, .{ .mark = "member:1001" } };
fn rememberPixels(app: *App) void {
    for (&refs) |*r| r.remember(app);
}

// O mascote do canto parado se repete sem ser refeito (ui/carimbo.zig; no invisível, a
// textura da camada): na volta da bandeja ele aparece igual, e a textura do invisível é
// refeita no renderizador novo (a de antes saiu com o antigo).
const pet = @import("ui/mascote_pet.zig");
var pet_px: [96 * 1024]u8 = undefined;
var pet_len: usize = 0;
var pet_rect: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
var pet_was: struct { life: u8 = 0, away: bool = false, ui: bool = false, status: u8 = 0 } = .{};
/// Por que a última comparação não bateu (o relatório depois do expect).
var pet_why: []const u8 = "";
fn petRect() ?Rect {
    const g = pet.qaDrawn();
    if (g[2] <= 0) return null;
    return .{ .x = g[0] - 0.7 * g[2], .y = g[1] - 0.85 * g[2], .w = 1.4 * g[2], .h = 1.45 * g[2] };
}
/// Parado e de olhos para a frente (o mouse fora; sem foco, a pose de esperar não vale; a
/// DM que chega na bandeja não o leva até o ícone na volta).
fn petQuiet(app: *App) void {
    const set = &app.st.settings;
    pet_was = .{ .life = set.mascot_life, .away = set.mascot_away, .ui = set.mascot_ui, .status = set.my_status };
    set.mascot_life = 0;
    set.mascot_away = false;
    set.mascot_ui = false;
    pet.qaHome();
    c.ImGuiIO_AddMousePosEvent(app.io, -std.math.floatMax(f32), -std.math.floatMax(f32));
}
fn petGhost(app: *App) void {
    app.st.settings.my_status = 3;
}
fn rememberPet(app: *App) void {
    pet_len = 0;
    pet_rect = petRect() orelse return;
    const px = readArea(app, pet_rect, &pet_px) orelse return;
    pet_len = px.len;
}
fn petSame(app: *App) bool {
    pet_why = "nada guardado antes";
    if (pet_len == 0) return false;
    pet_why = "com uma reação ou fora de casa";
    if (pet.reaction() != .none or pet.mode() != .home) return false;
    pet_why = "em outro lugar";
    const r = petRect() orelse return false;
    if (r.x != pet_rect.x or r.y != pet_rect.y or r.w != pet_rect.w or r.h != pet_rect.h) return false;
    pet_why = "sem os pixels";
    const px = readArea(app, r, &crop_buf) orelse return false;
    pet_why = "pixels diferentes";
    if (colors(px) < 3 or !std.mem.eql(u8, px, pet_px[0..pet_len])) return false;
    pet_why = "";
    return true;
}
fn petReport(_: *App) void {
    if (pet_why.len > 0) std.debug.print("       mascote na volta da bandeja: {s}\n", .{pet_why});
}
fn petGhostSame(app: *App) bool {
    if (!petSame(app)) return false;
    pet_why = "a textura do invisível não está no renderizador novo";
    if (!pet.qaGhostTexture(app.win.renderer)) return false;
    pet_why = "";
    return true;
}
fn petDone(app: *App) void {
    const set = &app.st.settings;
    set.mascot_life = pet_was.life;
    set.mascot_away = pet_was.away;
    set.mascot_ui = pet_was.ui;
    set.my_status = pet_was.status;
}

var releases0: u32 = 0;
var restores0: u32 = 0;
var unparked0: u32 = 0;
fn countBefore(app: *App) void {
    releases0 = app.gpu_releases;
    restores0 = app.gpu_restores;
    unparked0 = app.images.unparked;
}

fn windowCount() usize {
    var n: c_int = 0;
    const list = c.SDL_GetWindows(&n);
    if (list != null) c.SDL_free(@ptrCast(list));
    return @intCast(@max(n, 0));
}

/// A única janela que sobra na bandeja: a escondida de 1×1, sem renderizador.
fn onlyAnchor(app: *App) bool {
    const a = app.win.ancora orelse return false;
    var w: c_int = 0;
    var h: c_int = 0;
    _ = c.SDL_GetWindowSize(a, &w, &h);
    return windowCount() == 1 and c.SDL_GetWindowFlags(a) & c.SDL_WINDOW_HIDDEN != 0 and
        c.SDL_GetRenderer(a) == null and w == 1 and h == 1;
}

/// Na bandeja, nada da GPU fica: nem janela, nem renderizador, nem textura de imagem
/// (as pequenas que estavam na tela ficam em pixels), nem o atlas das fontes. Só a
/// janela escondida de 1×1, sem renderizador, para o laço dormir (Window.ancora).
fn gpuGone(app: *App) bool {
    const atlas = app.io.*.Fonts.*.TexData;
    return isHidden(app) and app.in_tray and app.win.window == null and app.win.renderer == null and onlyAnchor(app) and
        app.gpu_releases == releases0 + 1 and app.images.renderer == null and app.images.textureCount() == 0 and
        // O ImGui guarda os pixels do atlas: sem a textura, ele fica pedindo outra (WantCreate).
        app.images.parkedCount() > 0 and atlas.*.TexID == 0 and atlas.*.Status == c.ImTextureStatus_WantCreate;
}

var mem_open: platform.SelfMem = .{};
var rss_open: u32 = 0;
fn rssKb() u32 {
    // Os arquivos do /proc não dizem o tamanho: lidos direto.
    const fd = c.open("/proc/self/status", c.O_RDONLY);
    if (fd < 0) return 0;
    defer _ = c.close(fd);
    var buf: [4096]u8 = undefined;
    const n = c.read(fd, &buf, buf.len);
    if (n <= 0) return 0;
    const s_ = buf[0..@intCast(n)];
    const at = std.mem.indexOf(u8, s_, "VmRSS:") orelse return 0;
    var it = std.mem.tokenizeAny(u8, s_[at + 6 ..], " \t");
    return std.fmt.parseInt(u32, it.next() orelse return 0, 10) catch 0;
}
fn memOpen(_: *App) void {
    mem_open = platform.selfMemKb();
    rss_open = rssKb();
}
fn memTray(app: *App) void {
    const m = platform.selfMemKb();
    const rss = rssKb();
    const rn = std.mem.sliceTo(&platform.active_renderer, 0);
    std.debug.print("       memória (renderizador {s}): aberta PSS {d} KB, RSS {d} KB; na bandeja PSS {d} KB, RSS {d} KB ({d} imagens em pixels, {d} KB)\n", .{ rn, mem_open.pss, rss_open, m.pss, rss, app.images.parkedCount(), app.images.bytes / 1024 });
}

// Uma DM chegando com a janela na bandeja: a notificação sai, pelo notify-send (o de
// mentira, que só anota) e sem sessão D-Bus (um endereço que não existe).
var dir_buf: [512]u8 = undefined;
var ns_buf: [600]u8 = undefined;
var log_buf: [600]u8 = undefined;
var bus_buf: [600]u8 = undefined;
var ns0: u32 = 0;
const dm_texto = "oi com a janela na bandeja";
fn prepNotify(app: *App) void {
    const here = c.SDL_GetCurrentDirectory() orelse return;
    defer c.SDL_free(here);
    const dir = std.fmt.bufPrint(&dir_buf, "{s}/qa-out", .{std.mem.trimEnd(u8, std.mem.span(here), "/")}) catch return;
    const ns = std.fmt.bufPrintSentinel(&ns_buf, "{s}/notify-send-bandeja", .{dir}, 0) catch return;
    const log = std.fmt.bufPrintSentinel(&log_buf, "{s}/notify-send-bandeja.log", .{dir}, 0) catch return;
    const script = "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$(dirname \"$0\")/notify-send-bandeja.log\"\n";
    _ = c.SDL_SaveFile(ns.ptr, script.ptr, script.len);
    _ = c.SDL_SaveFile(log.ptr, "", 0);
    _ = c.chmod(ns.ptr, 0o755);
    an.notify_send = ns;
    an.qa_ligado = true;
    const bus = std.fmt.bufPrintSentinel(&bus_buf, "unix:path={s}/sem-barramento", .{dir}, 0) catch return;
    _ = c.SDL_setenv_unsafe("DBUS_SESSION_BUS_ADDRESS", bus.ptr, 1);
    notif_dbus.tentarDeNovo();
    ns0 = an.medidas.pelo_notify_send;
    _ = app;
}
fn dmArrives(app: *App) void {
    const dm = gw.dmId(1);
    const id = types.makeSnowflake(gw.nowMs(), 0x5b000);
    const content = std.heap.c_allocator.dupe(u8, dm_texto) catch return;
    app.events.push(.{ .message_create = .{ .id = id, .channel = dm, .author = gw.dmRecipient(dm) orelse 1001, .timestamp = @divTrunc(gw.nowMs(), 1000), .content = content } });
    platform.Window.wake(app.win.wake_type, .gateway);
}
fn notifiedInTray(app: *App) bool {
    var size: usize = 0;
    const data = c.SDL_LoadFile(std.mem.sliceTo(&log_buf, 0).ptr, &size) orelse return false;
    defer c.SDL_free(data);
    const log = @as([*]const u8, @ptrCast(data))[0..size];
    return an.medidas.pelo_notify_send == ns0 + 1 and std.mem.indexOf(u8, log, dm_texto) != null and app.win.window == null;
}
fn endNotify(_: *App) void {
    an.notify_send = "notify-send";
    an.qa_ligado = false;
    _ = c.SDL_unsetenv_unsafe("DBUS_SESSION_BUS_ADDRESS");
}

/// De volta: janela, renderizador e o atlas das fontes de pé, o quadro desenhado (com
/// cores, e o nome do canal igualzinho ao de antes), a imagem de volta e os avatares
/// guardados em pixels de volta na GPU sem baixar de novo.
fn gpuBack(app: *App) bool {
    if (app.win.window == null or app.win.renderer == null or app.in_tray or hiddenFlag(app)) return false;
    // A janela escondida da bandeja sai junto: fica uma janela só.
    if (app.win.ancora != null or windowCount() != 1) return false;
    if (app.gpu_restores != restores0 + 1 or app.images.renderer != app.win.renderer) return false;
    const atlas = app.io.*.Fonts.*.TexData;
    if (atlas.*.Status != c.ImTextureStatus_OK or atlas.*.TexID == 0) return false;
    return true;
}
fn drawsAgain(app: *App) bool {
    const vp = c.ImGui_GetMainViewport();
    const full = readArea(app, .{ .x = 0, .y = 0, .w = vp.*.Size.x, .h = @min(vp.*.Size.y, 100) }, &crop_buf) orelse return false;
    if (colors(full) < 8) return false;
    for (&refs) |*r| if (!r.same(app)) return false;
    return true;
}
fn imagesBack(app: *App) bool {
    return sunsetShown(app) and app.images.unparked > unparked0 and app.images.textureCount() > 0;
}

// --- Imagens fora da tela: depois de um minuto sem aparecer, saem ---------------------

var textures0: usize = 0;
fn jumpTo(app: *App, url: []const u8) void {
    const f = attachment(app, url) orelse return;
    app.st.jump = f.id;
}
/// Bem para cima na conversa: as imagens da demonstração (as últimas 25 mensagens) saem da tela.
fn jumpOld(app: *App) void {
    const cs = app.store.channel(app.st.activeChannel() orelse return) orelse return;
    const n = cs.messages.items.len;
    if (n > 60) app.st.jump = cs.messages.items[n - 60].msg.id;
}
fn jumpSunset(app: *App) void {
    jumpTo(app, "demo:1");
}
fn jumpGif(app: *App) void {
    jumpTo(app, "demo:gif");
}
/// O GIF da conversa na tela, tocando (mais de um quadro, cada um uma textura).
fn gifShown(app: *App) bool {
    const e = imageReady(app, "demo:gif") orelse return false;
    return attMark(app, "demo:gif") != null and (e.frames.len > 1 or e.stream != null) and imageCached(app, "demo:1");
}
/// O pôr do sol, o GIF e a aurora fora da tela (o pôr do sol e o GIF ainda no cache).
fn sunsetOffscreen(app: *App) bool {
    const ok = attMark(app, "demo:1") == null and attMark(app, "demo:gif") == null and attMark(app, "demo:3") == null and
        imageCached(app, "demo:1") and imageCached(app, "demo:gif");
    if (ok) textures0 = app.images.textureCount();
    return ok;
}
fn skewMinute(_: *App) void {
    images.qa_skew_ms = images.idle_ms + 1_000;
}
fn skewBack(app: *App) void {
    images.qa_skew_ms = 0;
    // A varredura do cache marcou a hora adiantada: volta a valer já.
    app.images.evicted_ms = 0;
}
/// Um minuto (no relógio das imagens) depois: a textura do pôr do sol e os quadros do GIF
/// saíram, e o que ficou pronto no cache é só o que está na tela (os avatares de agora).
fn sunsetEvicted(app: *App) bool {
    if (imageCached(app, "demo:1") or imageCached(app, "demo:gif") or app.images.textureCount() >= textures0) return false;
    var on_screen: usize = 0;
    var it = app.images.map.valueIterator();
    while (it.next()) |e| if (e.state == .ready) {
        if (app.images.drawn_ms - e.used_ms > 1000) return false;
        on_screen += 1;
    };
    return on_screen > 0;
}

pub const ops = [_]Op{
    s("listas flutuantes: dispositivos de voz"),
    run(openVoz),
    expect("página de voz aberta", vozPage),
    // A página entra com um leve zoom, e o robô rola até o que vai clicar (na
    // bateria geral ela pode estar rolada): mede depois de assentar e de rolar.
    .{ .wait = 500 },
    click("voz-mic"),
    esc,
    .{ .wait = 200 },
    run(rememberPage),
    click("voz-mic"),
    expect("o microfone abre a lista", micListOpen),
    expect("a lista não empurra a página", pageNotPushed),
    shot("dropdown-voz"),
    esc,
    expect("Esc fecha a lista e não as configurações", listClosedSettingsOpen),
    click("voz-out"),
    expect("a saída abre a lista", outListOpen),
    click("voz-sens"),
    expect("clicar fora fecha sem clicar no que está embaixo", clickDidNotPassThrough),

    s("listas flutuantes: perto da borda"),
    run(manyDevices),
    click("voz-mic"),
    expect("muitos dispositivos: a altura fica limitada e cabe na janela", listCapped),
    expect("a lista fica por cima da página", listCoversPage),
    shot("dropdown-rola"),
    run(wheelDown),
    expect("a rodinha rola a lista e a página fica parada", listScrolled),
    esc,
    expect("Esc fecha a lista rolada", listClosedSettingsOpen),
    .{ .resize = .{ 900, 260 } },
    // Em máquina sem GPU a janela nova só aparece alguns quadros depois.
    .{ .wait = 800 },
    click("voz-mic"),
    expect("sem espaço embaixo, abre para cima", listFlipped),
    shot("dropdown-cima"),
    click("voz-mic-opt:1"),
    expect("escolher guarda o nome e fecha", picked),
    run(restoreDevices),
    .{ .resize = .{ 1280, 800 } },

    s("listas flutuantes: cor do tema"),
    run(openLooks),
    // Alta o bastante para a página de Aparência inteira caber sem rolar.
    .{ .resize = .{ 1280, 3000 } },
    .{ .wait = 500 },
    run(rememberColors),
    click("theme-color:2"),
    expect("clicar numa cor abre o editor", colorEditorOpen),
    expect("e a grade de cores fica onde estava", colorGridStill),
    shot("dropdown-cor"),
    esc,
    expect("Esc fecha o editor", colorEditorClosed),
    .{ .resize = .{ 1280, 800 } },
    run(closeSettings),

    s("listas flutuantes: dar cargo"),
    run(becomeOwner),
    click("guild:500000"),
    click("member:1002"),
    .{ .expect = .{ .name = "o cartão tem o botão de dar cargo", .check = cardOpen, .timeout_ms = 3000 } },
    .{ .wait = 300 },
    run(rememberRoleButton),
    click("role-add"),
    expect("os cargos abrem por cima, sem mudar o cartão", roleListOpen),
    shot("dropdown-cargo"),
    esc,
    expect("Esc fecha a lista e não o cartão", roleListClosedCardOpen),
    run(stopBeingOwner),

    s("fechar para a bandeja: a opção"),
    expect("ligado por padrão", optionOnByDefault),
    run(trayFails),
    run(openAdvanced),
    expect("sem painel: a opção aparece indisponível, com o motivo", optionUnavailable),
    expect("e nenhum ícone", noIcon),
    shot("bandeja-indisponivel"),
    click(option_off),
    .{ .wait = 200 },
    expect("indisponível, o clique não muda nada", clickDidNothing),
    run(trayOk),
    expect("com painel, a opção fica disponível", optionAvailable),
    click(option_on),
    expect("o interruptor desliga a opção e tira o ícone", offNoIcon),
    click(option_on),
    expect("ligar põe o ícone com a janela aberta", iconWithWindowOpen),
    shot("bandeja-ligada"),
    run(closeSettings),

    s("fechar para a bandeja: clique no ícone"),
    run(clickIcon),
    expect("aberta: o clique esconde na bandeja", clickHid),
    .{ .wait = 300 },
    expect("escondida, continua de pé e conectada", keepsWorking),
    run(clickIcon),
    expect("escondida: o clique traz a janela e o ícone fica", clickShowed),
    .{ .wait = 300 },

    s("fechar para a bandeja: fechar, Abrir e um segundo larperCord"),
    run(pushClose),
    expect("fechar esconde a janela e o mesmo ícone fica", hiddenKeepsIcon),
    .{ .wait = 300 },
    expect("escondida, continua de pé e conectada", keepsWorking),
    run(wakeShow),
    expect("Abrir volta a janela e o ícone fica", iconWithWindowOpen),
    run(wakeShow),
    expect("Abrir (ou um segundo larperCord) com a janela aberta: nada muda", iconWithWindowOpen),
    run(closeToTrayOff),
    expect("desligar tira o ícone com a janela aberta", offNoIcon),
    run(iconNow),
    expect("e ligar de novo põe o ícone", iconWithWindowOpen),

    s("na bandeja: a janela, o renderizador e as texturas saem e voltam"),
    run(openGeral),
    .{ .expect = .{ .name = "a conversa aberta, com a caixa de texto", .check = geralLoaded, .timeout_ms = 4000 } },
    run(jumpSunset),
    .{ .expect = .{ .name = "o pôr do sol na tela", .check = sunsetShown, .timeout_ms = 4000 } },
    run(typeDraft),
    .{ .wait = 600 },
    expect("um rascunho na caixa", draftKept),
    run(rememberPixels),
    run(petQuiet),
    .{ .wait = 800 },
    run(rememberPet),
    run(memOpen),
    run(countBefore),
    run(pushClose),
    expect("fechar: sem janela (só a escondida de 1×1, sem renderizador), sem renderizador, sem textura (os avatares ficam em pixels) e sem o atlas na GPU", gpuGone),
    // O tique de 2 s devolve ao sistema o que saiu.
    .{ .wait = 2500 },
    run(memTray),
    run(prepNotify),
    run(dmArrives),
    .{ .expect = .{ .name = "uma DM na bandeja ainda sai como notificação, sem a janela voltar", .check = notifiedInTray, .timeout_ms = 5000 } },
    run(endNotify),
    run(wakeShow),
    expect("Abrir: a janela e o renderizador voltam, com o atlas das fontes", gpuBack),
    expect("e desenha: tela com cores; o nome do canal e uma pessoa da lista (foto e nome) iguais aos de antes, pixel por pixel", drawsAgain),
    expect("o mascote do canto parado volta igual, pixel por pixel", petSame),
    run(petReport),
    .{ .expect = .{ .name = "a imagem volta, e os avatares voltam para a GPU sem baixar de novo", .check = imagesBack, .timeout_ms = 4000 } },
    expect("o rascunho continua na caixa", draftKept),
    shot("bandeja-volta-1"),
    run(petGhost),
    .{ .wait = 500 },
    run(rememberPet),
    run(countBefore),
    run(pushClose),
    expect("de novo para a bandeja: tudo sai outra vez", gpuGone),
    .{ .wait = 300 },
    run(clickIcon),
    expect("o clique no ícone traz de volta", gpuBack),
    expect("e desenha igual", drawsAgain),
    expect("o mascote invisível volta igual, com a textura da camada refeita no renderizador novo", petGhostSame),
    run(petReport),
    run(petDone),
    .{ .expect = .{ .name = "com a imagem", .check = imagesBack, .timeout_ms = 4000 } },
    expect("e o rascunho", draftKept),
    shot("bandeja-volta-2"),
    run(clearDraft),

    s("imagens fora da tela saem depois de um minuto sem aparecer"),
    run(jumpGif),
    // (Os 24 quadros do GIF da demonstração são gerados na hora: em debug leva uns segundos.)
    .{ .expect = .{ .name = "o GIF da conversa na tela, tocando", .check = gifShown, .timeout_ms = 30000 } },
    run(jumpOld),
    .{ .expect = .{ .name = "rolou para cima: o pôr do sol e o GIF fora da tela, ainda no cache", .check = sunsetOffscreen, .timeout_ms = 4000 } },
    run(skewMinute),
    .{ .expect = .{ .name = "um minuto depois, a textura do pôr do sol e os quadros do GIF saem; o que está na tela fica", .check = sunsetEvicted, .timeout_ms = 3000 } },
    run(skewBack),
    run(jumpSunset),
    .{ .expect = .{ .name = "rolou de volta: o pôr do sol é desenhado de novo", .check = sunsetShown, .timeout_ms = 4000 } },
    run(trayFails),
};

// As baterias abaixo terminam com o app saindo: `never` só é alcançado se ele
// não saiu, e aí vira falha.
const never: Op = .{ .expect = .{ .name = "o app devia ter saído antes daqui", .check = neverHere, .timeout_ms = 500 } };

/// Sem bandeja: fechar sai de verdade, com a voz ligada.
pub const ops_no_tray = [_]Op{
    click("channel:500014"),
    .{ .expect = .{ .name = "na call", .check = inVoice, .timeout_ms = 4000 } },
    run(trayFails),
    run(pushClose),
    .{ .wait = 4000 },
    never,
};

/// Sair pelo menu da bandeja, com a janela escondida e a voz ligada.
pub const ops_quit = [_]Op{
    click("channel:500014"),
    .{ .expect = .{ .name = "na call", .check = inVoice, .timeout_ms = 4000 } },
    run(trayOk),
    run(pushClose),
    expect("escondida", isHidden),
    run(wakeQuit),
    .{ .wait = 4000 },
    never,
};

/// Com painel e a opção desligada: nenhum ícone, e fechar sai de verdade, com a
/// voz ligada (o comportamento de antes da bandeja ligada por padrão).
pub const ops_off = [_]Op{
    click("channel:500014"),
    .{ .expect = .{ .name = "na call", .check = inVoice, .timeout_ms = 4000 } },
    run(trayOk),
    run(closeToTrayOff),
    .{ .wait = 300 },
    expect("desligada: nenhum ícone com a janela aberta", offNoIcon),
    run(pushClose),
    .{ .wait = 4000 },
    never,
};

/// Sair pelo menu da bandeja com a janela aberta (o ícone fica lá desde a abertura)
/// e a voz ligada: o que antes pedia fechar a janela primeiro.
pub const ops_quit_open = [_]Op{
    click("channel:500014"),
    .{ .expect = .{ .name = "na call", .check = inVoice, .timeout_ms = 4000 } },
    run(trayOk),
    run(iconNow),
    expect("o ícone está lá com a janela aberta", iconWithWindowOpen),
    run(wakeQuit),
    .{ .wait = 4000 },
    never,
};

/// Pedido de reinício com a bandeja disponível: para o laço sem esconder.
pub const ops_restart = [_]Op{
    run(trayOk),
    run(demand),
    .{ .wait = 4000 },
    never,
};
