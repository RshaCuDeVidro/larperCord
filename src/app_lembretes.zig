//! Lembretes do lado do app (core/lembretes.zig, ui/lembretes.zig): criar, editar,
//! adiar, concluir, excluir, ir para a mensagem, e a hora de cada um. O laço não fica
//! conferindo: dorme até o próximo vencimento (`wakeAt`), como faz com o tempo das
//! calls. Quando um vence, o aviso aparece na tela, o mascote do canto leva o bilhete
//! até ele e, com a janela sem foco ou escondida na bandeja, sai a notificação do
//! sistema pelo mesmo caminho das DMs (fora do "Não perturbe"). O que venceu com o app
//! fechado avisa ao abrir, como "lembrete atrasado".
const std = @import("std");
const c = @import("c");
const App = @import("app.zig").App;
const core = @import("core/lembretes.zig");
const ui = @import("ui/lembretes.zig");
const saved_ui = @import("ui/saved.zig");
const i18n = @import("ui/i18n.zig");
const nowMs = @import("net/fake_gateway.zig").nowMs;

/// O próximo vencimento que ainda vai avisar (ms do relógio dos lembretes), refeito a
/// cada mudança na lista; null = nenhum. O laço olha isto a cada volta, sem percorrer
/// a lista.
var next_ms: ?i64 = null;

fn refresh(app: *App) void {
    next_ms = app.st.lembretes.nextWake();
}

/// Grava o arquivo (os prints da documentação não gravam nada).
fn persist(app: *App) void {
    refresh(app);
    if (app.opts.shot != null) return;
    ui.persist(&app.st.lembretes, app.gpa);
}

/// Os lembretes da conta que entrou. O QA e os prints começam sem nenhum; o QA lê o
/// arquivo com QA_LEMBRETES_READ (a bateria que confere o que ficou gravado ao fechar).
pub fn load(app: *App) void {
    if (app.store.me == 0) return;
    const read = if (app.opts.qa) c.SDL_getenv("QA_LEMBRETES_READ") != null else app.opts.shot == null;
    ui.load(&app.st.lembretes, app.gpa, app.store.me, read);
    refresh(app);
}

/// Saiu da conta: a lista vai embora (a da próxima conta vem do arquivo dela).
pub fn reset(app: *App) void {
    app.st.lembretes.clear(app.gpa);
    app.st.lembretes.owner = 0;
    next_ms = null;
}

/// Quando o laço precisa acordar, no relógio de verdade (ms); maxInt = nunca.
pub fn wakeAt() i64 {
    const n = next_ms orelse return std.math.maxInt(i64);
    // (No QA o relógio dos lembretes anda na frente: `clock(0)` é o quanto.)
    return n -| ui.clock(0);
}

/// Quantos venceram e não foram concluídos.
pub fn dueNow(app: *const App) usize {
    return app.st.lembretes.dueCount(ui.clock(nowMs()));
}

/// Venceu algum? O aviso aparece (o próximo quadro desenha), o mascote sai com o
/// bilhete e, sem ninguém olhando, sai a notificação. true: a tela muda.
pub fn check(app: *App) bool {
    const due = next_ms orelse return false;
    const now = ui.clock(nowMs());
    if (now < due) return false;
    const l = &app.st.lembretes;
    var ids: [32]u32 = undefined;
    const n = l.fire(now, &ids);
    // (Mais de 32 de uma vez: os outros vencem de novo na próxima volta.)
    refresh(app);
    if (n == 0) return false;
    ui.fired_n +%= @intCast(n);
    @import("ui/mascote_pet.zig").onReminder(nowMs());
    if (l.find(ids[0])) |r| notify(app, r, n);
    return true;
}

