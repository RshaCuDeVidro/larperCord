//! QA dos caminhos vetoriais (`shape kind=path`), dos fundos novos (`rain`, `matrix`,
//! `waves`, `particles`) e do papel de parede (QA_SUITE=vetores). Um tema de teste
//! entra na lista como se fosse embutido; os pixels são lidos de verdade. O papel de
//! parede passa pelo mesmo caminho do seletor de arquivo (o robô entrega o arquivo
//! que o seletor do sistema entregaria).
const std = @import("std");
const c = @import("c");
const App = @import("app.zig").App;
const R = @import("qa_runner.zig");
const Op = R.Op;
const qa = @import("ui/qa.zig");
const fx = @import("ui/fx.zig");
const anim = @import("ui/anim.zig");
const wallpaper = @import("ui/wallpaper.zig");
const wf = @import("ui/wallpaper_fit.zig");
const theme = @import("theme/theme.zig");
const settings_state = @import("ui/settings_state.zig");
const settings_ui = @import("ui/settings.zig");
const i18n = @import("ui/i18n.zig");
const Rect = @import("theme/layout.zig").Rect;

fn s(name: []const u8) Op {
    return .{ .section = name };
}
fn click(k: []const u8) Op {
    return .{ .click = .{ .mark = k } };
}
fn expect(name: []const u8, f: *const fn (*App) bool) Op {
    return .{ .expect = .{ .name = name, .check = f } };
}
fn expectLong(name: []const u8, f: *const fn (*App) bool, ms: u32) Op {
    return .{ .expect = .{ .name = name, .check = f, .timeout_ms = ms } };
}

pub const theme_src =
    \\theme "qa-vetores" description="QA: caminhos, fundos novos e papel de parede."
    \\options {
    \\    option "movimento" label="Movimento" default=#false
    \\}
    \\colors {
    \\    bg "#101418"
    \\    surface "#101418"
    \\    sidebar "#101418"
    \\}
    \\layout {
    \\    stack {
    \\        wallpaper fit=cover dim=0
    \\        column {
    \\            row height=200 {
    \\                stack width=200 {
    \\                    rain seed=3 density=2 color="#ffffff" color2="#ffffff" motion="$movimento" motion-fps=12
    \\                }
    \\                stack width=200 {
    \\                    matrix seed=3 color="#00ff00" color2="#ffffff" motion="$movimento"
    \\                }
    \\                stack width=200 {
    \\                    waves seed=3 lines=8 color="#ffffff" color2="#ffffff" motion="$movimento"
    \\                }
    \\                stack width=200 {
    \\                    particles seed=3 density=2 color="#ffffff" color2="#ffffff" motion="$movimento"
    \\                }
    \\                shape kind=path width=100 d="M0 0 L32 0 L16 32 Z" viewbox="0 0 32 32" fill="#ff0000"
    \\                shape kind=path width=100 d="M0 0 H32 V32 H0 Z M8 8 H24 V24 H8 Z" viewbox="0 0 32 32" fill="#00ff00" fill-rule=evenodd
    \\                shape kind=path width=100 d="M2 16 A14 14 0 1 1 30 16 A14 14 0 1 1 2 16 Z" viewbox="0 0 32 32" color="#0000ff" thickness=3
    \\                spacer flex=1
    \\            }
    \\            row flex=1 {
    \\                spacer width=120
    \\                channel-list width=240
    \\                column flex=1 {
    \\                    messages flex=1
    \\                    composer height=46
    \\                }
    \\            }
    \\        }
    \\    }
    \\}
    \\
;

/// A linha do tema de teste em que `needle` aparece (as marcações dos caminhos são por linha).
fn lineOf(comptime needle: []const u8) u32 {
    const at = std.mem.indexOf(u8, theme_src, needle) orelse unreachable;
    return @intCast(std.mem.count(u8, theme_src[0..at], "\n") + 1);
}

fn pathMark(buf: []u8, comptime needle: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "path:{d}", .{lineOf(needle)}) catch "";
}

// --- Pixels ---------------------------------------------------------------------

