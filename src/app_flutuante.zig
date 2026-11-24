//! A janela flutuante (picture-in-picture), do lado do app: uma segunda janela do
//! sistema, sempre por cima e redimensionável, com a vista compacta de uma conversa ou
//! da call (ui/flutuante.zig). Uma de cada vez; fechar devolve tudo ao normal.
//!
//! Como desenha: um segundo contexto do ImGui, com o mesmo atlas de fontes da principal,
//! desenhado pelo mesmo SDL_Renderer numa textura fora da tela, e os pixels vão para a
//! superfície da janela flutuante (SDL_GetWindowSurface: nem GPU nem contexto gráfico a
//! mais para ela). Texturas do SDL não passam de um renderizador para outro: assim as
//! fontes, as fotos, os emojis e as imagens do cache são os mesmos da principal, sem
//! carregar nada duas vezes, e o desenho é o de sempre. O preço é ler os pixels de volta,
//! e só quando a imagem dela muda (o mesmo portão de core/ritmo.zig da principal).
//!
//! Quando desenha: só quando algo dela mudou (core/flutuante.zig `precisa`): o mouse ou o
//! teclado nela, o que chegou da rede, as ações, as configurações, uma animação dela.
//! Parada, não acorda o laço. Com a principal escondida na bandeja ela continua.
//! Fechada, nada disto existe: nenhuma janela, contexto, textura ou superfície a mais.
const std = @import("std");
const c = @import("c");
const sys = @import("platform/sys.zig");
const platform = @import("platform/window.zig");
const App = @import("app.zig").App;
const fl = @import("core/flutuante.zig");
const ritmo = @import("core/ritmo.zig");
const envio = @import("core/envio.zig");
const types = @import("core/types.zig");
const ui = @import("ui/flutuante.zig");
const d = @import("ui/draw.zig");
const qa = @import("ui/qa.zig");
const quadro = @import("ui/quadro.zig");
const anim = @import("ui/anim.zig");
const popup = @import("ui/popup.zig");
const i18n = @import("ui/i18n.zig");
const sigil = @import("ui/comp_chat.zig").sigil;
const send_limits = @import("ui/composer_limits.zig");
const voz_audio = @import("net/voz_audio.zig");
const now = @import("net/fake_gateway.zig").nowMs;
const Id = types.Id;

/// Pontos da interface para coordenadas da janela, para a janela do IME (imgui_impl_sdl3.cpp).
extern var larper_ime_scale: f32;

/// Medidas que sobrevivem ao fechar (o QA confere; --stats mostra).
pub const Medidas = struct {
    /// Quadros feitos, os que foram para a tela e o tempo deles (montar + ler os pixels).
    quadros: u64 = 0,
    desenhados: u64 = 0,
    us: u64 = 0,
    aberturas: u32 = 0,
    /// Mensagens que saíram pela caixa dela.
    enviadas: u32 = 0,
};

pub const Pip = struct {
    win: ?*c.SDL_Window = null,
    ctx: ?*c.ImGuiContext = null,
    io: ?*c.ImGuiIO = null,
    alvo: fl.Alvo = .{ .conversa = 0 },
    /// A textura fora da tela (no renderizador da principal), do tamanho da janela em pixels.
    tex: ?*c.SDL_Texture = null,
    tex_w: c_int = 0,
    tex_h: c_int = 0,
    gate: ritmo.Gate = .{},
    pendentes: u8 = 0,
    mudou: bool = false,
    /// O mouse andou por cima sem botão apertado desde o último quadro.
    mouse: bool = false,
    ultimo_ms: i64 = 0,
    ultimo_ns: u64 = 0,
    /// O que as animações dela pediram no último quadro.
    anim_ativa: bool = false,
    acordar_ms: i64 = std.math.maxInt(i64),
    focada: bool = false,
    /// Pontos para coordenadas da janela (a escala do monitor dela e o tamanho da interface).
    escala: f32 = 1,
    /// O sistema deixa o app escolher onde a janela fica (o Wayland não deixa).
    posiciona: bool = true,
    /// O resumo das configurações e do resto que a vista mostra (`mudouFora`).
    resumo: u64 = 0,
    estado: ui.Estado = .{},
};

