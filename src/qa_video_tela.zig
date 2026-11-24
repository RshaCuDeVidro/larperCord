//! QA do vídeo em tela cheia (QA_SUITE=video-tela): o botão da barra põe a janela em
//! tela cheia do sistema com o vídeo cobrindo tudo em faixas pretas, sem recomeçar nem
//! abrir outro, e decodifica no tamanho da tela (até 1080p, com a memória do anel
//! conferida); tocando com o mouse parado os controles somem com o cursor e voltam com
//! ele; o teclado (espaço, ← →, ↑ ↓, M); Esc volta a janela como estava e a decodificação
//! ao tamanho da conversa; com F11 antes, ela continua em tela cheia; dois cliques, F e
//! F11; sair da tela cheia por fora; "reduzir movimento" sem esmaecer; e a bandeja sai da
//! tela cheia antes de esconder. O vídeo da demonstração (`demo:video`, 3 s) está em toda
//! conversa. Sem FFmpeg (a CI), o play só avisa e não aparece botão nenhum.
//!
//! Para medir com um vídeo maior: LARPER_DEMO_VIDEO=/caminho/1080p.mp4 (3 s, como o da
//! demonstração), com QA_DEBUG=1 para os números; QA_VIDEO_ESCALA=2 põe a interface em
//! outra escala. (A tela do driver sem janela tem 1024×768 pixels: ali a saída de um
//! vídeo 1080p para em 1024×576, e o teto de 1920×1080 só aparece numa tela maior.)
const std = @import("std");
const c = @import("c");
const App = @import("app.zig").App;
const R = @import("qa_runner.zig");
const Op = R.Op;
const qa = @import("ui/qa.zig");
const video = @import("ui/video.zig");
const ffmpeg = @import("platform/ffmpeg.zig");
const types = @import("core/types.zig");

fn s(name: []const u8) Op {
    return .{ .section = name };
}
fn click(k: []const u8) Op {
    return .{ .click = .{ .mark = k } };
}
fn dyn(f: *const fn (*App, []u8) []const u8) Op {
    return .{ .click = .{ .dyn = f } };
}
fn expect(name: []const u8, f: *const fn (*App) bool) Op {
    return .{ .expect = .{ .name = name, .check = f, .timeout_ms = 4000 } };
}
fn run(f: *const fn (*App) void) Op {
    return .{ .run = f };
}
fn key(k: c_int) Op {
    return .{ .key = .{ .key = k } };
}

fn hasFfmpeg() bool {
    return ffmpeg.known() == true;
}
fn debug() bool {
    return c.SDL_getenv("QA_DEBUG") != null;
}

// --- O vídeo da demonstração ------------------------------------------------------

fn findVideo(app: *App) ?struct { id: types.Id, i: usize } {
    const ch = app.st.activeChannel() orelse return null;
    const cs = app.store.channel(ch) orelse return null;
    var k = cs.messages.items.len;
    while (k > 0) {
        k -= 1;
        const m = &cs.messages.items[k];
        for (m.msg.attachments, 0..) |a, i| if (a.video and std.mem.eql(u8, a.link, video.demo_link)) return .{ .id = m.msg.id, .i = i };
    }
    return null;
}
fn jumpToVideo(app: *App) void {
    const f = findVideo(app) orelse return;
    app.st.jump = f.id;
}
fn tDemoVideo(app: *App, b: []u8) []const u8 {
    const f = findVideo(app) orelse return "";
    return std.fmt.bufPrint(b, "att:{d}:{d}", .{ f.id, f.i }) catch "";
}
/// Uma marca do player, só com ele aberto (sem FFmpeg o passo não se aplica).
fn tMark(b: []u8, name: []const u8) []const u8 {
    if (!video.info().active) return "";
    return std.fmt.bufPrint(b, "{s}", .{name}) catch "";
}
fn tFullBtn(_: *App, b: []u8) []const u8 {
    return tMark(b, "video-fullscreen");
}
fn tVideo(_: *App, b: []u8) []const u8 {
    return tMark(b, "video");
}
/// A imagem na tela cheia (só com ela aberta).
fn tPicture(_: *App, b: []u8) []const u8 {
    if (!video.info().full) return "";
    return tMark(b, "video-picture");
}
fn tPlay(_: *App, b: []u8) []const u8 {
    return tMark(b, "video-play");
}
/// O play só se estiver pausado (o vídeo de 3 s pode ter acabado no caminho).
fn tPlayIfPaused(_: *App, b: []u8) []const u8 {
    if (video.info().playing) return "";
    return tMark(b, "video-play");
}