/// A média de cor (RGB) de um retângulo da tela, em coordenadas da interface.
fn mean(app: *App, x: f32, y: f32, w: f32, h: f32) [3]f32 {
    const k = app.uiScale();
    var px_rect: c.SDL_Rect = .{ .x = @intFromFloat(x * k), .y = @intFromFloat(y * k), .w = @intFromFloat(@max(w * k, 1)), .h = @intFromFloat(@max(h * k, 1)) };
    const raw = c.SDL_RenderReadPixels(app.win.renderer, &px_rect) orelse return .{ -1, -1, -1 };
    defer c.SDL_DestroySurface(raw);
    // Cada renderizador devolve num formato: converte para RGBA para ler os canais.
    const surface = c.SDL_ConvertSurface(raw, c.SDL_PIXELFORMAT_RGBA32) orelse return .{ -1, -1, -1 };
    defer c.SDL_DestroySurface(surface);
    const sw: usize = @intCast(surface.*.w);
    const sh: usize = @intCast(surface.*.h);
    const pitch: usize = @intCast(surface.*.pitch);
    const px: [*]const u8 = @ptrCast(surface.*.pixels orelse return .{ -1, -1, -1 });
    var acc: [3]f32 = .{ 0, 0, 0 };
    for (0..sh) |yy| for (0..sw) |xx| {
        for (0..3) |ch| acc[ch] += @floatFromInt(px[yy * pitch + xx * 4 + ch]);
    };
    const n: f32 = @floatFromInt(@max(sw * sh, 1));
    return .{ acc[0] / n, acc[1] / n, acc[2] / n };
}

fn pixel(app: *App, x: f32, y: f32) [3]f32 {
    return mean(app, x, y, 1, 1);
}

fn near(a: [3]f32, b: [3]f32, tol: f32) bool {
    return @abs(a[0] - b[0]) <= tol and @abs(a[1] - b[1]) <= tol and @abs(a[2] - b[2]) <= tol;
}

fn rgb(v: u32) [3]f32 {
    return .{ @floatFromInt((v >> 16) & 0xff), @floatFromInt((v >> 8) & 0xff), @floatFromInt(v & 0xff) };
}

// --- O tema de teste --------------------------------------------------------------

var test_index: ?usize = null;

fn useTestTheme(app: *App) void {
    const m = &app.themes;
    if (m.indexOf("qa-vetores") == null) {
        const name = app.gpa.dupe(u8, "qa-vetores") catch return;
        m.entries.append(app.gpa, .{ .name = name, .builtin = theme_src }) catch return;
        m.names.append(app.gpa, name) catch return;
        m.previews_stale = true;
    }
    test_index = m.indexOf("qa-vetores");
    app.handle(.{ .set_theme = test_index.? });
}

fn onTestTheme(app: *App) bool {
    return std.mem.eql(u8, app.themes.name(), "qa-vetores") and app.store.ready and qa.find("composer") != null;
}

fn useTheme(app: *App, name: []const u8) void {
    if (app.themes.indexOf(name)) |i| app.handle(.{ .set_theme = i });
}
fn useClassico(app: *App) void {
    useTheme(app, "classico");
}
fn useOrbital(app: *App) void {
    useTheme(app, "orbital");
}
fn onClassico(app: *App) bool {
    return std.mem.eql(u8, app.themes.name(), "classico") and qa.find("composer") != null;
}
fn onOrbital(app: *App) bool {
    return std.mem.eql(u8, app.themes.name(), "orbital") and qa.find("composer") != null;
}

/// Erro no caminho: a linha do arquivo e o lugar em `d`, e o tema anterior continua.
fn badPathRefused(_: *App) bool {
    var diag: theme.Diagnostic = .{};
    const bad = "theme \"x\"\nlayout {\n    column {\n        shape kind=path d=\"M 0 0 L 5\"\n    }\n}\n";
    if (theme.load(std.heap.c_allocator, bad, null, &diag)) |t| {
        var tt = t;
        tt.deinit();
        return false;
    } else |_| {}
    return diag.line == 4 and std.mem.indexOf(u8, diag.message, "caractere 10") != null;
}

// --- Caminhos ---------------------------------------------------------------------

fn pathRect(comptime needle: []const u8) ?Rect {
    var b: [32]u8 = undefined;
    return qa.find(pathMark(&b, needle));
}

/// O conteúdo de uma caixa de visão 32×32 encaixada no nó (quadrado, centrado).
fn content(r: Rect) [3]f32 {
    const side = @min(r.w, r.h);
    return .{ r.x + (r.w - side) / 2, r.y + (r.h - side) / 2, side / 32 };
}

fn triangleFilled(app: *App) bool {
    const r = pathRect("fill=\"#ff0000\"") orelse return false;
    const k = content(r);
    // Dentro (perto do lado de cima) é vermelho puro; fora (canto de baixo) não é.
    const inside = pixel(app, k[0] + 16 * k[2], k[1] + 6 * k[2]);
    const outside = pixel(app, k[0] + 3 * k[2], k[1] + 28 * k[2]);
    return near(inside, rgb(0xff0000), 2) and outside[0] < 80;
}

fn ringHasHole(app: *App) bool {
    const r = pathRect("fill-rule=evenodd") orelse return false;
    const k = content(r);
    const hole = pixel(app, k[0] + 16 * k[2], k[1] + 16 * k[2]);
    const band = pixel(app, k[0] + 4 * k[2], k[1] + 16 * k[2]);
    return near(band, rgb(0x00ff00), 2) and hole[1] < 80;
}

