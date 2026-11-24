//! Monta o quadro: resolve o layout do tema, desenha os estilos dos nós,
//! chama cada componente pelo nome e cuida das sobreposições (paleta, aviso)
//! e dos atalhos de teclado.
const std = @import("std");
const c = @import("c");
const kdl = @import("../theme/kdl.zig");
const teclas = @import("teclas.zig");
const layout = @import("../theme/layout.zig");
const theme_mod = @import("../theme/theme.zig");
const d = @import("draw.zig");
const i18n = @import("i18n.zig");
const anim = @import("anim.zig");
const mascote = @import("mascote.zig");
const qa = @import("qa.zig");
const rail = @import("comp_rail.zig");
const channels = @import("comp_channels.zig");
const chat = @import("comp_chat.zig");
const msgs = @import("comp_messages.zig");
const popup = @import("popup.zig");
const side = @import("comp_side.zig");
const palette = @import("palette.zig");
const settings = @import("settings.zig");
const vim = @import("vim.zig");
const search = @import("search.zig");
const Preview = @import("../theme/manager.zig").Preview;

const extra = @import("comp_extra.zig");
const fx = @import("fx.zig");
const display = @import("display_text.zig");
const backdrop = @import("backdrop.zig");
const wallpaper = @import("wallpaper.zig");
const resize = @import("resize.zig");
const plugin_panel = @import("plugin_panel.zig");
const insp = @import("../inspect/captura.zig");
const video = @import("video.zig");

const Component = *const fn (*d.Ctx, *const kdl.Node, d.Rect) void;

const registry = std.StaticStringMap(Component).initComptime(.{
    .{ "guild-bar", rail.draw },
    .{ "channel-list", channels.channelList },
    .{ "user-panel", channels.userPanel },
    .{ "header", chat.header },
    .{ "tabs", chat.tabs },
    .{ "messages", msgs.messages },
    .{ "composer", msgs.composer },
    .{ "member-list", side.memberList },
    .{ "status-bar", side.statusBar },
    .{ "label", label },
    .{ "logo", extra.logo },
    .{ "topbar", extra.topbar },
    .{ "crt", extra.crt },
    .{ "shape", extra.shape },
    .{ "rule", extra.rule },
    .{ "window-controls", extra.windowControls },
    .{ "starfield", backdrop.draw },
    .{ "orbit", backdrop.draw },
    .{ "aurora", backdrop.draw },
    .{ "dunes", backdrop.draw },
    .{ "topography", backdrop.draw },
    .{ "radar", backdrop.draw },
    .{ "rain", backdrop.draw },
    .{ "matrix", backdrop.draw },
    .{ "waves", backdrop.draw },
    .{ "particles", backdrop.draw },
    .{ "wallpaper", wallpaper.draw },
    .{ "spacer", spacer },
});

fn spacer(_: *d.Ctx, _: *const kdl.Node, _: d.Rect) void {}

/// --stats: tempo gasto em cada componente (µs somados desde a última leitura).
pub var profile = false;
pub var prof_names: [24][]const u8 = undefined;
pub var prof_us: [24]u64 = @splat(0);
pub var prof_n: usize = 0;

fn profAdd(name: []const u8, us: u64) void {
    for (prof_names[0..prof_n], 0..) |nm, i| if (std.mem.eql(u8, nm, name)) {
        prof_us[i] += us;
        return;
    };
    if (prof_n == prof_names.len) return;
    prof_names[prof_n] = name;
    prof_us[prof_n] = us;
    prof_n += 1;
}

