//! Popups: menus de contexto (botão direito), cartão de perfil e seletor de
//! emoji. Um "fundo" invisível cobre a janela: clicar fora fecha o popup sem
//! clicar no que está embaixo.
const std = @import("std");
const c = @import("c");
const d = @import("draw.zig");
const qa = @import("qa.zig");
const anim = @import("anim.zig");
const w = @import("widgets.zig");
const icons = @import("icons.zig");
const state = @import("state.zig");
const types = @import("../core/types.zig");
const i18n = @import("i18n.zig");
const emb = @import("embeds.zig");
const Id = types.Id;
const rich = @import("rich.zig");
const att = @import("attachments.zig");
const profile = @import("profile.zig");
const saved_ui = @import("saved.zig");
const mosaic = @import("mosaic.zig");
const guild_color = @import("guild_color.zig");
const accounts_menu = @import("accounts_menu.zig");
const status_menu = @import("status_menu.zig");
const forum = @import("forum.zig");
const thread_settings = @import("thread_settings.zig");
const engine = @import("../plugins/engine.zig");

const quick = [_][]const u8{ "👍", "😂", "😭", "🔥" };


pub fn close(ctx: *d.Ctx) void {
    if (@import("qa.zig").on() and c.SDL_getenv("QA_DEBUG") != null) std.debug.print("[popup] fechou\n", .{});
    ctx.st.popup = .none;
    ctx.st.focus_input = true;
    ctx.st.note_editing = false;
}

/// Popup que estava aberto no quadro anterior. Só damos foco quando ele
/// aparece: focar outra janela a cada quadro cancelaria o clique em andamento
/// (o botão ficava "apertado" mas o clique nunca completava).
var shown_key: u64 = 0;
pub var appearing = false;

// --- Animação de abertura -------------------------------------------------
// Cada popup entra com um fade e um leve zoom/deslize. As listas de desenho
// do popup (a janela e as regiões com rolagem de dentro dele) são anotadas
// aqui e transformadas depois de desenhadas, enquanto a animação dura.

var open_t0: i64 = 0;
var tracked: [6]struct { dl: *c.ImDrawList, start: c_int } = undefined;
var n_tracked: usize = 0;
var anim_rect: d.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };

/// Anota uma lista de desenho para entrar na animação de abertura.
pub fn track(dl: *c.ImDrawList) void {
    if (n_tracked == tracked.len) return;
    tracked[n_tracked] = .{ .dl = dl, .start = dl.*.VtxBuffer.Size };
    n_tracked += 1;
}

/// Progresso da abertura (0..1, já com a curva) para quem quiser usar.
pub fn openK(ctx: *const d.Ctx, dur_ms: f32) f32 {
    if (anim.instant) return 1;
    return d.easeOut(@as(f32, @floatFromInt(ctx.now_ms - open_t0)) / dur_ms);
}

fn animateOpen(ctx: *d.Ctx) void {
    defer n_tracked = 0;
    const Look = struct { dur: f32, scale: f32, dy: f32, corner: bool };
    const look: Look = switch (ctx.st.popup) {
        .menu => .{ .dur = 120, .scale = 0.97, .dy = -6, .corner = true },
        .profile => .{ .dur = 170, .scale = 0.94, .dy = 10, .corner = false },
        .profile_full => .{ .dur = 220, .scale = 0.96, .dy = 18, .corner = false },
        else => .{ .dur = 150, .scale = 0.96, .dy = 8, .corner = false },
    };
    const k = openK(ctx, look.dur);
    if (k >= 1) return;
    anim.active = true;
    const r = anim_rect;
    const origin = if (look.corner) d.v(r.x, r.y) else d.v(r.x + r.w / 2, r.y + r.h / 2);
    const scale = look.scale + (1 - look.scale) * k;
    for (tracked[0..n_tracked]) |t| d.transformVerts(t.dl, t.start, origin, scale, look.dy * (1 - k), k);
}

fn popupKey(p: state.Popup) u64 {
    return switch (p) {
        .none => 0,
        .menu => |m| 1 +% m.id *% 31 +% @backingInt(m.kind),
        .profile => |pr| 2 +% pr.user *% 31,
        .profile_full => |pr| 4 +% pr.user *% 31,
        .emoji => |e| 3 +% e.target *% 31,
        .inbox => 4,
        .saved => 5,
        .mixer => 6,
        .pins => |x| 7 +% x.channel *% 31,
        .threads => |t| 8 +% t.parent *% 31,
        .new_thread => |t| 9 +% t.message *% 31,
        .new_post => |t| 10 +% t.forum *% 31,
        .edit_thread => |t| 21 +% t.thread *% 31,
        .edit_place => |t| 11 +% t.id *% 31,
        .gif => 14,
        .join_invite => 12,
        .create_invite => |t| 13 +% t.channel *% 31,
        .reactions => |t| 15 +% t.message *% 31,
        .poll_voters => |t| 16 +% (t.message *% 31) +% t.answer,
        .compose_options => 17,
        .upload_alt => |t| 18 +% @as(u64, t.index) *% 31,
        .custom_status => 19,
        .group_members => |t| 20 +% t.channel *% 31,
        .moderacao => |t| 22 +% t.guild *% 31 +% t.user *% 17,
        .server_rules => |t| 23 +% t.guild *% 31,
        .onboarding => |t| 24 +% t.guild *% 31,
        .devices => |dv| 25 +% @as(u64, @intFromEnum(dv.which)),
    };
}

/// Janela do ImGui para o popup (recebe o mouse antes do resto).
pub fn beginWindow(id: [*:0]const u8, r: d.Rect) *c.ImDrawList {
    c.ImGui_SetNextWindowPos(d.v(r.x, r.y), 0);
    c.ImGui_SetNextWindowSize(d.v(r.w, r.h), 0);
    if (appearing) c.ImGui_SetNextWindowFocus();
    _ = c.ImGui_Begin(id, null, c.ImGuiWindowFlags_NoDecoration | c.ImGuiWindowFlags_NoBackground |
        c.ImGuiWindowFlags_NoSavedSettings | c.ImGuiWindowFlags_NoMove | c.ImGuiWindowFlags_NoScrollWithMouse);
    const dl = c.ImGui_GetWindowDrawList();
    if (n_tracked == 0) anim_rect = r;
    track(dl);
    return dl;
}

/// Mantém o retângulo dentro da janela. Maior que ela, fica preso no canto de cima
/// (ou da esquerda) e o resto passa da borda.
pub fn fit(ctx: *const d.Ctx, x: f32, y: f32, wd: f32, h: f32) d.Rect {
    return .{
        .x = @max(ctx.win.x + 8, @min(x, ctx.win.right() - wd - 8)),
        .y = @max(ctx.win.y + 8, @min(y, ctx.win.bottom() - h - 8)),
        .w = wd,
        .h = h,
    };
}