fn circleStroked(app: *App) bool {
    const r = pathRect("thickness=3") orelse return false;
    const k = content(r);
    // O arco passa por (30, 16) e (16, 2); o meio fica vazio.
    const right = pixel(app, k[0] + 30 * k[2], k[1] + 16 * k[2]);
    const top = pixel(app, k[0] + 16 * k[2], k[1] + 2 * k[2]);
    const center = pixel(app, k[0] + 16 * k[2], k[1] + 16 * k[2]);
    return right[2] > 180 and right[0] < 90 and top[2] > 180 and center[2] < 80;
}

// --- Fundos -----------------------------------------------------------------------

fn backdropsDrawn(app: *App) bool {
    for ([_][]const u8{ "backdrop:rain", "backdrop:matrix", "backdrop:waves", "backdrop:particles" }) |k| {
        if (!R.hasInk(app, k)) return false;
    }
    return true;
}

var generated0: u32 = 0;
var wakes0: u32 = 0;
var loads0: u32 = 0;

fn remember(_: *App) void {
    generated0 = fx.generated;
    wakes0 = fx.motion_wakes;
    loads0 = wallpaper.loads;
}
fn staticStill(_: *App) bool {
    return fx.generated == generated0 and fx.motion_wakes == wakes0;
}

const moving_marks = [_][]const u8{ "backdrop:rain", "backdrop:matrix", "backdrop:waves", "backdrop:particles" };

fn motionOn(app: *App) void {
    _ = app.themes.setOption("movimento", true);
    wakes0 = fx.motion_wakes;
}
fn motionOff(app: *App) void {
    _ = app.themes.setOption("movimento", false);
}

/// Acordou, e não mais que 15 vezes por segundo.
fn motionWakes(_: *App) bool {
    if (fx.motion_wakes == wakes0) return false;
    return anim.next_wake_ms - anim.now_ms <= 100 and fx.last_period_ms >= 66;
}

/// Os pixels (RGBA) de um retângulo da tela, no c_allocator.
fn grab(app: *App, r: Rect) ?[]u8 {
    const k = app.uiScale();
    var px_rect: c.SDL_Rect = .{ .x = @intFromFloat(r.x * k), .y = @intFromFloat(r.y * k), .w = @intFromFloat(r.w * k), .h = @intFromFloat(r.h * k) };
    const raw = c.SDL_RenderReadPixels(app.win.renderer, &px_rect) orelse return null;
    defer c.SDL_DestroySurface(raw);
    const surface = c.SDL_ConvertSurface(raw, c.SDL_PIXELFORMAT_RGBA32) orelse return null;
    defer c.SDL_DestroySurface(surface);
    const w: usize = @intCast(surface.*.w);
    const h: usize = @intCast(surface.*.h);
    const pitch: usize = @intCast(surface.*.pitch);
    const src: [*]const u8 = @ptrCast(surface.*.pixels orelse return null);
    const out = std.heap.c_allocator.alloc(u8, w * h * 4) catch return null;
    for (0..h) |y| @memcpy(out[y * w * 4 ..][0 .. w * 4], src[y * pitch ..][0 .. w * 4]);
    return out;
}

var snaps: [4]?[]u8 = @splat(null);

fn snapBackdrops(app: *App) void {
    for (moving_marks, 0..) |k, i| {
        if (snaps[i]) |old| std.heap.c_allocator.free(old);
        snaps[i] = if (qa.find(k)) |r| grab(app, r) else null;
    }
    generated0 = fx.generated;
}

/// Andando, cada fundo muda de verdade na tela (a textura desliza; nada é refeito):
/// uma boa parte dos pixels de cada um não é mais a mesma.
fn backdropsMoved(app: *App) bool {
    for (moving_marks, 0..) |k, i| {
        const r = qa.find(k) orelse return false;
        const before = snaps[i] orelse return false;
        const now = grab(app, r) orelse return false;
        defer std.heap.c_allocator.free(now);
        if (now.len != before.len) return false;
        var changed: usize = 0;
        var j: usize = 0;
        while (j < now.len) : (j += 4) {
            const dr = @abs(@as(i16, now[j]) - before[j]);
            const dg = @abs(@as(i16, now[j + 1]) - before[j + 1]);
            const db = @abs(@as(i16, now[j + 2]) - before[j + 2]);
            if (@max(dr, dg, db) > 12) changed += 1;
        }
        if (changed < 40) return false;
    }
    return fx.generated == generated0;
}

fn reduceOn(app: *App) void {
    app.st.settings.reduce_motion = true;
}
fn reduceOff(app: *App) void {
    app.st.settings.reduce_motion = false;
}
fn rememberWakes(_: *App) void {
    wakes0 = fx.motion_wakes;
}
fn noWakes(_: *App) bool {
    return fx.motion_wakes == wakes0;
}

