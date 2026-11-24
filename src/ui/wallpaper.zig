//! Papel de parede: uma imagem do disco de quem usa, escolhida em Configurações →
//! Aparência (o caminho fica no settings.kdl). Tema nenhum aponta para arquivo ou
//! endereço: o tema só diz onde ela cai (`wallpaper fit=cover dim=0.3 blur=8`,
//! primeiro filho de um `stack`, como os fundos procedurais). Sem imagem escolhida,
//! o nó não desenha nada e o tema fica como sempre foi.
//!
//! Num tema sem `wallpaper`, a imagem vai atrás do layout inteiro e os fundos dos
//! nós do layout ficam translúcidos só o quanto o texto continua com contraste
//! (`wallpaper_fit.glass`); o fundo procedural do tema sai da frente.
//!
//! A imagem é lida numa thread, reduzida ao tamanho que cobre a janela (a original
//! em tamanho cheio não fica na memória) e vira uma textura parada: não pede quadro
//! nenhum. Cresceu a janela além do que foi carregado, recarrega uma vez; trocou a
//! configuração, relê.
const std = @import("std");
const c = @import("c");
const kdl = @import("../theme/kdl.zig");
const d = @import("draw.zig");
const fx = @import("fx.zig");
const qa = @import("qa.zig");
const anim = @import("anim.zig");
const i18n = @import("i18n.zig");
const images = @import("images.zig");
const wf = @import("wallpaper_fit.zig");
const platform = @import("../platform/window.zig");

const alloc = std.heap.c_allocator;
const Rect = d.Rect;

/// Lado maior da cópia pequena, a do desfoque e da conta de contraste.
const small_side: u32 = 512;

const Job = struct {
    refs: std.atomic.Value(u8) = .init(2),
    /// 0 lendo, 1 pronta, 2 não abriu.
    done: std.atomic.Value(u8) = .init(0),
    path: [:0]u8,
    cover_w: u32,
    cover_h: u32,
    wake_type: u32,
    still: ?images.Still = null,
    small: []u8 = &.{},
    small_w: u32 = 0,
    small_h: u32 = 0,

    fn release(j: *Job) void {
        if (j.refs.fetchSub(1, .acq_rel) != 1) return;
        if (j.still) |st| alloc.free(st.px);
        if (j.small.len > 0) alloc.free(j.small);
        alloc.free(j.path);
        alloc.destroy(j);
    }
};

fn work(arg: ?*anyopaque) callconv(.c) c_int {
    const j: *Job = @ptrCast(@alignCast(arg.?));
    const wake_type = j.wake_type;
    defer j.release();
    const st = images.loadStill(j.path, j.cover_w, j.cover_h) orelse {
        j.done.store(2, .release);
        platform.Window.wake(wake_type, .media);
        return 0;
    };
    // A cópia pequena, já com o tamanho certo para o desfoque e a conta de contraste.
    const k = @min(1.0, @as(f32, @floatFromInt(small_side)) / @as(f32, @floatFromInt(@max(st.w, st.h))));
    const sw: u32 = @intFromFloat(@max(@round(@as(f32, @floatFromInt(st.w)) * k), 1));
    const sh: u32 = @intFromFloat(@max(@round(@as(f32, @floatFromInt(st.h)) * k), 1));
    if (alloc.alloc(u8, sw * sh * 4)) |small| {
        images.resize(st.px, st.w, st.h, small, sw, sh);
        j.small = small;
        j.small_w = sw;
        j.small_h = sh;
    } else |_| {}
    j.still = st;
    j.done.store(1, .release);
    platform.Window.wake(wake_type, .media);
    return 0;
}