// --- A janela -----------------------------------------------------------------------

fn windowFull(app: *App) bool {
    _ = c.SDL_SyncWindow(app.win.window);
    return app.win.flags() & c.SDL_WINDOW_FULLSCREEN != 0;
}
fn windowMaximized(app: *App) bool {
    _ = c.SDL_SyncWindow(app.win.window);
    return app.win.flags() & c.SDL_WINDOW_MAXIMIZED != 0;
}
fn windowHidden(app: *App) bool {
    return app.win.flags() & c.SDL_WINDOW_HIDDEN != 0;
}

// --- Estado guardado entre os passos -----------------------------------------------

var starts0: u32 = 0;
var pos0: f64 = 0;
var playing0 = false;
var inline_box: [2]u32 = .{ 0, 0 };
var inline_out: [2]u32 = .{ 0, 0 };
var maximize_works = false;

fn prepare(app: *App) void {
    // 2 s é muito para um vídeo de 3 s: os controles somem antes de ele acabar.
    video.hide_ms = 600;
    app.st.settings.video_volume = 50;
    app.st.settings.reduce_motion = false;
    if (c.SDL_getenv("QA_VIDEO_ESCALA")) |e| app.st.settings.ui_scale = std.fmt.parseFloat(f32, std.mem.span(e)) catch 1;
}
fn restoreHide(_: *App) void {
    video.hide_ms = 2000;
}

fn playing(app: *App) bool {
    // O aviso sai no idioma da interface (a bateria roda também em japonês).
    const aviso = @import("ui/i18n.zig").tr("vídeo de demonstração (sem FFmpeg)", "demo video (no FFmpeg)");
    if (!hasFfmpeg()) return !video.info().active and std.mem.indexOf(u8, app.st.toast.text(), aviso) != null;
    const v = video.info();
    return v.active and v.playing and v.shown >= 3 and qa.find("video") != null;
}
/// Sem FFmpeg não há player, então nem barra, nem botão (o play caiu no aviso).
fn noButtonWithoutFfmpeg(_: *App) bool {
    if (hasFfmpeg()) return true;
    return qa.find("video-fullscreen") == null and !video.info().full;
}
fn buttonShown(_: *App) bool {
    return !hasFfmpeg() or (qa.find("video-fullscreen") != null and !video.info().full);
}
fn rememberInline(_: *App) void {
    const v = video.info();
    starts0 = v.starts;
    pos0 = v.pos_ms;
    playing0 = v.playing;
    inline_box = .{ v.box_w, v.box_h };
    inline_out = .{ v.w, v.h };
    if (debug()) std.debug.print("[tela cheia] na conversa: teto {d}x{d}, saída {d}x{d}, vídeo {d}x{d}, anel {d} KB\n", .{ v.box_w, v.box_h, v.w, v.h, v.src_w, v.src_h, v.ring_bytes / 1024 });
}
fn rememberPos(_: *App) void {
    const v = video.info();
    pos0 = v.pos_ms;
    playing0 = v.playing;
    starts0 = v.starts;
}