/// `label text="larperCord" size=14 weight=bold color=accent align=center`
fn label(ctx: *d.Ctx, n: *const kdl.Node, r: d.Rect) void {
    if (ctx.th.nodeFx(n)) |x| if (x.text) |tx| return display.label(ctx, n, r, tx);
    const t = d.pstr(n, "text", "");
    const fam = ctx.familyFor(n);
    const weight = std.meta.stringToEnum(d.Weight, d.pstr(n, "weight", "semibold")) orelse .semibold;
    const font = fam.get(weight);
    const size = d.pnum(n, "size", 14);
    const color = if (theme_mod.tokenFromName(d.pstr(n, "color", "muted"))) |tok| ctx.col(tok) else ctx.col(.muted);
    const tw = d.width(font, size, t);
    const x = if (d.is(n, "align", "center", "left")) r.x + (r.w - tw) / 2 else if (d.is(n, "align", "right", "left")) r.right() - tw - 10 else r.x + 10;
    d.text(ctx.dl, font, size, x, d.centerY(r, size), color, t);
}

fn hidden(ctx: *d.Ctx, name: []const u8) bool {
    const s = &ctx.st.settings;
    if (!s.show_member_list and std.mem.eql(u8, name, "member-list")) return true;
    if (!s.show_status_bar and std.mem.eql(u8, name, "status-bar")) return true;
    return false;
}

