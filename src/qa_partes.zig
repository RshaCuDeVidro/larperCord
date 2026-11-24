//! QA das partes do tema (theme/parts.zig, `QA_SUITE=partes`): três temas feitos na hora,
//! cada um com o layout de um embutido e o mesmo bloco `parts` (classico: mensagens cozy,
//! canais discord, membros discord e a caixa box; terminal: irc, tree, tty e prompt; bolhas:
//! bubbles, pills e pill). Em cada um, os pixels da tela trazem as cores do bloco: o fundo
//! do canal aberto, o nome do canal não lido, a caixa de mensagem (uma expressão com
//! `@accent`, que acompanha a cor de destaque trocada nas Configurações), a borda de quem
//! fala na lista de membros e embaixo do canal de voz, o fundo da mensagem sob o mouse, o
//! fundo e a faixa da que chama a gente e a faixa do lado em que o texto começa (à direita
//! na mensagem em árabe), o fundo da nossa mensagem (`self`) e o do canal silenciado
//! (`muted`), que some quando ele deixa de ser; na lista de membros, o fundo da nossa linha
//! e o de quem está offline. Tudo de novo com a interface em 125% (sem a lista de membros,
//! que some nessa largura). O Inspetor (`ctl inspect el`) diz o nome da parte de um
//! elemento. Depois, cada um dos três temas embutidos (sem `parts`) e uma cópia dele com um
//! bloco `parts` que não vale em nada da tela desenham o mesmo quadro, pixel por pixel, em
//! 100% e em 125%: com a tabela das partes ligada, o que nenhuma regra muda fica como era.
//! (Igual ao executável de antes das partes: tools/pixels_antes.sh.) No fim, o tema da
//! galeria da comunidade que mostra as partes abre sem erro.
const std = @import("std");
const c = @import("c");
const App = @import("app.zig").App;
const R = @import("qa_runner.zig");
const Op = R.Op;
const qa = @import("ui/qa.zig");
const gw = @import("net/fake_gateway.zig");
const types = @import("core/types.zig");
const bidi = @import("ui/bidi.zig");
const platform = @import("platform/window.zig");
const builtin_themes = @import("builtin_themes");
const cmds = @import("inspect/comandos.zig");
const Rect = @import("theme/layout.zig").Rect;
const Id = types.Id;

fn s(name: []const u8) Op {
    return .{ .section = name };
}
fn expect(name: []const u8, f: *const fn (*App) bool) Op {
    return .{ .expect = .{ .name = name, .check = f, .timeout_ms = 4000 } };
}
fn run(f: *const fn (*App) void) Op {
    return .{ .run = f };
}

// As cores do bloco (opacas e longe de qualquer tema embutido).
const sel_bg: u32 = 0xc814b4;
const unread_ink: u32 = 0xff8800;
const hover_bg: u32 = 0x1e7a3c;
const mention_bg: u32 = 0x7a1e5a;
const mention_bar: u32 = 0xf2a03a;
const base_bar: u32 = 0x3a3af2;
const speak_border: u32 = 0xe6e61e;
const box_border: u32 = 0x14c8c8;
const self_bg: u32 = 0x2a5d8f;
const muted_bg: u32 = 0x3c1e7a;
const member_self_bg: u32 = 0x5d8f2a;
const offline_bg: u32 = 0x7a5a1e;
/// A cor de destaque nº 4 das Configurações (App.accents), para a caixa com `@accent`.
const accent4: u32 = 0xED4245;

const block =
    \\
    \\// QA_SUITE=partes (qa_partes.zig)
    \\parts {
    \\    part "message" bar="#3a3af2" bar-width=3
    \\    part "message:hover" bg="#1e7a3c"
    \\    part "message:mention" bg="#7a1e5a" bar="#f2a03a" bar-width=4
    \\    part "channel.item:selected" bg="#c814b4" color="#ffffff"
    \\    part "channel.item:unread" color="#ff8800" weight=bold
    \\    part "member.row:speaking" border="#e6e61e" border-width=2
    \\    part "channel.voice-member:speaking" border="#e6e61e" border-width=2
    \\    part "composer.box" bg="@accent" border="#14c8c8" border-width=2 radius=6
    \\    part "message:self" bg="#2a5d8f"
    \\    part "channel.item:muted" bg="#3c1e7a"
    \\    part "member.row:self" bg="#5d8f2a"
    \\    part "member.row:offline" bg="#7a5a1e"
    \\}
    \\
;

/// Um bloco que existe mas não vale em nada da tela (quem está offline não fala): a tabela
/// das partes não é null, e o desenho tem de ser o do tema sem `parts`.
const neutral_block =
    \\
    \\// QA_SUITE=partes: nenhuma regra vale na tela
    \\parts {
    \\    part "member.row:offline:speaking" bg="#ff00ff"
    \\}
    \\
;

const dir = "qa-out/temas-partes";
/// O tema da galeria que mostra as partes (themes/community/), lido do disco: o QA roda
/// de dentro do repositório.
const showcase = "studio-ink";
const showcase_path = "themes/community/" ++ showcase ++ ".kdl";

var home: Id = 0;
var wrote = false;

fn source(name: []const u8) ?[]const u8 {
    for (builtin_themes.list) |b| if (std.mem.eql(u8, b.name, name)) return b.source;
    return null;
}

fn writeFile(app: *App, path: [:0]const u8, parts_: []const []const u8) bool {
    var all: std.ArrayList(u8) = .empty;
    defer all.deinit(app.gpa);
    for (parts_) |p| all.appendSlice(app.gpa, p) catch return false;
    return c.SDL_SaveFile(path.ptr, all.items.ptr, all.items.len);
}