pub var medidas: Medidas = .{};
/// O aviso do Wayland sobre ficar por cima sai uma vez por sessão.
var avisou_wayland = false;
/// Lido pelo `hitTest` (thread dos eventos, a mesma da interface).
var hit_escala: f32 = 1;

pub fn aberta(app: *const App) bool {
    return app.pip.win != null;
}

/// O contexto do ImGui da janela flutuante, para o QA mandar mouse e teclado para ela.
pub fn ioOf(app: *App) ?*c.ImGuiIO {
    return app.pip.io;
}

pub fn pedido(app: *App, p: fl.Pedido) void {
    switch (p) {
        .abrir => |alvo| abrir(app, alvo),
        .fechar => fechar(app, true),
        .voltar => voltar(app),
    }
}

/// O que ela segue ainda existe (a conversa, a call em que estamos).
fn seguindo(app: *App, alvo: fl.Alvo) bool {
    const cs = app.store.channel(alvo.canal());
    const existe = if (cs) |x| switch (alvo) {
        .conversa => fl.conversaFlutua(x.info.kind, app.store.canAccess(&x.info)),
        .call => true,
    } else false;
    return fl.segue(alvo, existe, app.st.voice);
}

fn titulo(app: *App, buf: []u8, alvo: fl.Alvo) [:0]const u8 {
    const cs = app.store.channel(alvo.canal()) orelse return fl.titulo(buf, "", "?");
    return fl.titulo(buf, if (alvo == .call) "🔊 " else sigil(&cs.info), cs.info.name);
}

