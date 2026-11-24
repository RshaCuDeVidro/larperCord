//! O lado do app dos plugins (ver engine.zig): lê a pasta, guarda quem está
//! desligado e os hosts aprovados, traduz teclas e entrega eventos, avisos e
//! mensagens. A pasta é ~/.config/larpercord/plugins (ou
//! $XDG_CONFIG_HOME/larpercord/plugins); as escolhas ficam em
//! ~/.config/larpercord/plugins.kdl e os dados de cada plugin, por conta, em
//! ~/.config/larpercord/plugin-data. No QA é tudo em qa-out e nada de escolha é salvo.
const std = @import("std");
const c = @import("c");
const App = @import("../app.zig").App;
const engine = @import("engine.zig");
const runtime = @import("runtime.zig");
const http_curl = @import("http_curl.zig");
const types = @import("../core/types.zig");
const Store = @import("../core/store.zig").Store;
const kdl = @import("../theme/kdl.zig");
const i18n = @import("../ui/i18n.zig");
const nowMs = @import("../net/fake_gateway.zig").nowMs;
const fsutil = @import("../platform/fsutil.zig");
const sys = @import("../platform/sys.zig");
const platform = @import("../platform/window.zig");
const plugin_confirm = @import("../ui/plugin_confirm.zig");

pub const Engine = engine.Engine;

/// QA: notificações do sistema que teriam saído, e o texto da última.
pub var qa_desktop: u32 = 0;
pub var qa_desktop_text: [256]u8 = undefined;
pub var qa_desktop_len: usize = 0;

var app_global: ?*App = null;

pub fn appOf() *App {
    return app_global.?;
}

pub fn init(app: *App) void {
    app_global = app;
    app.plugins = Engine.init(app.gpa, .{
        .ctx = app,
        .notify = &notify,
        .send = &send,
        .where = &where,
        .key = &keyCode,
        .rescan = &rescan,
        .save = &save,
        .failed = &failed,
        .insert = &insert,
        .jump = &jump,
        .copy = &copy,
        .open_url = &openUrl,
        .messages = &messages,
        .wake = &wake,
        .read_data = &readData,
        .write_data = &writeData,
        .keep_broken_data = &keepBroken,
        .http_start = &http_curl.start,
        .http_stop = &http_curl.stop,
        .action = &action,
        .secret_get = &secretGet,
        .secret_set = &secretSet,
        .secret_delete = &secretDelete,
    });
    engine.current = &app.plugins;
    runtime.lang_en = &i18n.en;
    // O código de cada idioma da interface, como o plugin vê (um idioma novo entra sozinho).
    runtime.lang_code = &struct {
        fn f() [*:0]const u8 {
            return @tagName(i18n.current());
        }
    }.f;
    // Prints da documentação: sempre iguais, sem os plugins de quem roda.
    if (app.opts.shot != null) return;
    var buf: [512]u8 = undefined;
    if (dirPath(app, &buf)) |d| app.plugins.setDir(d);
    // No QA a pasta começa vazia e o roteiro usa o botão Recarregar.
    if (app.opts.qa) return;
    loadPrefs(app);
    rescan(app);
}

fn dirPath(app: *const App, buf: []u8) ?[:0]const u8 {
    if (app.opts.qa) return std.fmt.bufPrintSentinel(buf, "qa-out/plugins", .{}, 0) catch null;
    return fsutil.configPath(buf, "plugins");
}