// --- Papel de parede ----------------------------------------------------------------

const fixture = "qa-out/papel-de-parede.png";

/// 4000 × 3000, metade esquerda vermelha e a direita azul: maior que a janela, para
/// a redução ao carregar ter o que reduzir.
fn makeFixture(_: *App) void {
    const sf = c.SDL_CreateSurface(4000, 3000, c.SDL_PIXELFORMAT_RGBA32) orelse return;
    defer c.SDL_DestroySurface(sf);
    const fmt = c.SDL_GetPixelFormatDetails(sf.*.format);
    const red = c.SDL_MapRGBA(fmt, null, 255, 0, 0, 255);
    const blue = c.SDL_MapRGBA(fmt, null, 0, 0, 255, 255);
    var left: c.SDL_Rect = .{ .x = 0, .y = 0, .w = 2000, .h = 3000 };
    var right: c.SDL_Rect = .{ .x = 2000, .y = 0, .w = 2000, .h = 3000 };
    _ = c.SDL_FillSurfaceRect(sf, &left, red);
    _ = c.SDL_FillSurfaceRect(sf, &right, blue);
    _ = c.SDL_SavePNG(sf, fixture);
}

fn openAppearance(app: *App) void {
    app.st.settings.open = true;
    app.st.settings.page = .aparencia;
}
fn closeSettings(app: *App) void {
    app.st.settings.open = false;
}

fn picking(_: *App) bool {
    return wallpaper.qaPicking();
}

/// O que o seletor do sistema devolveria.
fn pickFixture(app: *App) void {
    const z = std.heap.c_allocator.dupeSentinel(u8, fixture, 0) catch return;
    app.picked.push(z);
}
fn pickMissing(app: *App) void {
    const z = std.heap.c_allocator.dupeSentinel(u8, "qa-out/nao-existe.png", 0) catch return;
    app.picked.push(z);
}

fn wallpaperSaved(app: *App) bool {
    return std.mem.eql(u8, app.st.settings.wallpaper.slice(), fixture) and wallpaper.ready() and wallpaper.loads == loads0 + 1;
}

/// A original de 4000 × 3000 virou o que cobre a janela (em degraus de 256): a
/// grande não ficou na memória.
fn reducedOnLoad(app: *App) bool {
    const sz = wallpaper.qaSizes();
    const win = app.win.window;
    var w: c_int = 0;
    var h: c_int = 0;
    _ = c.SDL_GetWindowSizeInPixels(win, &w, &h);
    const want = wf.coverSize(4000, 3000, wf.bound(@intCast(w)), wf.bound(@intCast(h)));
    // (O arredondamento da redução pode dar um pixel a menos.)
    return sz[2] == 4000 and sz[3] == 3000 and sz[0] + 1 >= want[0] and sz[0] <= want[0] and sz[1] + 1 >= want[1] and sz[1] <= want[1];
}

/// O caminho vai e volta pelo settings.kdl (com barras de Windows também, no teste de unidade).
fn persisted(app: *App) bool {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(app.gpa);
    settings_state.write(&app.st.settings, "qa-vetores", &out, app.gpa) catch return false;
    return std.mem.indexOf(u8, out.items, "wallpaper=\"" ++ fixture ++ "\"") != null;
}

fn settingsRows(_: *App) bool {
    return qa.find("button:Remover") != null and qa.find("slider:Escurecer") != null and qa.find("button:Trocar imagem…") != null;
}

fn dimZero(app: *App) void {
    app.st.settings.wallpaper_dim = 0;
}
fn dimHalf(app: *App) void {
    app.st.settings.wallpaper_dim = 50;
}
fn dimDefault(app: *App) void {
    app.st.settings.wallpaper_dim = 45;
}

/// Pontos onde só o papel de parede aparece no tema de teste: a coluna vazia da
/// esquerda e a sobra da faixa de cima, à direita.
fn freeLeft() [2]f32 {
    return .{ 60, 420 };
}
fn freeRight() ?[2]f32 {
    const r = pathRect("thickness=3") orelse return null;
    return .{ r.right() + 40, r.y + r.h / 2 };
}

fn wallpaperPlain(app: *App) bool {
    if (qa.find("wallpaper:imagem") == null) return false;
    const l = freeLeft();
    const rr = freeRight() orelse return false;
    return near(pixel(app, l[0], l[1]), rgb(0xff0000), 3) and near(pixel(app, rr[0], rr[1]), rgb(0x0000ff), 3);
}

fn wallpaperDimmed(app: *App) bool {
    const l = freeLeft();
    const bg = rgb(0x101418);
    const want: [3]f32 = .{ 255 * 0.5 + bg[0] * 0.5, bg[1] * 0.5, bg[2] * 0.5 };
    return near(pixel(app, l[0], l[1]), want, 4);
}