fn abrir(app: *App, alvo: fl.Alvo) void {
    if (sys.web) return app.st.showToast(now(), true, "a janela flutuante não existe no navegador", "the floating window isn't available in the browser", .{});
    if (!seguindo(app, alvo)) return;
    var tb: [160]u8 = undefined;
    const p = &app.pip;
    if (p.win) |win| {
        // Uma de cada vez: a que está aberta passa a seguir a outra coisa.
        if (!std.meta.eql(p.alvo, alvo)) {
            // O que estava escrito era para a outra conversa: não vai parar nesta.
            p.alvo = alvo;
            p.estado = .{};
            popup.dropPip(&app.st);
        }
        _ = c.SDL_SetWindowTitle(win, titulo(app, &tb, alvo).ptr);
        _ = c.SDL_RaiseWindow(win);
        p.estado.focus = true;
        p.pendentes = 3;
        p.gate.redraw();
        return;
    }
    // Ela desenha com o renderizador da principal: com a principal na bandeja sem a parte
    // da GPU (App.releaseGpu), ele volta (a janela da principal continua escondida).
    if (!app.ensureGpu()) return app.st.showToast(now(), true, "não consegui abrir a janela flutuante", "couldn't open the floating window", .{});
    const driver = if (c.SDL_GetCurrentVideoDriver()) |v| std.mem.span(v) else "";
    const posiciona = !std.mem.eql(u8, driver, "wayland");
    // A área útil do monitor da principal e a escala que o SDL deixa para o app.
    const display = c.SDL_GetDisplayForWindow(app.win.window);
    var area: c.SDL_Rect = .{ .x = 0, .y = 0, .w = 1280, .h = 800 };
    _ = c.SDL_GetDisplayUsableBounds(display, &area);
    const set = &app.st.settings;
    const guardada = fl.lida(set.pip_x, set.pip_y, set.pip_w, set.pip_h);
    const geo = fl.abertura(guardada, .{ .x = area.x, .y = area.y, .w = area.w, .h = area.h }, app.win.scale(), posiciona);

    // A superfície da janela flutuante direto na memória (XShm no X11, GDI no Windows): sem
    // isto o SDL cria um segundo renderizador, com um contexto de GPU, só para mostrar a
    // imagem dela. O Wayland não tem esse caminho, e lá o SDL usa um renderizador mesmo.
    // (O SDL decide uma vez por sessão, na primeira superfície: a principal não usa.)
    if (posiciona) _ = c.SDL_SetHint(c.SDL_HINT_FRAMEBUFFER_ACCELERATION, "0");
    const props = c.SDL_CreateProperties();
    defer c.SDL_DestroyProperties(props);
    _ = c.SDL_SetStringProperty(props, c.SDL_PROP_WINDOW_CREATE_TITLE_STRING, titulo(app, &tb, alvo).ptr);
    _ = c.SDL_SetNumberProperty(props, c.SDL_PROP_WINDOW_CREATE_WIDTH_NUMBER, geo.w);
    _ = c.SDL_SetNumberProperty(props, c.SDL_PROP_WINDOW_CREATE_HEIGHT_NUMBER, geo.h);
    if (posiciona) {
        _ = c.SDL_SetNumberProperty(props, c.SDL_PROP_WINDOW_CREATE_X_NUMBER, geo.x);
        _ = c.SDL_SetNumberProperty(props, c.SDL_PROP_WINDOW_CREATE_Y_NUMBER, geo.y);
    }
    _ = c.SDL_SetBooleanProperty(props, c.SDL_PROP_WINDOW_CREATE_RESIZABLE_BOOLEAN, true);
    _ = c.SDL_SetBooleanProperty(props, c.SDL_PROP_WINDOW_CREATE_ALWAYS_ON_TOP_BOOLEAN, true);
    _ = c.SDL_SetBooleanProperty(props, c.SDL_PROP_WINDOW_CREATE_HIGH_PIXEL_DENSITY_BOOLEAN, true);
    _ = c.SDL_SetBooleanProperty(props, c.SDL_PROP_WINDOW_CREATE_HIDDEN_BOOLEAN, true);
    const win = c.SDL_CreateWindowWithProperties(props) orelse {
        std.log.warn("janela flutuante: {s}", .{c.SDL_GetError()});
        return app.st.showToast(now(), true, "não consegui abrir a janela flutuante", "couldn't open the floating window", .{});
    };
    const k = app.win.scale();
    _ = c.SDL_SetWindowMinimumSize(win, @intFromFloat(@as(f32, @floatFromInt(fl.min_w)) * k), @intFromFloat(@as(f32, @floatFromInt(fl.min_h)) * k));
    if (platform.decodeIcon(platform.iconPng(app.st.settings.mascot == 1, .window))) |icon| {
        _ = c.SDL_SetWindowIcon(win, icon);
        c.SDL_DestroySurface(icon);
    }

    // O segundo contexto: o atlas de fontes é o da principal; o renderizador também.
    const main_ctx = c.ImGui_GetCurrentContext();
    const style = c.ImGui_GetStyle().*;
    const pctx = c.ImGui_CreateContext(app.io.*.Fonts);
    c.ImGui_SetCurrentContext(pctx);
    const io = c.ImGui_GetIO();
    io.*.IniFilename = null;
    io.*.ConfigInputTextCursorBlink = false; // sem piscar = sem redesenho parado
    c.ImGui_GetStyle().* = style;
    _ = c.cImGui_ImplSDL3_InitForOther(win);
    _ = c.cImGui_ImplSDLRenderer3_Init(app.win.renderer);
    c.ImGui_SetCurrentContext(main_ctx);

    // A barra de cima arrasta a janela (sem a barra do sistema, como no GNOME sem libdecor).
    _ = c.SDL_SetWindowHitTest(win, hitTest, null);
    _ = c.SDL_ShowWindow(win);
    p.* = .{
        .win = win,
        .ctx = pctx,
        .io = io,
        .alvo = alvo,
        .posiciona = posiciona,
        .pendentes = 3,
        .focada = c.SDL_GetWindowFlags(win) & c.SDL_WINDOW_INPUT_FOCUS != 0,
    };
    ui.aberta = true;
    medidas.aberturas += 1;
    // O Wayland não tem "sempre por cima" para o app pedir: quem decide é o compositor
    // (no KWin, Alt+F3 → Mais ações → Manter acima das outras; no Hyprland, "pin").
    if (!posiciona and !avisou_wayland and !app.opts.qa) {
        avisou_wayland = true;
        app.st.showToast(now(), false, "no Wayland, ficar por cima das outras janelas depende do compositor", "on Wayland, staying above other windows is up to the compositor", .{});
    }
}