/// Lê os *.lua da pasta (em ordem alfabética) e recarrega todos.
fn rescan(ctx: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(ctx));
    const e = &app.plugins;
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var files: std.ArrayList(engine.Source) = .empty;
    var dbuf: [512]u8 = undefined;
    if (dirPath(app, &dbuf)) |dir| {
        var count: c_int = 0;
        if (c.SDL_GlobDirectory(dir.ptr, "*.lua", 0, &count)) |names| {
            defer c.SDL_free(@ptrCast(names));
            var list: std.ArrayList([]const u8) = .empty;
            for (0..@intCast(count)) |i| {
                const n = std.mem.span(names[i] orelse continue);
                // Só arquivos diretos da pasta (o glob não desce, mas confere).
                if (std.mem.indexOfAny(u8, n, "/\\") != null or n.len > 120) continue;
                list.append(a, a.dupe(u8, n) catch continue) catch continue;
            }
            @import("../core/sort.zig").stable([]const u8, list.items, {}, struct {
                fn lt(_: void, x: []const u8, y: []const u8) bool {
                    return std.mem.lessThan(u8, x, y);
                }
            }.lt);
            for (list.items[0..@min(list.items.len, engine.max_plugins)]) |n| {
                var pbuf: [700]u8 = undefined;
                const path = std.fmt.bufPrintSentinel(&pbuf, "{s}/{s}", .{ dir, n }, 0) catch continue;
                var info: c.SDL_PathInfo = undefined;
                if (!c.SDL_GetPathInfo(path.ptr, &info) or info.type != c.SDL_PATHTYPE_FILE) continue;
                // Grande demais: entra na lista vazio (e dá erro de "arquivo grande").
                var src: []const u8 = i18n.tr("error('arquivo maior que 256 KB')", "error('file larger than 256 KB')");
                if (info.size <= engine.max_source) {
                    var size: usize = 0;
                    const data = c.SDL_LoadFile(path.ptr, &size) orelse continue;
                    defer c.SDL_free(data);
                    src = a.dupe(u8, @as([*]const u8, @ptrCast(data))[0..size]) catch continue;
                }
                files.append(a, .{ .name = n, .src = src }) catch continue;
            }
        }
    }
    e.load(files.items, app.store.ready);
}

fn prefsPath(buf: []u8) ?[:0]const u8 {
    return fsutil.configPath(buf, "plugins.kdl");
}

fn loadPrefs(app: *App) void {
    var buf: [512]u8 = undefined;
    const path = prefsPath(&buf) orelse return;
    var size: usize = 0;
    const data = c.SDL_LoadFile(path.ptr, &size) orelse return;
    defer c.SDL_free(data);
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const src = arena.allocator().dupe(u8, @as([*]const u8, @ptrCast(data))[0..size]) catch return;
    const nodes = kdl.parse(arena.allocator(), src, null) catch return;
    for (nodes) |*n| app.plugins.applyPrefNode(n);
}

fn save(ctx: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(ctx));
    if (app.opts.qa or app.opts.shot != null) return;
    var buf: [512]u8 = undefined;
    const path = prefsPath(&buf) orelse return;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(app.gpa);
    app.plugins.writePrefs(app.gpa, &out) catch return;
    _ = fsutil.writePrivate(path, out.items);
}

/// A largura ou o lado do painel mudaram (a interface chama ao soltar o mouse).
pub fn savePrefs() void {
    if (app_global) |app| save(app);
}

// --- Host -------------------------------------------------------------------

/// Quantas notificações do sistema cada plugin manda em 1 minuto, e todos juntos:
/// nem um plugin com defeito nem uma rajada de mensagens enche a área de trabalho,
/// e um plugin barulhento não come o aviso de um lembrete.
const desktop_per_minute = 6;
const desktop_all_per_minute = 20;
const Quota = struct { key: u64 = 0, from: i64 = 0, n: u32 = 0 };
var desktop_quota: [engine.max_plugins + 1]Quota = @splat(.{});

fn quotaFor(plugin: []const u8, now: i64) *Quota {
    const key = std.hash.Wyhash.hash(0, plugin) | 1;
    var oldest = &desktop_quota[1];
    for (desktop_quota[1..]) |*q| {
        if (q.key == key) return q;
        if (q.from < oldest.from) oldest = q;
    }
    oldest.* = .{ .key = key, .from = now };
    return oldest;
}

/// Mais uma notificação cabe nesta cota?
fn quotaTake(q: *Quota, limit: u32, now: i64) bool {
    if (now - q.from >= 60_000) {
        q.from = now;
        q.n = 0;
    }
    if (q.n >= limit) return false;
    q.n += 1;
    return true;
}