/// Os três temas e a cópia do da galeria numa pasta só do QA, que entra na lista.
fn setup(app: *App) void {
    home = app.st.activeChannel() orelse 0;
    _ = c.SDL_CreateDirectory(dir);
    var ok = true;
    for ([_][]const u8{ "classico", "terminal", "bolhas" }) |t| {
        var pb: [96]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&pb, "{s}/partes-{s}.kdl", .{ dir, t }, 0) catch return;
        ok = ok and writeFile(app, path, &.{ source(t) orelse return, block });
        const np = std.fmt.bufPrintSentinel(&pb, "{s}/neutro-{s}.kdl", .{ dir, t }, 0) catch return;
        ok = ok and writeFile(app, np, &.{ source(t) orelse return, neutral_block });
    }
    var size: usize = 0;
    if (c.SDL_LoadFile(showcase_path, &size)) |data| {
        defer c.SDL_free(data);
        ok = ok and writeFile(app, dir ++ "/" ++ showcase ++ ".kdl", &.{@as([*]const u8, @ptrCast(data))[0..size]});
    } else ok = false;
    const m = &app.themes;
    m.dirs.append(m.gpa, m.gpa.dupeSentinel(u8, dir, 0) catch return) catch return;
    m.scan() catch return;
    wrote = ok;
}

fn written(app: *App) bool {
    return wrote and app.themes.indexOf("partes-classico") != null and app.themes.indexOf("neutro-bolhas") != null and app.themes.indexOf(showcase) != null;
}

fn useTheme(app: *App, name: []const u8) void {
    const i = app.themes.indexOf(name) orelse return;
    app.handle(.{ .set_theme = i });
}
fn useClassico(app: *App) void {
    useTheme(app, "partes-classico");
}
/// Sem as linhas de varredura do terminal, que escurecem uma linha de pixels a cada tantas.
fn useTerminal(app: *App) void {
    useTheme(app, "partes-terminal");
    _ = app.themes.setOption("crt", false);
}
fn useBolhas(app: *App) void {
    useTheme(app, "partes-bolhas");
}
fn useShowcase(app: *App) void {
    useTheme(app, showcase);
}
fn useBack(app: *App) void {
    useTheme(app, "classico");
}
fn themeIs(app: *App, name: []const u8) bool {
    return std.mem.eql(u8, app.themes.name(), name) and app.themes.theme_().parts != null;
}
fn onClassico(app: *App) bool {
    return themeIs(app, "partes-classico") and homeReady(app);
}
fn onTerminal(app: *App) bool {
    return themeIs(app, "partes-terminal") and homeReady(app);
}
fn onBolhas(app: *App) bool {
    return themeIs(app, "partes-bolhas") and homeReady(app);
}
fn onShowcase(app: *App) bool {
    return themeIs(app, showcase) and app.themes.last_error == null and qa.find("composer") != null;
}
fn backToClassico(app: *App) bool {
    return std.mem.eql(u8, app.themes.name(), "classico") and app.themes.theme_().parts == null;
}

// --- Pixels -----------------------------------------------------------------------------

fn near(r: u8, g: u8, b: u8, want: u32, tol: i16) bool {
    const wr: i16 = @intCast((want >> 16) & 0xff);
    const wg: i16 = @intCast((want >> 8) & 0xff);
    const wb: i16 = @intCast(want & 0xff);
    return @abs(@as(i16, r) - wr) <= tol and @abs(@as(i16, g) - wg) <= tol and @abs(@as(i16, b) - wb) <= tol;
}

/// Quantos pixels da área (em coordenadas da interface) têm a cor, e quantos ela tem.
fn count(app: *App, r: Rect, want: u32, tol: i16) [2]usize {
    const k = app.uiScale();
    var area: c.SDL_Rect = .{ .x = @intFromFloat(@floor(r.x * k)), .y = @intFromFloat(@floor(r.y * k)), .w = @intFromFloat(@max(1, @floor(r.w * k))), .h = @intFromFloat(@max(1, @floor(r.h * k))) };
    const surface = c.SDL_RenderReadPixels(app.win.renderer, &area) orelse return .{ 0, 1 };
    defer c.SDL_DestroySurface(surface);
    var n: usize = 0;
    var y: c_int = 0;
    while (y < surface.*.h) : (y += 1) {
        var x: c_int = 0;
        while (x < surface.*.w) : (x += 1) {
            var pr: u8 = 0;
            var pg: u8 = 0;
            var pb: u8 = 0;
            var pa: u8 = 0;
            if (c.SDL_ReadSurfacePixel(surface, x, y, &pr, &pg, &pb, &pa) and near(pr, pg, pb, want, tol)) n += 1;
        }
    }
    return .{ n, @intCast(surface.*.w * surface.*.h) };
}

/// Pelo menos `frac` da área tem a cor.
fn covers(app: *App, r: Rect, want: u32, frac: f32) bool {
    const got = count(app, r, want, 4);
    return @as(f32, @floatFromInt(got[0])) >= frac * @as(f32, @floatFromInt(got[1]));
}