pub fn draw(ctx: *d.Ctx) void {
    const k = popupKey(ctx.st.popup);
    appearing = k != shown_key;
    shown_key = k;
    n_tracked = 0;
    if (appearing) open_t0 = ctx.now_ms;
    if (ctx.st.popup == .none) return;
    // Fundo que captura cliques fora.
    c.ImGui_SetNextWindowPos(d.v(ctx.win.x, ctx.win.y), 0);
    c.ImGui_SetNextWindowSize(d.v(ctx.win.w, ctx.win.h), 0);
    if (appearing) c.ImGui_SetNextWindowFocus();
    _ = c.ImGui_Begin("##popup-backdrop", null, c.ImGuiWindowFlags_NoDecoration | c.ImGuiWindowFlags_NoBackground |
        c.ImGuiWindowFlags_NoSavedSettings | c.ImGuiWindowFlags_NoMove);
    c.ImGui_SetCursorScreenPos(d.v(ctx.win.x, ctx.win.y));
    _ = c.ImGui_InvisibleButton("##bd", d.v(ctx.win.w, ctx.win.h), c.ImGuiButtonFlags_MouseButtonLeft | c.ImGuiButtonFlags_MouseButtonRight);
    const outside = c.ImGui_IsItemClickedEx(0) or c.ImGui_IsItemClickedEx(1);
    // O perfil grande escurece o resto da tela (entrando junto com ele).
    if (ctx.st.popup == .profile_full) d.rect(c.ImGui_GetWindowDrawList(), ctx.win, d.Rgba.black.alpha(0.5 * openK(ctx, 220)), 0);
    c.ImGui_End();
    if (@import("qa.zig").on() and c.SDL_getenv("QA_DEBUG") != null and (outside or appearing)) std.debug.print("[popup] appearing={} outside={} mouse={d:.0},{d:.0}\n", .{ appearing, outside, ctx.mouse.x, ctx.mouse.y });
    // Esc com uma anotação aberta só cancela a edição (ui/saved.zig).
    const editing_note = ctx.st.popup == .saved and saved_ui.isEditing();
    const esc = c.ImGui_IsKeyPressed(c.ImGuiKey_Escape) and !editing_note and !@import("dropdown.zig").ownsEsc();
    if (outside or esc) return close(ctx);

    const saved = ctx.dl;
    defer ctx.dl = saved;
    switch (ctx.st.popup) {
        .menu => |m| menu(ctx, m.kind, m.id, m.x, m.y),
        .profile => |p| profile.card(ctx, p.user, p.x, p.y, p.guild orelse ctx.st.guild),
        .profile_full => |p| profile.full(ctx, p.user, p.guild orelse ctx.st.guild),
        .emoji => |e| @import("emoji_picker.zig").draw(ctx, e.target, e.x, e.y),
        .gif => |g| @import("gif_picker.zig").draw(ctx, g.x, g.y),
        .mixer => |m| mixer(ctx, m.x, m.y),
        .inbox => |ib| @import("inbox.zig").draw(ctx, ib.tab),
        .saved => saved_ui.draw(ctx),
        .pins => |x| @import("pins.zig").draw(ctx, x.channel),
        .threads => |t| forum.panel(ctx, t.parent, t.archived, t.private),
        .new_thread => |t| forum.newThread(ctx, t.message),
        .new_post => |t| forum.newPost(ctx, t.forum),
        .edit_thread => |t| thread_settings.dialog(ctx, t.thread),
        .edit_place => |t| @import("edit_place.zig").draw(ctx, t.id, t.group),
        .join_invite => @import("invites.zig").drawJoin(ctx),
        .create_invite => |t| @import("invites.zig").drawCreate(ctx, t.channel),
        .reactions => |t| @import("reactors.zig").drawReactions(ctx, t.message, t.x, t.y),
        .poll_voters => |t| @import("reactors.zig").drawVoters(ctx, t.message, t.answer, t.x, t.y),
        .compose_options => |t| @import("compose_opts.zig").drawMenu(ctx, t.x, t.y),
        .upload_alt => |t| @import("upload_opts.zig").drawAlt(ctx, t.index, t.x, t.y),
        .custom_status => |t| @import("custom_status.zig").draw(ctx, t.x, t.y),
        .group_members => |t| @import("group_dm.zig").draw(ctx, t.channel),
        .moderacao => |t| @import("moderacao.zig").draw(ctx, t.guild, t.user),
        .server_rules => |t| @import("entrada.zig").drawRules(ctx, t.guild),
        .onboarding => |t| @import("entrada.zig").drawOnboarding(ctx, t.guild),
        .devices => |dv| @import("device_menu.zig").draw(ctx, dv.which, dv.x, dv.y),
        .none => {},
    }
    animateOpen(ctx);
}

// --- Menu de contexto -------------------------------------------------------

/// `label` (português) também é a marca do QA; `en` é o texto em inglês.
/// `on`: marcado (a opção que vale agora).
pub const Item = struct { label: []const u8, en: []const u8, id: u8, danger: bool = false, sep: bool = false, on: bool = false };
const conta_menu = @import("conta_menu.zig");

/// Texto do botão de confirmar a exclusão (leva o nome da thread).
var delete_buf: [128]u8 = undefined;
var delete_label: []const u8 = "";

/// Canal de voz em que a pessoa está, se dá para movê-la de lá (é do
/// servidor aberto e temos "Mover membros").
fn movable(ctx: *d.Ctx, uid: Id) ?*const @import("../core/store.zig").ChannelState {
    const ch = ctx.store.voiceChannelOf(uid, ctx.st.guild);
    if (ch == 0) return null;
    const cs = ctx.store.channel(ch) orelse return null;
    if (!ctx.store.can(cs.info.guild, types.perm.move_members)) return null;
    return cs;
}

/// Volume e "silenciar para mim" no menu de quem está na call com a gente (os
/// outros ids do menu e do ui/conta_menu.zig não usam estes).
const id_volume: u8 = 38;
const id_mute_local: u8 = 39;
const volume_row_h: f32 = 54;

/// A pessoa está na call em que estamos (e não somos nós): como no Discord, o menu
/// dela ganha o volume, onde quer que ela apareça.
fn inMyCall(ctx: *d.Ctx, uid: Id) bool {
    if (uid == ctx.store.me) return false;
    const vc = ctx.st.voice orelse return false;
    const cs = ctx.store.channel(vc) orelse return false;
    return std.mem.indexOfScalar(Id, cs.voice_members.items, uid) != null;
}

/// Volume no ponto `x` de um controle de 0 a 200%, em passos de 1%.
fn volumeAt(x: f32, tr: d.Rect) f32 {
    const t = std.math.clamp((x - tr.x) / tr.w, 0, 1);
    return @round(t * 200) / 100;
}

/// O volume como o menu e o mixer mostram (100 = normal).
pub fn volumePct(vol: f32) u32 {
    return @intFromFloat(@round(std.math.clamp(vol, 0, 2) * 100));
}

/// Para onde dá para mover: os outros canais de voz do mesmo servidor.
fn voiceTargets(ctx: *d.Ctx, uid: Id, buf: []Id) []Id {
    const cs = movable(ctx, uid) orelse return buf[0..0];
    var n: usize = 0;
    for (ctx.store.channelsOf(cs.info.guild)) |ch| {
        const other = ctx.store.channel(ch) orelse continue;
        if (other.info.kind != .voice or ch == cs.info.id or n == buf.len) continue;
        buf[n] = ch;
        n += 1;
    }
    return buf[0..n];
}

/// De qual entrada é a segunda lista aberta.
var choice_kind: engine.MenuKind = .message;
var choice_index: usize = 0;
var choice_gen: u32 = 0;

/// Clicou numa entrada de plugin (no menu ou na barra da mensagem): com escolhas,
/// abre a segunda lista; sem, roda direto.
pub fn pluginEntry(ctx: *d.Ctx, kind: engine.MenuKind, index: usize, id: Id, x: f32, y: f32) void {
    const host = @import("../plugins/host.zig");
    const app = host.appOf();
    const hit = host.menuEntry(app, kind, index) orelse return;
    if (hit.entry.choices.len == 0) return host.menuClick(app, kind, index, id, null);
    choice_kind = kind;
    choice_index = index;
    choice_gen = app.plugins.menu_gen;
    ctx.st.popup = .{ .menu = .{ .kind = .plugin_choices, .id = id, .x = x, .y = y } };
}

/// Entradas dos plugins neste menu, depois das do app. O `id` a partir de 200 é a
/// posição delas (a mesma ordem de `plugin_host.menuClick`).
fn pluginItems(items: *[32]Item, n: *usize, kind: state.MenuKind) void {
    const want: engine.MenuKind = switch (kind) {
        .message => .message,
        .user => .user,
        else => return,
    };
    const e = engine.current orelse return;
    var i: usize = 0;
    var first = true;
    for (e.list.items) |p| {
        if (!p.isRunning()) continue;
        for (p.menus.items) |*m| {
            if (m.kind != want) continue;
            if (n.* < items.len and i < 32) {
                items[n.*] = .{ .label = m.pt, .en = m.en, .id = @intCast(200 + i), .sep = first };
                n.* += 1;
                first = false;
            }
            i += 1;
        }
    }
}