// O "Ajuste" das Configurações vence o `fit=` do tema (o tema de teste pede cover).
fn fitIs(comptime n: u8) *const fn (*App) bool {
    return struct {
        fn f(app: *App) bool {
            return app.st.settings.wallpaper_fit == n;
        }
    }.f;
}
fn fitTheme(app: *App) void {
    app.st.settings.wallpaper_fit = 0;
}
fn fitCenter(app: *App) void {
    app.st.settings.wallpaper_fit = 4;
}

/// A imagem caiu na tela onde `wf.place` diz para esse ajuste (a de 4000 × 3000 no
/// tamanho próprio dela, um pixel da original num pixel da tela).
fn placedAs(fit: wf.Fit) bool {
    if (wallpaper.last_fit != fit) return false;
    const r = qa.find("wallpaper:imagem") orelse return false;
    const sc = c.ImGui_GetIO().*.DisplayFramebufferScale;
    const want = wf.place(fit, 4000 / sc.x, 3000 / sc.y, r.x, r.y, r.w, r.h);
    const got = wallpaper.last_quad;
    const px = [_][2]f32{ .{ want.x0, got.x0 }, .{ want.y0, got.y0 }, .{ want.x1, got.x1 }, .{ want.y1, got.y1 } };
    for (px) |v| if (@abs(v[0] - v[1]) > 0.5) return false;
    const uv = [_][2]f32{ .{ want.u0, got.u0 }, .{ want.v0, got.v0 }, .{ want.u1, got.u1 }, .{ want.v1, got.v1 } };
    for (uv) |v| if (@abs(v[0] - v[1]) > 1e-3) return false;
    return true;
}

/// Inteira (contain): a imagem 4:3 numa janela mais larga deixa faixas dos lados, com
/// o fundo do tema; logo depois da faixa, o vermelho da imagem.
fn wholeShowsBars(app: *App) bool {
    if (!placedAs(.contain)) return false;
    const r = qa.find("wallpaper:imagem") orelse return false;
    const q = wallpaper.last_quad;
    if (q.x0 - r.x < 20 or q.x0 + 6 > 120) return false;
    const bar = pixel(app, r.x + (q.x0 - r.x) / 2, 420);
    const img = pixel(app, q.x0 + 6, 420);
    return near(bar, rgb(0x101418), 6) and near(img, rgb(0xff0000), 3);
}

/// Repetir (tile): no tamanho próprio, a partir do canto; a metade vermelha da original
/// (2000 pixels) passa da janela, então o lado direito também é vermelho.
fn tiledFromCorner(app: *App) bool {
    if (!placedAs(.tile)) return false;
    const l = freeLeft();
    const rr = freeRight() orelse return false;
    return near(pixel(app, l[0], l[1]), rgb(0xff0000), 3) and near(pixel(app, rr[0], rr[1]), rgb(0xff0000), 3);
}

fn centered(_: *App) bool {
    return placedAs(.center);
}
fn coverAgain(app: *App) bool {
    return placedAs(.cover) and wallpaperPlain(app);
}

/// O ajuste vai para o settings.kdl.
fn fitPersisted(app: *App) bool {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(app.gpa);
    settings_state.write(&app.st.settings, "qa-vetores", &out, app.gpa) catch return false;
    return std.mem.indexOf(u8, out.items, " wallpaper_fit=3") != null;
}

var no_wall: [3]f32 = undefined;
fn rememberNoWall(app: *App) void {
    const l = freeLeft();
    no_wall = pixel(app, l[0], l[1]);
}
fn backToTheme(app: *App) bool {
    const l = freeLeft();
    return qa.find("wallpaper:vazio") != null and near(pixel(app, l[0], l[1]), no_wall, 2);
}

// Tema sem lugar para a imagem: ela vai atrás, os painéis ficam vidro.
var panels_before: [2][3]f32 = undefined;
fn placedRect(app: *App, name: []const u8) ?Rect {
    for (app.placed.items) |p| if (std.mem.eql(u8, p.node.name, name)) return p.rect;
    return null;
}
/// Um pedaço do meio para baixo da lista (a parte de cima tem o banner e os nomes).
fn area(app: *App, name: []const u8) [4]f32 {
    const r = placedRect(app, name) orelse return .{ 0, 0, 1, 1 };
    return .{ r.x + 8, r.y + r.h * 0.35, r.w - 16, r.h * 0.5 };
}
fn leftArea(app: *App) [4]f32 {
    return area(app, "channel-list");
}
fn rightArea(app: *App) [4]f32 {
    return area(app, "member-list");
}
fn snapPanels(app: *App) void {
    const a = leftArea(app);
    const b = rightArea(app);
    panels_before = .{ mean(app, a[0], a[1], a[2], a[3]), mean(app, b[0], b[1], b[2], b[3]) };
}
fn removeWallpaper(app: *App) void {
    app.st.settings.wallpaper = .{};
}
fn restoreWallpaper(app: *App) void {
    app.st.settings.wallpaper.set(fixture);
    loads0 = wallpaper.loads;
}
fn wallpaperGone(_: *App) bool {
    return !wallpaper.ready();
}
fn wallpaperBack(_: *App) bool {
    return wallpaper.ready() and wallpaper.loads == loads0 + 1;
}