/// A tela cheia aberta, a janela em tela cheia do sistema, e o vídeo cobrindo a janela
/// em faixas pretas: a imagem no meio, na proporção do vídeo, encostando nos lados ou
/// em cima e embaixo.
fn fullCovers(app: *App) bool {
    if (!hasFfmpeg()) return true;
    const v = video.info();
    if (!v.full or !v.window_full or !windowFull(app)) return false;
    const ds = app.io.*.DisplaySize;
    const r = qa.find("video-full") orelse return false;
    if (@abs(r.x) > 0.5 or @abs(r.y) > 0.5 or @abs(r.w - ds.x) > 0.5 or @abs(r.h - ds.y) > 0.5) return false;
    const p = v.pic;
    if (p.w < 1 or p.h < 1 or v.src_w == 0) return false;
    const want: f32 = @as(f32, @floatFromInt(v.src_w)) / @as(f32, @floatFromInt(v.src_h));
    const fills = @abs(p.w - r.w) < 1 or @abs(p.h - r.h) < 1;
    const centered = @abs(p.x + p.w / 2 - r.w / 2) < 1 and @abs(p.y + p.h / 2 - r.h / 2) < 1;
    if (debug()) std.debug.print("[tela cheia] janela {d:.0}x{d:.0}, imagem {d:.0}x{d:.0} em {d:.0},{d:.0}\n", .{ r.w, r.h, p.w, p.h, p.x, p.y });
    return fills and centered and @abs(p.w / p.h - want) < want * 0.01;
}
/// Mesmo vídeo (nenhum aberto de novo), do ponto onde estava, tocando como estava.
fn seamless(_: *App) bool {
    if (!hasFfmpeg()) return true;
    const v = video.info();
    return v.active and v.starts == starts0 and v.pos_ms + 1 >= pos0 and (v.playing == playing0 or v.ended);
}
/// Decodifica no tamanho da tela em pixels (até 1920×1080), sem passar do vídeo; a
/// textura acompanha e o anel fica dentro do teto de 3 quadros de 1080p.
fn fullRes(app: *App) bool {
    if (!hasFfmpeg()) return true;
    const v = video.info();
    const ds = app.io.*.DisplaySize;
    const fb = app.io.*.DisplayFramebufferScale.x;
    const box = [2]u32{ @min(video.full_max_w, px(ds.x * fb)), @min(video.full_max_h, px(ds.y * fb)) };
    const out = video.fitSize(v.src_w, v.src_h, box[0], box[1]);
    if (debug()) std.debug.print("[tela cheia] teto {d}x{d} (esperado {d}x{d}), saída {d}x{d} (esperada {d}x{d}), textura {d}x{d}, anel {d} KB\n", .{ v.box_w, v.box_h, box[0], box[1], v.w, v.h, out[0], out[1], v.tex_w, v.tex_h, v.ring_bytes / 1024 });
    return v.box_w == box[0] and v.box_h == box[1] and v.w == out[0] and v.h == out[1] and
        v.tex_w == out[0] and v.tex_h == out[1] and v.ring_bytes <= 3 * ffmpeg.rgbaSize(video.full_max_w, video.full_max_h);
}
fn px(x: f32) u32 {
    return @intFromFloat(std.math.clamp(@round(x), 0, 16384));
}
fn memPrint(_: *App) void {
    if (!debug()) return;
    const m = @import("platform/window.zig").selfMemKb();
    const v = video.info();
    std.debug.print("[tela cheia] memória: PSS {d} KB; anel {d} KB, textura {d}x{d} ({d} KB)\n", .{ m.pss, v.ring_bytes / 1024, v.tex_w, v.tex_h, v.tex_w * v.tex_h * 4 / 1024 });
}