/// Entre `x0` e `x1` (da interface), na metade do meio da altura de `r`, alguma coluna de
/// pixels tem a cor. Uma borda de 2 px cai entre pixels em 125% e as beiradas se misturam
/// com o fundo: basta uma coluna inteira (quase) dela.
fn edgeHas(app: *App, r: Rect, x0: f32, x1: f32, want: u32) bool {
    const k = app.uiScale();
    var area: c.SDL_Rect = .{ .x = @intFromFloat(@floor(x0 * k)), .y = @intFromFloat(@floor((r.y + r.h * 0.25) * k)), .w = @intFromFloat(@max(1, @ceil((x1 - x0) * k))), .h = @intFromFloat(@max(1, @floor(r.h * 0.5 * k))) };
    const surface = c.SDL_RenderReadPixels(app.win.renderer, &area) orelse return false;
    defer c.SDL_DestroySurface(surface);
    var x: c_int = 0;
    while (x < surface.*.w) : (x += 1) {
        var n: c_int = 0;
        var y: c_int = 0;
        while (y < surface.*.h) : (y += 1) {
            var pr: u8 = 0;
            var pg: u8 = 0;
            var pb: u8 = 0;
            var pa: u8 = 0;
            if (c.SDL_ReadSurfacePixel(surface, x, y, &pr, &pg, &pb, &pa) and near(pr, pg, pb, want, 24)) n += 1;
        }
        if (n * 10 >= surface.*.h * 8) return true;
    }
    return false;
}

fn markFmt(buf: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(buf, fmt, args) catch "";
}

fn findFmt(comptime fmt: []const u8, args: anytype) ?Rect {
    var b: [64]u8 = undefined;
    return qa.find(markFmt(&b, fmt, args));
}

// --- Na conversa de sempre --------------------------------------------------------------

fn goHome(app: *App) void {
    if (home != 0) app.handle(.{ .open_message = .{ .channel = home, .id = 0 } });
    app.st.settings.accent = 0;
}
fn homeReady(app: *App) bool {
    const id = app.st.activeChannel() orelse return false;
    const cs = app.store.channel(id) orelse return false;
    return id == home and cs.history == .loaded and qa.find("composer") != null;
}

/// O canal aberto tem o fundo da parte `channel.item:selected`.
fn selectedBg(app: *App) bool {
    const r = findFmt("channel:{d}", .{home}) orelse return false;
    return covers(app, r, sel_bg, 0.45);
}

/// Um canal de texto do mesmo servidor, nem aberto nem silenciado, vira não lido.
var unread_id: Id = 0;
fn markUnread(app: *App) void {
    const cs_home = app.store.channel(home) orelse return;
    unread_id = 0;
    for (app.store.channelsOf(cs_home.info.guild)) |id| {
        if (id == home or app.st.muted_channels.contains(id)) continue;
        const cs = app.store.channel(id) orelse continue;
        if (cs.info.kind != .text or !app.store.canAccess(&cs.info) or app.st.filtros.count(id) > 0) continue;
        if (qa.find(markFmt(&unread_buf, "channel:{d}", .{id})) == null) continue;
        cs.info.unread = true;
        unread_id = id;
        break;
    }
}
var unread_buf: [48]u8 = undefined;
/// O nome dele vem na cor da parte `channel.item:unread`.
fn unreadInk(app: *App) bool {
    if (unread_id == 0) return false;
    const r = findFmt("channel:{d}", .{unread_id}) orelse return false;
    return count(app, r, unread_ink, 10)[0] >= 12;
}

/// A caixa de mensagem: fundo com a cor de destaque do momento e a borda da parte.
fn boxIs(app: *App, bg: u32) bool {
    const r = qa.find("composer-box") orelse return false;
    return covers(app, r, bg, 0.3) and edgeHas(app, r, r.x, r.x + 4, box_border);
}
fn rgbOf(col: @import("theme/color.zig").Rgba) u32 {
    const q = struct {
        fn f(x: f32) u32 {
            return @intFromFloat(std.math.clamp(x, 0, 1) * 255.0 + 0.5);
        }
    }.f;
    return (q(col.r) << 16) | (q(col.g) << 8) | q(col.b);
}
fn boxAccent(app: *App) bool {
    return boxIs(app, rgbOf(app.customTheme().c(.accent)));
}
fn accentRed(app: *App) void {
    app.st.settings.accent = 4;
}
fn accentBack(app: *App) void {
    app.st.settings.accent = 0;
}
/// A cor de destaque trocada nas Configurações chega na caixa (a expressão é avaliada no quadro).
fn boxFollows(app: *App) bool {
    return boxIs(app, accent4);
}

/// A Aninha (na call da demonstração) fala: a linha dela na lista de membros ganha a borda.
const ana: Id = 1001;
fn speak(app: *App) void {
    app.events.push(.{ .voice_speaking = .{ .user = ana, .speaking = true } });
    platform.Window.wake(app.win.wake_type, .gateway);
}
/// A call da madrugada, onde ela está (na lista de canais, embaixo do canal de voz).
const call0: Id = gw.channelId(0, 13);