fn notify(ctx: *anyopaque, plugin: []const u8, text: []const u8, desktop: bool) void {
    const app: *App = @ptrCast(@alignCast(ctx));
    app.st.showToast(nowMs(), false, "{s}", "{s}", .{text});
    const flags = app.win.flags();
    const hidden = flags & c.SDL_WINDOW_HIDDEN != 0;
    const focused = !hidden and flags & c.SDL_WINDOW_INPUT_FOCUS != 0 and !app.qa_blur;
    // Sem `desktop`, só com a pessoa longe da janela (e fora do modo foco, que
    // só deixa passar DMs e menções).
    if (!desktop and (focused or app.st.filtros.focusOn(nowMs()))) return;
    if (!app.st.settings.desktop_notifs) return;
    const now = nowMs();
    if (!quotaTake(quotaFor(plugin, now), desktop_per_minute, now)) return;
    if (!quotaTake(&desktop_quota[0], desktop_all_per_minute, now)) return;
    var tb: [160]u8 = undefined;
    const title = std.fmt.bufPrintSentinel(&tb, "larperCord · {s}", .{plugin}, 0) catch return;
    var cut = @min(text.len, 200);
    while (cut > 0 and cut < text.len and (text[cut] & 0xC0) == 0x80) cut -= 1;
    var bb: [208]u8 = undefined;
    const body = std.fmt.bufPrintSentinel(&bb, "{s}", .{text[0..cut]}, 0) catch return;
    if (app.opts.qa) {
        qa_desktop +%= 1;
        qa_desktop_len = @min(body.len, qa_desktop_text.len);
        @memcpy(qa_desktop_text[0..qa_desktop_len], body[0..qa_desktop_len]);
        return;
    }
    app.desktopNotify(title, body);
}

fn send(ctx: *anyopaque, channel: u64, text: []const u8, reply_to: u64) bool {
    const app: *App = @ptrCast(@alignCast(ctx));
    if (!app.store.ready) return false;
    var ch = channel;
    // Respondendo: no canal da mensagem (e só nele).
    if (reply_to != 0) {
        const f = app.store.findAny(reply_to) orelse return false;
        if (f.m.deleted or f.m.msg.id == 0) return false;
        if (ch == 0) ch = f.cs.info.id;
        if (ch != f.cs.info.id) return false;
    }
    if (ch == 0) ch = app.st.activeChannel() orelse return false;
    const cs = app.store.channel(ch) orelse return false;
    if (cs.info.kind != .text) return false;
    app.sendWith(ch, text, reply_to, false);
    return true;
}

// --- Ações dos plugins na conta ------------------------------------------------------

/// A mensagem que a ação pede, se ainda existe e é de verdade (nem apagada, nem de
/// sistema, nem pendente).
fn actionTarget(app: *App, id: types.Id) @TypeOf(Store.findAny(undefined, 0)) {
    const f = app.store.findAny(id) orelse return null;
    if (f.m.deleted or f.m.pending or f.m.msg.id == 0 or f.m.msg.system != .none) return null;
    return f;
}