fn menu(ctx: *d.Ctx, kind: state.MenuKind, id: Id, x: f32, y: f32) void {
    var items: [32]Item = undefined;
    var n: usize = 0;
    const add = struct {
        fn f(list: *[32]Item, count: *usize, it: Item) void {
            if (count.* < list.len) {
                list[count.*] = it;
                count.* += 1;
            }
        }
    }.f;
    const dev = ctx.st.settings.developer_mode;
    var own = false;
    switch (kind) {
        .message => {
            const found = ctx.store.findAny(id) orelse return close(ctx);
            own = found.m.msg.author == ctx.store.me and found.m.msg.id != 0;
            add(&items, &n, .{ .label = "Responder", .en = "Reply", .id = 1 });
            if (own) add(&items, &n, .{ .label = "Editar mensagem", .en = "Edit Message", .id = 2 });
            add(&items, &n, .{ .label = "Adicionar reação", .en = "Add Reaction", .id = 3 });
            // Quem reagiu: buscado só ao abrir (ui/reactors.zig).
            if (found.m.n_reactions > 0 and found.m.msg.id != 0) add(&items, &n, .{ .label = "Ver reações", .en = "View Reactions", .id = 15 });
            if (found.m.msg.id != 0 and found.m.msg.system == .none) add(&items, &n, .{ .label = "Encaminhar", .en = "Forward", .id = 14 });
            add(&items, &n, .{ .label = if (ctx.st.selection.empty()) "Copiar texto" else "Copiar seleção", .en = if (ctx.st.selection.empty()) "Copy Text" else "Copy Selection", .id = 4 });
            add(&items, &n, .{ .label = "Copiar link da mensagem", .en = "Copy Message Link", .id = 5 });
            // Salvas: só neste computador (ui/saved.zig).
            if (found.m.msg.id != 0) {
                if (ctx.st.saved.find(id) != null)
                    add(&items, &n, .{ .label = "Remover dos salvos", .en = "Remove from Saved", .id = 10 })
                else
                    add(&items, &n, .{ .label = "Salvar mensagem", .en = "Save Message", .id = 10 });
            }
            // Thread: abre a que já existe ou cria uma, se o pai deixa.
            if (found.m.msg.id != 0) {
                if (found.m.msg.thread != 0 and ctx.store.channel(found.m.msg.thread) != null)
                    add(&items, &n, .{ .label = "Abrir thread", .en = "Open Thread", .id = 12 })
                else if (ctx.store.canCreateThread(&found.cs.info))
                    add(&items, &n, .{ .label = "Criar thread", .en = "Create Thread", .id = 11 });
            }
            add(&items, &n, .{ .label = "Marcar como não lida", .en = "Mark Unread", .id = 7 });
            // Fixar pede "gerenciar mensagens" no canal (numa DM, qualquer um).
            if (found.m.msg.id != 0 and found.m.msg.system == .none and ctx.store.channelPermissions(&found.cs.info) & types.perm.manage_messages != 0)
                add(&items, &n, if (found.m.msg.pinned) .{ .label = "Desafixar mensagem", .en = "Unpin Message", .id = 13 } else .{ .label = "Fixar mensagem", .en = "Pin Message", .id = 13 });
            if (dev) add(&items, &n, .{ .label = "Copiar ID da mensagem", .en = "Copy Message ID", .id = 8 });
            // Dos outros também, para quem pode gerenciar mensagens no servidor.
            const mod = found.m.msg.id != 0 and ctx.store.can(found.cs.info.guild, types.perm.manage_messages);
            if (own or mod) add(&items, &n, .{ .label = "Excluir mensagem", .en = "Delete Message", .id = 9, .danger = true, .sep = true });
        },
        .user => {
            add(&items, &n, .{ .label = "Perfil", .en = "Profile", .id = 20 });
            if (ctx.store.user(id)) |pu| if (pu.avatar != null or (if (ctx.store.face(ctx.st.guild, id)) |f| f.avatar != null else false)) add(&items, &n, .{ .label = "Ver foto de perfil", .en = "View Picture", .id = 27 });
            add(&items, &n, .{ .label = "Mencionar", .en = "Mention", .id = 21 });
            const hook = if (ctx.store.user(id)) |u| u.webhook else false;
            if (id != ctx.store.me and !hook) add(&items, &n, .{ .label = "Mensagem", .en = "Message", .id = 22 });
            // Na call com a gente: o volume dela e o silenciar só para nós. São os do
            // mixer (os mesmos valores, gravados nas configurações).
            const voice_items = inMyCall(ctx, id);
            if (voice_items) {
                add(&items, &n, .{ .label = "Volume do usuário", .en = "User Volume", .id = id_volume, .sep = true });
                add(&items, &n, .{ .label = "Silenciar para mim", .en = "Mute for Me", .id = id_mute_local, .on = ctx.st.volumes.isMuted(id) });
            }
            // Amizade, ignorar e bloquear vão para a conta (ui/conta_menu.zig).
            const conta_at = n;
            n += conta_menu.userItems(ctx, id, items[n..]);
            if (voice_items and n > conta_at) items[conta_at].sep = true;
            add(&items, &n, .{ .label = "Copiar nome de usuário", .en = "Copy Username", .id = 24, .sep = true });
            if (dev and !hook) add(&items, &n, .{ .label = "Copiar ID do usuário", .en = "Copy User ID", .id = 25 });
            if (movable(ctx, id) != null) {
                var tb: [24]Id = undefined;
                if (voiceTargets(ctx, id, &tb).len > 0) add(&items, &n, .{ .label = "Mover para…", .en = "Move To…", .id = 28, .sep = true });
                add(&items, &n, .{ .label = "Desconectar da call", .en = "Disconnect", .id = 29, .danger = true, .sep = voiceTargets(ctx, id, &tb).len == 0 });
            }
            // Moderação: só o que dá para fazer com essa pessoa (ui/moderacao.zig).
            var mb: [5]@import("moderacao.zig").Entrada = undefined;
            for (@import("moderacao.zig").entradas(ctx, id, &mb), 0..) |e, i| add(&items, &n, .{ .label = e.label, .en = e.en, .id = e.id, .danger = e.danger, .sep = i == 0 });
        },
        .channel => {
            add(&items, &n, .{ .label = "Marcar como lido", .en = "Mark As Read", .id = 40 });
            add(&items, &n, .{ .label = "Abrir em nova aba", .en = "Open in New Tab", .id = 41 });
            // Tela dividida: o canal ao lado do que está aberto (até 3).
            if (mosaic.canOpenBeside(ctx, id)) add(&items, &n, .{ .label = "Abrir ao lado", .en = "Open to the Side", .id = 45 });
            n += conta_menu.channelItems(ctx, id, items[n..]);
            // Thread: entrar, sair e as arquivadas do mesmo canal pai. Num canal
            // de texto: as threads dele (a lista de canais só mostra algumas).
            if (ctx.store.channel(id)) |tcs| if (tcs.info.thread) |t| {
                add(&items, &n, if (t.joined)
                    .{ .label = "Sair da thread", .en = "Leave Thread", .id = 47, .sep = true }
                else
                    .{ .label = "Entrar na thread", .en = "Join Thread", .id = 47, .sep = true });
                if (tcs.info.parent != null) add(&items, &n, .{ .label = "Threads arquivadas", .en = "Archived Threads", .id = 48 });
                // Editar, arquivar e trancar: só o que dá (ui/thread_settings.zig).
                const te = thread_settings.menuEntries(ctx, &tcs.info);
                for (te.slice()) |e| add(&items, &n, .{ .label = e.label, .en = e.en, .id = e.id });
                // Apagar pede a permissão de gerenciar threads, mesmo para quem criou.
                if (ctx.store.channelPermissions(&tcs.info) & types.perm.manage_threads != 0)
                    add(&items, &n, .{ .label = "Excluir thread…", .en = "Delete Thread…", .id = 50, .danger = true });
            } else if (tcs.info.kind == .text and tcs.info.guild != 0) {
                add(&items, &n, .{ .label = "Ver threads", .en = "View Threads", .id = 49, .sep = true });
                add(&items, &n, .{ .label = "Threads arquivadas", .en = "Archived Threads", .id = 48 });
            };
            if (ctx.store.channel(id)) |ics| if (@import("invites.zig").canInvite(ctx, &ics.info)) add(&items, &n, .{ .label = "Convidar pessoas…", .en = "Invite People…", .id = 56, .sep = true });
            if (ctx.store.channel(id)) |gcs| if (gcs.info.group) {
                add(&items, &n, .{ .label = "Editar grupo…", .en = "Edit Group…", .id = 53, .sep = true });
                add(&items, &n, .{ .label = "Pessoas do grupo…", .en = "Group Members…", .id = 57 });
                if (gcs.info.icon != null) add(&items, &n, .{ .label = "Ver ícone", .en = "View Icon", .id = 54 });
            };
            add(&items, &n, .{ .label = "Copiar link", .en = "Copy Link", .id = 43, .sep = true });
            // Canal de voz em que estamos (mesmo que o app tenha perdido a
            // conexão e o Discord ainda nos mostre lá).
            if (ctx.store.channel(id)) |vcs| if (vcs.info.kind == .voice and ((ctx.st.voice != null and ctx.st.voice.? == id) or ctx.store.voiceChannelOf(ctx.store.me, vcs.info.guild) == id))
                add(&items, &n, .{ .label = "Sair da call", .en = "Leave Call", .id = 46, .danger = true, .sep = true });
            if (dev) add(&items, &n, .{ .label = "Copiar ID do canal", .en = "Copy Channel ID", .id = 44 });
            if (ctx.store.channel(id)) |gcs| if (gcs.info.group) add(&items, &n, .{ .label = "Sair do grupo", .en = "Leave Group", .id = 58, .danger = true, .sep = true });
        },
        .thread_delete => {
            const name = if (ctx.store.channel(id)) |tcs| tcs.info.name else "?";
            delete_label = i18n.fmt(&delete_buf, "Excluir «{s}» para sempre", "Delete “{s}” for good", .{name[0..@min(name.len, 40)]});
            add(&items, &n, .{ .label = delete_label, .en = delete_label, .id = 51, .danger = true });
            add(&items, &n, .{ .label = "Cancelar", .en = "Cancel", .id = 52 });
        },
        .guild_leave => {
            const name = if (ctx.store.guild(id)) |g| g.name else "?";
            delete_label = i18n.fmt(&delete_buf, "Sair de «{s}»", "Leave “{s}”", .{d.utf8Prefix(name, 40)});
            add(&items, &n, .{ .label = delete_label, .en = delete_label, .id = 68, .danger = true });
            add(&items, &n, .{ .label = "Cancelar", .en = "Cancel", .id = 52 });
        },
        .group_leave => {
            const name = if (ctx.store.channel(id)) |gcs| gcs.info.name else "?";
            delete_label = i18n.fmt(&delete_buf, "Sair de «{s}»", "Leave “{s}”", .{d.utf8Prefix(name, 40)});
            add(&items, &n, .{ .label = delete_label, .en = delete_label, .id = 59, .danger = true });
            add(&items, &n, .{ .label = "Cancelar", .en = "Cancel", .id = 52 });
        },
        .status => {
            add(&items, &n, .{ .label = "●  Online", .en = "●  Online", .id = 80 });
            add(&items, &n, .{ .label = "◐  Ausente", .en = "◐  Idle", .id = 81 });
            add(&items, &n, .{ .label = "⊘  Não perturbe", .en = "⊘  Do Not Disturb", .id = 82 });
            add(&items, &n, .{ .label = "○  Invisível", .en = "○  Invisible", .id = 83 });
            if (ctx.st.filtros.focusOn(ctx.now_ms)) {
                add(&items, &n, .{ .label = "Sair do modo foco", .en = "End Focus Mode", .id = 85, .sep = true });
            } else {
                add(&items, &n, .{ .label = "Modo foco: 15 min", .en = "Focus mode: 15 min", .id = 86, .sep = true });
                add(&items, &n, .{ .label = "Modo foco: 30 min", .en = "Focus mode: 30 min", .id = 87 });
                add(&items, &n, .{ .label = "Modo foco: 1 h", .en = "Focus mode: 1 h", .id = 88 });
                add(&items, &n, .{ .label = "Modo foco: até desligar", .en = "Focus mode: until I turn it off", .id = 89 });
            }
            add(&items, &n, if (ctx.st.settings.data_saver)
                .{ .label = "Desligar modo economia", .en = "Turn Off Data Saver", .id = 90 }
            else
                .{ .label = "Ligar modo economia", .en = "Turn On Data Saver", .id = 90 });
            n += conta_menu.statusItems(ctx, items[n..]);
            add(&items, &n, .{ .label = "Ver perfil", .en = "View Profile", .id = 84, .sep = true });
        },
        .pet => for (@import("mascote_pet.zig").menu_items, 1..) |it, i| add(&items, &n, .{ .label = it.pt, .en = it.en, .id = @intCast(i) }),
        .notif => n += conta_menu.notifItems(ctx, id, items[n..]),
        .block_confirm => n += conta_menu.blockItems(ctx, id, items[n..]),
        .voice_move => {
            var tb: [20]Id = undefined;
            for (voiceTargets(ctx, id, &tb), 0..) |ch, i| {
                const name = ctx.store.channel(ch).?.info.name;
                add(&items, &n, .{ .label = name, .en = name, .id = @intCast(100 + i) });
            }
            if (n == 0) return close(ctx);
        },
        .plugin_choices => {
            const host = @import("../plugins/host.zig");
            // O plugin recarregou com a lista aberta: as posições já não valem.
            if (host.appOf().plugins.menu_gen != choice_gen) return close(ctx);
            const hit = host.menuEntry(host.appOf(), choice_kind, choice_index) orelse return close(ctx);
            for (hit.entry.choices, 0..) |ch, i| add(&items, &n, .{ .label = ch.pt, .en = ch.en, .id = @intCast(100 + i) });
            if (n == 0) return close(ctx);
        },
        .guild => {
            add(&items, &n, .{ .label = "Marcar como lido", .en = "Mark As Read", .id = 60 });
            if (@import("invites.zig").channelFor(ctx, id) != null) add(&items, &n, .{ .label = "Convidar pessoas…", .en = "Invite People…", .id = 69 });
            if (ctx.store.can(id, types.perm.manage_guild)) add(&items, &n, .{ .label = "Editar servidor…", .en = "Edit Server…", .id = 64 });
            if (ctx.store.isPending(id)) add(&items, &n, .{ .label = "Regras do servidor…", .en = "Server Rules…", .id = 94 });
            if (ctx.store.guild(id)) |vg| if (vg.onboarding) add(&items, &n, .{ .label = "Boas-vindas do servidor…", .en = "Server Onboarding…", .id = 93 });
            if (ctx.store.guild(id)) |vg| {
                if (vg.icon != null) add(&items, &n, .{ .label = "Ver ícone", .en = "View Icon", .id = 65 });
                if (vg.banner != null) add(&items, &n, .{ .label = "Ver banner", .en = "View Banner", .id = 66 });
            }
            n += conta_menu.guildItems(ctx, id, items[n..]);
            if (@import("moderacao.zig").podeVerBans(ctx, id)) add(&items, &n, .{ .label = "Banimentos", .en = "Bans", .id = @import("moderacao.zig").id_bans });
            if (dev) add(&items, &n, .{ .label = "Copiar ID do servidor", .en = "Copy Server ID", .id = 63 });
            // Quem é dono não pode sair: precisa passar o servidor antes.
            if (ctx.store.guild(id)) |vg| if (vg.owner != ctx.store.me) add(&items, &n, .{ .label = "Sair do servidor", .en = "Leave Server", .id = 67, .danger = true, .sep = true });
        },
    }

    pluginItems(&items, &n, kind);

    const row_h: f32 = 32;
    const quick_h: f32 = if (kind == .message) 46 else 0;
    // "Cor do servidor": uma fileira de cores no fim do menu do servidor.
    const colors_h: f32 = if (kind == .guild and ctx.store.guild(id) != null) 62 else 0;
    var seps: f32 = 0;
    for (items[0..n]) |it| {
        if (it.sep) seps += 9;
        // O volume é uma linha mais alta (o nome em cima, o controle embaixo).
        if (kind == .user and it.id == id_volume) seps += volume_row_h - row_h;
    }
    const mw: f32 = 220;
    // Menu do usuário: as contas embaixo (o menu cresce para cima).
    const acc_h: f32 = if (kind == .status) accounts_menu.height(ctx) else 0;
    const mh = quick_h + @as(f32, @floatFromInt(n)) * row_h + seps + colors_h + 12 + acc_h;
    // Janela baixa (ou a interface grande): o menu para na altura da janela e os
    // itens rolam por dentro (as reações rápidas ficam paradas em cima).
    const max_h = @max(ctx.win.h - 16, quick_h + 3 * row_h + 12);
    const scrolls = mh > max_h;
    const r = fit(ctx, x + 2, y + 2 - acc_h, mw, @min(mh, max_h));
    const k = anim.to(anim.id("menu", @intFromEnum(kind)), 1, 30);
    const dl = beginWindow("##menu", r);
    defer c.ImGui_End();
    ctx.dl = dl;
    qa.mark(r, "popup-menu", .{});
    const radius = @max(ctx.th.radius, 4);
    d.shadow(dl, r, radius, 14, ctx.col(.shadow).alpha(k));
    d.rect(dl, r, ctx.col(.overlay), radius);
    d.border(dl, r, ctx.col(.border), radius, 1);

    var yy = r.y + 6;
    const fam = ctx.ui;
    if (kind == .message) {
        // Reações rápidas, como no Discord.
        for (quick, 0..) |e, i| {
            const er: d.Rect = .{ .x = r.x + 8 + @as(f32, @floatFromInt(i)) * 42, .y = yy, .w = 38, .h = 36 };
            const hb = d.hit(ctx, 200 + i, er);
            qa.mark(er, "menu-react:{d}", .{i});
            if (hb.hovered) d.circle(dl, er.x + 19, er.y + 18, 18, ctx.col(.hover).mix(ctx.col(.text), 0.06));
            const es: f32 = if (hb.hovered) 23 else 20;
            d.text(dl, fam.get(.regular), es, er.x + 19 - es / 2, er.y + 18 - es * 0.6, d.Rgba.white, e);
            if (hb.clicked) {
                ctx.act(.{ .react = .{ .id = id, .emoji = types.Reaction.init(e) } });
                return close(ctx);
            }
        }
        yy += quick_h;
    }
    // Os itens, as cores e as contas: numa região que rola quando o menu não cabe.
    var idl = dl;
    if (scrolls) {
        idl = d.beginRegion(ctx, "##menu-items", .{ .x = r.x, .y = yy, .w = r.w, .h = r.bottom() - 6 - yy }, 0);
        track(idl);
        ctx.dl = idl;
        yy = c.ImGui_GetCursorScreenPos().y;
    }
    var picked: ?u8 = null;
    for (items[0..n], 0..) |it, i| {
        if (it.sep) {
            d.line(idl, r.x + 10, yy + 4, r.right() - 10, yy + 4, ctx.col(.border), 1);
            yy += 9;
        }
        if (kind == .user and it.id == id_volume) {
            volumeRow(ctx, idl, .{ .x = r.x + 6, .y = yy, .w = r.w - 12, .h = volume_row_h - 2 }, id, it);
            yy += volume_row_h;
            continue;
        }
        const ir: d.Rect = .{ .x = r.x + 6, .y = yy, .w = r.w - 12, .h = row_h - 2 };
        const hb = d.hit(ctx, i, ir);
        qa.mark(ir, "menu:{s}", .{it.label});
        const base = if (it.danger) ctx.col(.danger) else ctx.col(.accent);
        if (hb.hovered) d.rect(idl, ir, base, @max(ctx.th.radius - 2, 2));
        const tc = if (hb.hovered) (if (it.danger) d.Rgba.white else ctx.col(.accent_text)) else if (it.danger) ctx.col(.danger) else ctx.col(.text).mix(ctx.col(.muted), 0.15);
        _ = d.textClipped(idl, fam.get(.medium), 14, ir.x + 10, d.centerY(ir, 14), tc, i18n.tr(it.label, it.en), ir.w - (if (it.on) @as(f32, 40) else 18));
        // Status: o visto no de agora e o submenu do prazo (ui/status_menu.zig).
        if (kind == .status) status_menu.row(ctx, idl, ir, it, hb.hovered, tc);
        if (it.on) {
            // A opção que vale agora: um visto à direita.
            const cx = ir.right() - 18;
            const cy = ir.y + ir.h / 2;
            d.line(idl, cx - 5, cy, cx - 1.5, cy + 4, tc, 2);
            d.line(idl, cx - 1.5, cy + 4, cx + 5.5, cy - 4.5, tc, 2);
            qa.mark(ir, "menu-on:{s}", .{it.label});
        }
        // A escolha roda depois de fechar a região (ela pode abrir outro popup).
        if (hb.clicked) {
            picked = it.id;
            break;
        }
        yy += row_h;
    }
    var chosen_account = false;
    if (picked == null) {
        if (colors_h > 0) guildColors(ctx, idl, id, r, yy);
        if (kind == .status and accounts_menu.draw(ctx, idl, r, yy)) chosen_account = true;
    }
    if (scrolls) {
        d.endRegion(ctx, yy + colors_h + acc_h, r.x);
        ctx.dl = dl;
    }
    if (picked) |item| return choose(ctx, kind, id, item, r);
    if (chosen_account) return close(ctx);
    // O submenu do prazo, fora da região que rola (ele é uma janela à parte).
    if (kind == .status and status_menu.drawSub(ctx, r)) close(ctx);
}