/// As linhas dela à vista: na lista de membros (`member.row`) e embaixo do canal de voz
/// (`channel.voice-member`). Em 125% a lista de membros some; a de canais rola até a call.
fn anaRows(out: *[2]Rect) usize {
    var n: usize = 0;
    var b: [48]u8 = undefined;
    if (qa.visiblePart(markFmt(&b, "member:{d}", .{ana}))) |r| if (r.h >= 16) {
        out[n] = r;
        n += 1;
    };
    if (qa.visiblePart(markFmt(&b, "voice-member:{d}:{d}", .{ call0, ana }))) |r| if (r.h >= 16) {
        out[n] = r;
        n += 1;
    };
    return n;
}
/// Os pixels da cor da borda numa faixa de 6 (da interface) na beirada esquerda ou direita
/// da linha, comparados com a altura dela em pixels: uma borda reta dá umas duas colunas
/// cheias; a de cantos bem redondos (as bolhas), o arco. A conta não depende de uma coluna
/// inteira, que o arredondamento e a escala de 125% espalham.
fn edgeInk(app: *App, r: Rect, left: bool) f32 {
    const strip: Rect = .{ .x = if (left) r.x else r.right() - 6, .y = r.y, .w = 6, .h = r.h };
    const n: f32 = @floatFromInt(count(app, strip, speak_border, 24)[0]);
    return n / (r.h * app.uiScale());
}

/// Toda linha dela à vista (pelo menos uma) tem a borda dos dois lados.
fn speakingBorder(app: *App) bool {
    var rows: [2]Rect = undefined;
    const n = anaRows(&rows);
    if (n == 0) return false;
    for (rows[0..n]) |r| {
        const left = edgeInk(app, r, true) >= 0.6;
        const right = edgeInk(app, r, false) >= 0.6;
        if (c.SDL_getenv("QA_DEBUG") != null) std.debug.print("  [partes] quem fala: {d:.0},{d:.0} {d:.0}x{d:.0} esquerda={} direita={} falando={}\n", .{ r.x, r.y, r.w, r.h, left, right, app.store.speaking.contains(ana) });
        if (!left or !right) return false;
    }
    return true;
}
fn quiet(app: *App) void {
    app.events.push(.{ .voice_speaking = .{ .user = ana, .speaking = false } });
    platform.Window.wake(app.win.wake_type, .gateway);
}
fn noBorder(app: *App) bool {
    var rows: [2]Rect = undefined;
    const n = anaRows(&rows);
    if (n == 0) return false;
    for (rows[0..n]) |r| if (edgeInk(app, r, true) > 0.1 or edgeInk(app, r, false) > 0.1) return false;
    return true;
}

// --- self, muted e offline ---------------------------------------------------------------

/// Um canal de texto à vista, nem o aberto nem o não lido: ele fica silenciado e volta.
var muted_id: Id = 0;
var muted_buf: [48]u8 = undefined;
fn pickMuted(app: *App) void {
    const cs_home = app.store.channel(home) orelse return;
    muted_id = 0;
    for (app.store.channelsOf(cs_home.info.guild)) |id| {
        if (id == home or id == unread_id or app.st.muted_channels.contains(id)) continue;
        const cs = app.store.channel(id) orelse continue;
        if (cs.info.kind != .text or !app.store.canAccess(&cs.info) or cs.info.unread) continue;
        if (qa.visiblePart(markFmt(&muted_buf, "channel:{d}", .{id})) == null) continue;
        muted_id = id;
        break;
    }
}
fn mute(app: *App) void {
    if (muted_id != 0) app.st.muted_channels.put(app.gpa, muted_id, {}) catch {};
}
fn unmute(app: *App) void {
    if (muted_id != 0) _ = app.st.muted_channels.remove(muted_id);
}
fn mutedCovers(app: *App) ?bool {
    if (muted_id == 0) return null;
    const r = findFmt("channel:{d}", .{muted_id}) orelse return null;
    return covers(app, r, muted_bg, 0.45);
}
/// Silenciado: a linha com o fundo de `channel.item:muted`.
fn mutedBg(app: *App) bool {
    return mutedCovers(app) orelse false;
}
/// Não silenciado (antes e depois): sem ele.
fn notMutedBg(app: *App) bool {
    return !(mutedCovers(app) orelse true);
}

const own_text = "parte self";

/// O QA manda uma mensagem: a nossa, embaixo da conversa, para `message:self`.
fn ownSent(app: *App) bool {
    const cs = app.store.channel(home) orelse return false;
    const items = cs.messages.items;
    if (items.len == 0) return false;
    const m = &items[items.len - 1];
    return m.msg.author == app.store.me and !m.pending and std.mem.eql(u8, m.msg.content, own_text);
}

/// A nossa mensagem tem o fundo de `message:self`; a de outra pessoa mais perto dela, não.
fn selfMsgBg(app: *App) bool {
    const cs = app.store.channel(home) orelse return false;
    var own: ?Rect = null;
    var other: ?Rect = null;
    var b: [48]u8 = undefined;
    var i = cs.messages.items.len;
    while (i > 0 and (own == null or other == null)) {
        i -= 1;
        const m = &cs.messages.items[i];
        if (m.msg.id == 0 or m.msg.system != .none or m.msg.content.len == 0) continue;
        if (app.store.mentionsMeCached(cs.info.guild, m)) continue;
        const r = qa.visiblePart(markFmt(&b, "msg:{d}", .{m.msg.id})) orelse continue;
        if (r.h < 16) continue;
        if (m.msg.author == app.store.me) {
            if (own == null) own = r;
        } else if (other == null) other = r;
    }
    const o = own orelse return false;
    const x = other orelse return false;
    return covers(app, o, self_bg, 0.25) and !covers(app, x, self_bg, 0.05);
}

/// Na lista de membros: a nossa linha com o fundo de `member.row:self`.
fn memberSelfBg(app: *App) bool {
    var b: [48]u8 = undefined;
    const r = qa.visiblePart(markFmt(&b, "member:{d}", .{app.store.me})) orelse return false;
    return r.h >= 16 and covers(app, r, member_self_bg, 0.4);
}