const State = struct {
    /// O caminho carregado (ou carregando).
    path: [256]u8 = undefined,
    path_len: usize = 0,
    tex: ?*c.SDL_Texture = null,
    tex_w: u32 = 0,
    tex_h: u32 = 0,
    src_w: u32 = 0,
    src_h: u32 = 0,
    /// O limite pedido na carga da textura atual (a janela em degraus).
    cover_w: u32 = 0,
    cover_h: u32 = 0,
    small: []u8 = &.{},
    small_w: u32 = 0,
    small_h: u32 = 0,
    lum: [2]f32 = .{ 0, 1 },
    blur_tex: ?*c.SDL_Texture = null,
    blur_r: u32 = 0,
    job: ?*Job = null,
    failed: bool = false,
    /// Escolhida agora no seletor: se não abrir, avisa e não guarda.
    fresh: bool = false,
    grew_ms: i64 = 0,
    glass_key: u64 = 0,
    glass: wf.Glass = .{ .alpha = 1, .dim = 0 },

    fn pathNow(x: *const State) []const u8 {
        return x.path[0..x.path_len];
    }
};

var wp: State = .{};

/// Quantas imagens já foram carregadas (o QA confere que é uma por troca).
pub var loads: u32 = 0;

fn dropTextures() void {
    if (wp.tex) |t| c.SDL_DestroyTexture(t);
    if (wp.blur_tex) |t| c.SDL_DestroyTexture(t);
    wp.tex = null;
    wp.blur_tex = null;
    wp.blur_r = 0;
    if (wp.small.len > 0) alloc.free(wp.small);
    wp.small = &.{};
}

fn clear() void {
    dropTextures();
    if (wp.job) |j| j.release();
    wp.job = null;
    wp.path_len = 0;
    wp.failed = false;
    wp.grew_ms = 0;
    wp.glass_key = 0;
}

/// A janela em pixels de verdade (com a escala da interface).
fn windowPx(ctx: *const d.Ctx) [2]u32 {
    const sc = ctx.io.*.DisplayFramebufferScale;
    return .{ @intFromFloat(@max(ctx.win.w * sc.x, 1)), @intFromFloat(@max(ctx.win.h * sc.y, 1)) };
}

fn startLoad(ctx: *const d.Ctx, path: []const u8) void {
    const win = windowPx(ctx);
    const j = alloc.create(Job) catch return;
    j.* = .{
        .path = alloc.dupeSentinel(u8, path, 0) catch {
            alloc.destroy(j);
            return;
        },
        .cover_w = wf.bound(win[0]),
        .cover_h = wf.bound(win[1]),
        .wake_type = ctx.images.wake_type,
    };
    const t = c.SDL_CreateThread(work, "papel-de-parede", j) orelse {
        j.refs.store(1, .monotonic);
        j.release();
        wp.failed = true;
        return;
    };
    c.SDL_DetachThread(t);
    if (wp.job) |old| old.release();
    wp.job = j;
    @memcpy(wp.path[0..path.len], path);
    wp.path_len = path.len;
}

/// A thread terminou: a textura nova entra (a velha sai), os pixels grandes vão embora.
fn collect(ctx: *d.Ctx) void {
    const j = wp.job orelse return;
    const st = j.done.load(.acquire);
    if (st == 0) return;
    wp.job = null;
    defer j.release();
    if (st == 2) {
        // Arquivo apagado, movido, ou que não é imagem: a textura antiga (se era a
        // mesma imagem, numa recarga) continua, e esse tamanho não é pedido de novo.
        if (wp.tex == null) wp.failed = true;
        wp.cover_w = j.cover_w;
        wp.cover_h = j.cover_h;
        if (wp.fresh) {
            ctx.st.showToast(ctx.now_ms, true, "não consegui abrir essa imagem (PNG, JPEG, WebP ou BMP, até 8192 pixels de lado)", "couldn't open that image (PNG, JPEG, WebP or BMP, up to 8192 pixels per side)", .{});
            ctx.st.settings.wallpaper = .{};
            ctx.act(.save_settings);
            clear();
        }
        wp.fresh = false;
        return;
    }
    wp.fresh = false;
    const still = j.still.?;
    const tex = c.SDL_CreateTexture(ctx.images.renderer, c.SDL_PIXELFORMAT_RGBA32, c.SDL_TEXTUREACCESS_STATIC, @intCast(still.w), @intCast(still.h)) orelse {
        if (wp.tex == null) wp.failed = true;
        return;
    };
    _ = c.SDL_SetTextureBlendMode(tex, c.SDL_BLENDMODE_BLEND);
    _ = c.SDL_UpdateTexture(tex, null, still.px.ptr, @intCast(still.w * 4));
    dropTextures();
    wp.tex = tex;
    wp.tex_w = still.w;
    wp.tex_h = still.h;
    wp.src_w = still.src_w;
    wp.src_h = still.src_h;
    wp.cover_w = j.cover_w;
    wp.cover_h = j.cover_h;
    wp.small = j.small;
    wp.small_w = j.small_w;
    wp.small_h = j.small_h;
    j.small = &.{};
    wp.lum = if (wp.small.len > 0) wf.lumRange(wp.small) else .{ 0, 1 };
    wp.failed = false;
    wp.glass_key = 0;
    loads +%= 1;
}

