//! O aviso de versão nova (core/aviso_versao.zig decide quando): uma faixa no topo
//! que fica até a pessoa fechar, com "Atualizar agora", o progresso e "Reiniciar
//! agora" quando a versão nova já está instalada; e um pontinho no botão das
//! configurações enquanto houver o que atualizar. A faixa é uma janela própria do
//! ImGui, como o aviso de chamada: recebe o clique sem tirar o foco da caixa de texto.
const std = @import("std");
const c = @import("c");
const d = @import("draw.zig");
const anim = @import("anim.zig");
const qa = @import("qa.zig");
const i18n = @import("i18n.zig");
const updater = @import("../net/updater.zig");
const aviso = @import("../core/aviso_versao.zig");

/// A versão cuja faixa a pessoa fechou (vale até o app abrir de novo).
var fechada_buf: [32]u8 = @splat(0);
var fechada_len: usize = 0;
/// "Atualizar agora" foi clicado: um erro depois disso aparece na faixa.
pub var tentou = false;

pub fn fase(s: *const updater.Status) aviso.Fase {
    return switch (s.phase) {
        .available => .disponivel,
        .downloading => .baixando,
        .ready => .pronta,
        .failed => .falhou,
        .idle, .checking, .up_to_date => .nada,
    };
}

/// Há o que atualizar (o pontinho no botão das configurações).
pub fn pendente() bool {
    const s = updater.snapshot();
    return aviso.ponto(fase(&s));
}

/// O pontinho, no canto de cima à direita do botão `r`.
pub fn ponto(ctx: *d.Ctx, dl: *c.ImDrawList, r: d.Rect) void {
    if (!pendente()) return;
    d.circle(dl, r.right() - 5, r.y + 5, 4.5, ctx.col(.bg));
    d.circle(dl, r.right() - 5, r.y + 5, 3, ctx.col(.accent));
}