/// Quem está offline (os quatro do fim da demonstração) tem o fundo de
/// `member.row:offline`; quem está online à vista, não.
const offline_ids = [_]Id{ 1008, 1009, 1010, 1011 };
const online_ids = [_]Id{ 1003, 1005, 1007, 1012, 1013 };
fn offlineBg(app: *App) bool {
    var b: [48]u8 = undefined;
    var seen = false;
    for (offline_ids) |id| {
        const r = qa.visiblePart(markFmt(&b, "member:{d}", .{id})) orelse continue;
        if (r.h < 16) continue;
        if (!covers(app, r, offline_bg, 0.4)) return false;
        seen = true;
    }
    if (!seen) return false;
    for (online_ids) |id| {
        const r = qa.visiblePart(markFmt(&b, "member:{d}", .{id})) orelse continue;
        if (covers(app, r, offline_bg, 0.05)) return false;
    }
    return true;
}
/// A rodinha em cima da lista de membros: até quem está offline, no fim.
fn tMembers(_: *App, b: []u8) []const u8 {
    return markFmt(b, "member:{d}", .{ana});
}

/// A rodinha em cima da lista de canais: até o fim (a call) e de volta ao começo.
fn tChannels(_: *App, b: []u8) []const u8 {
    return markFmt(b, "channel:{d}", .{home});
}
fn wheelDown(app: *App) void {
    c.ImGuiIO_AddMouseWheelEvent(app.io, 0, -60);
}
fn wheelUp(app: *App) void {
    c.ImGuiIO_AddMouseWheelEvent(app.io, 0, 60);
}

/// A mensagem mais nova de outra pessoa, sem menção, à vista.
var hover_id: Id = 0;
fn tHover(app: *App, b: []u8) []const u8 {
    const cs = app.store.channel(home) orelse return "";
    var i = cs.messages.items.len;
    while (i > 0) {
        i -= 1;
        const m = &cs.messages.items[i];
        if (m.msg.author == app.store.me or m.msg.id == 0 or m.msg.system != .none or m.msg.content.len == 0) continue;
        if (app.store.mentionsMeCached(cs.info.guild, m)) continue;
        const k = markFmt(b, "msgtext:{d}", .{m.msg.id});
        if (qa.find(k) == null) continue;
        hover_id = m.msg.id;
        return k;
    }
    return "";
}
/// Sob o mouse, o fundo da parte `message:hover`; a de cima não.
fn hoverBg(app: *App) bool {
    const r = findFmt("msg:{d}", .{hover_id}) orelse return false;
    return covers(app, r, hover_bg, 0.25);
}

// --- O destaque de menção ---------------------------------------------------------------

fn toMentions(app: *App) void {
    app.handle(.{ .open_message = .{ .channel = gw.mention_channel, .id = 0 } });
    app.st.scrollOf(gw.mention_channel).stick_bottom = true;
}
fn mentionRowRect(app: *App) ?Rect {
    const cs = app.store.channel(gw.mention_channel) orelse return null;
    if (app.st.activeChannel() != gw.mention_channel or cs.history != .loaded) return null;
    var i = cs.messages.items.len;
    while (i > 0) {
        i -= 1;
        if (findFmt("row-mention:{d}", .{cs.messages.items[i].msg.id})) |r| return r;
    }
    return null;
}
/// A que chama a gente: o fundo e a faixa (4 px, à esquerda) da parte `message:mention`.
fn mentionLook(app: *App) bool {
    const r = mentionRowRect(app) orelse return false;
    return covers(app, r, mention_bg, 0.25) and edgeHas(app, r, r.x, r.x + 5, mention_bar);
}

// --- O lado em que o texto começa -------------------------------------------------------

fn toRtl(app: *App) void {
    app.handle(.{ .open_message = .{ .channel = gw.rtl_channel, .id = 0 } });
    app.st.scrollOf(gw.rtl_channel).stick_bottom = true;
}
/// A linha de uma mensagem do #música à vista: em árabe (`rtl`) ou latina.
fn rtlRow(app: *App, rtl: bool) ?Rect {
    const cs = app.store.channel(gw.rtl_channel) orelse return null;
    if (app.st.activeChannel() != gw.rtl_channel or cs.history != .loaded) return null;
    var i = cs.messages.items.len;
    while (i > 0) {
        i -= 1;
        const m = &cs.messages.items[i];
        if (m.msg.content.len == 0 or m.msg.system != .none) continue;
        if (rtl != std.mem.eql(u8, m.msg.content, gw.rtl_arabic)) continue;
        if (!rtl and bidi.hasRtl(m.msg.content)) continue;
        if (app.store.mentionsMeCached(cs.info.guild, m)) continue;
        if (findFmt("msgtext:{d}", .{m.msg.id}) == null) continue;
        // O que aparece da linha: ela passa por baixo do lugar da barra de rolagem.
        var b: [48]u8 = undefined;
        const row = qa.visiblePart(markFmt(&b, "msg:{d}", .{m.msg.id})) orelse continue;
        // Só a parte de baixo: em cima pode estar a data do dia.
        return .{ .x = row.x, .y = row.bottom() - 14, .w = row.w, .h = 12 };
    }
    return null;
}
/// A faixa da parte `message`: à direita na mensagem em árabe, à esquerda na latina.
fn barSides(app: *App) bool {
    const ar = rtlRow(app, true) orelse return false;
    const lat = rtlRow(app, false) orelse return false;
    return edgeHas(app, ar, ar.right() - 4, ar.right(), base_bar) and !edgeHas(app, ar, ar.x, ar.x + 4, base_bar) and
        edgeHas(app, lat, lat.x, lat.x + 4, base_bar) and !edgeHas(app, lat, lat.right() - 4, lat.right(), base_bar);
}