/// Fileira "Cor do servidor": a primeira bolinha volta para a cor de sempre,
/// as outras são a paleta de destaque das configurações.
fn guildColors(ctx: *d.Ctx, dl: *c.ImDrawList, guild: Id, r: d.Rect, y: f32) void {
    const palette = &@import("../app.zig").App.accents;
    const fam = ctx.ui;
    d.line(dl, r.x + 10, y + 4, r.right() - 10, y + 4, ctx.col(.border), 1);
    d.text(dl, fam.get(.semibold), 12, r.x + 16, y + 12, ctx.col(.muted), i18n.tr("Cor do servidor", "Server Color"));
    const cur = guild_color.get(guild);
    const step = (r.w - 24) / @as(f32, @floatFromInt(palette.len + 1));
    for (0..palette.len + 1) |i| {
        const cx = r.x + 12 + step * (@as(f32, @floatFromInt(i)) + 0.5);
        const cy = y + 44;
        const sr: d.Rect = .{ .x = cx - step / 2, .y = cy - 11, .w = step, .h = 22 };
        const hb = d.hit(ctx, 300 + i, sr);
        qa.mark(sr, "guild-color:{d}", .{i});
        const sel = if (i == 0) cur == null else cur == palette[i - 1];
        if (sel or hb.hovered) c.ImDrawList_AddCircleEx(dl, d.v(cx, cy), 10.5, (if (sel) ctx.col(.text) else ctx.col(.muted)).u(), 0, 1.5, 0);
        if (i == 0) {
            // Sem cor própria: anel com um risco.
            c.ImDrawList_AddCircleEx(dl, d.v(cx, cy), 7, ctx.col(.faint).u(), 0, 1.5, 0);
            d.line(dl, cx - 4.5, cy + 4.5, cx + 4.5, cy - 4.5, ctx.col(.faint), 1.5);
            d.tip(ctx, sr, i18n.tr("Cor de sempre", "Default color"), hb.hovered);
        } else d.circle(dl, cx, cy, 7.5, d.Rgba.hex(palette[i - 1]));
        if (hb.clicked) {
            ctx.act(.{ .set_guild_color = .{ .guild = guild, .rgb = if (i == 0) null else palette[i - 1] } });
            return close(ctx);
        }
    }
}