pub fn frame(ctx: *d.Ctx, placed: *std.ArrayList(layout.Placed), previews: []const Preview) void {
    const vp = c.ImGui_GetMainViewport();
    c.ImGui_SetNextWindowPos(vp.*.Pos, 0);
    c.ImGui_SetNextWindowSize(vp.*.Size, 0);
    _ = c.ImGui_Begin("##root", null, c.ImGuiWindowFlags_NoDecoration | c.ImGuiWindowFlags_NoMove |
        c.ImGuiWindowFlags_NoSavedSettings | c.ImGuiWindowFlags_NoBringToFrontOnFocus |
        c.ImGuiWindowFlags_NoBackground | c.ImGuiWindowFlags_NoScrollWithMouse | c.ImGuiWindowFlags_NoNav);
    ctx.dl = c.ImGui_GetWindowDrawList();
    ctx.fg = c.ImGui_GetForegroundDrawList();
    const rich = @import("rich.zig");
    rich.frame_ctx = ctx;
    rich.emoji_images = @import("emoji_img.zig").enabled(ctx);
    vim.beforeFrame(ctx.st);
    ctx.win = .{ .x = vp.*.Pos.x, .y = vp.*.Pos.y, .w = vp.*.Size.x, .h = vp.*.Size.y };
    // Inspetor encaixado: o app inteiro (layout e sobreposições) cabe no que sobra.
    ctx.win = @import("../inspect/doca.zig").reserve(ctx.win);

    d.opt_theme = ctx.th;
    fx.beginFrame();
    // Vídeo em tela cheia: só ele, e o resto do app nem é montado (nem gasta).
    if (video.fullscreen()) return videoFull(ctx);
    wallpaper.frame(ctx);
    if (ctx.th.layout) |root| {
        const Look = struct {
            fn get(p: *const anyopaque, name: []const u8) ?bool {
                const th: *const theme_mod.Theme = @ptrCast(@alignCast(p));
                return th.option(name);
            }
        };
        // O que o usuário desligou sai do layout (a conversa ocupa o espaço).
        var hides: [2][]const u8 = undefined;
        var n_hides: usize = 0;
        if (!ctx.st.settings.show_member_list) {
            hides[n_hides] = "member-list";
            n_hides += 1;
        }
        if (!ctx.st.settings.show_status_bar) {
            hides[n_hides] = "status-bar";
            n_hides += 1;
        }
        // Painel de plugin aberto: o tema inteiro cabe no que sobra da janela.
        const bounds = search.reserve(plugin_panel.reserve(ctx.win));
        // Largura dos painéis: a da pessoa, com a conversa sempre usável.
        var sizes = resize.sizes(&ctx.st.settings);
        layout.solveSized(ctx.st.gpa, root, bounds, bounds.w, .{ .ctx = ctx.th, .get = Look.get, .hides = hides[0..n_hides] }, &sizes, "messages", resize.min_chat, placed) catch {};
        resize.addPanels(ctx, placed.items, &sizes);
        const base_theme = ctx.th;
        defer ctx.th = base_theme;
        var local: theme_mod.Theme = undefined;
        // Papel de parede num tema sem lugar para ele: atrás de tudo, e os fundos dos
        // nós do layout com este alfa (o fundo procedural do tema sai da frente).
        const glass = wallpaper.behind(ctx, ctx.win);
        for (placed.items, 0..) |p, i| {
            // O Inspetor vê cada pedaço do layout (contêiner ou componente) com o que ele desenhou.
            const insp_scope = insp.scope(p.node.name, p.rect, p.node, p.depth, p.kind == .component);
            const insp_t0 = if (insp.recording()) c.SDL_GetTicksNS() else 0;
            defer insp.endScope(insp_scope, if (insp_t0 != 0) (c.SDL_GetTicksNS() - insp_t0) / 1000 else 0);
            // Cores sobrescritas neste pedaço do layout.
            ctx.th = base_theme;
            if (base_theme.node_colors.get(p.node)) |ovs| {
                local = base_theme.*;
                for (ovs) |o| local.colors.set(o.tok, o.color);
                ctx.th = &local;
            }
            const bg_start = ctx.dl.*.VtxBuffer.Size;
            // Fundo rápido pelo próprio nó: bg=sidebar radius=12
            if (p.node.str("bg")) |bg| if (theme_mod.tokenFromName(bg)) |tok|
                d.rect(ctx.dl, p.rect, ctx.col(tok), d.pnum(p.node, "radius", 0));
            if (ctx.th.style(p.node.str("style"))) |st| d.drawStyle(ctx, ctx.dl, st, p.rect, i);
            // Primitivas novas no próprio nó (gradiente, grão, borda por lado…).
            if (base_theme.nodeFx(p.node)) |x| fx.node(ctx, x, p.node, p.rect, i);
            if (glass) |k| wallpaper.glassVerts(ctx.dl, bg_start, k);
            if (p.kind != .component or hidden(ctx, p.node.name)) continue;
            if (glass != null and backdrop.isBackdrop(p.node.name)) continue;
            c.ImGui_PushIDPtr(p.node);
            defer c.ImGui_PopID();
            const inner = p.rect.inset(d.pnum(p.node, "inset-x", 0), d.pnum(p.node, "inset-y", 0));
            if (registry.get(p.node.name)) |draw| {
                const t0 = if (profile) c.SDL_GetTicksNS() else 0;
                // (Uma régua pode ter 1 pixel de altura.)
                if ((inner.w > 4 and inner.h > 4) or (draw == &extra.rule and inner.w > 0 and inner.h > 0)) draw(ctx, p.node, inner);
                // Os lugares aonde o mascote do canto pode ir passear.
                @import("mascote_pet.zig").component(p.node.name, inner, ctx.now_ms);
                if (profile) profAdd(p.node.name, (c.SDL_GetTicksNS() - t0) / 1000);
            } else unknown(ctx, p);
            if (d.pflag(p.node, "autohide", false)) autohide(ctx, p, i);
        }
    }
    // Por cima dos painéis, por baixo do que flutua (a lista do autocompletar).
    var sc = insp.scope("resize", ctx.win, null, 0, false);
    resize.submit(ctx);
    insp.endScope(sc, 0);
    sc = insp.scope("plugin-panel", ctx.win, null, 0, false);
    plugin_panel.draw(ctx);
    insp.endScope(sc, 0);
    sc = insp.scope("lsp", ctx.win, null, 0, false);
    @import("lsp_ui.zig").panel(ctx);
    insp.endScope(sc, 0);
    sc = insp.scope("autocomplete", ctx.win, null, 0, false);
    @import("autocomplete.zig").draw(ctx);
    insp.endScope(sc, 0);
    c.ImGui_End();

    const t1 = if (profile) c.SDL_GetTicksNS() else 0;
    // O popup aberto na janela flutuante é desenhado lá (app_flutuante.zig).
    popup.claim(ctx.st, false);
    // O editor de imagem fechou no quadro anterior: a textura e a imagem saem antes de
    // qualquer desenho deste.
    @import("editor_imagem.zig").varrer(ctx.st);
    sc = insp.scope("popup", ctx.win, null, 0, false);
    if (!popup.in_pip) popup.draw(ctx);
    insp.endScope(sc, 0);
    // Formulário de comando e modal de bot: por cima dos popups.
    sc = insp.scope("interact", ctx.win, null, 0, false);
    @import("interact.zig").draw(ctx);
    insp.endScope(sc, 0);
    sc = insp.scope("settings", ctx.win, null, 0, false);
    settings.draw(ctx, previews);
    insp.endScope(sc, 0);
    if (profile) profAdd("overlays", (c.SDL_GetTicksNS() - t1) / 1000);
    sc = insp.scope("viewer", ctx.win, null, 0, false);
    @import("attachments.zig").viewer(ctx);
    insp.endScope(sc, 0);
    sc = insp.scope("palette", ctx.win, null, 0, false);
    palette.draw(ctx);
    insp.endScope(sc, 0);
    sc = insp.scope("search", ctx.win, null, 0, false);
    search.draw(ctx);
    insp.endScope(sc, 0);
    sc = insp.scope("toast", ctx.win, null, 0, false);
    toast(ctx);
    insp.endScope(sc, 0);
    // Exportar conversa e salvar mídia: a resposta do seletor, o andamento e o resultado.
    sc = insp.scope("export", ctx.win, null, 0, false);
    @import("exportar.zig").frame(ctx);
    @import("exportar.zig").cards(ctx);
    insp.endScope(sc, 0);
    sc = insp.scope("banner", ctx.win, null, 0, false);
    connectionBanner(ctx);
    @import("aviso_atualizacao.zig").draw(ctx);
    insp.endScope(sc, 0);
    // Lembrete vencido: o aviso fica até alguém mexer (o mascote do canto, desenhado
    // logo depois, vem por cima dele trazer o bilhete).
    sc = insp.scope("reminder", ctx.win, null, 0, false);
    @import("lembretes.zig").notice(ctx);
    insp.endScope(sc, 0);
    sc = insp.scope("mascot", ctx.win, null, 0, false);
    @import("mascote_pet.zig").draw(ctx);
    insp.endScope(sc, 0);
    // Chamada chegando: por cima de tudo, em qualquer tema.
    sc = insp.scope("incoming-call", ctx.win, null, 0, false);
    @import("chamada.zig").overlay(ctx);
    insp.endScope(sc, 0);
    sc = insp.scope("shortcuts", ctx.win, null, 0, false);
    shortcuts(ctx);
    insp.endScope(sc, 0);
    // A conversão do IME num campo que não é a caixa do chat: por cima de tudo, no cursor dele.
    @import("ime.zig").floating(ctx);
    // O que abriu depois dos popups (Configurações, paleta, atalhos) também é desta janela.
    popup.claim(ctx.st, false);
}