// --- Inspetor ----------------------------------------------------------------------------

var insp_buf: [16 * 1024]u8 = undefined;
var insp_len: usize = 0;
var insp_done = false;
/// `ctl inspect el` na linha do canal aberto traz o nome da parte, com os estados dela.
fn inspectorPart(app: *App) bool {
    if (!insp_done) {
        var w = std.Io.Writer.fixed(&insp_buf);
        var b: [48]u8 = undefined;
        insp_done = cmds.run(app, markFmt(&b, "el qa:channel:{d}", .{home}), &w, .ctl) == .pronto;
        insp_len = w.buffered().len;
        return false;
    }
    const o = insp_buf[0..insp_len];
    return std.mem.indexOf(u8, o, "\"part\":\"channel.item:") != null and std.mem.indexOf(u8, o, ":selected") != null;
}

// --- Escala ------------------------------------------------------------------------------

/// Em 125% a janela continua 1280x800: a interface fica com 1024x640, e a lista de membros
/// some (os layouts a escondem abaixo de 1040 de largura). Quem fala aparece então embaixo do
/// canal de voz, na lista de canais.
fn scale125(app: *App) void {
    app.st.settings.ui_scale = 1.25;
}
fn scale100(app: *App) void {
    app.st.settings.ui_scale = 1;
}
fn at125(app: *App) bool {
    return app.ui_size == 1.25 and homeReady(app);
}
fn at100(app: *App) bool {
    return app.ui_size == 1 and homeReady(app);
}

/// O que cada tema confere, na escala do momento. `members`: a lista de membros está à
/// vista (em 125% ela some).
fn round(comptime tag: []const u8, comptime members: bool) [roundLen(members)]Op {
    return [_]Op{
        run(goHome),
        expect("a conversa de sempre está aberta", homeReady),
        .{ .wait = 150 },
        expect("canal aberto: o fundo de channel.item:selected", selectedBg),
        expect("caixa de mensagem: composer.box com @accent e a borda", boxAccent),
        run(markUnread),
        .{ .wait = 150 },
        expect("canal não lido: o nome na cor de channel.item:unread", unreadInk),
        run(pickMuted),
        expect("canal antes de silenciar: sem o fundo de channel.item:muted", notMutedBg),
        run(mute),
        .{ .wait = 150 },
        expect("canal silenciado: o fundo de channel.item:muted", mutedBg),
        run(unmute),
        .{ .wait = 150 },
        expect("deixou de ser silenciado: o fundo sai", notMutedBg),
        // O mouse fora das mensagens: sob ele, `hover` venceria o `self`.
        .{ .hover = .{ .mark = "composer" } },
        expect("a nossa mensagem: o fundo de message:self (a dos outros, não)", selfMsgBg),
    } ++ (if (members) [_]Op{
        expect("a nossa linha na lista de membros: o fundo de member.row:self", memberSelfBg),
        .{ .hover = .{ .dyn = tMembers } },
        run(wheelDown),
        .{ .wait = 300 },
        expect("quem está offline: o fundo de member.row:offline (quem está online, não)", offlineBg),
        run(wheelUp),
        .{ .wait = 300 },
    } else [_]Op{}) ++ [_]Op{
        .{ .hover = .{ .dyn = tChannels } },
        run(wheelDown),
        .{ .wait = 300 },
        run(speak),
        .{ .wait = 200 },
        .{ .shot = "partes-" ++ tag ++ "-fala" },
        expect("quem fala: a borda de member.row e channel.voice-member :speaking", speakingBorder),
        run(quiet),
        .{ .wait = 200 },
        expect("parou de falar: a borda sai", noBorder),
        run(wheelUp),
        .{ .wait = 300 },
        .{ .hover = .{ .dyn = tHover } },
        .{ .wait = 200 },
        expect("mensagem sob o mouse: o fundo de message:hover", hoverBg),
        run(toMentions),
        .{ .wait = 400 },
        expect("menção: o fundo e a faixa de message:mention", mentionLook),
        run(toRtl),
        .{ .wait = 400 },
        expect("a faixa de message fica do lado em que o texto começa (árabe à direita)", barSides),
        .{ .shot = "partes-" ++ tag ++ "-rtl" },
        run(goHome),
    };
}
fn roundLen(comptime members: bool) usize {
    return 41 + (if (members) @as(usize, 7) else 0);
}

fn themeRounds(comptime name: []const u8, comptime use: *const fn (*App) void, comptime on: *const fn (*App) bool) [roundLen(true) + roundLen(false) + 17]Op {
    return [_]Op{
        s("partes: " ++ name),
        run(use),
        run(goHome),
        expect("o tema " ++ name ++ " com o bloco parts abre", on),
        .{ .wait = 200 },
        .{ .shot = "partes-" ++ name },
    } ++ round(name, true) ++ [_]Op{
        run(accentRed),
        .{ .wait = 150 },
        expect("a cor de destaque trocada chega na caixa (a expressão segue o token)", boxFollows),
        run(accentBack),
        run(scale125),
        .{ .wait = 300 },
        expect("interface em 125%", at125),
        .{ .shot = "partes-" ++ name ++ "-125" },
    } ++ round(name ++ "-125", false) ++ [_]Op{
        run(scale100),
        .{ .wait = 300 },
        expect("de volta a 100%", at100),
    };
}