/// O vermelho aparece através da lista de canais (à esquerda), o azul através da
/// lista de membros (à direita), e o texto continua com contraste sobre o vidro.
fn glassShows(app: *App) bool {
    if (qa.find("wallpaper:atras") == null) return false;
    const a = leftArea(app);
    const b = rightArea(app);
    const l = mean(app, a[0], a[1], a[2], a[3]);
    const r = mean(app, b[0], b[1], b[2], b[3]);
    // Mais vermelho que verde à esquerda, mais azul que verde à direita (no claro, o
    // painel já tem R e B altos: o que muda é o verde que cai).
    const lb = panels_before[0];
    const rb = panels_before[1];
    if (!((l[0] - l[1]) > (lb[0] - lb[1]) + 6 and (r[2] - r[1]) > (rb[2] - rb[1]) + 6)) return false;
    const th = app.customTheme();
    const text = th.c(.text);
    for ([_][3]f32{ l, r }) |m| {
        const under: theme.Rgba = .{ .r = m[0] / 255, .g = m[1] / 255, .b = m[2] / 255 };
        if (text.contrast(under) < 4.5) return false;
    }
    return true;
}

fn lightMode(app: *App) void {
    app.st.settings.color_mode = 1;
}
fn darkMode(app: *App) void {
    app.st.settings.color_mode = 0;
}
fn isLight(app: *App) bool {
    return app.themes.mode == .light and qa.find("composer") != null;
}
fn isDark(app: *App) bool {
    return app.themes.mode == .dark and qa.find("composer") != null;
}

fn backdropStepsAside(_: *App) bool {
    return qa.find("wallpaper:atras") != null and qa.find("backdrop:starfield") == null and qa.find("backdrop:orbit") == null;
}
fn backdropBack(_: *App) bool {
    return qa.find("wallpaper:atras") == null and qa.find("backdrop:starfield") != null;
}

// Quadros parados com o papel de parede: nada pede quadro e eles saem iguais.
var built_mark: u64 = 0;
var same_mark: u64 = 0;
var gifs_before = true;
fn gifsOff(app: *App) void {
    gifs_before = app.st.settings.autoplay_gifs;
    app.st.settings.autoplay_gifs = false;
}
fn gifsOn(app: *App) void {
    app.st.settings.autoplay_gifs = gifs_before;
}
fn markFrames(app: *App) void {
    built_mark = app.gate.built;
    same_mark = app.gate.same;
    remember(app);
}
fn framesSettled(app: *App) bool {
    if (app.gate.built - built_mark < 10) return false;
    if (app.gate.same - same_mark == app.gate.built - built_mark) {
        return fx.motion_wakes == wakes0 and wallpaper.loads == loads0;
    }
    built_mark = app.gate.built;
    same_mark = app.gate.same;
    return false;
}

fn reloadedOnce(_: *App) bool {
    return wallpaper.loads == loads0 + 1 and wallpaper.qaSizes()[0] > 1500;
}
fn noMoreLoads(_: *App) bool {
    return wallpaper.loads == loads0 + 1;
}

// Japonês e russo com a interface em 125%: as linhas novas (o nome do arquivo, o
// Escurecer, o Ajuste com cinco opções e a nota) cabem e nada sai cortado.
/// Como o app troca de idioma: com as fontes refeitas (sem isso o japonês sai em "?").
fn startLang(app: *App, l: []const u8) void {
    i18n.set(l);
    app.fonts_lang_changed = true;
    i18n.cuts.store(0, .monotonic);
    settings_ui.overflows.store(0, .monotonic);
}
fn langJa(app: *App) void {
    startLang(app, "ja");
    openAppearance(app);
}
fn langRu(app: *App) void {
    startLang(app, "ru");
    openAppearance(app);
}
fn langDone(app: *App) void {
    i18n.set("pt");
    app.fonts_lang_changed = true;
    app.st.settings.open = false;
    app.st.settings.ui_scale = 1;
    app.st.settings.wallpaper_fit = 0;
}
fn scale125(app: *App) void {
    app.st.settings.ui_scale = 1.25;
}
fn inScale125(app: *App) bool {
    return app.ui_size == 1.25;
}
fn noCuts(_: *App) bool {
    return i18n.cuts.load(.monotonic) == 0;
}
fn noOverflow(_: *App) bool {
    if (settings_ui.overflows.load(.monotonic) == 0) return true;
    std.log.warn("texto maior que a área: \"{s}\"", .{settings_ui.last_overflow[0..settings_ui.last_overflow_len]});
    return false;
}
/// O botão de cada opção do Ajuste no idioma do momento (a marcação leva o texto).
fn segWhole(_: *App, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "seg:{s}", .{i18n.tr("Inteira", "Whole")}) catch "";
}
fn segTile(_: *App, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "seg:{s}", .{i18n.tr("Repetir", "Tile")}) catch "";
}
/// As linhas novas aparecem na página, no idioma dela.
fn rowsTranslated(_: *App) bool {
    var b: [96]u8 = undefined;
    const rm = std.fmt.bufPrint(&b, "button:{s}", .{i18n.tr("Remover", "Remove")}) catch return false;
    if (qa.find(rm) == null) return false;
    var b2: [96]u8 = undefined;
    const sl = std.fmt.bufPrint(&b2, "slider:{s}", .{i18n.tr("Escurecer", "Dim")}) catch return false;
    return qa.find(sl) != null;
}