/// A cada quadro, antes do layout: segue a configuração (carrega, troca, solta) e
/// recarrega uma vez quando a janela passa do tamanho carregado.
pub fn frame(ctx: *d.Ctx) void {
    collect(ctx);
    const want = ctx.st.settings.wallpaper.slice();
    if (want.len == 0) {
        if (wp.path_len > 0 or wp.tex != null or wp.job != null) clear();
        return;
    }
    if (!std.mem.eql(u8, want, wp.pathNow())) {
        const fresh = wp.fresh;
        clear();
        wp.fresh = fresh;
        startLoad(ctx, want);
        return;
    }
    if (wp.failed or wp.job != null or wp.tex == null) return;
    const win = windowPx(ctx);
    if (wf.needsReload(.{ wp.cover_w, wp.cover_h }, win, .{ wp.src_w, wp.src_h }, .{ wp.tex_w, wp.tex_h })) {
        // Espera a janela parar de mudar (um arrasto não carrega a cada degrau).
        if (wp.grew_ms == 0) wp.grew_ms = ctx.now_ms;
        if (ctx.now_ms - wp.grew_ms >= 300) {
            wp.grew_ms = 0;
            startLoad(ctx, want);
        } else anim.at(wp.grew_ms + 300);
    } else wp.grew_ms = 0;
}

/// Janela escondida há um tempo: a textura e a cópia pequena saem (voltam quando ela
/// aparecer). true = soltou alguma coisa.
pub fn releaseHidden() bool {
    if (wp.tex == null and wp.small.len == 0) return false;
    clear();
    return true;
}

/// Quanto escurecer, como a pessoa escolheu (0 a 0,9).
fn userDim(ctx: *const d.Ctx) f32 {
    return std.math.clamp(@as(f32, @floatFromInt(ctx.st.settings.wallpaper_dim)) / 100, 0, 0.9);
}

/// O ajuste escolhido em Configurações; 0 (ou um número que não é opção, vindo de um
/// settings.kdl editado à mão) fica com o do tema.
pub fn fitFor(user: u8, theme_fit: wf.Fit) wf.Fit {
    return switch (user) {
        1 => .cover,
        2 => .contain,
        3 => .tile,
        4 => .center,
        else => theme_fit,
    };
}

/// QA: onde a última imagem caiu na tela, e com que ajuste.
pub var last_quad: wf.Quad = .{ .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0 };
pub var last_fit: wf.Fit = .cover;

/// A textura desfocada, feita uma vez da cópia pequena (raio em pixels dela).
fn blurred(ctx: *const d.Ctx, blur: f32, shown_w: f32) ?*c.SDL_Texture {
    if (wp.small.len == 0) return wp.tex;
    const r: u32 = @intFromFloat(std.math.clamp(@round(blur * @as(f32, @floatFromInt(wp.small_w)) / @max(shown_w, 1)), 1, 64));
    if (wp.blur_tex != null and wp.blur_r == r) return wp.blur_tex;
    const px = alloc.dupe(u8, wp.small) catch return wp.tex;
    defer alloc.free(px);
    const tmp = alloc.alloc(u8, px.len) catch return wp.tex;
    defer alloc.free(tmp);
    wf.blur(px, wp.small_w, wp.small_h, r, tmp);
    const tex = c.SDL_CreateTexture(ctx.images.renderer, c.SDL_PIXELFORMAT_RGBA32, c.SDL_TEXTUREACCESS_STATIC, @intCast(wp.small_w), @intCast(wp.small_h)) orelse return wp.tex;
    _ = c.SDL_SetTextureBlendMode(tex, c.SDL_BLENDMODE_BLEND);
    _ = c.SDL_UpdateTexture(tex, null, px.ptr, @intCast(wp.small_w * 4));
    if (wp.blur_tex) |old| c.SDL_DestroyTexture(old);
    wp.blur_tex = tex;
    wp.blur_r = r;
    return tex;
}