// --- Sem parts: o mesmo quadro -----------------------------------------------------------

/// O quadro inteiro (largura, altura e os pixels em ARGB8888), para comparar dois temas.
fn readFrame(app: *App) ?[]u8 {
    const surface = c.SDL_RenderReadPixels(app.win.renderer, null) orelse return null;
    defer c.SDL_DestroySurface(surface);
    const conv = c.SDL_ConvertSurface(surface, c.SDL_PIXELFORMAT_ARGB8888) orelse return null;
    defer c.SDL_DestroySurface(conv);
    const w: usize = @intCast(conv.*.w);
    const h: usize = @intCast(conv.*.h);
    const pitch: usize = @intCast(conv.*.pitch);
    const px: [*]const u8 = @ptrCast(conv.*.pixels orelse return null);
    const out = app.gpa.alloc(u8, w * h * 4 + 8) catch return null;
    std.mem.writeInt(u32, out[0..4], @intCast(w), .little);
    std.mem.writeInt(u32, out[4..8], @intCast(h), .little);
    for (0..h) |y| @memcpy(out[8 + y * w * 4 ..][0 .. w * 4], px[y * pitch ..][0 .. w * 4]);
    return out;
}

/// Quantos pixels mudam de um quadro para o outro (todos, se o tamanho mudou).
fn diffPixels(a: []const u8, b: []const u8) usize {
    return diffBox(a, b, null);
}

/// Como `diffPixels`, e o retângulo (em pixels) que tem todas as diferenças.
fn diffBox(a: []const u8, b: []const u8, box: ?*[4]usize) usize {
    if (a.len != b.len or !std.mem.eql(u8, a[0..8], b[0..8])) return std.math.maxInt(usize);
    const w: usize = std.mem.readInt(u32, a[0..4], .little);
    var n: usize = 0;
    var bx: [4]usize = .{ std.math.maxInt(usize), std.math.maxInt(usize), 0, 0 };
    var i: usize = 8;
    while (i < a.len) : (i += 4) {
        if (std.mem.eql(u8, a[i..][0..4], b[i..][0..4])) continue;
        n += 1;
        const px = (i - 8) / 4;
        bx = .{ @min(bx[0], px % w), @min(bx[1], px / w), @max(bx[2], px % w), @max(bx[3], px / w) };
    }
    if (box) |o| o.* = bx;
    return n;
}

/// O que muda sozinho na tela sem ter a ver com as partes fica parado enquanto compara: o
/// GIF da demonstração, o tempo da call ao lado do canal de voz, o mascote, as animações e
/// a barra de status (que mostra o nome do tema, a memória e o tempo do quadro).
const Frozen = struct { gifs: bool, timer: bool, motion: bool, mascot: u8, status: bool };
var frozen: ?Frozen = null;
fn freeze(app: *App) void {
    const st = &app.st.settings;
    if (frozen == null) frozen = .{ .gifs = st.autoplay_gifs, .timer = st.voice_timer, .motion = st.reduce_motion, .mascot = st.mascot_life, .status = st.show_status_bar };
    st.autoplay_gifs = false;
    st.voice_timer = false;
    st.reduce_motion = true;
    st.mascot_life = 0;
    st.show_status_bar = false;
}
fn thaw(app: *App) void {
    const f = frozen orelse return;
    const st = &app.st.settings;
    st.autoplay_gifs = f.gifs;
    st.voice_timer = f.timer;
    st.reduce_motion = f.motion;
    st.mascot_life = f.mascot;
    st.show_status_bar = f.status;
    frozen = null;
}

/// Grava um quadro de `readFrame` (para ver a diferença quando a comparação falha).
fn saveFrame(frame: []u8, comptime fmt: []const u8, args: anytype) void {
    const w: c_int = @intCast(std.mem.readInt(u32, frame[0..4], .little));
    const h: c_int = @intCast(std.mem.readInt(u32, frame[4..8], .little));
    const surf = c.SDL_CreateSurfaceFrom(w, h, c.SDL_PIXELFORMAT_ARGB8888, frame[8..].ptr, w * 4) orelse return;
    defer c.SDL_DestroySurface(surf);
    var b: [128]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&b, fmt, args, 0) catch return;
    _ = c.SDL_SavePNG(surf, path.ptr);
}

/// Quadros seguidos iguais para dizer que a tela parou.
const still_frames = 4;

const Same = struct {
    builtin: []const u8 = "",
    /// Quantos quadros seguidos saíram iguais ao último.
    still: u8 = 0,
    copy: []const u8 = "",
    /// 0: esperando o embutido; 1: o embutido parar; 2: a cópia parar.
    step: u8 = 0,
    tries: u8 = 0,
    last: ?[]u8 = null,
    ref: ?[]u8 = null,

    fn drop(sm: *Same, app: *App) void {
        if (sm.last) |x| app.gpa.free(x);
        if (sm.ref) |x| app.gpa.free(x);
        sm.last = null;
        sm.ref = null;
    }
};
var same: Same = .{};

fn useNoCrt(app: *App, name: []const u8) void {
    useTheme(app, name);
    // O aviso "tema: …" tem o nome de cada um: fora do quadro.
    app.st.toast.until_ms = 0;
    // As linhas de varredura do terminal, desligadas nos dois.
    if (std.mem.endsWith(u8, name, "terminal")) _ = app.themes.setOption("crt", false);
}