/// "Volume do usuário" no menu: 0 a 200%, com o 100% (o normal) marcado no meio.
/// O mesmo valor e a mesma ação do mixer, então os dois andam juntos. Arrastando, o
/// controle segue o mouse mesmo fora do menu, e soltar não fecha nada: o fundo do
/// popup só fecha com um clique nele. Silenciada, o controle fica apagado e
/// continua mostrando o volume para onde ela volta.
fn volumeRow(ctx: *d.Ctx, dl: *c.ImDrawList, r: d.Rect, uid: Id, it: Item) void {
    const fam = ctx.ui;
    qa.mark(r, "menu:{s}", .{it.label});
    const tr: d.Rect = .{ .x = r.x + 12, .y = r.y + 34, .w = r.w - 24, .h = 6 };
    const hr: d.Rect = .{ .x = tr.x - 8, .y = tr.y - 11, .w = tr.w + 16, .h = 28 };
    const hb = d.hit(ctx, 400, hr);
    qa.mark(hr, "menu-volume:{d}", .{uid});
    var vol = ctx.st.volumes.volume(uid);
    if (hb.held) {
        const v = volumeAt(ctx.mouse.x, tr);
        if (v != vol) ctx.act(.{ .set_voice_volume = .{ .user = uid, .volume = v } });
        vol = v;
    }
    const off = vol <= 0.001 or ctx.st.volumes.isMuted(uid);
    _ = d.textClipped(dl, fam.get(.medium), 14, r.x + 10, r.y + 7, ctx.col(.text).mix(ctx.col(.muted), 0.15), i18n.tr(it.label, it.en), r.w - 66);
    var buf: [16]u8 = undefined;
    const pct = volumePct(vol);
    const pt = std.fmt.bufPrint(&buf, "{d}%", .{pct}) catch "";
    const pw = d.width(fam.get(.semibold), 13, pt);
    const pr: d.Rect = .{ .x = r.right() - 10 - pw, .y = r.y + 8, .w = pw, .h = 16 };
    d.text(dl, fam.get(.semibold), 13, pr.x, pr.y, if (off) ctx.col(.faint) else ctx.col(.muted), pt);
    qa.mark(pr, "menu-volume-pct:{d}:{d}", .{ uid, pct });
    const k = std.math.clamp(vol / 2.0, 0, 1);
    d.rect(dl, tr, ctx.col(.overlay).mix(ctx.col(.text), if (hb.hovered or hb.held) 0.16 else 0.11), 3);
    // 100% = sem mudança.
    d.line(dl, tr.x + tr.w / 2, tr.y - 3, tr.x + tr.w / 2, tr.bottom() + 3, ctx.col(.faint), 1);
    d.rect(dl, .{ .x = tr.x, .y = tr.y, .w = tr.w * k, .h = tr.h }, if (off) ctx.col(.faint) else ctx.col(.accent), 3);
    const kr: d.Rect = .{ .x = tr.x + tr.w * k - 5, .y = tr.y - 4, .w = 10, .h = 14 };
    d.shadow(dl, kr, 3, 4, ctx.col(.shadow));
    d.rect(dl, kr, d.Rgba.white, 3);
}