/// Desenha a imagem em `r`: `opacity` no alfa e, por cima, o `bg` do tema com `dim`.
fn paint(ctx: *d.Ctx, r: Rect, fit: wf.Fit, dim: f32, blur: f32, opacity: f32, radius: f32) void {
    const sc = ctx.io.*.DisplayFramebufferScale;
    // O tamanho próprio dela na tela: um pixel da original num pixel da tela.
    const nat_w = @as(f32, @floatFromInt(wp.src_w)) / sc.x;
    const nat_h = @as(f32, @floatFromInt(wp.src_h)) / sc.y;
    const q = wf.place(fit, nat_w, nat_h, r.x, r.y, r.w, r.h);
    if (q.x1 <= q.x0 or q.y1 <= q.y0) return;
    last_quad = q;
    last_fit = fit;
    const tex = (if (blur >= 0.5) blurred(ctx, blur, q.x1 - q.x0) else wp.tex) orelse return;
    const ref = fx.refOf(tex);
    const col = d.Rgba.white.alpha(opacity).u();
    if (fit == .tile and !fx.wrapsAnySize(ctx)) {
        // O renderizador não repete textura de lado qualquer: um quad por repetição
        // (com no máximo 32 × 32; ladrilho pequeno demais fica maior).
        const tw = @max(nat_w, r.w / 32);
        const th = @max(nat_h, r.h / 32);
        var y = r.y;
        while (y < r.bottom()) : (y += th) {
            var x = r.x;
            while (x < r.right()) : (x += tw) {
                const x1 = @min(x + tw, r.right());
                const y1 = @min(y + th, r.bottom());
                c.ImDrawList_AddImageEx(ctx.dl, ref, d.v(x, y), d.v(x1, y1), d.v(0, 0), d.v((x1 - x) / tw, (y1 - y) / th), col);
            }
        }
    } else {
        c.ImDrawList_AddImageRounded(ctx.dl, ref, d.v(q.x0, q.y0), d.v(q.x1, q.y1), d.v(q.u0, q.v0), d.v(q.u1, q.v1), col, radius, 0);
    }
    const bg = ctx.col(.bg);
    if (dim > 0.001) d.rect(ctx.dl, .{ .x = q.x0, .y = q.y0, .w = q.x1 - q.x0, .h = q.y1 - q.y0 }, .{ .r = bg.r, .g = bg.g, .b = bg.b, .a = dim * opacity }, radius);
}

/// `wallpaper fit=cover|contain|tile|center dim=0.3 blur=8 opacity=1 radius=0`
/// O `dim` do tema é o mínimo: o "Escurecer" das Configurações pode escurecer mais.
/// O `fit` do tema vale enquanto o "Ajuste" das Configurações está em "Do tema".
pub fn draw(ctx: *d.Ctx, n: *const kdl.Node, r: Rect) void {
    if (wp.tex == null) {
        if (qa.on()) qa.mark(r, "wallpaper:vazio", .{});
        return;
    }
    if (qa.on()) qa.mark(r, "wallpaper:imagem", .{});
    const theme_fit = std.meta.stringToEnum(wf.Fit, d.pstr(n, "fit", "cover")) orelse .cover;
    const fit = fitFor(ctx.st.settings.wallpaper_fit, theme_fit);
    const dim = @max(std.math.clamp(d.pnum(n, "dim", 0), 0, 1), userDim(ctx));
    const blur = std.math.clamp(d.pnum(n, "blur", 0), 0, 64);
    const opacity = std.math.clamp(d.pnum(n, "opacity", 1), 0, 1);
    paint(ctx, r, fit, dim, blur, opacity, d.pnum(n, "radius", 0));
}