/// O quadro com o vídeo em tela cheia (ui/video.zig): ele por cima de tudo, com o teclado
/// dele. Por cima dele, só o aviso passageiro e a chamada chegando; dos atalhos, ficam o
/// mudo e o ensurdecer (os outros abririam coisas por baixo do vídeo).
fn videoFull(ctx: *d.Ctx) void {
    c.ImGui_End();
    popup.claim(ctx.st, false);
    @import("editor_imagem.zig").varrer(ctx.st);
    var sc = insp.scope("video", ctx.win, null, 0, false);
    video.drawFull(ctx);
    insp.endScope(sc, 0);
    sc = insp.scope("toast", ctx.win, null, 0, false);
    toast(ctx);
    insp.endScope(sc, 0);
    sc = insp.scope("incoming-call", ctx.win, null, 0, false);
    @import("chamada.zig").overlay(ctx);
    insp.endScope(sc, 0);
    const kb = &ctx.st.teclas;
    if (teclas.pressed(kb, ctx.io, .mutar, false)) ctx.act(.toggle_mute);
    if (teclas.pressed(kb, ctx.io, .ensurdecer, false)) ctx.act(.toggle_deafen);
    popup.claim(ctx.st, false);
}

/// `autohide`: o componente some (fica quase invisível) até o mouse chegar
/// perto. Um véu da cor do fundo por cima faz o papel de "transparência".
fn autohide(ctx: *d.Ctx, p: layout.Placed, i: usize) void {
    const near = p.rect.inset(-48, -48).contains(ctx.mouse.x, ctx.mouse.y) or ctx.st.popup != .none;
    const k = anim.to(anim.id("autohide", i), if (near) 1 else 0, 10);
    if (k > 0.98) return;
    // Escondido atrás do véu: o mascote do canto não vai até lá.
    @import("mascote_pet.zig").veiled(p.node.name, ctx.now_ms);
    d.rect(ctx.fg, p.rect, ctx.col(.bg).alpha(0.9 * (1 - k)), 0);
    // Escondido, fica um tracinho na beirada dizendo que tem algo ali.
    const hx = if (p.rect.x - ctx.win.x < ctx.win.right() - p.rect.right()) p.rect.x + 5 else p.rect.right() - 8;
    d.rect(ctx.fg, .{ .x = hx, .y = p.rect.y + p.rect.h / 2 - 22, .w = 3, .h = 44 }, ctx.col(.faint).alpha(0.7 * (1 - k)), 1.5);
}