/// Fecha e solta tudo: a janela (com a superfície), o contexto do ImGui e a textura.
/// `guardar`: grava o lugar e o tamanho (ao apagar todos os dados, nada vai para o disco).
pub fn fechar(app: *App, guardar: bool) void {
    const p = &app.pip;
    const win = p.win orelse return;
    lembrar(app);
    if (guardar) app.saveSettings();
    popup.dropPip(&app.st);
    if (p.ctx) |pctx| {
        const main_ctx = c.ImGui_GetCurrentContext();
        c.ImGui_SetCurrentContext(pctx);
        c.cImGui_ImplSDLRenderer3_Shutdown();
        c.cImGui_ImplSDL3_Shutdown();
        c.ImGui_SetCurrentContext(main_ctx);
        c.ImGui_DestroyContext(pctx);
    }
    if (p.tex) |t| c.SDL_DestroyTexture(t);
    c.SDL_DestroyWindow(win);
    p.* = .{};
    ui.aberta = false;
    // A caixa da principal volta a receber o teclado, e o malloc devolve o que soltou.
    app.st.focus_input = true;
    app.gate.redraw();
    app.trim_wanted.store(true, .release);
}

/// Saindo do app: some da tela junto com a principal (o resto do encerramento é por trás).
pub fn esconder(app: *App) void {
    if (app.pip.win) |w| _ = c.SDL_HideWindow(w);
}

/// O botão de voltar: a principal aparece (até da bandeja) na conversa ou na call.
fn voltar(app: *App) void {
    switch (app.pip.alvo) {
        .conversa => |ch| app.handle(.{ .open_message = .{ .channel = ch, .id = 0 } }),
        .call => |ch| app.handle(.{ .show_call = ch }),
    }
    app.showWindow();
}

/// O lugar e o tamanho de agora vão para as configurações (o arquivo é gravado ao fechar
/// e ao sair do app).
fn lembrar(app: *App) void {
    const win = app.pip.win orelse return;
    var g: fl.Geo = .{ .w = 0, .h = 0 };
    _ = c.SDL_GetWindowPosition(win, &g.x, &g.y);
    _ = c.SDL_GetWindowSize(win, &g.w, &g.h);
    if (g.w <= 0 or g.h <= 0) return;
    const set = &app.st.settings;
    const v = fl.paraGuardar(fl.guardar(g, fl.lida(set.pip_x, set.pip_y, set.pip_w, set.pip_h), app.pip.posiciona));
    set.pip_x = v[0];
    set.pip_y = v[1];
    set.pip_w = v[2];
    set.pip_h = v[3];
}

/// A barra de cima (menos os botões da ponta) arrasta a janela.
fn hitTest(win: ?*c.SDL_Window, area: [*c]const c.SDL_Point, _: ?*anyopaque) callconv(.c) c.SDL_HitTestResult {
    var w: c_int = 0;
    _ = c.SDL_GetWindowSize(win, &w, null);
    const x: f32 = @floatFromInt(area.*.x);
    const y: f32 = @floatFromInt(area.*.y);
    if (y >= 0 and y < fl.topo_h * hit_escala and x < @as(f32, @floatFromInt(w)) - ui.botoes_w * hit_escala) return c.SDL_HITTEST_DRAGGABLE;
    return c.SDL_HITTEST_NORMAL;
}

/// O evento é da janela flutuante (o laço manda para `onEvent`, não para a principal).
pub fn owns(app: *const App, e: *const c.SDL_Event) bool {
    const win = app.pip.win orelse return false;
    return c.SDL_GetWindowFromEvent(e) == win;
}