pub fn draw(ctx: *d.Ctx) void {
    const s = updater.snapshot();
    const f = fase(&s);
    const na_pagina = ctx.st.settings.open and ctx.st.settings.page == .atualizacoes;
    if (!aviso.faixa(f, s.latest(), fechada_buf[0..fechada_len], tentou, na_pagina)) return;

    var mb: [120]u8 = undefined;
    const text: []const u8 = switch (f) {
        .disponivel => i18n.fmt(&mb, "Versão nova do larperCord: {s}", "New larperCord version: {s}", .{s.latest()}),
        .baixando => i18n.fmt(&mb, "Baixando {s}… {d}%", "Downloading {s}… {d}%", .{ s.latest(), s.percent }),
        .pronta => i18n.fmt(&mb, "{s} instalada. Reinicie para usar.", "{s} installed. Restart to use it.", .{s.latest()}),
        .falhou => i18n.tr("A atualização não deu certo.", "The update didn't work."),
        .nada => return,
    };
    // O botão da vez: instalar, reiniciar, ou abrir a página (gerenciador de pacotes, erro).
    const gerenciado = updater.managedBySystem();
    const acao: ?[]const u8 = switch (f) {
        .disponivel => if (gerenciado) i18n.tr("Como atualizar", "How to update") else i18n.tr("Atualizar agora", "Update now"),
        .pronta => i18n.tr("Reiniciar agora", "Restart now"),
        .falhou => i18n.tr("Ver o motivo", "See why"),
        .baixando, .nada => null,
    };
    if (f == .baixando) anim.every(200);

    const font = ctx.ui.get(.semibold);
    const fs: f32 = 13.5;
    const bf = ctx.ui.get(.medium);
    const bfs: f32 = 13;
    const tw = d.width(font, fs, text);
    const bw: f32 = if (acao) |a| d.width(bf, bfs, a) + 24 else 0;
    const h: f32 = 40;
    const w = @min(ctx.win.w - 32, 40 + tw + (if (acao != null) bw + 12 else 0) + 38);
    // Abaixo do toast e do aviso de conexão caída, quando eles estão na tela.
    const toast_on = ctx.now_ms < ctx.st.toast.until_ms;
    const conn = ctx.store.connection;
    const conn_down = ctx.store.ready and !ctx.store.demo and (conn == .reconnecting or conn == .offline or conn == .failed);
    const y = ctx.win.y + 14 + (if (toast_on) @as(f32, 42) else 0) + (if (conn_down) @as(f32, 46) else 0);
    const box: d.Rect = .{ .x = ctx.win.x + (ctx.win.w - w) / 2, .y = y, .w = w, .h = h };

    // A janela é só do tamanho da faixa (o clique em volta continua indo para o que
    // está embaixo); o desenho vai na camada de cima, com a sombra fora dela.
    c.ImGui_SetNextWindowPos(d.v(box.x, box.y), 0);
    c.ImGui_SetNextWindowSize(d.v(box.w, box.h), 0);
    _ = c.ImGui_Begin("##aviso-atualizacao", null, c.ImGuiWindowFlags_NoDecoration | c.ImGuiWindowFlags_NoBackground |
        c.ImGuiWindowFlags_NoSavedSettings | c.ImGuiWindowFlags_NoMove | c.ImGuiWindowFlags_NoScrollWithMouse | c.ImGuiWindowFlags_NoNav |
        c.ImGuiWindowFlags_NoFocusOnAppearing);
    defer c.ImGui_End();
    d.windowToFront();
    const dl = ctx.fg;
    const k = anim.to(anim.id("aviso-atualizacao", 0), 1, 16);
    const r: d.Rect = .{ .x = box.x, .y = box.y - (1 - k) * 10, .w = box.w, .h = box.h };
    qa.markTop(r, "update-banner:{t}", .{f});
    d.shadow(dl, r, h / 2, 12, ctx.col(.shadow).alpha(k));
    d.rect(dl, r, ctx.col(.overlay).alpha(k), h / 2);
    d.border(dl, r, (if (f == .falhou) ctx.col(.danger) else ctx.col(.accent)).alpha(0.7 * k), h / 2, 1);
    // A setinha para cima, desenhada (não depende de a fonte ter o glifo).
    const ax = r.x + 22;
    const ay = r.y + h / 2;
    const ink = (if (f == .falhou) ctx.col(.danger) else ctx.col(.accent)).alpha(k);
    d.line(dl, ax, ay + 6, ax, ay - 6, ink, 2);
    d.line(dl, ax - 5, ay - 1, ax, ay - 6, ink, 2);
    d.line(dl, ax + 5, ay - 1, ax, ay - 6, ink, 2);
    const text_w = r.w - 40 - (if (acao != null) bw + 12 else 0) - 38;
    _ = d.textClipped(dl, font, fs, r.x + 40, d.centerY(r, fs), ctx.col(.text).alpha(k), text, text_w);

    // O botão da vez.
    if (acao) |label| {
        const br: d.Rect = .{ .x = r.right() - 38 - bw, .y = r.y + 7, .w = bw, .h = h - 14 };
        const hb = d.hit(ctx, 1, br);
        qa.markTop(br, "update-banner-action", .{});
        const hk = anim.to(anim.id("aviso-atualizacao-btn", 0), if (hb.hovered) 1 else 0, 24);
        d.rect(dl, br, ctx.col(.accent).mix(d.Rgba.white, 0.12 * hk).alpha(k), br.h / 2);
        d.text(dl, bf, bfs, br.x + 12, d.centerY(br, bfs), d.Rgba.white.alpha(k), label);
        if (hb.clicked) switch (f) {
            .disponivel => if (gerenciado) abrirPagina(ctx) else {
                tentou = true;
                updater.install();
            },
            .pronta => ctx.act(.restart),
            .falhou => abrirPagina(ctx),
            .baixando, .nada => {},
        };
    }
    // Fechar: até o app abrir de novo, ou até sair outra versão.
    const xr: d.Rect = .{ .x = r.right() - 32, .y = r.y + (h - 24) / 2, .w = 24, .h = 24 };
    const xh = d.hit(ctx, 2, xr);
    qa.markTop(xr, "update-banner-close", .{});
    d.tip(ctx, xr, i18n.tr("Fechar (o pontinho nas configurações fica)", "Close (the dot on settings stays)"), xh.hovered);
    if (xh.hovered) d.circle(dl, xr.x + 12, xr.y + 12, 12, ctx.col(.hover).alpha(k));
    const xc = ctx.col(.muted).alpha(k);
    d.line(dl, xr.x + 8, xr.y + 8, xr.x + 16, xr.y + 16, xc, 1.6);
    d.line(dl, xr.x + 16, xr.y + 8, xr.x + 8, xr.y + 16, xc, 1.6);
    if (xh.clicked) {
        const v = s.latest();
        fechada_len = @min(v.len, fechada_buf.len);
        @memcpy(fechada_buf[0..fechada_len], v[0..fechada_len]);
        if (f == .falhou) tentou = false;
    }
}

fn abrirPagina(ctx: *d.Ctx) void {
    ctx.st.settings.page = .atualizacoes;
    ctx.act(.open_settings);
}