fn controlsHidden(_: *App) bool {
    if (!hasFfmpeg()) return true;
    const v = video.info();
    return v.full and v.playing and !v.controls and v.cursor_hidden;
}
fn controlsBack(_: *App) bool {
    if (!hasFfmpeg()) return true;
    const v = video.info();
    return v.full and v.controls and !v.cursor_hidden;
}
fn paused(_: *App) bool {
    if (!hasFfmpeg()) return true;
    const v = video.info();
    return v.full and !v.playing;
}
fn posKept(_: *App) bool {
    if (!hasFfmpeg()) return true;
    return video.info().pos_ms == pos0;
}
fn atStart(_: *App) bool {
    if (!hasFfmpeg()) return true;
    const v = video.info();
    return v.full and v.pos_ms < 50 and !v.ended;
}
/// → pula 5 s: o vídeo de 3 s vai ao fim (e para no último quadro).
fn atEnd(_: *App) bool {
    if (!hasFfmpeg()) return true;
    const v = video.info();
    return v.full and v.ended and v.pos_ms == @as(f64, @floatFromInt(v.duration_ms));
}
fn gainIs(app: *App, volume: u8) bool {
    if (!hasFfmpeg()) return true;
    const v = video.info();
    if (app.st.settings.video_volume != volume) return false;
    if (!v.has_audio) return true;
    const want = @import("ui/settings_state.zig").videoGain(volume);
    return @abs(v.gain - want) < 0.002;
}
fn vol60(app: *App) bool {
    return gainIs(app, 60);
}
fn vol50(app: *App) bool {
    return gainIs(app, 50);
}
fn vol0(app: *App) bool {
    return gainIs(app, 0) and (!hasFfmpeg() or !video.info().has_audio or video.info().muted);
}

/// Esc: o vídeo volta para a conversa, a janela sai da tela cheia, e nada recomeça.
fn leftKeptPos(app: *App) bool {
    if (!hasFfmpeg()) return true;
    const v = video.info();
    return !v.full and !v.window_full and !windowFull(app) and v.active and v.starts == starts0 and v.pos_ms == pos0 and
        qa.find("video") != null and qa.find("video-full") == null;
}
/// A decodificação volta ao teto da conversa: o anel inteiro e a textura no tamanho de
/// antes (pausado, o quadro da tela é decodificado de novo; a memória volta junto).
fn backToInline(_: *App) bool {
    if (!hasFfmpeg()) return true;
    const v = video.info();
    if (debug()) std.debug.print("[tela cheia] de volta: teto {d}x{d}, saída {d}x{d}, textura {d}x{d}, anel {d} KB\n", .{ v.box_w, v.box_h, v.w, v.h, v.tex_w, v.tex_h, v.ring_bytes / 1024 });
    return v.box_w == inline_box[0] and v.box_h == inline_box[1] and v.w == inline_out[0] and v.h == inline_out[1] and
        v.tex_w == inline_out[0] and v.tex_h == inline_out[1] and v.ring_bytes == 3 * ffmpeg.rgbaSize(inline_out[0], inline_out[1]);
}

fn videoFullOn(app: *App) bool {
    if (!hasFfmpeg()) return true;
    return video.info().full and video.info().window_full and windowFull(app);
}
fn videoFullOff(app: *App) bool {
    if (!hasFfmpeg()) return true;
    return !video.info().full and !video.info().window_full and !windowFull(app);
}
fn f11On(app: *App) bool {
    return windowFull(app);
}
fn f11Off(app: *App) bool {
    return !windowFull(app);
}
/// Com F11 antes: o vídeo sai da tela cheia e a janela continua nela.
fn videoOffWindowStays(app: *App) bool {
    if (!hasFfmpeg()) return windowFull(app);
    return !video.info().full and !video.info().window_full and windowFull(app);
}
/// Dois cliques: tela cheia, e o vídeo como estava (o primeiro clique pausou ou
/// continuou, o segundo desfaz). Ele está pausado perto do começo: se o primeiro clique
/// ficasse valendo, ele tocaria (e acabaria no meio da espera, por isso o fim não vale).
fn dblEntered(app: *App) bool {
    if (!hasFfmpeg()) return true;
    const v = video.info();
    return videoFullOn(app) and v.playing == playing0 and !v.ended;
}
fn dblLeft(app: *App) bool {
    if (!hasFfmpeg()) return true;
    const v = video.info();
    return videoFullOff(app) and v.playing == playing0 and !v.ended;
}
fn notFull(_: *App) bool {
    return !video.info().full;
}