pub fn onEvent(app: *App, e: *c.SDL_Event) void {
    const p = &app.pip;
    switch (e.type) {
        // O "fechar" da janela flutuante fecha só ela (nunca sai do app nem vai para a bandeja).
        c.SDL_EVENT_WINDOW_CLOSE_REQUESTED => return fechar(app, true),
        c.SDL_EVENT_WINDOW_RESIZED, c.SDL_EVENT_WINDOW_MOVED, c.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED => {
            lembrar(app);
            p.gate.redraw();
            p.pendentes = @max(p.pendentes, 2);
        },
        c.SDL_EVENT_WINDOW_EXPOSED, c.SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED, c.SDL_EVENT_WINDOW_SHOWN, c.SDL_EVENT_WINDOW_RESTORED => {
            p.gate.redraw();
            p.pendentes = @max(p.pendentes, 2);
        },
        c.SDL_EVENT_WINDOW_FOCUS_GAINED => {
            p.focada = true;
            p.estado.focus = true;
            p.pendentes = 3;
        },
        c.SDL_EVENT_WINDOW_FOCUS_LOST => {
            p.focada = false;
            p.pendentes = @max(p.pendentes, 2);
        },
        // O texto em conversão do IME (o backend do SDL3 não conhece): na caixinha dela.
        c.SDL_EVENT_TEXT_EDITING => {
            ui.preedit(&p.estado, e.edit.text);
            p.pendentes = 3;
            return;
        },
        c.SDL_EVENT_TEXT_INPUT => {
            p.estado.preedit_len = 0;
            p.pendentes = 3;
        },
        c.SDL_EVENT_MOUSE_MOTION => {
            // O mouse vem em coordenadas da janela; o ImGui trabalha em pontos.
            e.motion.x /= p.escala;
            e.motion.y /= p.escala;
            if (e.motion.state == 0) p.mouse = true else p.pendentes = 3;
        },
        c.SDL_EVENT_KEY_DOWN, c.SDL_EVENT_KEY_UP => {
            p.pendentes = 3;
            // Aperte para falar também com a janela flutuante em foco.
            if (voz_audio.onSdlEvent(e)) return;
        },
        // Arquivo arrastado: a bandeja de anexos é da caixa da principal.
        c.SDL_EVENT_DROP_BEGIN, c.SDL_EVENT_DROP_FILE, c.SDL_EVENT_DROP_TEXT, c.SDL_EVENT_DROP_POSITION, c.SDL_EVENT_DROP_COMPLETE => return,
        else => p.pendentes = 3,
    }
    const pctx = p.ctx orelse return;
    const main_ctx = c.ImGui_GetCurrentContext();
    c.ImGui_SetCurrentContext(pctx);
    _ = c.cImGui_ImplSDL3_ProcessEvent(e);
    c.ImGui_SetCurrentContext(main_ctx);
}

/// Algo que a vista mostra mudou fora dela (rede, ações, imagens que chegaram).
pub fn marcar(app: *App) void {
    if (app.pip.win != null) app.pip.mudou = true;
}

/// Ela precisa que o laço continue sem dormir (o mouse ou o teclado nela).
pub fn ocupada(app: *const App) bool {
    return app.pip.win != null and app.pip.pendentes > 0;
}

fn motivo(app: *const App, now_ms: i64) fl.Motivo {
    const p = &app.pip;
    return .{
        .pendentes = p.pendentes,
        .mudou = p.mudou,
        .mouse = p.mouse,
        .anim = p.anim_ativa,
        .agora_ms = now_ms,
        .ultimo_ms = p.ultimo_ms,
        .acordar_ms = p.acordar_ms,
    };
}

/// Até quando o laço pode dormir por causa dela (maxInt: fechada ou nada marcado).
pub fn proximo(app: *const App, now_ms: i64) i64 {
    if (app.pip.win == null) return std.math.maxInt(i64);
    return fl.proximo(motivo(app, now_ms));
}