/// larper.react, edit, delete, pin, thread e attach, depois do gesto conferido
/// (engine.zig): o mesmo caminho dos botões do app, com as mesmas permissões, os
/// mesmos limites de envio e a demonstração respondendo igual. Apagar e anexar só
/// depois de a pessoa confirmar (ui/plugin_confirm.zig).
fn action(ctx: *anyopaque, _: []const u8, title: []const u8, a: *const engine.Action) ?[]const u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    if (!app.store.ready) return i18n.tr("o app ainda não conectou", "the app isn't connected yet");
    const gone = i18n.tr("mensagem não encontrada", "message not found");
    switch (a.*) {
        .react => |r| {
            const f = actionTarget(app, r.id) orelse return gone;
            const emoji = if (runtime.customEmoji(r.emoji)) |ce| types.Reaction.initCustom(ce.name, ce.id, ce.animated) else types.Reaction.init(r.emoji);
            // A reação do app alterna; a do plugin só põe.
            for (f.m.reactionSlice()) |*x| if (x.same(&emoji) and x.me) return null;
            app.handle(.{ .react = .{ .id = r.id, .emoji = emoji } });
        },
        .edit => |x| {
            const f = actionTarget(app, x.id) orelse return gone;
            if (f.m.msg.author != app.store.me) return i18n.tr("larper.edit: só dá para editar mensagens suas", "larper.edit: only your own messages can be edited");
            app.editTo(x.id, x.text, &.{});
        },
        .delete => |x| {
            const f = actionTarget(app, x.id) orelse return gone;
            const own = f.m.msg.author == app.store.me;
            const mod = app.store.can(f.cs.info.guild, types.perm.manage_messages);
            if (!own and !mod) return i18n.tr("larper.delete: sem permissão para apagar essa mensagem", "larper.delete: no permission to delete that message");
            plugin_confirm.ask(&app.st, .{ .delete = x.id }, title);
        },
        .pin => |x| {
            const f = actionTarget(app, x.id) orelse return gone;
            if (app.store.channelPermissions(&f.cs.info) & types.perm.manage_messages == 0) return i18n.tr("larper.pin: sem permissão para fixar neste canal", "larper.pin: no permission to pin in this channel");
            if (f.m.msg.pinned == x.add) return null;
            app.handle(.{ .pin_message = .{ .channel = f.cs.info.id, .id = x.id, .add = x.add } });
        },
        .thread => |x| {
            const f = actionTarget(app, x.id) orelse return gone;
            if (f.m.msg.thread != 0) return i18n.tr("larper.thread: essa mensagem já tem uma thread", "larper.thread: that message already has a thread");
            if (!app.store.canCreateThread(&f.cs.info)) return i18n.tr("larper.thread: sem permissão para criar threads neste canal", "larper.thread: no permission to create threads in this channel");
            const name = app.gpa.dupe(u8, x.name) catch return null;
            app.handle(.{ .create_thread = .{ .message = x.id, .name = name } });
        },
        .attach => |x| {
            const ch = if (x.channel != 0) x.channel else app.st.activeChannel() orelse return i18n.tr("larper.attach: nenhum canal aberto", "larper.attach: no channel open");
            const cs = app.store.channel(ch) orelse return i18n.tr("larper.attach: canal não encontrado", "larper.attach: channel not found");
            if (cs.info.kind != .text) return i18n.tr("larper.attach: esse canal não aceita mensagens", "larper.attach: that channel doesn't take messages");
            if (cs.info.guild != 0 and app.store.channelPermissions(&cs.info) & types.perm.attach_files == 0) return i18n.tr("larper.attach: sem permissão para anexar arquivos neste canal", "larper.attach: no permission to attach files in this channel");
            // O arquivo vai para a caixa desse canal: ele abre antes da pergunta.
            if (app.st.activeChannel() != ch) app.openChannel(ch, false);
            plugin_confirm.ask(&app.st, .{ .attach = ch }, title);
        },
    }
    return null;
}

// --- Segredos dos plugins (na thread dos plugins) -------------------------------------
//
// No chaveiro do sistema, uma entrada por plugin e chave: no Linux pelo secret-tool
// (`service larpercord-plugin plugin NOME key CHAVE`, o valor pela entrada padrão,
// nunca na linha de comando), no Windows no Gerenciador de Credenciais
// (`larperCord/plugin/NOME/CHAVE`). Sem chaveiro, como o token das contas
// (net/accounts_store.zig): um arquivo só do dono em plugin-secrets/NOME/CHAVE. O
// nome e a chave só têm letras, números, ".", "_" e "-" (runtime.safeName), e nenhum
// valor vai para o registro. No QA e na demonstração do navegador, só na memória.

const secrets_service = "larpercord-plugin";

var qa_secrets: std.StringHashMapUnmanaged([]u8) = .empty;
var qa_secrets_lock: ?*c.SDL_Mutex = null;

fn memoryOnly(app: *const App) bool {
    return app.opts.qa or app.opts.shot != null or sys.web;
}

fn secretSafe(plugin: []const u8, key: []const u8) bool {
    return runtime.safeName(plugin, 120) and runtime.safeName(key, 64);
}

fn secretPath(buf: []u8, plugin: []const u8, key: []const u8) ?[:0]const u8 {
    var nb: [220]u8 = undefined;
    const rel = std.fmt.bufPrint(&nb, "plugin-secrets/{s}/{s}", .{ plugin, key }) catch return null;
    return fsutil.configPath(buf, rel);
}

fn qaKey(buf: []u8, plugin: []const u8, key: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}\x00{s}", .{ plugin, key }) catch "";
}

fn qaLock() *c.SDL_Mutex {
    if (qa_secrets_lock == null) qa_secrets_lock = c.SDL_CreateMutex();
    return qa_secrets_lock.?;
}