fn unknown(ctx: *d.Ctx, p: layout.Placed) void {
    // Ajuda quem está escrevendo um tema: mostra o nome que não existe.
    d.border(ctx.dl, p.rect, ctx.col(.danger), 4, 2);
    var buf: [96]u8 = undefined;
    const t = i18n.fmt(&buf, "componente desconhecido: {s} (linha {d})", "unknown component: {s} (line {d})", .{ p.node.name, p.node.line });
    d.text(ctx.dl, ctx.ui.get(.semibold), 13, p.rect.x + 8, p.rect.y + 6, ctx.col(.danger), t);
}

fn toast(ctx: *d.Ctx) void {
    const t = &ctx.st.toast;
    const k = anim.to(anim.id("toast", 0), if (ctx.now_ms < t.until_ms) 1 else 0, 14);
    // Parado na tela não precisa de quadros; só acorda para sumir.
    if (ctx.now_ms < t.until_ms) anim.at(t.until_ms);
    if (k < 0.01) return;
    const font = ctx.ui.get(.semibold);
    const fs: f32 = 14;
    const tw = d.width(font, fs, t.text());
    const r: d.Rect = .{ .x = ctx.win.x + (ctx.win.w - tw - 36) / 2, .y = ctx.win.y + 14 - (1 - k) * 10, .w = tw + 36, .h = 34 };
    d.shadow(ctx.fg, r, 17, 12, ctx.col(.shadow).alpha(k));
    d.rect(ctx.fg, r, (if (t.is_error) ctx.col(.danger) else ctx.col(.overlay)).alpha(k), 17);
    if (!t.is_error) d.border(ctx.fg, r, ctx.col(.accent).alpha(0.6 * k), 17, 1);
    d.text(ctx.fg, font, fs, r.x + 18, d.centerY(r, fs), (if (t.is_error) d.Rgba.white else ctx.col(.text)).alpha(k), t.text());
}

/// Caiu a conexão (fora do demo, depois de conectar): um aviso pequeno no topo,
/// com o mascote digitando "..." enquanto reconecta, ou preocupado sem rede. Só
/// depois de 1,5 s, para uma queda rápida não piscar na tela.
/// O QA mostra o aviso na demonstração (que nunca perde a conexão de verdade).
pub var qa_banner = false;