fn copyFmt(ctx: *d.Ctx, comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.allocPrint(ctx.st.gpa, fmt, args) catch return;
    ctx.act(.{ .copy = s });
}

/// Links de DM usam "@me" no lugar do servidor.
fn guildPart(buf: []u8, guild: Id) []const u8 {
    return if (guild == 0) "@me" else std.fmt.bufPrint(buf, "{d}", .{guild}) catch "@me";
}

fn choose(ctx: *d.Ctx, kind: state.MenuKind, id: Id, item: u8, r: d.Rect) void {
    const st = ctx.st;
    close(ctx);
    if (kind == .pet) return @import("mascote_pet.zig").menuChoose(ctx, item);
    if (kind == .plugin_choices) {
        const host = @import("../plugins/host.zig");
        const hit = host.menuEntry(host.appOf(), choice_kind, choice_index) orelse return;
        const i = item -| 100;
        if (i < hit.entry.choices.len) host.menuClick(host.appOf(), choice_kind, choice_index, id, hit.entry.choices[i].value);
        return;
    }
    if (item >= 200) return pluginEntry(ctx, if (kind == .user) .user else .message, item - 200, id, r.x + r.w - 8, r.y + r.h - 70);
    if (kind != .message and conta_menu.choose(ctx, kind, id, item, r)) return;
    if (kind == .voice_move and item >= 100) {
        var tb: [20]Id = undefined;
        const list = voiceTargets(ctx, id, &tb);
        const cs = movable(ctx, id) orelse return;
        if (item - 100 < list.len) ctx.act(.{ .move_member = .{ .guild = cs.info.guild, .user = id, .channel = list[item - 100] } });
        return;
    }
    switch (item) {
        1 => ctx.act(.{ .reply = id }),
        2 => ctx.act(.{ .edit_message = id }),
        3 => st.popup = .{ .emoji = .{ .target = id, .x = r.x, .y = r.y } },
        15 => @import("reactors.zig").openReactions(ctx, id, 0, r.x, r.y),
        4 => if (!st.selection.empty()) {
            if (selectionText(ctx)) |s| ctx.act(.{ .copy = s });
        } else if (ctx.store.findAny(id)) |f| {
            // A mensagem inteira, com o texto dos cartões.
            var out: std.ArrayList(u8) = .empty;
            emb.appendText(ctx, &out, f.m, 0, emb.textLen(f.m));
            if (out.toOwnedSlice(ctx.st.gpa)) |s| ctx.act(.{ .copy = s }) else |_| {}
        },
        5 => if (ctx.store.findAny(id)) |f| {
            var gb: [24]u8 = undefined;
            copyFmt(ctx, "https://discord.com/channels/{s}/{d}/{d}", .{ guildPart(&gb, f.cs.info.guild), f.cs.info.id, id });
        },
        7 => ctx.act(.{ .mark_unread = id }),
        14 => ctx.act(.{ .forward_pick = id }),
        13 => if (ctx.store.findAny(id)) |f| ctx.act(.{ .pin_message = .{ .channel = f.cs.info.id, .id = id, .add = !f.m.msg.pinned } }),
        8, 25, 44, 63 => copyFmt(ctx, "{d}", .{id}),
        10 => ctx.act(if (st.saved.find(id) != null) .{ .unsave_message = id } else .{ .save_message = id }),
        11 => forum.openNewThread(ctx, id),
        12 => if (ctx.store.findAny(id)) |f| ctx.act(.{ .select_channel = f.m.msg.thread }),
        47 => if (ctx.store.channel(id)) |cs| if (cs.info.thread) |t| {
            ctx.act(.{ .join_thread = .{ .thread = id, .join = !t.joined } });
        },
        35, 36, 37 => thread_settings.choose(ctx, id, item),
        // Apagar não tem volta: abre a confirmação no mesmo lugar.
        50 => st.popup = .{ .menu = .{ .kind = .thread_delete, .id = id, .x = r.x, .y = r.y } },
        51 => ctx.act(.{ .delete_thread = id }),
        // Sair também pede confirmação: voltar pode precisar de convite.
        67 => st.popup = .{ .menu = .{ .kind = .guild_leave, .id = id, .x = r.x, .y = r.y } },
        68 => ctx.act(.{ .leave_guild = id }),
        52 => {},
        53 => @import("edit_place.zig").open(ctx, id, true),
        57 => @import("group_dm.zig").open(ctx, id),
        // Sair do grupo pede confirmação: voltar precisa de alguém que adicione.
        58 => st.popup = .{ .menu = .{ .kind = .group_leave, .id = id, .x = r.x, .y = r.y } },
        59 => ctx.act(.{ .social = .{ .leave_group = id } }),
        64 => @import("edit_place.zig").open(ctx, id, false),
        56 => @import("invites.zig").openCreate(ctx, id),
        69 => if (@import("invites.zig").channelFor(ctx, id)) |ch| @import("invites.zig").openCreate(ctx, ch),
        // 77 e 78 são do ui/conta_menu.zig (notificações).
        93 => st.popup = .{ .onboarding = .{ .guild = id } },
        94 => st.popup = .{ .server_rules = .{ .guild = id } },
        27 => @import("profile.zig").viewAvatarIn(ctx, ctx.st.guild, id),
        160...166 => @import("moderacao.zig").escolheu(ctx, id, item),
        54 => if (ctx.store.channel(id)) |cs| if (cs.info.icon) |h| {
            var ub: [192]u8 = undefined;
            att.openOriginal(ctx, w.cdnFull(&ub, .group, id, h), cs.info.name, 1024, 1024);
        },
        65 => if (ctx.store.guild(id)) |g| if (g.icon) |h| {
            var ub: [192]u8 = undefined;
            att.openOriginal(ctx, w.cdnFull(&ub, .guild, id, h), g.name, 1024, 1024);
        },
        66 => if (ctx.store.guild(id)) |g| @import("comp_channels.zig").viewBanner(ctx, g),
        48, 49 => if (ctx.store.channel(id)) |cs| {
            const parent = if (cs.info.thread != null) cs.info.parent orelse id else id;
            st.popup = .{ .threads = .{ .parent = parent, .archived = item == 48 } };
            if (item == 48 and cs.info.thread != null and cs.info.thread.?.private) st.popup.threads.private = true;
        },
        80, 81, 82, 83 => ctx.act(.{ .set_status = @enumFromInt(item - 80) }),
        84 => st.popup = .{ .profile = .{ .user = id, .x = r.x, .y = r.y - 200 } },
        85 => {
            st.filtros.endFocus(ctx.store);
            st.showToast(ctx.now_ms, false, "modo foco desligado", "focus mode off", .{});
        },
        86, 87, 88, 89 => {
            st.filtros.startFocus(ctx.now_ms, ([_]u32{ 15, 30, 60, 0 })[item - 86]);
            st.showToast(ctx.now_ms, false, "modo foco: só DMs e menções notificam", "focus mode: only DMs and mentions notify", .{});
        },
        90 => {
            st.settings.data_saver = !st.settings.data_saver;
            st.filtros.save = true;
            if (st.settings.data_saver)
                st.showToast(ctx.now_ms, false, "modo economia: imagens só ao clicar", "data saver: images load on click", .{})
            else
                st.showToast(ctx.now_ms, false, "modo economia desligado", "data saver off", .{});
        },
        9 => ctx.act(.{ .delete_message = id }),
        20 => st.popup = .{ .profile = .{ .user = id, .x = r.x, .y = r.y } },
        21 => if (ctx.store.nameIn(st.guild, id)) |name| {
            insertText(st, name, true);
            // Com o ID guardado, dois "Ana" no servidor não se confundem.
            var sb: [136]u8 = undefined;
            var rb: [32]u8 = undefined;
            const auto = @import("autocomplete.zig");
            auto.addToken(std.fmt.bufPrint(&sb, "@{s}", .{name}) catch "", std.fmt.bufPrint(&rb, "<@{d}>", .{id}) catch "");
        },
        22 => ctx.act(.{ .open_dm = id }),
        // Como o botão do mixer: o volume guardado fica, tirar o silêncio volta a ele.
        id_mute_local => ctx.act(.{ .set_voice_mute = .{ .user = id, .mute = !st.volumes.isMuted(id) } }),
        24 => if (ctx.store.user(id)) |u| copyFmt(ctx, "{s}", .{u.name}),
        28 => st.popup = .{ .menu = .{ .kind = .voice_move, .id = id, .x = r.x + r.w - 8, .y = r.y + r.h - 70 } },
        29 => if (movable(ctx, id)) |cs| ctx.act(.{ .move_member = .{ .guild = cs.info.guild, .user = id, .channel = null } }),
        40, 60 => ctx.act(.{ .mark_read = id }),
        41 => {
            st.tabs.append(st.gpa, id) catch {};
            ctx.act(.{ .focus_tab = st.tabs.items.len - 1 });
        },
        45 => mosaic.openBeside(ctx, id),
        46 => if (ctx.store.channel(id)) |cs| {
            st.voice_guild = cs.info.guild;
            ctx.act(.leave_voice);
        },
        43 => if (ctx.store.channel(id)) |cs| {
            var gb: [24]u8 = undefined;
            copyFmt(ctx, "https://discord.com/channels/{s}/{d}", .{ guildPart(&gb, cs.info.guild), id });
        },
        else => {},
    }
}