fn sameStart(comptime t: []const u8) *const fn (*App) void {
    return struct {
        fn f(app: *App) void {
            same.drop(app);
            same = .{ .builtin = t, .copy = "neutro-" ++ t };
            freeze(app);
            goHome(app);
            useNoCrt(app, t);
        }
    }.f;
}

/// O mesmo quadro: o embutido parado (`still_frames` quadros seguidos iguais), a cópia com
/// o bloco neutro parada, e os dois iguais. Se algo da tela mudou no meio (uma animação, a rede),
/// tenta de novo a partir do embutido, até quatro vezes.
fn sameFrame(app: *App) bool {
    if (same.tries >= 4) return false;
    const want = if (same.step < 2) same.builtin else same.copy;
    if (!std.mem.eql(u8, app.themes.name(), want) or !homeReady(app)) return false;
    // A caixa de mensagem com o foco nos dois quadros (o cursor, que não pisca, parado
    // nela): abrir a conversa dá o foco, e trocar de tema às vezes tira.
    if (!app.io.*.WantTextInput) {
        app.st.focus_input = true;
        same.still = 0;
        return false;
    }
    if (same.step == 0) {
        same.step = 1;
        return false;
    }
    const frame = readFrame(app) orelse return false;
    const prev = same.last orelse {
        same.last = frame;
        return false;
    };
    same.last = frame;
    defer app.gpa.free(prev);
    if (diffPixels(prev, frame) != 0) {
        same.still = 0;
        return false;
    }
    same.still += 1;
    if (same.still < still_frames) return false;
    same.still = 0;
    if (same.step == 1) {
        // O embutido parou: guarda e troca para a cópia.
        if (same.ref) |x| app.gpa.free(x);
        same.ref = frame;
        same.last = null;
        same.step = 2;
        useNoCrt(app, same.copy);
        return false;
    }
    var box: [4]usize = undefined;
    const n = diffBox(same.ref.?, frame, &box);
    if (n == 0) {
        same.drop(app);
        return true;
    }
    same.tries += 1;
    std.debug.print("  [partes] {s} e {s}: {d} pixels diferentes entre {d},{d} e {d},{d} (tentativa {d})\n", .{ same.builtin, same.copy, n, box[0], box[1], box[2], box[3], same.tries });
    if (c.SDL_getenv("QA_DEBUG") != null) {
        saveFrame(same.ref.?, "qa-out/partes-igual-{s}-{d}-{d}-embutido.png", .{ same.builtin, same.tries, app.ui_size * 100 });
        saveFrame(frame, "qa-out/partes-igual-{s}-{d}-{d}-neutro.png", .{ same.builtin, same.tries, app.ui_size * 100 });
    }
    if (same.tries == 4) {
        const prefix = if (c.SDL_getenv("QA_PREFIX")) |px| std.mem.span(px) else "";
        saveFrame(same.ref.?, "qa-out/{s}partes-igual-{s}-{d}-embutido.png", .{ prefix, same.builtin, app.ui_size * 100 });
        saveFrame(frame, "qa-out/{s}partes-igual-{s}-{d}-neutro.png", .{ prefix, same.builtin, app.ui_size * 100 });
    }
    if (same.tries < 4) {
        same.step = 1;
        app.gpa.free(frame);
        same.last = null;
        useNoCrt(app, same.builtin);
    }
    return false;
}

fn sameOp(comptime t: []const u8, comptime scale: []const u8) [2]Op {
    return .{
        run(sameStart(t)),
        .{ .expect = .{ .name = t ++ " embutido e com um parts que não vale em nada: o mesmo quadro, pixel por pixel (" ++ scale ++ ")", .check = sameFrame, .timeout_ms = 20000 } },
    };
}

fn freeSame(app: *App) void {
    same.drop(app);
    thaw(app);
}

const ops_same = [_]Op{
    s("partes: sem parts, o mesmo desenho"),
} ++ sameOp("classico", "100%") ++ sameOp("terminal", "100%") ++ sameOp("bolhas", "100%") ++ [_]Op{
    run(scale125),
    .{ .wait = 300 },
} ++ sameOp("classico", "125%") ++ sameOp("terminal", "125%") ++ sameOp("bolhas", "125%") ++ [_]Op{
    run(freeSame),
    run(scale100),
    .{ .wait = 300 },
};

pub const ops = [_]Op{
    s("partes do tema"),
    run(setup),
    expect("os temas com parts entram na lista", written),
    run(useClassico),
    run(goHome),
    expect("o tema classico com o bloco parts abre", onClassico),
    // A nossa mensagem embaixo da conversa (para `message:self`), e a caixa sem o foco.
    .{ .click = .{ .mark = "composer" } },
    .{ .text = own_text },
    .{ .key = .{ .key = c.ImGuiKey_Enter } },
    expect("a nossa mensagem chegou", ownSent),
    .{ .key = .{ .key = c.ImGuiKey_Escape } },
} ++ themeRounds("classico", useClassico, onClassico) ++ [_]Op{
    expect("o Inspetor diz a parte embaixo de um elemento (channel.item:selected)", inspectorPart),
} ++ themeRounds("terminal", useTerminal, onTerminal) ++
    themeRounds("bolhas", useBolhas, onBolhas) ++ ops_same ++ [_]Op{
    s("partes: tema da galeria"),
    run(useShowcase),
    run(goHome),
    expect("o tema da galeria que usa parts abre sem erro", onShowcase),
    .{ .wait = 300 },
    .{ .shot = "partes-galeria" },
    run(useBack),
    expect("volta ao classico, sem parts", backToClassico),
};