fn declares(n: *const kdl.Node) bool {
    if (std.mem.eql(u8, n.name, "wallpaper")) return true;
    for (n.children) |*ch| if (declares(ch)) return true;
    return false;
}

/// O tema atual tem lugar para a imagem (um nó `wallpaper`, mesmo escondido)?
pub fn themeDeclares(ctx: *const d.Ctx) bool {
    const root = ctx.th.layout orelse return false;
    return declares(root);
}

/// Tem imagem pronta para mostrar?
pub fn ready() bool {
    return wp.tex != null;
}

/// Tema sem `wallpaper`: a imagem cobre `r` atrás de tudo, escurecida, e volta o
/// alfa que os fundos dos nós do layout devem ter (`glassVerts`). null = sem imagem,
/// ou o tema decide onde ela vai.
pub fn behind(ctx: *d.Ctx, r: Rect) ?f32 {
    if (wp.tex == null or themeDeclares(ctx)) return null;
    const g = glassFor(ctx);
    if (qa.on()) qa.mark(r, "wallpaper:atras", .{});
    // Por baixo, o fundo opaco: num tema de janela transparente, a imagem cobre o desktop.
    const bg = ctx.col(.bg);
    d.rect(ctx.dl, r, .{ .r = bg.r, .g = bg.g, .b = bg.b }, 0);
    paint(ctx, r, fitFor(ctx.st.settings.wallpaper_fit, .cover), g.dim, 0, 1, 0);
    return g.alpha;
}

/// O vidro do tema atual, refeito só quando as cores, o "Escurecer" ou a imagem mudam.
fn glassFor(ctx: *const d.Ctx) wf.Glass {
    const toks = [_]d.Rgba{ ctx.col(.bg), ctx.col(.sidebar), ctx.col(.surface), ctx.col(.text), ctx.col(.muted) };
    var h = std.hash.Wyhash.init(0x6a55);
    h.update(std.mem.sliceAsBytes(&toks));
    std.hash.autoHash(&h, ctx.st.settings.wallpaper_dim);
    h.update(std.mem.sliceAsBytes(&wp.lum));
    const key = h.final() | 1;
    if (key != wp.glass_key) {
        wp.glass_key = key;
        wp.glass = wf.glass(toks[0..3], toks[0], toks[3], toks[4], userDim(ctx), wp.lum);
    }
    return wp.glass;
}

/// Multiplica o alfa dos vértices de `start` em diante por `k`: o fundo de um nó do
/// layout (cor, gradiente, padrão, borda) vira vidro sobre a imagem.
pub fn glassVerts(dl: *c.ImDrawList, start: c_int, k: f32) void {
    const vb = &dl.*.VtxBuffer;
    if (start >= vb.Size or k >= 0.999) return;
    for (vb.Data[@intCast(start)..@intCast(vb.Size)]) |*p| {
        const a: f32 = @floatFromInt((p.col >> 24) & 0xff);
        p.col = (p.col & 0x00ff_ffff) | (@as(u32, @intFromFloat(a * k + 0.5)) << 24);
    }
}

// --- O seletor (Configurações → Aparência) ------------------------------------

var picking = false;
var pick_cancelled = std.atomic.Value(bool).init(false);

/// O seletor do sistema devolveu um arquivo: é a imagem pedida? true = era daqui.
pub fn takePicked(st: anytype, now_ms: i64, path: [:0]const u8) bool {
    if (!picking) return false;
    picking = false;
    if (path.len > st.settings.wallpaper.buf.len) {
        st.showToast(now_ms, true, "o caminho dessa imagem é longo demais", "that image's path is too long", .{});
        return true;
    }
    // A mesma imagem de novo não recarrega (nem avisa se uma recarga dela falhar depois).
    if (!std.mem.eql(u8, path, st.settings.wallpaper.slice())) wp.fresh = true;
    st.settings.wallpaper.set(path);
    return true;
}