/// A janela pisca na barra de tarefas e sai a notificação do sistema (notify-send no
/// Linux, o aviso da bandeja no Windows), só com a janela sem foco ou escondida, com as
/// notificações ligadas e fora do "Não perturbe".
fn notify(app: *App, r: *const core.Reminder, n: usize) void {
    const set = &app.st.settings;
    const flags = c.SDL_GetWindowFlags(app.win.window);
    const hidden = app.in_tray or flags & c.SDL_WINDOW_HIDDEN != 0;
    // O QA roda fora da tela, sem foco de verdade: vale o "faz de conta" dele.
    const focused = !hidden and if (app.opts.qa) !app.qa_blur else flags & c.SDL_WINDOW_INPUT_FOCUS != 0;
    const dnd = if (app.store.user(app.store.me)) |u| u.status == .dnd else false;
    if (!app.opts.qa and set.taskbar_flash and !focused and !hidden) _ = c.SDL_FlashWindow(app.win.window, c.SDL_FLASH_UNTIL_FOCUSED);
    if (!core.shouldDesktop(focused, dnd, set.desktop_notifs)) return;
    ui.desktop_n +%= 1;
    if (app.opts.qa) return;
    var tb: [96]u8 = undefined;
    const title = if (n > 1)
        i18n.fmtZ(&tb, "{d} lembretes", "{d} reminders", .{n})
    else if (r.late())
        i18n.trZ("Lembrete atrasado", "Overdue reminder")
    else
        i18n.trZ("Lembrete", "Reminder");
    if (title.len == 0) return;
    const text = if (r.content.len > 0) r.content else i18n.tr("(sem texto)", "(no text)");
    var bb: [520]u8 = undefined;
    const body = std.fmt.bufPrintSentinel(&bb, "{s} ({s}{s}): {s}{s}{s}", .{
        core.clip(r.author_name, 64),
        if (r.guild == 0) "@" else "#",
        core.clip(r.channel_name, 64),
        core.clip(text, 180),
        if (r.note.len > 0) "\n" else "",
        core.clip(r.note, 160),
    }, 0) catch return;
    app.desktopNotify(title, body);
}

pub fn handle(app: *App, a: core.Action) void {
    const st = &app.st;
    const l = &st.lembretes;
    const now = ui.clock(nowMs());
    var wb: [48]u8 = undefined;
    switch (a) {
        .add => |x| {
            defer app.gpa.free(x.note);
            const res: core.AddResult = l.add(app.gpa, &app.store, x.message, x.due_ms, x.note, now) catch .missing;
            switch (res) {
                .added => {
                    persist(app);
                    st.showToast(nowMs(), false, "lembrete para {s} ✓", "reminder set for {s} ✓", .{ui.whenLabel(&wb, x.due_ms, now)});
                },
                .full => st.showToast(nowMs(), true, "limite de {d} lembretes", "limit of {d} reminders", .{core.max_items}),
                .missing => st.showToast(nowMs(), true, "essa mensagem não está mais carregada", "that message isn't loaded anymore", .{}),
            }
        },
        .edit => |x| {
            defer app.gpa.free(x.note);
            if (l.find(x.id) == null) return;
            _ = l.setNote(app.gpa, x.id, x.note) catch {};
            _ = l.setDue(x.id, x.due_ms);
            persist(app);
            st.showToast(nowMs(), false, "lembrete para {s} ✓", "reminder set for {s} ✓", .{ui.whenLabel(&wb, x.due_ms, now)});
        },
        .snooze => |id| if (l.snooze(id, now)) {
            persist(app);
            st.showToast(nowMs(), false, "adiado para {s}", "snoozed until {s}", .{ui.whenLabel(&wb, now + core.snooze_ms, now)});
        },
        .done => |id| if (l.done(id, @divFloor(now, 1000))) {
            persist(app);
            st.showToast(nowMs(), false, "lembrete concluído ✓", "reminder done ✓", .{});
        },
        .delete => |id| if (l.remove(app.gpa, id)) {
            persist(app);
            st.showToast(nowMs(), false, "lembrete excluído", "reminder deleted", .{});
        },
        // O mesmo caminho de abrir uma salva ou um resultado da busca: o canal abre e a
        // conversa vai até a mensagem (buscando em volta dela se não estiver carregada).
        .open => |id| if (l.find(id)) |r| {
            st.popup = .none;
            app.handle(.{ .open_message = .{ .channel = r.channel, .id = r.message } });
        },
        .toggle_list => {
            st.palette.open = false;
            if (st.popup == .saved and saved_ui.tab == .lembretes) {
                st.popup = .none;
                st.focus_input = true;
            } else {
                saved_ui.tab = .lembretes;
                st.popup = .saved;
            }
        },
    }
}