fn connectionBanner(ctx: *d.Ctx) void {
    const conn = ctx.store.connection;
    const down = ctx.store.ready and (!ctx.store.demo or qa_banner) and (conn == .reconnecting or conn == .offline or conn == .failed);
    if (!down) return;
    const since = mascote.age(.offline, ctx.now_ms);
    if (since < 1.5) {
        anim.at(ctx.now_ms + @as(i64, @intFromFloat((1.5 - since) * 1000)) + 5);
        return;
    }
    const k = std.math.clamp((since - 1.5) / 0.25, 0, 1);
    if (k < 1) anim.at(ctx.now_ms + 16);
    const font = ctx.ui.get(.semibold);
    const fs: f32 = 13.5;
    const text = switch (conn) {
        .reconnecting => i18n.tr("Reconectando ao Discord…", "Reconnecting to Discord…"),
        .failed => i18n.tr("Não deu para conectar ao Discord.", "Couldn't connect to Discord."),
        else => i18n.tr("Sem conexão. Tentando de novo…", "No connection. Trying again…"),
    };
    const tw = d.width(font, fs, text);
    const toast_on = ctx.now_ms < ctx.st.toast.until_ms;
    const r: d.Rect = .{ .x = ctx.win.x + (ctx.win.w - tw - 64) / 2, .y = ctx.win.y + (if (toast_on) @as(f32, 56) else 14) - (1 - k) * 10, .w = tw + 64, .h = 38 };
    qa.markTop(r, "conn-banner", .{});
    d.shadow(ctx.fg, r, 19, 12, ctx.col(.shadow).alpha(k));
    d.rect(ctx.fg, r, ctx.col(.overlay).alpha(k), 19);
    d.border(ctx.fg, r, (if (conn == .reconnecting) ctx.col(.idle) else ctx.col(.danger)).alpha(0.7 * k), 19, 1);
    mascote.inApp(ctx, ctx.fg, r.x + 24, r.y + r.h / 2 + 1, 34, if (conn == .reconnecting) .loading else .offline, .offline, 20);
    d.text(ctx.fg, font, fs, r.x + 46, d.centerY(r, fs), ctx.col(.text).alpha(k), text);
}