/// O sistema tira a janela da tela cheia (um atalho dele): o vídeo sai junto.
fn systemLeaves(app: *App) void {
    _ = c.SDL_SetWindowFullscreen(app.win.window, false);
}
fn systemLeft(app: *App) bool {
    if (!hasFfmpeg()) return true;
    return !video.info().full and !video.info().window_full and !windowFull(app);
}

fn maximize(app: *App) void {
    _ = c.SDL_MaximizeWindow(app.win.window);
}
fn maximizedOrNot(app: *App) bool {
    // O driver sem tela do QA pode não saber maximizar: aí o caso fica de fora (e diz).
    maximize_works = windowMaximized(app);
    if (!maximize_works) std.debug.print("       (o driver de vídeo não maximiza: a volta à maximizada não foi conferida aqui)\n", .{});
    return true;
}
fn maximizedBack(app: *App) bool {
    if (!hasFfmpeg() or !maximize_works) return videoFullOff(app);
    return videoFullOff(app) and windowMaximized(app);
}
fn unmaximize(app: *App) void {
    _ = c.SDL_RestoreWindow(app.win.window);
}
fn notMaximized(app: *App) bool {
    return !windowMaximized(app);
}

// "Reduzir movimento": no primeiro quadro sem os controles, o cursor já sumiu (sem esmaecer).
var first_hidden = false;
var hid_instantly = false;
fn reduceOn(app: *App) void {
    app.st.settings.reduce_motion = true;
    first_hidden = false;
    hid_instantly = false;
}
fn reduceOff(app: *App) void {
    app.st.settings.reduce_motion = false;
}
fn sawHidden(_: *App) bool {
    if (!hasFfmpeg()) return true;
    const v = video.info();
    if (!first_hidden and v.full and !v.controls) {
        first_hidden = true;
        hid_instantly = v.cursor_hidden;
    }
    return first_hidden;
}
fn hidInstantly(_: *App) bool {
    return !hasFfmpeg() or hid_instantly;
}
fn playingFull(_: *App) bool {
    if (!hasFfmpeg()) return true;
    const v = video.info();
    return v.full and v.playing;
}

// A bandeja (de mentira no QA) com o vídeo em tela cheia.
fn trayFake(_: *App) void {
    @import("platform/tray.zig").fake = true;
}
fn trayFakeOff(_: *App) void {
    @import("platform/tray.zig").fake = false;
}
fn pushCloseEvent(app: *App) void {
    var e = std.mem.zeroes(c.SDL_Event);
    e.type = c.SDL_EVENT_WINDOW_CLOSE_REQUESTED;
    e.window.windowID = c.SDL_GetWindowID(app.win.window);
    _ = c.SDL_PushEvent(&e);
}
fn wakeShowWindow(app: *App) void {
    @import("platform/window.zig").Window.wake(app.win.wake_type, .show);
}
/// Escondeu, saindo da tela cheia antes: a janela guardada fora dela (e o vídeo pausado).
fn trayLeftFull(app: *App) bool {
    if (!@import("qa_bandeja.zig").isHidden(app)) return false;
    if (!hasFfmpeg()) return true;
    const v = video.info();
    return !v.full and !v.window_full and !app.win.geo.fullscreen and !v.playing;
}
fn backFromTray(app: *App) bool {
    if (windowHidden(app) or app.win.window == null) return false;
    return !windowFull(app) and !video.info().full;
}
/// O play depois da bandeja: o mesmo player (nenhum vídeo aberto de novo), tocando.
fn resumedAfterTray(_: *App) bool {
    if (!hasFfmpeg()) return true;
    const v = video.info();
    return v.active and v.starts == starts0 and v.playing;
}
/// A caixa de texto com o foco e o vídeo tocando: o F é dela (digitar), não da tela cheia.
fn fTyped(_: *App) bool {
    if (!hasFfmpeg()) return !video.info().full;
    const v = video.info();
    return !v.full and v.playing;
}

