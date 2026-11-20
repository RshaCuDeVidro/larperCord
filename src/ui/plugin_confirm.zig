//! A pergunta antes de um plugin apagar uma mensagem ou abrir o seletor de arquivos
//! (larper.delete e larper.attach, ver src/plugins/host.zig): no meio da tela, com o
//! nome do plugin e o que ele quer fazer. Só a pessoa decide; o plugin nem fica
//! sabendo do arquivo escolhido.
const std = @import("std");
const c = @import("c");
const d = @import("draw.zig");
const qa = @import("qa.zig");
const i18n = @import("i18n.zig");
const inbox = @import("inbox.zig");
const forum = @import("forum.zig");
const popup = @import("popup.zig");
const state = @import("state.zig");
const types = @import("../core/types.zig");
const Id = types.Id;

pub const Ask = union(enum) {
    /// A mensagem a apagar.
    delete: Id,
    /// O canal em cuja caixa o arquivo vai entrar.
    attach: Id,
};

var pending: ?Ask = null;
var who_buf: [64]u8 = undefined;
var who_len: usize = 0;
/// Muda a cada pergunta (a animação de abrir recomeça).
var serial: u32 = 0;
/// QA: quantas vezes o "Escolher arquivo" chamou o seletor (que no QA não abre).
pub var qa_picks: u32 = 0;

/// Abre a pergunta (troca a que estiver aberta: o gesto acabou de acontecer).
pub fn ask(st: *state.State, what: Ask, plugin_title: []const u8) void {
    pending = what;
    who_len = d.utf8Prefix(plugin_title, who_buf.len).len;
    @memcpy(who_buf[0..who_len], plugin_title[0..who_len]);
    serial +%= 1;
    st.popup = .plugin_confirm;
}

/// O que está esperando a pessoa (o QA confere).
pub fn current() ?Ask {
    return pending;
}

pub fn key() u64 {
    return serial;
}

fn close(ctx: *d.Ctx) void {
    pending = null;
    popup.close(ctx);
}

pub fn draw(ctx: *d.Ctx) void {
    const what = pending orelse return popup.close(ctx);
    const who = who_buf[0..who_len];
    const r = forum.dialogRect(ctx, 460, 268);
    const dl = popup.beginWindow("##plugin-confirm", r);
    defer c.ImGui_End();
    ctx.dl = dl;
    inbox.panelFrame(ctx, dl, r);
    qa.mark(r, "plugin-confirm", .{});
    const fam = ctx.ui;
    var tb: [400]u8 = undefined;
    var y = r.y + 16;
    switch (what) {
        .delete => |id| {
            const f = ctx.store.findAny(id) orelse return close(ctx);
            if (f.m.deleted) return close(ctx);
            d.text(dl, fam.get(.bold), 17, r.x + 18, y, ctx.col(.text), i18n.tr("Apagar esta mensagem?", "Delete this message?"));
            y += 34;
            y += inbox.wrapText(dl, fam.get(.regular), 13, r.x + 18, y, r.w - 36, i18n.fmt(&tb, "O plugin {s} pediu para apagar a mensagem abaixo. Não dá para desfazer.", "The plugin {s} asked to delete the message below. This can't be undone.", .{who}), 3, ctx.col(.muted)) + 10;
            // A mensagem, para a pessoa ver o que vai sumir.
            const box: d.Rect = .{ .x = r.x + 18, .y = y, .w = r.w - 36, .h = r.bottom() - 64 - y };
            d.rect(dl, box, ctx.col(.rail).mix(ctx.col(.surface), 0.35), @max(ctx.th.radius, 4));
            const author = if (ctx.store.user(f.m.msg.author)) |u| u.name else "?";
            d.text(dl, fam.get(.semibold), 13, box.x + 10, box.y + 8, ctx.col(.text), d.utf8Prefix(author, 48));
            _ = inbox.wrapText(dl, fam.get(.regular), 13, box.x + 10, box.y + 28, box.w - 20, f.m.msg.content, 3, ctx.col(.muted));
        },
        .attach => |ch| {
            const cs = ctx.store.channel(ch) orelse return close(ctx);
            d.text(dl, fam.get(.bold), 17, r.x + 18, y, ctx.col(.text), i18n.tr("Escolher um arquivo?", "Choose a file?"));
            y += 34;
            y += inbox.wrapText(dl, fam.get(.regular), 13, r.x + 18, y, r.w - 36, i18n.fmt(&tb, "O plugin {s} pediu para anexar um arquivo em #{s}.", "The plugin {s} asked to attach a file in #{s}.", .{ who, d.utf8Prefix(cs.info.name, 60) }), 3, ctx.col(.muted)) + 8;
            _ = inbox.wrapText(dl, fam.get(.regular), 13, r.x + 18, y, r.w - 36, i18n.tr("Você escolhe o arquivo, e ele fica na caixa de mensagem até você enviar. O plugin não fica sabendo qual foi.", "You pick the file, and it waits in the message box until you send it. The plugin never learns which one."), 4, ctx.col(.faint));
        },
    }

    const go_lbl = switch (what) {
        .delete => i18n.tr("Apagar", "Delete"),
        .attach => i18n.tr("Escolher arquivo…", "Choose file…"),
    };
    const gw = inbox.buttonWidth(ctx, go_lbl);
    const gr: d.Rect = .{ .x = r.right() - 18 - gw, .y = r.bottom() - 46, .w = gw, .h = 30 };
    qa.mark(gr, "plugin-confirm-yes", .{});
    const go = switch (what) {
        .delete => inbox.button(ctx, dl, 0x7300, gr, go_lbl, true),
        .attach => forum.primary(ctx, dl, fam, 0x7300, gr, go_lbl, true),
    };
    const cancel = i18n.tr("Cancelar", "Cancel");
    const cw = inbox.buttonWidth(ctx, cancel);
    const cr: d.Rect = .{ .x = gr.x - cw - 10, .y = gr.y + 1, .w = cw, .h = 28 };
    qa.mark(cr, "plugin-confirm-no", .{});
    if (inbox.button(ctx, dl, 0x7301, cr, cancel, false)) return close(ctx);
    if (!go) return;
    close(ctx);
    switch (what) {
        .delete => |id| ctx.act(.{ .delete_message = id }),
        .attach => {
            if (qa.on()) qa_picks +%= 1;
            ctx.act(.pick_files);
        },
    }
}