fn secretGet(ctx: *anyopaque, gpa: std.mem.Allocator, plugin: []const u8, key: []const u8) ?[]u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    if (!secretSafe(plugin, key)) return null;
    if (memoryOnly(app)) {
        var kb: [200]u8 = undefined;
        c.SDL_LockMutex(qaLock());
        defer c.SDL_UnlockMutex(qaLock());
        const v = qa_secrets.get(qaKey(&kb, plugin, key)) orelse return null;
        return gpa.dupe(u8, v) catch null;
    }
    var buf: [2560]u8 = undefined;
    defer std.crypto.secureZero(u8, &buf);
    var cbuf: [320]u8 = undefined;
    if (sys.windows) {
        const target = std.fmt.bufPrintSentinel(&cbuf, "larperCord/plugin/{s}/{s}", .{ plugin, key }, 0) catch return null;
        if (sys.credRead(target.ptr, &buf)) |v| if (v.len > 0) return gpa.dupe(u8, v) catch null;
    } else {
        const cmd = std.fmt.bufPrintSentinel(&cbuf, "secret-tool lookup service " ++ secrets_service ++ " plugin {s} key {s} 2>/dev/null", .{ plugin, key }, 0) catch return null;
        if (c.popen(cmd.ptr, "r")) |f| {
            const n = c.fread(&buf, 1, buf.len, f);
            _ = c.pclose(f);
            if (n > 0) return gpa.dupe(u8, buf[0..n]) catch null;
        }
    }
    // Sem chaveiro: o arquivo só do dono.
    var pbuf: [640]u8 = undefined;
    const path = secretPath(&pbuf, plugin, key) orelse return null;
    if (!sys.ownerOnly(path.ptr)) return null;
    var size: usize = 0;
    const data = c.SDL_LoadFile(path.ptr, &size) orelse return null;
    defer {
        std.crypto.secureZero(u8, @as([*]u8, @ptrCast(data))[0..size]);
        c.SDL_free(data);
    }
    if (size == 0) return null;
    return gpa.dupe(u8, @as([*]const u8, @ptrCast(data))[0..size]) catch null;
}

fn secretSet(ctx: *anyopaque, plugin: []const u8, key: []const u8, value: []const u8) bool {
    const app: *App = @ptrCast(@alignCast(ctx));
    if (!secretSafe(plugin, key)) return false;
    if (memoryOnly(app)) {
        var kb: [200]u8 = undefined;
        const k = qaKey(&kb, plugin, key);
        c.SDL_LockMutex(qaLock());
        defer c.SDL_UnlockMutex(qaLock());
        const own_v = app.gpa.dupe(u8, value) catch return false;
        if (qa_secrets.fetchRemove(k)) |old| {
            app.gpa.free(old.key);
            app.gpa.free(old.value);
        }
        const own_k = app.gpa.dupe(u8, k) catch {
            app.gpa.free(own_v);
            return false;
        };
        qa_secrets.put(app.gpa, own_k, own_v) catch {
            app.gpa.free(own_k);
            app.gpa.free(own_v);
            return false;
        };
        return true;
    }
    var cbuf: [360]u8 = undefined;
    var pbuf: [640]u8 = undefined;
    const path = secretPath(&pbuf, plugin, key);
    if (sys.windows) {
        const target = std.fmt.bufPrintSentinel(&cbuf, "larperCord/plugin/{s}/{s}", .{ plugin, key }, 0) catch return false;
        if (sys.credWrite(target.ptr, "larperCord plugin", value)) {
            if (path) |p| _ = c.unlink(p.ptr);
            return true;
        }
    } else {
        const cmd = std.fmt.bufPrintSentinel(&cbuf, "secret-tool store --label='larperCord ({s})' service " ++ secrets_service ++ " plugin {s} key {s} 2>/dev/null", .{ plugin, plugin, key }, 0) catch return false;
        if (c.popen(cmd.ptr, "w")) |f| {
            const wrote = c.fwrite(value.ptr, 1, value.len, f);
            if (c.pclose(f) == 0 and wrote == value.len) {
                // Não deixa cópia velha em arquivo.
                if (path) |p| _ = c.unlink(p.ptr);
                return true;
            }
        }
    }
    const p = path orelse return false;
    return fsutil.writePrivate(p, value);
}