/// Coloca texto na caixa de mensagem (no fim), como uma menção ou um emoji.
pub fn insertText(st: *state.State, text: []const u8, mention: bool) void {
    const len = std.mem.indexOfScalar(u8, &st.input, 0) orelse st.input.len;
    var out = st.input[len..];
    var n: usize = 0;
    if (len > 0 and st.input[len - 1] != ' ' and mention) {
        if (out.len > 1) {
            out[0] = ' ';
            n = 1;
        }
    }
    const piece = if (mention) "@" else "";
    for ([_][]const u8{ piece, text, if (mention) " " else "" }) |part| {
        const k = d.utf8Prefix(part, out.len - n - 1).len;
        @memcpy(out[n .. n + k], part[0..k]);
        n += k;
    }
    out[n] = 0;
    st.input_sync = true;
    st.focus_input = true;
}

/// Texto da seleção atual (alocado; quem recebe libera).
pub fn selectionText(ctx: *d.Ctx) ?[]u8 {
    const sel = &ctx.st.selection;
    const cs = ctx.store.channel(sel.channel) orelse return null;
    var ia: ?usize = null;
    var ib: ?usize = null;
    for (cs.messages.items, 0..) |m, i| {
        if (m.msg.id == sel.a_id) ia = i;
        if (m.msg.id == sel.b_id) ib = i;
    }
    var first = ia orelse return null;
    var last = ib orelse return null;
    var o0 = sel.a_off;
    var o1 = sel.b_off;
    if (first > last or (first == last and o0 > o1)) {
        std.mem.swap(usize, &first, &last);
        std.mem.swap(u32, &o0, &o1);
    }
    var out: std.ArrayList(u8) = .empty;
    for (cs.messages.items[first .. last + 1], first..) |*m, i| {
        if (i != first) out.append(ctx.st.gpa, '\n') catch {};
        emb.appendText(ctx, &out, m, if (i == first) o0 else 0, if (i == last) o1 else emb.textLen(m));
    }
    return out.toOwnedSlice(ctx.st.gpa) catch null;
}

// --- Mixer da call ----------------------------------------------------------

/// Uma chave em forma de pílula, ao lado da anterior (`x` anda). true: clicou.
fn dspChip(ctx: *d.Ctx, dl: *c.ImDrawList, x: *f32, y: f32, id: usize, label: []const u8, on: bool, tip: []const u8, comptime mark: []const u8, uid: Id) bool {
    const font = ctx.ui.get(.medium);
    const fs: f32 = 11;
    const tw = d.width(font, fs, label);
    const r: d.Rect = .{ .x = x.*, .y = y, .w = tw + 26, .h = 20 };
    x.* += r.w + 6;
    const hb = d.hit(ctx, id, r);
    qa.mark(r, mark ++ ":{d}", .{uid});
    if (on) qa.mark(r, mark ++ "-on:{d}", .{uid});
    const fill = if (on) ctx.col(.accent) else if (hb.hovered) ctx.col(.hover) else ctx.col(.sidebar).mix(ctx.col(.text), 0.06);
    d.rect(dl, r, fill, 10);
    if (!on) d.border(dl, r, ctx.col(.border), 10, 1);
    // O "ligado" leva um visto; o desligado, uma bolinha vazia.
    const ink = if (on) ctx.col(.accent_text) else ctx.col(.muted);
    const mx = r.x + 10;
    const my = r.y + r.h / 2;
    if (on) {
        d.line(dl, mx - 3.5, my, mx - 1, my + 2.5, ink, 1.6);
        d.line(dl, mx - 1, my + 2.5, mx + 3.5, my - 3, ink, 1.6);
    } else c.ImDrawList_AddCircleEx(dl, d.v(mx, my), 3.5, ink.u(), 0, 1.3, 0);
    d.text(dl, font, fs, r.x + 18, d.centerY(r, fs), ink, label);
    d.tip(ctx, r, tip, hb.hovered);
    return hb.clicked;
}