const ops_tela = [_]Op{
    s("vídeo em tela cheia"),
    run(prepare),
    run(jumpToVideo),
    .{ .wait = 500 },
    dyn(tDemoVideo),
    expect("play no vídeo: toca aqui (sem FFmpeg, avisa e não toca)", playing),
    expect("sem FFmpeg não aparece botão de tela cheia", noButtonWithoutFfmpeg),
    .{ .hover = .{ .dyn = tDemoVideo } },
    .{ .wait = 150 },
    expect("a barra do vídeo tem o botão de tela cheia", buttonShown),
    .{ .shot = "video-tela-botao" },
    .{ .hover = .{ .dyn = tFullBtn } },
    .{ .wait = 350 },
    .{ .shot = "video-tela-botao-dica" },
    run(rememberInline),
    run(memPrint),
    dyn(tFullBtn),
    expect("o botão põe a janela em tela cheia, e o vídeo cobre a janela em faixas pretas", fullCovers),
    expect("continua de onde estava, sem abrir outro vídeo", seamless),
    expect("decodifica no tamanho da tela (até 1080p), com a textura e o anel nesse tamanho", fullRes),
    run(memPrint),
    .{ .shot = "video-tela-cheia" },
    // Do começo, tocando (o vídeo tem 3 s): ← volta, e o play se tiver acabado.
    key(c.ImGuiKey_LeftArrow),
    dyn(tPlayIfPaused),
    expect("tocando do começo", playingFull),
    .{ .hover = .{ .dyn = tPicture } },
    expect("tocando com o mouse parado, os controles e o cursor somem", controlsHidden),
    .{ .shot = "video-tela-cheia-sem-controles" },
    .{ .hover = .{ .dyn_at = .{ .f = tPicture, .fx = 0.3, .fy = 0.4 } } },
    expect("mexer o mouse traz os controles e o cursor de volta", controlsBack),

    s("teclado na tela cheia"),
    key(c.ImGuiKey_Space),
    expect("espaço pausa", paused),
    run(rememberPos),
    .{ .wait = 300 },
    expect("pausado, o tempo não anda", posKept),
    key(c.ImGuiKey_LeftArrow),
    expect("← volta 5 s (até o começo)", atStart),
    key(c.ImGuiKey_RightArrow),
    expect("→ avança 5 s (o vídeo de 3 s vai ao fim)", atEnd),
    key(c.ImGuiKey_LeftArrow),
    expect("← de novo, do fim ao começo", atStart),
    key(c.ImGuiKey_UpArrow),
    expect("↑ sobe o volume (50 → 60), no som de verdade", vol60),
    key(c.ImGuiKey_DownArrow),
    expect("↓ desce o volume (60 → 50)", vol50),
    key(c.ImGuiKey_M),
    expect("M tira o som", vol0),
    key(c.ImGuiKey_M),
    expect("M de novo volta ao volume de antes", vol50),
    .{ .shot = "video-tela-cheia-pausado" },
    .{ .hover = .{ .dyn = tFullBtn } },
    .{ .wait = 350 },
    .{ .shot = "video-tela-cheia-dica" },
    run(rememberPos),
    key(c.ImGuiKey_Escape),
    expect("Esc sai: a janela volta, o vídeo volta para a conversa no mesmo ponto", leftKeptPos),
    expect("a decodificação, a textura e a memória voltam ao tamanho da conversa", backToInline),
    run(memPrint),
    .{ .shot = "video-tela-saiu" },

    s("F11 antes, F, dois cliques e F11"),
    key(c.ImGuiKey_F11),
    expect("F11: a janela em tela cheia", f11On),
    .{ .hover = .{ .dyn = tVideo } },
    key(c.ImGuiKey_F),
    expect("F com o mouse no vídeo abre a tela cheia do vídeo", videoFullOn),
    key(c.ImGuiKey_Escape),
    expect("Esc sai do vídeo e a janela continua em tela cheia (estava antes)", videoOffWindowStays),
    key(c.ImGuiKey_F11),
    expect("F11 tira a janela da tela cheia", f11Off),
    run(rememberPos),
    .{ .dclick = .{ .dyn = tVideo } },
    expect("dois cliques no vídeo abrem a tela cheia, sem pausar nem continuar", dblEntered),
    .{ .dclick = .{ .dyn = tPicture } },
    expect("dois cliques de novo saem", dblLeft),
    .{ .hover = .{ .dyn = tVideo } },
    key(c.ImGuiKey_F),
    expect("F de novo", videoFullOn),
    key(c.ImGuiKey_F),
    expect("F na tela cheia sai", videoFullOff),
    .{ .hover = .{ .dyn = tVideo } },
    key(c.ImGuiKey_F),
    expect("e F mais uma vez", videoFullOn),
    key(c.ImGuiKey_F11),
    expect("F11 na tela cheia do vídeo sai dela (e da janela, que não estava)", videoFullOff),
    .{ .hover = .{ .dyn = tDemoVideo } },
    dyn(tFullBtn),
    expect("o botão de novo", videoFullOn),
    dyn(tFullBtn),
    expect("o botão de sair, na barra da tela cheia", videoFullOff),
    .{ .hover = .{ .dyn = tDemoVideo } },
    dyn(tPlayIfPaused),
    click("composer"),
    key(c.ImGuiKey_F),
    expect("com a caixa de texto em foco, o F não abre a tela cheia (nem com o vídeo tocando)", fTyped),

    s("a janela muda por fora"),
    .{ .hover = .{ .dyn = tDemoVideo } },
    dyn(tFullBtn),
    expect("tela cheia", videoFullOn),
    run(systemLeaves),
    expect("o sistema tira a janela da tela cheia: o vídeo sai junto", systemLeft),
    run(maximize),
    expect("janela maximizada", maximizedOrNot),
    .{ .hover = .{ .dyn = tDemoVideo } },
    dyn(tFullBtn),
    expect("tela cheia com a janela maximizada", videoFullOn),
    key(c.ImGuiKey_Escape),
    expect("Esc: a janela volta maximizada (onde o driver maximiza)", maximizedBack),
    run(unmaximize),
    expect("e sai da maximizada", notMaximized),

    s("reduzir movimento"),
    run(reduceOn),
    .{ .hover = .{ .dyn = tDemoVideo } },
    dyn(tFullBtn),
    expect("tela cheia", videoFullOn),
    dyn(tPlayIfPaused),
    expect("tocando", playingFull),
    .{ .hover = .{ .dyn = tPicture } },
    expect("os controles somem", sawHidden),
    expect("com \"reduzir movimento\", somem de uma vez (sem esmaecer)", hidInstantly),
    run(reduceOff),

    s("bandeja na tela cheia"),
    run(rememberPos),
    run(trayFake),
    run(pushCloseEvent),
    expect("ir para a bandeja sai da tela cheia antes (a janela guardada fora dela)", trayLeftFull),
    run(wakeShowWindow),
    run(trayFakeOff),
    expect("volta da bandeja fora da tela cheia", backFromTray),
    .{ .hover = .{ .dyn = tDemoVideo } },
    .{ .click = .{ .dyn = tPlay } },
    expect("e o play toca o mesmo vídeo, sem abrir outro", resumedAfterTray),
    run(restoreHide),
};

pub const ops = ops_tela;

fn escala125(app: *App) void {
    app.st.settings.ui_scale = 1.25;
}
fn emEscala(app: *App) bool {
    return app.ui_size == 1.25;
}

/// Outro tema, outro idioma e a interface em 125% (tools/qa.sh: papel claro, japonês).
pub const ops_tema = [_]Op{
    run(escala125),
    expect("a interface em 125%", emEscala),
} ++ ops_tela;