fn secretDelete(ctx: *anyopaque, plugin: []const u8, key: []const u8) void {
    const app: *App = @ptrCast(@alignCast(ctx));
    if (!secretSafe(plugin, key)) return;
    if (memoryOnly(app)) {
        var kb: [200]u8 = undefined;
        c.SDL_LockMutex(qaLock());
        defer c.SDL_UnlockMutex(qaLock());
        if (qa_secrets.fetchRemove(qaKey(&kb, plugin, key))) |old| {
            std.crypto.secureZero(u8, old.value);
            app.gpa.free(old.key);
            app.gpa.free(old.value);
        }
        return;
    }
    var cbuf: [320]u8 = undefined;
    if (sys.windows) {
        if (std.fmt.bufPrintSentinel(&cbuf, "larperCord/plugin/{s}/{s}", .{ plugin, key }, 0)) |target| sys.credDelete(target.ptr) else |_| {}
    } else if (std.fmt.bufPrintSentinel(&cbuf, "secret-tool clear service " ++ secrets_service ++ " plugin {s} key {s} 2>/dev/null", .{ plugin, key }, 0)) |cmd| {
        if (c.popen(cmd.ptr, "r")) |f| _ = c.pclose(f);
    } else |_| {}
    var pbuf: [640]u8 = undefined;
    if (secretPath(&pbuf, plugin, key)) |p| _ = c.unlink(p.ptr);
}

fn where(ctx: *anyopaque) engine.Where {
    const app: *App = @ptrCast(@alignCast(ctx));
    const ch = app.st.activeChannel() orelse return .{};
    if (app.st.friends) return .{};
    const cs = app.store.channel(ch) orelse return .{};
    var w: engine.Where = .{ .channel = ch, .channel_name = cs.info.name };
    if (app.store.guild(cs.info.guild)) |g| {
        w.guild = g.id;
        w.guild_name = g.name;
    }
    return w;
}

fn failed(ctx: *anyopaque, plugin: []const u8, msg: []const u8) void {
    const app: *App = @ptrCast(@alignCast(ctx));
    app.st.showToast(nowMs(), true, "plugin {s}: {s}", "plugin {s}: {s}", .{ plugin, msg });
    std.log.warn("plugin {s}: {s}", .{ plugin, msg });
}

fn insert(ctx: *anyopaque, text: []const u8) void {
    const app: *App = @ptrCast(@alignCast(ctx));
    @import("../ui/popup.zig").insertText(&app.st, text, false);
}

fn jump(ctx: *anyopaque, channel: u64, id: u64) void {
    const app: *App = @ptrCast(@alignCast(ctx));
    app.handle(.{ .open_message = .{ .channel = channel, .id = id } });
}

fn copy(ctx: *anyopaque, text: []const u8) void {
    const app: *App = @ptrCast(@alignCast(ctx));
    app.handle(.{ .copy = app.gpa.dupe(u8, text) catch return });
}

fn openUrl(_: *anyopaque, url: []const u8) void {
    @import("../ui/attachments.zig").openUrl(url);
}

/// A mensagem como o plugin vê. Nunca o que foi apagado (com o registro ligado
/// ela continua na memória) nem o texto de antes de uma edição.
pub fn pluginMessage(app: *const App, store: *const Store, m: *const types.Message) engine.Message {
    const cs = store.channel(m.channel);
    const guild_id: types.Id = if (cs) |x| x.info.guild else 0;
    const g = if (guild_id != 0) store.guild(guild_id) else null;
    return .{
        .id = m.id,
        .content = m.content,
        .author = m.author,
        .author_name = if (store.user(m.author)) |u| u.name else "?",
        .channel = m.channel,
        .channel_name = if (cs) |x| x.info.name else "",
        .guild = if (g) |x| x.id else 0,
        .guild_name = if (g) |x| x.name else "",
        .mine = m.author == store.me,
        .ignored = app.st.filtros.isIgnored(m.author),
        .timestamp = m.timestamp,
        .attachments = @intCast(@min(m.attachments.len, std.math.maxInt(u16))),
        .reply_to = m.reply_to,
    };
}