/// Volume individual de cada pessoa na call. Um "card" flutuante com sliders e o
/// botão de silenciar só aquela pessoa (o volume guardado fica), sem mexer no
/// volume do sistema. Embaixo de cada um, "Tirar ruído" e "Igualar volume" só para
/// aquela pessoa, desligados de começo (net/voice.zig faz o trabalho, e desligados
/// não gastam nada).
fn mixer(ctx: *d.Ctx, x: f32, y: f32) void {
    const vc = ctx.st.voice orelse return;
    const cs = ctx.store.channel(vc) orelse return;
    var count: usize = 0;
    for (cs.voice_members.items) |uid| if (uid != ctx.store.me) {
        count += 1;
    };
    const wd: f32 = 318;
    const header: f32 = 52;
    const row: f32 = 68;
    const max_h = @max(ctx.win.h - 24, 120);
    const fit_rows: usize = @intFromFloat(@max((max_h - header - 12) / row, 1));
    const shown = @min(@min(count, 9), fit_rows);
    const h: f32 = @min(header + @as(f32, @floatFromInt(@max(shown, 1))) * row + (if (count > shown) @as(f32, 20) else 0) + 12, max_h);
    const r = fit(ctx, x, y, wd, h);
    const dl = beginWindow("##voice-mixer", r);
    defer c.ImGui_End();
    qa.mark(r, "voice-mixer-card", .{});
    d.shadow(dl, r, 14, 22, ctx.col(.shadow).alpha(0.55));
    d.rect(dl, r, ctx.col(.elevated), 14);
    d.border(dl, r, ctx.col(.border), 14, 1);
    d.rect(dl, .{ .x = r.x + 1, .y = r.y + 1, .w = r.w - 2, .h = 2.5 }, ctx.col(.accent).alpha(0.85), 4);

    // Cabeçalho.
    d.text(dl, ctx.ui.get(.bold), 14, r.x + 16, r.y + 13, ctx.col(.text), i18n.tr("Mixer da call", "Call mixer"));
    d.text(dl, ctx.ui.get(.regular), 11, r.x + 16, r.y + 31, ctx.col(.muted), i18n.tr("volume de cada pessoa · 100% = normal", "each person's volume · 100% = normal"));
    const xr: d.Rect = .{ .x = r.right() - 37, .y = r.y + 9, .w = 28, .h = 28 };
    const xh = d.hit(ctx, 7100, xr);
    qa.mark(xr, "voice-mixer-close", .{});
    if (xh.hovered) d.rect(dl, xr, ctx.col(.hover), 7);
    const xc = xr.x + 14;
    const xy = xr.y + 14;
    d.line(dl, xc - 5, xy - 5, xc + 5, xy + 5, ctx.col(.muted), 1.8);
    d.line(dl, xc + 5, xy - 5, xc - 5, xy + 5, ctx.col(.muted), 1.8);
    if (xh.clicked) return close(ctx);

    if (count == 0) {
        d.text(dl, ctx.ui.get(.regular), 12, r.x + 16, r.y + header + 8, ctx.col(.muted), i18n.tr("só você na call", "you're alone in the call"));
        return;
    }

    // Linhas: avatar + nome + slider + porcentagem + botão de mudo.
    var yy = r.y + header;
    var drawn: usize = 0;
    for (cs.voice_members.items) |uid| {
        if (uid == ctx.store.me) continue;
        if (drawn >= shown) break;
        drawn += 1;
        const u = ctx.store.user(uid) orelse continue;
        const name = ctx.store.nameIn(cs.info.guild, uid) orelse u.name;
        const speaking = ctx.store.isSpeaking(uid, ctx.now_ms);
        const rowr: d.Rect = .{ .x = r.x + 8, .y = yy, .w = r.w - 16, .h = row - 2 };
        const hover = rowr.contains(ctx.mouse.x, ctx.mouse.y);
        if (hover) d.rect(dl, rowr, ctx.col(.hover).alpha(0.6), 8);
        const ax = rowr.x + 22;
        const ay = rowr.y + rowr.h / 2;
        if (speaking) c.ImDrawList_AddCircleEx(dl, d.v(ax, ay), 15.5, ctx.col(.online).u(), 0, 2, 0);
        w.avatarIn(ctx, dl, cs.info.guild, ax, ay, 28, uid, .circle, null, 1);
        _ = d.textClipped(dl, ctx.ui.get(.semibold), 13, rowr.x + 46, rowr.y + 6, ctx.col(.text), name, 86);
        w.markName(rowr, "mixer", uid, name);
        const vf = ctx.store.voiceFlags(uid);
        const vf_text = if (vf.deaf) i18n.tr("surdo pelo servidor", "server deafened") else if (vf.serverMuted()) i18n.tr("mudo pelo servidor", "server muted") else if (vf.self_deaf) i18n.tr("surdo", "deafened") else if (vf.self_mute) i18n.tr("mudo", "muted") else "";
        d.text(dl, ctx.ui.get(.regular), 10, rowr.x + 46, rowr.y + 23, if (speaking) ctx.col(.online) else if (vf.deaf or vf.serverMuted()) ctx.col(.danger) else ctx.col(.faint), if (speaking) i18n.tr("falando", "speaking") else vf_text);

        const vol = ctx.st.volumes.volume(uid);
        const local_mute = ctx.st.volumes.isMuted(uid);
        const off = vol <= 0.001 or local_mute;
        const tr: d.Rect = .{ .x = rowr.x + 140, .y = rowr.y + rowr.h / 2 - 2, .w = 92, .h = 6 };
        const hr: d.Rect = .{ .x = tr.x - 6, .y = tr.y - 9, .w = tr.w + 12, .h = 24 };
        const hb = d.hit(ctx, 7200 +% @as(usize, @truncate(uid)), hr);
        qa.mark(hr, "voice-volume:{d}", .{uid});
        if (hb.held) ctx.act(.{ .set_voice_volume = .{ .user = uid, .volume = volumeAt(ctx.mouse.x, tr) } });
        const k = std.math.clamp(vol / 2.0, 0, 1);
        d.rect(dl, tr, ctx.col(.sidebar).mix(ctx.col(.text), 0.1), 3);
        d.line(dl, tr.x + tr.w / 2, tr.y - 2, tr.x + tr.w / 2, tr.y + tr.h + 2, ctx.col(.faint).alpha(0.7), 1);
        d.rect(dl, .{ .x = tr.x, .y = tr.y, .w = tr.w * k, .h = tr.h }, if (off) ctx.col(.faint) else ctx.col(.accent), 3);
        const kx = tr.x + tr.w * k;
        d.rect(dl, .{ .x = kx - 5, .y = tr.y - 4, .w = 10, .h = 14 }, d.Rgba.white, 3);

        var buf: [16]u8 = undefined;
        // O mesmo número do menu da pessoa (volumePct).
        const p = volumePct(vol);
        const pct = std.fmt.bufPrint(&buf, "{d}%", .{p}) catch "";
        d.text(dl, ctx.ui.get(.semibold), 11, tr.right() + 8, tr.y - 4, if (off) ctx.col(.faint) else ctx.col(.muted), pct);
        qa.mark(.{ .x = tr.right() + 8, .y = tr.y - 4, .w = 30, .h = 14 }, "voice-volume-pct:{d}:{d}", .{ uid, p });

        const mr: d.Rect = .{ .x = rowr.right() - 30, .y = rowr.y + 7, .w = 26, .h = 26 };
        const mh = d.hit(ctx, 7300 +% @as(usize, @truncate(uid)), mr);
        qa.mark(mr, "voice-mute:{d}", .{uid});
        if (mh.hovered) d.rect(dl, mr, ctx.col(.hover), 6);
        const ink = if (off) ctx.col(.faint) else ctx.col(.muted).mix(ctx.col(.text), if (mh.hovered) 0.5 else 0.15);
        icons.speaker(dl, mr.x + 13, mr.y + 13, ink.u());
        if (local_mute) {
            d.line(dl, mr.x + 6, mr.y + 20, mr.x + 20, mr.y + 6, ctx.col(.danger), 1.8);
            qa.mark(mr, "voice-muted:{d}", .{uid});
        }
        // O mesmo "Silenciar para mim" do menu da pessoa.
        if (mh.clicked) ctx.act(.{ .set_voice_mute = .{ .user = uid, .mute = !local_mute } });

        // Tirar ruído e igualar volume, só para esta pessoa.
        const dn = ctx.st.volumes.denoiseOn(uid);
        const lv = ctx.st.volumes.levelOn(uid);
        var cx = rowr.x + 46;
        const cy = rowr.y + 42;
        if (dspChip(ctx, dl, &cx, cy, 7400 +% @as(usize, @truncate(uid)), i18n.tr("Tirar ruído", "Remove noise"), dn, i18n.tr("Tira o chiado e o barulho de fundo do som desta pessoa, só aqui. Usa um pouco de CPU enquanto ela fala.", "Removes hiss and background noise from this person's sound, only here. Uses a little CPU while they talk."), "voice-denoise", uid))
            ctx.act(.{ .set_voice_dsp = .{ .user = uid, .denoise = !dn, .level = lv } });
        if (dspChip(ctx, dl, &cx, cy, 7500 +% @as(usize, @truncate(uid)), i18n.tr("Igualar volume", "Even out volume"), lv, i18n.tr("Sobe quem fala baixo e desce quem fala alto, para perto do mesmo volume dos outros.", "Raises a quiet voice and lowers a loud one, close to everyone else's level."), "voice-level", uid))
            ctx.act(.{ .set_voice_dsp = .{ .user = uid, .denoise = dn, .level = !lv } });
        yy += row;
    }
    if (count > shown) {
        var more: [48]u8 = undefined;
        const t = std.fmt.bufPrint(&more, "+{d} {s}", .{ count - shown, i18n.tr("mais", "more") }) catch "";
        d.text(dl, ctx.ui.get(.medium), 11, r.x + 16, yy + 4, ctx.col(.faint), t);
    }
}