/// O seletor fechou sem arquivo (chamado da thread do diálogo).
pub fn cancelPick() void {
    pick_cancelled.store(true, .release);
}

/// A cada volta do laço: o seletor cancelado não deixa o próximo anexo virar papel de parede.
pub fn pollCancel() void {
    if (pick_cancelled.swap(false, .acq_rel)) picking = false;
}

/// QA: o botão pediu o arquivo (o seletor do sistema não abre no QA).
pub fn qaPicking() bool {
    return picking;
}

/// QA: o tamanho da textura e da original.
pub fn qaSizes() [4]u32 {
    return .{ wp.tex_w, wp.tex_h, wp.src_w, wp.src_h };
}

/// O nome do arquivo, sem a pasta (barra de Linux ou de Windows).
pub fn baseName(path: []const u8) []const u8 {
    const i = std.mem.lastIndexOfAny(u8, path, "/\\") orelse return path;
    return path[i + 1 ..];
}

/// A seção em Configurações → Aparência.
pub fn section(p: anytype) void {
    const ctx = p.ctx;
    const set = &ctx.st.settings;
    p.heading(i18n.tr("Papel de parede", "Wallpaper"));
    const cur = set.wallpaper.slice();
    var buf: [320]u8 = undefined;
    if (cur.len == 0) {
        p.note(i18n.tr("Uma imagem do seu computador atrás do tema. Ela fica só aqui: nada vai para a internet.", "A picture from your computer behind the theme. It stays here: nothing goes online."));
    } else {
        p.note(i18n.fmt(&buf, "Imagem: {s}", "Image: {s}", .{baseName(cur)}));
        if (wp.failed and std.mem.eql(u8, cur, wp.pathNow())) {
            p.note(i18n.tr("Não deu para abrir essa imagem: ela foi apagada ou movida?", "Couldn't open that image: was it deleted or moved?"));
        } else if (wp.tex == null) p.note(i18n.tr("Carregando a imagem…", "Loading the image…"));
    }
    if (p.buttonSoft(if (cur.len == 0) i18n.tr("Escolher imagem…", "Choose image…") else i18n.tr("Trocar imagem…", "Change image…"))) {
        picking = true;
        pick_cancelled.store(false, .release);
        ctx.act(.pick_wallpaper);
    }
    if (cur.len == 0) return;
    p.sameLine();
    if (p.buttonSoft(i18n.tr("Remover", "Remove"))) {
        set.wallpaper = .{};
        ctx.act(.save_settings);
        return;
    }
    var dim: f32 = @as(f32, @floatFromInt(@min(set.wallpaper_dim, 90))) / 100;
    p.slider(i18n.tr("Escurecer", "Dim"), &dim, 0, 0.9, "{d:.0}%", 100);
    set.wallpaper_dim = @intFromFloat(std.math.clamp(@round(dim * 100), 0, 90));
    // (Grava ao fechar as Configurações, como os outros seletores desta página.)
    p.line(.medium, 16, ctx.col(.text), i18n.tr("Ajuste", "Fit"), 30);
    if (set.wallpaper_fit > 4) set.wallpaper_fit = 0;
    p.segmented(&.{ i18n.tr("Do tema", "Theme"), i18n.tr("Preencher", "Fill"), i18n.tr("Inteira", "Whole"), i18n.tr("Repetir", "Tile"), i18n.tr("Centro", "Center") }, &set.wallpaper_fit);
    if (themeDeclares(ctx)) {
        p.note(i18n.tr("Este tema tem um lugar para a imagem e escolhe o ajuste dela em \"Do tema\"; \"Escurecer\" só escurece mais do que ele pede.", "This theme has a place for the image and picks its fit under \"Theme\"; \"Dim\" only darkens it further than the theme does."));
    } else {
        p.note(i18n.tr("Ela fica atrás dos painéis, que ficam translúcidos só até onde o texto continua fácil de ler. O fundo animado do tema sai enquanto houver imagem.", "It sits behind the panels, which turn translucent only as far as text stays easy to read. The theme's animated background steps aside while there's an image."));
    }
}