fn messages(ctx: *anyopaque, channel: u64, limit: u32, out: *engine.MsgList) void {
    const app: *App = @ptrCast(@alignCast(ctx));
    const ch = if (channel != 0) channel else app.st.activeChannel() orelse return;
    const cs = app.store.channel(ch) orelse return;
    out.channel = ch;
    // A linha "novas mensagens" guarda até onde estava lido antes de abrir o canal.
    out.last_read = if (cs.divider_after > 1) cs.divider_after else if (cs.info.unread) cs.read_id else 0;
    const items = cs.messages.items;
    // As últimas `limit`, sem o que foi apagado, as pendentes e as de sistema.
    var first = items.len;
    var kept: u32 = 0;
    while (first > 0 and kept < limit) {
        first -= 1;
        if (visible(&items[first])) kept += 1;
    }
    for (items[first..]) |*m| {
        if (!visible(m) or !out.wants(m.msg.content)) continue;
        var pm = pluginMessage(app, &app.store, &m.msg);
        pm.mentions_me = app.store.mentionsMeCached(cs.info.guild, m);
        var refs: [16]engine.FileRef = undefined;
        if (out.files) {
            var n: usize = 0;
            for (m.msg.attachments) |*att| {
                // O que veio de um link já está no texto da mensagem.
                if (att.embed or n == refs.len) continue;
                refs[n] = .{ .name = att.filename, .url = att.url, .size = att.size };
                n += 1;
            }
            pm.files = refs[0..n];
        }
        out.add(&pm);
    }
}

fn visible(m: *const @import("../core/store.zig").StoredMessage) bool {
    return !m.deleted and !m.pending and m.msg.id != 0 and m.msg.system == .none;
}

fn wake(ctx: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(ctx));
    platform.Window.wake(app.win.wake_type, .plugins);
}

// --- Dados de cada plugin (na thread dos plugins) -----------------------------------

fn dataPath(app: *const App, buf: []u8, account: u64, plugin: []const u8) ?[:0]const u8 {
    if (app.opts.qa) return std.fmt.bufPrintSentinel(buf, "qa-out/plugin-data/{d}/{s}.json", .{ account, plugin }, 0) catch null;
    var nb: [200]u8 = undefined;
    const rel = std.fmt.bufPrint(&nb, "plugin-data/{d}/{s}.json", .{ account, plugin }) catch return null;
    return fsutil.configPath(buf, rel);
}

fn readData(ctx: *anyopaque, gpa: std.mem.Allocator, account: u64, plugin: []const u8) ?[]u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    var buf: [640]u8 = undefined;
    const path = dataPath(app, &buf, account, plugin) orelse return null;
    var size: usize = 0;
    const data = c.SDL_LoadFile(path.ptr, &size) orelse return null;
    defer c.SDL_free(data);
    return gpa.dupe(u8, @as([*]const u8, @ptrCast(data))[0..size]) catch null;
}

fn writeData(ctx: *anyopaque, account: u64, plugin: []const u8, bytes: []const u8) bool {
    const app: *App = @ptrCast(@alignCast(ctx));
    var buf: [640]u8 = undefined;
    const path = dataPath(app, &buf, account, plugin) orelse return false;
    return fsutil.writePrivate(path, bytes);
}

fn keepBroken(ctx: *anyopaque, account: u64, plugin: []const u8) void {
    const app: *App = @ptrCast(@alignCast(ctx));
    var buf: [640]u8 = undefined;
    const path = dataPath(app, &buf, account, plugin) orelse return;
    fsutil.keepBroken(path);
}

fn keyCode(name: []const u8) ?i32 {
    if (name.len == 1) {
        const ch = name[0];
        if (ch >= 'a' and ch <= 'z') return c.ImGuiKey_A + @as(i32, ch - 'a');
        if (ch >= '0' and ch <= '9') return c.ImGuiKey_0 + @as(i32, ch - '0');
    }
    if (name.len >= 2 and name[0] == 'f') {
        const n = std.fmt.parseInt(u8, name[1..], 10) catch return null;
        if (n >= 1 and n <= 24) return c.ImGuiKey_F1 + @as(i32, n - 1);
        return null;
    }
    const named = [_]struct { n: []const u8, k: c_int }{
        .{ .n = "enter", .k = c.ImGuiKey_Enter },    .{ .n = "space", .k = c.ImGuiKey_Space },
        .{ .n = "tab", .k = c.ImGuiKey_Tab },        .{ .n = "backspace", .k = c.ImGuiKey_Backspace },
        .{ .n = "delete", .k = c.ImGuiKey_Delete },  .{ .n = "insert", .k = c.ImGuiKey_Insert },
        .{ .n = "home", .k = c.ImGuiKey_Home },      .{ .n = "end", .k = c.ImGuiKey_End },
        .{ .n = "pageup", .k = c.ImGuiKey_PageUp },  .{ .n = "pagedown", .k = c.ImGuiKey_PageDown },
        .{ .n = "up", .k = c.ImGuiKey_UpArrow },     .{ .n = "down", .k = c.ImGuiKey_DownArrow },
        .{ .n = "left", .k = c.ImGuiKey_LeftArrow }, .{ .n = "right", .k = c.ImGuiKey_RightArrow },
        .{ .n = ",", .k = c.ImGuiKey_Comma },        .{ .n = ".", .k = c.ImGuiKey_Period },
        .{ .n = "/", .k = c.ImGuiKey_Slash },        .{ .n = ";", .k = c.ImGuiKey_Semicolon },
        .{ .n = "-", .k = c.ImGuiKey_Minus },        .{ .n = "=", .k = c.ImGuiKey_Equal },
    };
    for (named) |x| if (std.mem.eql(u8, x.n, name)) return x.k;
    return null;
}