/// As configurações e o que mais aparece nela sem passar pela rede nem por uma ação
/// (Configurações por cima, tema, idioma, mudo da call): um resumo barato, por quadro.
fn mudouFora(app: *App) bool {
    var h = std.hash.Wyhash.init(0);
    h.update(std.mem.asBytes(&app.st.settings));
    h.update(std.mem.asBytes(&app.themes.current));
    h.update(std.mem.asBytes(&app.themes.mode));
    h.update(&.{ app.st.theme_gen, @intFromBool(app.st.muted), @intFromBool(app.st.deafened), @intFromBool(app.qa_blur) });
    // O idioma, e o arquivo de tradução recarregado.
    const lang = i18n.stamp();
    h.update(std.mem.asBytes(&lang));
    h.update(std.mem.asBytes(&app.st.voice));
    const s = h.final();
    if (s == app.pip.resumo) return false;
    app.pip.resumo = s;
    return true;
}

/// Uma volta do laço: faz o quadro da janela flutuante se ela precisa. Devolve se ela
/// mexeu no app (ações), para a principal redesenhar.
pub fn talvez(app: *App, now_ms: i64) bool {
    const p = &app.pip;
    if (p.win == null) return false;
    if (!seguindo(app, p.alvo)) {
        fechar(app, true);
        return true;
    }
    if (mudouFora(app)) p.mudou = true;
    // No QA o roteiro manda o mouse e o teclado pelo contexto dela: um quadro por volta,
    // como na principal (menos quando ele confere os quadros parados de verdade).
    const sempre = (app.opts.qa and !app.qa_real_gate) or app.opts.shot != null;
    if (!sempre and !fl.precisa(motivo(app, now_ms))) return false;
    return frame(app, now_ms);
}

fn frame(app: *App, now_ms: i64) bool {
    const p = &app.pip;
    const viewer_before = app.st.viewer != null;
    if (!build(app, now_ms)) return false;
    // O que ela pediu, já com o contexto da principal de volta (uma ação pode mexer no
    // estilo, nas fontes ou fechar a própria janela flutuante): a resposta citada e a
    // imagem aberta vão para a principal.
    for (app.actions.items) |*a| switch (a.*) {
        .jump_to => |id| {
            a.* = .{ .open_message = .{ .channel = p.alvo.canal(), .id = id } };
            app.showWindow();
        },
        else => {},
    };
    if (!viewer_before and app.st.viewer != null) app.showWindow();
    if (app.actions.items.len == 0) return false;
    for (app.actions.items) |a| app.handle(a);
    app.actions.clearRetainingCapacity();
    marcar(app);
    return true;
}