/// A lista que as configurações e o site mostram fica em ui/atalhos.zig: mudou
/// uma tecla aqui, mude lá também.
fn shortcuts(ctx: *d.Ctx) void {
    const io = ctx.io;
    const ctrl = io.*.KeyCtrl;
    if (c.ImGui_IsKeyPressed(c.ImGuiKey_Escape) and ctx.st.popup == .none and !ctx.st.selection.empty()) ctx.st.selection = .{};
    // Trocando um atalho em Configurações: a tecla é para a troca, não para disparar.
    // (Fora da página de atalhos, não há troca nenhuma esperando.)
    if (!ctx.st.settings.open or ctx.st.settings.page != .atalhos) teclas.capturing = null;
    if (teclas.busy()) return;
    if (ctrl) zoomKeys(ctx);
    // Os que dá para trocar (Configurações → Atalhos de teclado): a combinação de cada
    // ação vem de ui/atalhos.zig, a trocada ou a do padrão.
    const kb = &ctx.st.teclas;
    const K = struct {
        fn on(k: *const @import("atalhos.zig").Personalizados, x: *c.ImGuiIO, a: teclas.Acao, repeat: bool) bool {
            return teclas.pressed(k, x, a, repeat);
        }
    };
    if (K.on(kb, io, .tela_cheia, false)) ctx.act(.toggle_fullscreen);
    if (K.on(kb, io, .reiniciar, false)) ctx.act(.restart);
    if (K.on(kb, io, .inspetor, false)) @import("../inspect/ui.zig").toggle();
    if (K.on(kb, io, .inspetor_selecionar, false)) @import("../inspect/ui.zig").startPick();
    if (K.on(kb, io, .configuracoes, true)) ctx.act(if (ctx.st.settings.open) .close_settings else .open_settings);
    if (K.on(kb, io, .paleta, true)) {
        palette.commands_first = false;
        ctx.act(if (ctx.st.palette.open) .close_palette else .open_palette);
    }
    // A mesma paleta, com as ações primeiro.
    if (K.on(kb, io, .paleta_acoes, true)) {
        palette.commands_first = true;
        ctx.act(if (ctx.st.palette.open) .close_palette else .open_palette);
    }
    vim.keys(ctx);
    if (K.on(kb, io, .buscar, true) and !ctx.st.settings.open) search.toggle();
    if (K.on(kb, io, .proximo_tema, true)) ctx.act(.{ .next_theme = 1 });
    if (K.on(kb, io, .tema_anterior, true)) ctx.act(.{ .next_theme = -1 });
    // Uma troca por toque: segurar não sai trocando de aba em rajada.
    if (K.on(kb, io, .proxima_aba, false)) ctx.act(.{ .next_tab = 1 });
    if (K.on(kb, io, .aba_anterior, false)) ctx.act(.{ .next_tab = -1 });
    if (K.on(kb, io, .fechar_aba, true)) ctx.act(.{ .close_tab = ctx.st.tab });
    // Conjuntos de abas (app_conjuntos.zig): um por toque, como as abas.
    if (K.on(kb, io, .proximo_conjunto, false)) ctx.act(.{ .conjunto = .next });
    // Caixa de entrada e mensagens salvas (ui/inbox.zig, ui/saved.zig).
    if (K.on(kb, io, .caixa_entrada, true) and !ctx.st.settings.open) ctx.act(.toggle_inbox);
    if (K.on(kb, io, .salvas, true) and !ctx.st.settings.open) ctx.act(.toggle_saved);
    // Mudo e ensurdecer (as dicas dos botões mostram a combinação de agora).
    if (K.on(kb, io, .mutar, false)) ctx.act(.toggle_mute);
    if (K.on(kb, io, .ensurdecer, false)) ctx.act(.toggle_deafen);
    // Gravar áudio na caixa (ou, gravando, enviar): quem atende é o botão dela.
    if (K.on(kb, io, .gravar_audio, false) and !ctx.st.settings.open) @import("gravar_audio.zig").shortcut();
    if (io.*.KeyAlt) {
        const keys = [_]c_int{ c.ImGuiKey_1, c.ImGuiKey_2, c.ImGuiKey_3, c.ImGuiKey_4, c.ImGuiKey_5, c.ImGuiKey_6, c.ImGuiKey_7, c.ImGuiKey_8, c.ImGuiKey_9 };
        for (keys, 0..) |k, i| if (c.ImGui_IsKeyPressed(k)) ctx.act(.{ .focus_tab = i });
    }
}

/// Ctrl + , Ctrl - e Ctrl 0: a interface inteira, como no navegador e no Discord.
fn zoomKeys(ctx: *d.Ctx) void {
    const set = &ctx.st.settings;
    const before = set.ui_scale;
    if (c.ImGui_IsKeyPressedEx(c.ImGuiKey_Equal, false) or c.ImGui_IsKeyPressedEx(c.ImGuiKey_KeypadAdd, false)) set.ui_scale += 0.1;
    if (c.ImGui_IsKeyPressedEx(c.ImGuiKey_Minus, false) or c.ImGui_IsKeyPressedEx(c.ImGuiKey_KeypadSubtract, false)) set.ui_scale -= 0.1;
    if (c.ImGui_IsKeyPressedEx(c.ImGuiKey_0, false) or c.ImGui_IsKeyPressedEx(c.ImGuiKey_Keypad0, false)) set.ui_scale = 1;
    if (set.ui_scale == before) return;
    set.ui_scale = std.math.clamp(@round(set.ui_scale * 20) / 20, 0.75, 2);
    ctx.st.showToast(ctx.now_ms, false, "interface em {d:.0}%", "interface at {d:.0}%", .{set.ui_scale * 100});
    ctx.act(.save_settings);
}