// --- Ganchos chamados pelo app ----------------------------------------------

/// MESSAGE_CREATE (antes de ir para o Store; os textos ainda são da mensagem).
pub fn onMessage(app: *App, m: types.Message) void {
    if (app.plugins.n_message == 0 or m.system != .none) return;
    const msg = pluginMessage(app, &app.store, &m);
    app.plugins.onMessage(&msg);
}

/// MESSAGE_UPDATE com texto novo (o Store acabou de aplicar). Nunca passa o de antes.
pub fn onEdit(app: *App, id: types.Id) void {
    if (app.plugins.n_edit == 0 or !app.store.ready) return;
    const f = app.store.findAny(id) orelse return;
    if (f.m.deleted or f.m.pending or f.m.msg.system != .none) return;
    const msg = pluginMessage(app, &app.store, &f.m.msg);
    app.plugins.onEdit(&msg);
}

/// MESSAGE_DELETE: a nota de plugin dessa mensagem sai, e quem pediu fica sabendo.
pub fn onDelete(app: *App, channel: types.Id, id: types.Id) void {
    app.plugins.onDelete(channel, id);
}

/// A cada quadro (antes do desenho): custa uma comparação sem plugin rodando.
pub fn frame(app: *App) void {
    const ch: u64 = if (app.st.friends) 0 else app.st.activeChannel() orelse 0;
    app.plugins.frameTick(ch, i18n.en());
}

fn pressed(ctx: *anyopaque, k: *const engine.Keybind) bool {
    const io: *c.ImGuiIO = @ptrCast(@alignCast(ctx));
    if (io.*.KeyCtrl != k.ctrl or io.*.KeyShift != k.shift or io.*.KeyAlt != k.alt or io.*.KeySuper != k.super) return false;
    return c.ImGui_IsKeyPressedEx(k.key, false);
}

/// Atalhos dos plugins (no meio do quadro, depois da interface).
pub fn pollKeys(app: *App) void {
    if (app.plugins.n_keys == 0) return;
    const st = &app.st;
    if (st.settings.open or st.palette.open or app.login.visible()) return;
    app.plugins.pollKeys(app.io, &pressed);
}

pub const MenuHit = struct { plugin: *engine.Plugin, entry: *const engine.MenuEntry };

/// A entrada `index` dos menus de plugin (a ordem em que o menu lista).
pub fn menuEntry(app: *App, kind: engine.MenuKind, index: usize) ?MenuHit {
    var i: usize = 0;
    for (app.plugins.list.items) |p| {
        if (!p.isRunning()) continue;
        for (p.menus.items) |*entry| {
            if (entry.kind != kind) continue;
            if (i == index) return .{ .plugin = p, .entry = entry };
            i += 1;
        }
    }
    return null;
}

/// Clicou na entrada `index` dos menus de plugin. `value`: a escolha da segunda lista.
pub fn menuClick(app: *App, kind: engine.MenuKind, index: usize, id: types.Id, value: ?[]const u8) void {
    const e = &app.plugins;
    const hit = menuEntry(app, kind, index) orelse return;
    switch (kind) {
        .message => {
            const f = app.store.findAny(id) orelse return;
            if (f.m.deleted) return;
            const pm = pluginMessage(app, &app.store, &f.m.msg);
            e.menuMessage(hit.plugin, hit.entry, &pm, value);
        },
        .user => {
            const u = app.store.user(id) orelse return;
            e.menuUser(hit.plugin, hit.entry, id, u.name, value);
        },
    }
}