/// Monta o quadro no contexto dela e, se a imagem mudou, desenha e põe na janela.
fn build(app: *App, now_ms: i64) bool {
    const p = &app.pip;
    const pctx = p.ctx orelse return false;
    const io = p.io orelse return false;
    const t0 = c.SDL_GetTicksNS();
    // Fontes pedidas num quadro anterior (desta, ou da principal escondida): fora do quadro.
    if (app.fonts.loadWanted()) {
        app.st.theme_gen +%= 1;
        app.trim_wanted.store(true, .release);
        app.gate.redraw();
        p.gate.redraw();
    }
    const main_ctx = c.ImGui_GetCurrentContext();
    const style = c.ImGui_GetStyle().*;
    const main_density = app.io.*.DisplayFramebufferScale.x;
    c.ImGui_SetCurrentContext(pctx);
    defer {
        c.ImGui_SetCurrentContext(main_ctx);
        app.fonts.setDensity(main_density);
        larper_ime_scale = app.uiScale();
    }
    // O tema da principal (cores, cantos, tamanho da fonte) vale aqui também.
    c.ImGui_GetStyle().* = style;
    p.escala = platform.contentScale(p.win.?) * app.ui_size;
    hit_escala = p.escala;
    larper_ime_scale = p.escala;
    c.cImGui_ImplSDLRenderer3_NewFrame();
    c.cImGui_ImplSDL3_NewFrame();
    io.*.DisplaySize.x /= p.escala;
    io.*.DisplaySize.y /= p.escala;
    io.*.DisplayFramebufferScale.x *= p.escala;
    io.*.DisplayFramebufferScale.y *= p.escala;
    app.fonts.setDensity(io.*.DisplayFramebufferScale.x);

    // O que é global no desenho fica com o desta janela durante o quadro dela: as
    // animações (o que ela pedir fica guardado nela), o foco que conta para ler a
    // conversa, o mascote (que mora na principal) e as marcas do QA ("pip/...").
    const a_active = anim.active;
    const a_wake = anim.next_wake_ms;
    const a_clock = anim.clock_wake_ms;
    const a_dt = anim.dt;
    const a_now = anim.now_ms;
    anim.active = false;
    anim.next_wake_ms = std.math.maxInt(i64);
    anim.clock_wake_ms = std.math.maxInt(i64);
    anim.dt = if (p.ultimo_ns == 0) 1.0 / 60.0 else std.math.clamp(@as(f32, @floatFromInt(t0 - p.ultimo_ns)) / 1e9, 0.001, 1.0 / 30.0);
    anim.now_ms = now_ms;
    // O próximo quadro dos GIFs dela e o "quadro novo na mesma textura" também.
    const img_next = app.images.next_frame_ms;
    const img_changed = app.images.texture_changed;
    app.images.next_frame_ms = std.math.maxInt(i64);
    app.images.texture_changed = false;
    const focused = app.st.window_focused;
    app.st.window_focused = if (app.opts.qa or app.opts.shot != null) !app.qa_blur else p.focada;
    const mascote_pet = @import("ui/mascote_pet.zig");
    const rich = @import("ui/rich.zig");
    mascote_pet.pausado = true;
    popup.claim(&app.st, false);

    c.ImGui_NewFrame();
    qa.setScope("pip/", .{});
    const th = app.customTheme();
    var ctx: d.Ctx = .{
        .th = th,
        .theme_name = app.themes.name(),
        .theme_names = app.themes.names.items,
        .theme_index = app.themes.current,
        .store = &app.store,
        .st = &app.st,
        .fonts = &app.fonts,
        .ui = app.textFamily(th, false),
        .mono = app.textFamily(th, true),
        .dl = undefined,
        .fg = undefined,
        .io = io,
        .mouse = io.*.MousePos,
        .now_ms = now_ms,
        .actions = &app.actions,
        .stats = &app.stats,
        .images = &app.images,
        .win = undefined,
        .pip = true,
    };
    rich.frame_ctx = &ctx;
    rich.emoji_images = @import("ui/emoji_img.zig").enabled(&ctx);
    d.opt_theme = th;
    ui.draw(&ctx, p.alvo, &p.estado);
    // O popup aberto aqui (o cartão de alguém da call, o menu do microfone, o mixer)
    // fica nesta janela, por cima do resto.
    popup.claim(&app.st, true);
    if (popup.in_pip) popup.draw(&ctx);
    qa.setScope("", .{});
    rich.frame_ctx = null;
    mascote_pet.pausado = false;
    c.ImGui_Render();

    p.anim_ativa = anim.active;
    p.acordar_ms = @min(@min(anim.next_wake_ms, anim.clock_wake_ms), app.images.next_frame_ms);
    const gif_changed = app.images.takeChanged();
    app.images.next_frame_ms = img_next;
    app.images.texture_changed = img_changed;
    anim.active = a_active;
    anim.next_wake_ms = a_wake;
    anim.clock_wake_ms = a_clock;
    anim.dt = a_dt;
    anim.now_ms = a_now;
    app.st.window_focused = focused;

    const dd = c.ImGui_GetDrawData();
    const bg = app.themes.theme_().c(.bg);
    // Opaca: a janela flutuante não é transparente como a principal pode ser.
    const clear = [4]f32{ bg.r, bg.g, bg.b, 1 };
    const always = (app.opts.qa and !app.qa_real_gate) or app.opts.shot != null or gif_changed or quadro.texturesDirty(dd);
    const show = p.gate.check(quadro.sum(dd, clear), always);
    if (show) present(app, dd, clear);

    if (p.pendentes > 0) p.pendentes -= 1;
    p.mudou = false;
    p.mouse = false;
    p.ultimo_ms = now_ms;
    p.ultimo_ns = t0;
    medidas.quadros += 1;
    if (show) medidas.desenhados += 1;
    medidas.us += (c.SDL_GetTicksNS() - t0) / 1000;
    return true;
}