fn missingRefused(app: *App) bool {
    // Não abriu: avisa, não guarda e não deixa uma imagem quebrada nas configurações.
    return app.st.settings.wallpaper.len == 0 and !wallpaper.ready() and app.st.toast.is_error;
}

pub const ops = [_]Op{
    s("caminhos vetoriais"),
    expect("erro no caminho aponta a linha e o lugar em d", badPathRefused),
    .{ .run = useTestTheme },
    expectLong("o tema de teste carrega", onTestTheme, 5000),
    expect("triângulo preenchido no lugar certo", triangleFilled),
    expect("evenodd fura o quadrado de dentro", ringHasHole),
    expect("o traço do círculo feito de arcos passa onde deve", circleStroked),
    .{ .shot = "vetores-caminhos" },

    s("fundos novos"),
    expect("chuva, chuva de código, ondas e partículas desenham", backdropsDrawn),
    .{ .run = remember },
    .{ .wait = 300 },
    expect("parados: nenhuma textura nova e nenhum quadro pedido", staticStill),
    .{ .run = motionOn },
    .{ .wait = 150 },
    expect("em movimento: pede quadros, no máximo 15 por segundo", motionWakes),
    .{ .run = snapBackdrops },
    .{ .wait = 1200 },
    expect("em movimento: cada fundo muda na tela sem gerar textura", backdropsMoved),
    .{ .run = reduceOn },
    .{ .wait = 80 },
    .{ .run = rememberWakes },
    .{ .wait = 250 },
    expect("\"reduzir movimento\" para os fundos", noWakes),
    .{ .run = reduceOff },
    .{ .run = motionOff },
    .{ .wait = 100 },
    .{ .run = remember },
    .{ .wait = 250 },
    expect("desligou o movimento: parados de novo", staticStill),

    s("papel de parede pelo seletor"),
    .{ .run = makeFixture },
    .{ .run = rememberNoWall },
    .{ .run = openAppearance },
    .{ .wait = 150 },
    click("button:Escolher imagem…"),
    expect("o botão pede o arquivo ao sistema", picking),
    .{ .run = remember },
    .{ .run = pickFixture },
    expectLong("a imagem escolhida fica nas configurações e carrega", wallpaperSaved, 6000),
    expect("reduzida ao carregar: só o que cobre a janela fica na memória", reducedOnLoad),
    expect("o caminho vai para o settings.kdl", persisted),
    expect("aparecem Trocar, Remover e Escurecer", settingsRows),
    .{ .shot = "vetores-papel-config" },
    .{ .run = closeSettings },
    .{ .run = dimZero },
    .{ .wait = 150 },
    expect("o tema com lugar para a imagem a mostra (cover, metade vermelha e metade azul)", wallpaperPlain),
    .{ .run = dimHalf },
    .{ .wait = 150 },
    expect("\"Escurecer\" mistura a imagem com o fundo do tema", wallpaperDimmed),
    .{ .shot = "vetores-papel" },

    s("ajuste da imagem"),
    .{ .run = openAppearance },
    .{ .wait = 150 },
    click("seg:Inteira"),
    expect("\"Inteira\" fica nas configurações", fitIs(2)),
    .{ .shot = "vetores-papel-ajuste" },
    .{ .run = closeSettings },
    .{ .run = dimZero },
    .{ .wait = 150 },
    expect("Inteira: a imagem toda, com faixas do fundo do tema dos lados", wholeShowsBars),
    .{ .shot = "vetores-papel-inteira" },
    .{ .run = openAppearance },
    .{ .wait = 150 },
    click("seg:Repetir"),
    expect("\"Repetir\" fica nas configurações", fitIs(3)),
    expect("o ajuste vai para o settings.kdl", fitPersisted),
    .{ .run = closeSettings },
    .{ .wait = 150 },
    expect("Repetir: no tamanho dela, a partir do canto", tiledFromCorner),
    .{ .run = fitCenter },
    .{ .wait = 150 },
    expect("Centro: no tamanho dela, no meio", centered),
    .{ .run = fitTheme },
    .{ .wait = 150 },
    expect("\"Do tema\": volta ao fit=cover do tema", coverAgain),
    .{ .run = dimHalf },
    .{ .run = gifsOff },
    .{ .run = markFrames },
    expectLong("com a imagem parada, os quadros saem iguais e nada pede quadro", framesSettled, 15000),
    .{ .run = gifsOn },

    s("janela maior recarrega uma vez"),
    .{ .run = remember },
    .{ .resize = .{ 1920, 1200 } },
    expectLong("cresceu além do carregado: uma carga, maior", reloadedOnce, 6000),
    .{ .wait = 800 },
    expect("e só uma", noMoreLoads),
    .{ .resize = .{ 1280, 800 } },
    .{ .wait = 600 },
    expect("diminuir não recarrega", noMoreLoads),

    s("tema sem lugar para a imagem"),
    .{ .run = removeWallpaper },
    .{ .run = useClassico },
    expectLong("classico", onClassico, 5000),
    expect("sem imagem, o tema fica como é", wallpaperGone),
    .{ .wait = 200 },
    .{ .run = snapPanels },
    .{ .run = restoreWallpaper },
    expectLong("a imagem volta", wallpaperBack, 6000),
    .{ .wait = 150 },
    expect("escuro: a imagem aparece através dos painéis, o texto continua legível", glassShows),
    .{ .shot = "vetores-papel-classico" },
    .{ .run = removeWallpaper },
    .{ .run = lightMode },
    expectLong("modo claro", isLight, 4000),
    .{ .wait = 200 },
    .{ .run = snapPanels },
    .{ .run = restoreWallpaper },
    expectLong("a imagem volta no claro", wallpaperBack, 6000),
    .{ .wait = 150 },
    expect("claro: a imagem aparece através dos painéis, o texto continua legível", glassShows),
    .{ .shot = "vetores-papel-classico-claro" },
    .{ .run = darkMode },
    expectLong("modo escuro de novo", isDark, 4000),
    .{ .run = useOrbital },
    expectLong("orbital", onOrbital, 5000),
    expect("o fundo procedural sai da frente da imagem", backdropStepsAside),
    .{ .run = removeWallpaper },
    expect("sem imagem, as estrelas voltam", backdropBack),

    s("remover e arquivo que não abre"),
    .{ .run = useTestTheme },
    expectLong("o tema de teste de novo", onTestTheme, 5000),
    .{ .run = restoreWallpaper },
    expectLong("a imagem volta", wallpaperBack, 6000),
    .{ .run = openAppearance },
    .{ .wait = 150 },
    click("button:Remover"),
    expect("remover tira a imagem", wallpaperGone),
    .{ .run = closeSettings },
    .{ .run = dimDefault },
    .{ .wait = 150 },
    expect("e o tema volta a ser o de antes", backToTheme),
    .{ .run = openAppearance },
    .{ .wait = 150 },
    click("button:Escolher imagem…"),
    expect("o botão pede o arquivo ao sistema", picking),
    .{ .run = pickMissing },
    expectLong("arquivo que não abre: avisa e não guarda", missingRefused, 6000),
    .{ .run = closeSettings },

    s("japonês e russo, interface em 125%"),
    .{ .run = restoreWallpaper },
    expectLong("a imagem volta", wallpaperBack, 6000),
    .{ .run = scale125 },
    expectLong("interface em 125%", inScale125, 4000),
    .{ .run = langJa },
    .{ .wait = 800 },
    .{ .click = .{ .dyn = segWhole } },
    expect("japonês: \"全体を表示\" fica nas configurações", fitIs(2)),
    expect("japonês: Remover e Escurecer traduzidos", rowsTranslated),
    .{ .wait = 150 },
    .{ .shot = "vetores-papel-ja-125" },
    expect("japonês: nada maior que a área", noOverflow),
    expect("japonês: nenhum texto cortado", noCuts),
    .{ .run = langRu },
    .{ .wait = 800 },
    .{ .click = .{ .dyn = segTile } },
    expect("russo: \"Tile\" fica nas configurações", fitIs(3)),
    .{ .wait = 150 },
    .{ .shot = "vetores-papel-ru-125" },
    expect("russo: nada maior que a área", noOverflow),
    expect("russo: nenhum texto cortado", noCuts),
    .{ .run = langDone },
    .{ .run = removeWallpaper },
    expect("de volta: sem imagem", wallpaperGone),
};