/// Desenha na textura fora da tela, lê os pixels e põe na superfície da janela.
fn present(app: *App, dd: *c.ImDrawData, clear: [4]f32) void {
    const p = &app.pip;
    const win = p.win orelse return;
    const r = app.win.renderer orelse return;
    var pw: c_int = 0;
    var ph: c_int = 0;
    _ = c.SDL_GetWindowSizeInPixels(win, &pw, &ph);
    if (pw <= 0 or ph <= 0) return;
    if (p.tex == null or p.tex_w != pw or p.tex_h != ph) {
        if (p.tex) |t| c.SDL_DestroyTexture(t);
        p.tex = c.SDL_CreateTexture(r, c.SDL_PIXELFORMAT_ARGB8888, c.SDL_TEXTUREACCESS_TARGET, pw, ph);
        p.tex_w = pw;
        p.tex_h = ph;
    }
    const tex = p.tex orelse return;
    const prev = c.SDL_GetRenderTarget(r);
    if (!c.SDL_SetRenderTarget(r, tex)) return;
    // A escala vale só para a vista da textura (o SDL guarda uma por alvo).
    _ = c.SDL_SetRenderScale(r, dd.*.FramebufferScale.x, dd.*.FramebufferScale.y);
    _ = c.SDL_SetRenderDrawColorFloat(r, clear[0], clear[1], clear[2], clear[3]);
    _ = c.SDL_RenderClear(r);
    c.cImGui_ImplSDLRenderer3_RenderDrawData(dd, r);
    const px = c.SDL_RenderReadPixels(r, null);
    _ = c.SDL_SetRenderTarget(r, prev);
    const surf = px orelse return;
    defer c.SDL_DestroySurface(surf);
    const ws = c.SDL_GetWindowSurface(win) orelse return;
    _ = c.SDL_SetSurfaceBlendMode(surf, c.SDL_BLENDMODE_NONE);
    _ = c.SDL_BlitSurface(surf, null, ws, null);
    _ = c.SDL_UpdateWindowSurface(win);
}

/// A caixa da janela flutuante mandou: na conversa que ela segue, com as regras dos
/// plugins e o "@silent " como na caixa da principal (sem os anexos, que são de lá).
pub fn send(app: *App, ch: Id, text: []const u8) void {
    defer app.gpa.free(text);
    const cleaned = app.plugins.rewriteOutgoing(text);
    defer if (cleaned) |t| app.gpa.free(t);
    var body: []const u8 = cleaned orelse text;
    var opts: envio.SendOpts = .{};
    if (envio.stripSilent(body)) |rest| {
        opts.silent = true;
        body = rest;
    }
    if (body.len == 0) return;
    medidas.enviadas += 1;
    // Não dá para mandar agora (modo lento, conectando): o aviso sai e o texto volta.
    if (send_limits.blockForId(&app.store, ch, now()).reason != .none) {
        const e = &app.pip.estado;
        if (app.pip.alvo == .conversa and app.pip.alvo.canal() == ch and e.input[0] == 0) {
            const n = @min(text.len, e.input.len - 1);
            @memcpy(e.input[0..n], text[0..n]);
            e.sync = false;
        }
    }
    app.sendWithOpts(ch, body, 0, false, opts);
}

/// QA: o que está na janela flutuante, num PNG (a superfície dela tem o último quadro).
pub fn shot(app: *App, path: [*:0]const u8) bool {
    const win = app.pip.win orelse return false;
    const ws = c.SDL_GetWindowSurface(win) orelse return false;
    return c.SDL_SavePNG(ws, path);
}
