//! A thread dos plugins: todo o Lua roda aqui, nunca na thread da interface.
//!
//! Cada plugin tem o próprio `lua_State` (um travado ou com erro não mexe nos
//! outros) e roda num sandbox:
//! - só as bibliotecas base, string, table, math e utf8, mais os.time, os.date
//!   e os.clock. Sem io, os.execute, require, load/dofile, debug;
//! - um limite de instruções por chamada (lua_sethook com contagem): um laço
//!   infinito vira erro, e `pcall` não consegue engolir esse erro;
//! - um teto de memória por plugin (o alocador recusa passar dele);
//! - toda entrada no Lua passa por um `lua_pcall` (até montar as tabelas),
//!   então nenhum erro derruba o app: vira aviso na interface.
//!
//! A conversa com a interface é só por duas filas (ver wire.zig): `Ev` chega,
//! `Cmd` sai. Dormindo, a thread espera a condição da fila, com prazo apenas se
//! algum plugin tem temporizador: sem nada acontecendo não há quadro, tique nem
//! varredura. Sem plugin ligado a thread nem existe (ver engine.zig).
const std = @import("std");
const lua = @import("lua.zig");
const lsp_core = @import("../core/lsp.zig");
const filtros = @import("../core/filtros.zig");
const wire = @import("wire.zig");
const manifest = @import("manifest.zig");
const panel = @import("panel.zig");
const deco = @import("deco.zig");
const json = @import("json.zig");
const rewrite = @import("rewrite.zig");
const sync = @import("sync.zig");
const loc = @import("loc.zig");
const http_policy = @import("http_policy.zig");

/// Navegador (src/web_main.zig): sem threads, o Lua roda na thread da página, uma leva
/// por quadro (`Worker.pump`, que App.webFrame chama). Filas, limites e sandbox são os
/// mesmos; só não há quem espere a condição da fila.
pub const inline_mode = @hasDecl(@import("root"), "larper_web");

pub const max_plugins = 64;
pub const max_source = 256 * 1024;
const max_commands = 32;
const max_keys = 32;
const max_lsp = 8;
const max_menus = 4;
const max_choices = 16;
/// larper.completions: quantas, e quanto texto ao todo (fica na memória da interface).
const max_completions = 256;
const completions_bytes = 256 * 1024;
const max_timers = 64;
/// Teto de memória de cada plugin.
pub const mem_cap = 8 * 1024 * 1024;
/// O gancho do Lua roda a cada tantas instruções.
const hook_every = 1000;
/// Erros seguidos (fora o de travar) antes de o plugin ser parado.
const max_errors = 10;
/// larper.send por gesto.
const max_sends = 5;
/// Eventos esperando: uma rajada de mensagens não cresce sem limite. Gestos da
/// pessoa nunca são jogados fora.
const max_events = 4096;
const max_out = 16 * 1024;
/// O que um plugin pode pedir à interface numa chamada só.
const max_cmds_per_call = 4096;
/// larper.storage: tamanho total (chaves e valores em JSON).
pub const storage_cap = 1024 * 1024;
const storage_flush_ms = 1500;
/// larper.notify: quantos em 10 s (o resto é ignorado em silêncio).
const notify_burst = 20;
/// larper.every: o menor intervalo. Bem mais que isso seria um plugin ocupado à toa.
const every_min_ms = 1000;
/// Plugin com temporizador longe: a thread confere o relógio de minuto em minuto
/// (o computador pode ter dormido; esperas longas não contam esse tempo).
const timer_recheck_ms = 60_000;
/// larper.messages: quantas por vez, e no máximo uma consulta a cada tanto.
const messages_default = 200;
const messages_max = 500;
const messages_gap_ms = 500;
/// larper.http: limites por plugin.
pub const http_body_max = 64 * 1024;
const http_per_minute = 30;
const http_in_flight = 3;
/// Cabeçalhos por pedido, e o tamanho do valor (as credenciais podem ser um JWT).
const http_max_headers = 8;
const http_header_value = 256;
const http_credential_value = 2048;
/// larper.secrets: tamanho da chave e do valor (o Gerenciador de Credenciais do
/// Windows guarda até 2560 bytes).
const secret_key_max = 64;
const secret_value_max = 2048;
/// Ações na conta (larper.react e afins): quantas por gesto e por minuto, de cada
/// uma. Apagar e criar thread, uma por gesto: cada uma ainda pede confirmação ou é
/// algo que ninguém faz em série.
const ActKind = enum(u3) { react, edit, delete, pin, thread, attach };
const act_per_gesture = [_]u8{ 5, 3, 1, 3, 1, 1 };
const act_per_minute = [_]u8{ 30, 20, 5, 10, 5, 5 };
/// Mensagens na frente da fila a partir das quais um plugin lento perde as dele,
/// e o que conta como lento (ms por mensagem, na média).
const shed_backlog = 64;
const shed_slow_ms = 2.0;

/// Idioma das mensagens de erro (o app troca por `i18n.en`, que é atômico).
pub var lang_en: *const fn () bool = &struct {
    fn f() bool {
        return false;
    }
}.f;

/// O que `larper.lang()` responde ("pt", "en", "ja", "ru"…): o idioma de verdade da
/// interface. Os textos de plugin escolhem por ele (loc.zig).
pub var lang_code: *const fn () [*:0]const u8 = &struct {
    fn f() [*:0]const u8 {
        return if (lang_en()) "en" else "pt";
    }
}.f;

fn tr(pt: []const u8, en: []const u8) []const u8 {
    return if (lang_en()) en else pt;
}

fn uiLang() []const u8 {
    return std.mem.span(lang_code());
}

// --- A thread --------------------------------------------------------------------

const WhereBuf = struct {
    channel: u64 = 0,
    guild: u64 = 0,
    channel_name: [128]u8 = undefined,
    channel_len: u8 = 0,
    guild_name: [128]u8 = undefined,
    guild_len: u8 = 0,

    fn put(buf: *[128]u8, s: []const u8) u8 {
        var n = @min(s.len, buf.len);
        while (n > 0 and n < s.len and (s[n] & 0xC0) == 0x80) n -= 1;
        @memcpy(buf[0..n], s[0..n]);
        return @intCast(n);
    }
};

pub const Worker = struct {
    gpa: std.mem.Allocator,
    host: wire.Host,
    lock: sync.Lock,
    // Com a trava:
    events: std.ArrayList(wire.Ev) = .empty,
    out: std.ArrayList(wire.Cmd) = .empty,
    where: WhereBuf = .{},
    /// Rodando Lua agora (ou acabou de pegar eventos).
    busy: bool = false,
    /// A thread deve sair depois do que está na fila.
    quit: bool = false,
    // Atômicos:
    /// O app está fechando: até o que está rodando para.
    closing: std.atomic.Value(bool) = .init(false),
    /// A thread saiu e dá para juntar sem esperar.
    exited: std.atomic.Value(bool) = .init(false),
    /// Já tem um aviso para a interface a caminho.
    signaled: std.atomic.Value(bool) = .init(false),
    /// Bytes de Lua por plugin (a página mostra).
    mem: [max_plugins]std.atomic.Value(usize) = @splat(.init(0)),
    /// Quantas vezes a thread acordou (o QA confere que parada ela não acorda).
    loops: std.atomic.Value(u32) = .init(0),
    /// Mensagens que cada plugin perdeu por demorar demais (a página mostra).
    shed: [max_plugins]std.atomic.Value(u32) = @splat(.init(0)),
    /// Quantos eventos foram jogados fora por excesso (só para o log).
    dropped: u32 = 0,
    // Só da interface:
    thread: ?sync.Thread = null,
    // Só da thread dos plugins:
    rts: std.ArrayList(*Rt) = .empty,
    /// A leva em andamento quando não há thread (`pump`).
    inline_batch: std.ArrayList(wire.Ev) = .empty,
    /// Eventos que ainda faltam neste lote.
    backlog: usize = 0,

    pub fn create(gpa: std.mem.Allocator, host: wire.Host) !*Worker {
        const w = try gpa.create(Worker);
        w.* = .{ .gpa = gpa, .host = host, .lock = sync.lockInit() };
        return w;
    }

    pub fn start(w: *Worker) bool {
        // Sem thread: `pump` atende a fila a cada quadro.
        if (inline_mode) return true;
        if (w.thread != null) return true;
        w.quit = false;
        w.exited.store(false, .release);
        w.thread = sync.Thread.spawn(threadMain, w, "plugins");
        return w.thread != null;
    }

    /// Pede para a thread sair depois do que está na fila (sem esperar).
    pub fn retire(w: *Worker) void {
        w.lock.lock();
        defer w.lock.unlock();
        w.quit = true;
        w.lock.signal();
    }

    /// Espera a thread acabar. Com `closing`, até o que está rodando desiste.
    pub fn join(w: *Worker, closing: bool) void {
        if (inline_mode) {
            // O que está na fila (os pedidos de parar) e o fim de `threadMain`.
            if (closing) w.closing.store(true, .release);
            w.pump();
            for (w.rts.items) |rt| rt.close();
            w.reap();
            return;
        }
        if (w.thread == null) return;
        if (closing) w.closing.store(true, .release);
        w.retire();
        w.thread.?.join();
        w.thread = null;
    }

    /// Só com a thread parada.
    pub fn destroy(w: *Worker) void {
        for (w.events.items) |*ev| freeEv(w.gpa, ev);
        w.events.deinit(w.gpa);
        for (w.out.items) |*cmd| freeCmd(w.gpa, cmd);
        w.out.deinit(w.gpa);
        w.rts.deinit(w.gpa);
        w.inline_batch.deinit(w.gpa);
        w.lock.deinit();
        w.gpa.destroy(w);
    }

    pub fn push(w: *Worker, ev: wire.Ev) void {
        var e = ev;
        w.lock.lock();
        defer w.lock.unlock();
        const droppable = switch (e) {
            .message, .edit, .delete, .channel, .lang, .messages => true,
            else => false,
        };
        if (droppable and w.events.items.len >= max_events) {
            w.dropped +%= 1;
            return freeEv(w.gpa, &e);
        }
        w.events.append(w.gpa, e) catch return freeEv(w.gpa, &e);
        w.lock.signal();
    }

    pub fn setWhere(w: *Worker, wh: wire.Where) void {
        w.lock.lock();
        defer w.lock.unlock();
        w.where.channel = wh.channel;
        w.where.guild = wh.guild;
        w.where.channel_len = WhereBuf.put(&w.where.channel_name, wh.channel_name);
        w.where.guild_len = WhereBuf.put(&w.where.guild_name, wh.guild_name);
    }

    /// Da interface: pega tudo o que a thread mandou.
    pub fn takeOut(w: *Worker, into: *std.ArrayList(wire.Cmd)) void {
        w.signaled.store(false, .release);
        w.lock.lock();
        defer w.lock.unlock();
        std.mem.swap(std.ArrayList(wire.Cmd), &w.out, into);
    }

    /// A fila vazia e nada rodando (os testes esperam por isso).
    pub fn idle(w: *Worker) bool {
        w.lock.lock();
        defer w.lock.unlock();
        return w.events.items.len == 0 and !w.busy and w.out.items.len == 0;
    }

    fn emit(w: *Worker, run: u32, what: wire.CmdWhat) bool {
        var cmd: wire.Cmd = .{ .run = run, .what = what };
        w.lock.lock();
        defer w.lock.unlock();
        if (w.out.items.len >= max_out) {
            freeCmd(w.gpa, &cmd);
            return false;
        }
        w.out.append(w.gpa, cmd) catch {
            freeCmd(w.gpa, &cmd);
            return false;
        };
        return true;
    }

    /// Acorda a interface, se tem o que ela ver e ninguém avisou ainda.
    fn kick(w: *Worker) void {
        w.lock.lock();
        const any = w.out.items.len > 0;
        w.lock.unlock();
        if (any and !w.signaled.swap(true, .acq_rel)) w.host.wake(w.host.ctx);
    }

    fn find(w: *Worker, run: u32) ?*Rt {
        for (w.rts.items) |rt| if (rt.run == run and !rt.dead) return rt;
        return null;
    }

    fn nextDue(w: *const Worker) ?i64 {
        var due: ?i64 = null;
        for (w.rts.items) |rt| {
            if (rt.dead) continue;
            for (rt.timers.items) |t| {
                if (due == null or t.due_ms < due.?) due = t.due_ms;
            }
            if (rt.store_dirty and (due == null or rt.store_flush_at < due.?)) due = rt.store_flush_at;
        }
        return due;
    }

    fn handle(w: *Worker, ev: *wire.Ev) void {
        switch (ev.*) {
            .start => |args| startRun(w, args),
            .stop => |run| if (w.find(run)) |rt| rt.close(),
            .ready => for (w.rts.items) |rt| if (rt.n_ready > 0 and !rt.dead) {
                rt.invoke(.{ .kind = .ready });
            },
            .message => |own| for (w.rts.items) |rt| if (rt.n_message > 0 and !rt.dead) {
                // Nenhuma função dele quer este texto: o Lua nem acorda.
                if (!anyWants(rt.msg_filters.items, rt.n_message, own.msg.content)) continue;
                // Fila atrasada: quem demora em cada mensagem perde esta, e os
                // outros plugins não esperam por ele.
                if (w.backlog > shed_backlog and rt.msg_ms >= shed_slow_ms) {
                    _ = w.shed[rt.slot].fetchAdd(1, .monotonic);
                    continue;
                }
                const t0 = sync.nowMs();
                rt.invoke(.{ .kind = .message, .msg = &own.msg });
                rt.msg_ms = rt.msg_ms * 0.75 + @as(f32, @floatFromInt(sync.nowMs() - t0)) * 0.25;
            },
            .edit => |own| for (w.rts.items) |rt| if (rt.n_edit > 0 and !rt.dead) {
                if (!anyWants(rt.edit_filters.items, rt.n_edit, own.msg.content)) continue;
                rt.invoke(.{ .kind = .edit, .msg = &own.msg });
            },
            .dismiss => |d| if (w.find(d.run)) |rt| {
                if (rt.n_dismiss > 0) rt.invoke(.{ .kind = .dismiss, .id = d.id });
            },
            .delete => |d| for (w.rts.items) |rt| if (rt.n_delete > 0 and !rt.dead) {
                rt.invoke(.{ .kind = .delete, .id = d.id, .channel = d.channel });
            },
            .channel => for (w.rts.items) |rt| if (rt.n_channel > 0 and !rt.dead) {
                rt.invoke(.{ .kind = .channel });
            },
            .lang => for (w.rts.items) |rt| if (rt.n_lang > 0 and !rt.dead) {
                rt.invoke(.{ .kind = .lang });
            },
            .panel_state => |s| if (w.find(s.run)) |rt| {
                if (rt.n_panel > 0) rt.invoke(.{ .kind = .panel_state, .flag = s.open });
            },
            .gesture => |g| if (w.find(g.run)) |rt| switch (g.what) {
                .command => |x| rt.invoke(.{ .kind = .command, .name = x.name, .args = x.args, .token = g.token }),
                .key => |slot| rt.invoke(.{ .kind = .key, .slot = slot, .token = g.token }),
                .menu_message => |x| rt.invoke(.{ .kind = .menu_message, .slot = x.slot, .msg = &x.msg.msg, .value = x.value, .token = g.token }),
                .menu_user => |x| rt.invoke(.{ .kind = .menu_user, .slot = x.slot, .id = x.id, .name = x.name, .value = x.value, .token = g.token }),
                .panel => |x| rt.invoke(.{ .kind = .panel, .handle = x.handle, .value = x.value, .toggled = x.toggled, .token = g.token }),
            },
            .messages => |r| if (w.find(r.run)) |rt| {
                rt.invoke(.{ .kind = .messages, .slot = r.req, .list = r.list });
            },
            .http => |res| if (w.find(res.run)) |rt| {
                if (!res.refused) rt.http_flying -|= 1;
                // O registro de rede da página: o que saiu e o que voltou, sem conteúdo.
                var entry = res.log;
                entry.status = res.status;
                entry.err = res.err;
                entry.bytes = @intCast(@min(res.body.len, std.math.maxInt(u32)));
                entry.ms = res.ms;
                _ = w.emit(rt.run, .{ .net_log = entry });
                rt.invoke(.{ .kind = .http, .res = res, .carry = res.token });
            },
            .hosts => |h| if (w.find(h.run)) |rt| {
                rt.freeApproved();
                rt.approved = h.approved;
                ev.* = .ready; // quem ficou com a lista foi o plugin
                if (rt.n_hosts > 0) rt.invoke(.{ .kind = .hosts });
            },
        }
        freeEv(w.gpa, ev);
    }

    fn fireTimers(w: *Worker) void {
        const now = sync.nowMs();
        // O plugin pode mexer nos próprios temporizadores: procura de novo a cada um.
        for (w.rts.items) |rt| {
            var guard: usize = 0;
            while (!rt.dead and guard < max_timers) : (guard += 1) {
                const i = for (rt.timers.items, 0..) |t, k| {
                    if (t.due_ms <= now and !t.fired) break k;
                } else break;
                const t = &rt.timers.items[i];
                const id = t.id;
                if (t.every_ms > 0) {
                    // Sem correr atrás do tempo perdido (o computador dormiu).
                    t.due_ms = now + t.every_ms;
                    t.fired = true;
                } else _ = rt.timers.swapRemove(i);
                rt.invoke(.{ .kind = .timer, .slot = id });
            }
            for (rt.timers.items) |*t| t.fired = false;
        }
    }

    fn flushDue(w: *Worker) void {
        const now = sync.nowMs();
        for (w.rts.items) |rt| if (!rt.dead and rt.store_dirty and rt.store_flush_at <= now) rt.flushStorage();
    }

    /// Navegador: uma leva na thread da página, sem esperar. Nada na fila e nenhum
    /// temporizador vencido: volta na hora.
    pub fn pump(w: *Worker) void {
        if (!inline_mode) return;
        w.lock.lock();
        const due = w.nextDue();
        if (w.events.items.len == 0 and (due == null or due.? > sync.nowMs())) {
            w.lock.unlock();
            return;
        }
        w.busy = true;
        std.mem.swap(std.ArrayList(wire.Ev), &w.events, &w.inline_batch);
        w.lock.unlock();
        w.runBatch(&w.inline_batch);
        w.lock.lock();
        w.busy = false;
        w.lock.unlock();
    }

    /// Uma leva: os eventos que chegaram, os temporizadores vencidos e a faxina.
    fn runBatch(w: *Worker, batch: *std.ArrayList(wire.Ev)) void {
        _ = w.loops.fetchAdd(1, .monotonic);
        for (batch.items, 0..) |*ev, i| {
            w.backlog = batch.items.len - i - 1;
            w.handle(ev);
            w.kick();
        }
        w.backlog = 0;
        batch.clearRetainingCapacity();
        w.fireTimers();
        w.flushDue();
        w.reap();
        w.kick();
    }

    /// Tira da lista quem parou.
    fn reap(w: *Worker) void {
        var i: usize = 0;
        while (i < w.rts.items.len) {
            const rt = w.rts.items[i];
            if (rt.dead) {
                _ = w.rts.orderedRemove(i);
                rt.destroy();
            } else i += 1;
        }
    }
};

fn threadMain(raw: ?*anyopaque) void {
    const w: *Worker = @ptrCast(@alignCast(raw.?));
    var batch: std.ArrayList(wire.Ev) = .empty;
    defer batch.deinit(w.gpa);
    while (true) {
        w.lock.lock();
        w.busy = false;
        while (w.events.items.len == 0 and !w.quit) {
            const due = w.nextDue() orelse {
                w.lock.wait(null);
                continue;
            };
            const now = sync.nowMs();
            if (due <= now) break;
            w.lock.wait(@intCast(@min(due - now, timer_recheck_ms)));
            // Pode ter acordado sem nada novo: o laço confere de novo o prazo.
        }
        if (w.quit and w.events.items.len == 0) {
            w.lock.unlock();
            break;
        }
        w.busy = true;
        std.mem.swap(std.ArrayList(wire.Ev), &w.events, &batch);
        w.lock.unlock();
        w.runBatch(&batch);
    }
    // Saindo: o que estava escrito vai para o disco.
    for (w.rts.items) |rt| rt.close();
    w.reap();
    w.exited.store(true, .release);
    w.lock.lock();
    w.busy = false;
    w.lock.unlock();
    if (!w.signaled.swap(true, .acq_rel)) w.host.wake(w.host.ctx);
}

pub fn freeEv(gpa: std.mem.Allocator, ev: *wire.Ev) void {
    switch (ev.*) {
        .start => |a| {
            gpa.free(a.name);
            gpa.free(a.src);
            freeList(gpa, a.approved);
            gpa.destroy(a);
        },
        .message, .edit => |m| m.free(gpa),
        .gesture => |g| switch (g.what) {
            .command => |x| {
                gpa.free(x.name);
                gpa.free(x.args);
            },
            .menu_message => |x| {
                x.msg.free(gpa);
                if (x.value) |v| gpa.free(v);
            },
            .menu_user => |x| {
                gpa.free(x.name);
                if (x.value) |v| gpa.free(v);
            },
            .panel => |x| if (x.value) |v| gpa.free(v),
            .key => {},
        },
        .messages => |r| r.list.free(),
        .http => |r| {
            gpa.free(r.body);
            gpa.free(r.headers);
            gpa.destroy(r);
        },
        .hosts => |h| freeList(gpa, h.approved),
        .stop, .ready, .delete, .dismiss, .channel, .lang, .panel_state => {},
    }
}

pub fn freeCmd(gpa: std.mem.Allocator, cmd: *wire.Cmd) void {
    switch (cmd.what) {
        .reg => |r| r.free(gpa),
        .failed => |f| gpa.free(f.msg),
        .notify => |n| gpa.free(n.text),
        .send => |s| gpa.free(s.text),
        .action => |a| a.what.free(gpa),
        .insert => |s| gpa.free(s.text),
        .copy => |s| gpa.free(s.text),
        .open_url => |s| gpa.free(s.url),
        .panel_tree, .settings_tree => |t| t.destroy(),
        .completions => |set| set.free(gpa),
        .rewrite => |list| rewrite.freeList(gpa, list),
        .deco_set => |s| {
            gpa.free(s.badge);
            gpa.free(s.note);
            gpa.free(s.label);
        },
        .deco_rules => |list| {
            for (list) |*r| r.free(gpa);
            gpa.free(list);
        },
        .want_messages => |q| wire.freeNeedles(gpa, q.needles),
        .jump, .panel_show, .deco_remove, .net_log => {},
    }
}

pub fn freeList(gpa: std.mem.Allocator, list: [][]u8) void {
    for (list) |s| gpa.free(s);
    gpa.free(list);
}

fn startRun(w: *Worker, args: *wire.StartArgs) void {
    const rt = w.gpa.create(Rt) catch return;
    rt.* = .{ .w = w, .run = args.run, .slot = args.slot, .account = args.account, .budget = args.budget, .name = args.name };
    args.name = &.{};
    rt.approved = args.approved;
    args.approved = &.{};
    w.rts.append(w.gpa, rt) catch {
        rt.destroy();
        return;
    };
    rt.boot(args.src, args.fire_ready);
}

// --- Um plugin -------------------------------------------------------------------

const Timer = struct { id: u32, due_ms: i64, every_ms: i64 = 0, fired: bool = false };

const Kind = enum { setup, store_load, store_flush, message, edit, dismiss, hosts, ready, delete, channel, lang, panel_state, command, key, menu_message, menu_user, panel, timer, http, messages };

/// O que o trampolim protegido vai fazer dentro do Lua.
const Call = struct {
    kind: Kind,
    msg: ?*const wire.Message = null,
    name: []const u8 = "",
    args: []const u8 = "",
    slot: u32 = 0,
    id: u64 = 0,
    channel: u64 = 0,
    handle: u32 = 0,
    value: ?[]const u8 = null,
    toggled: ?bool = null,
    res: ?*const wire.HttpRes = null,
    list: ?*const wire.MsgList = null,
    bytes: []const u8 = "",
    flag: bool = false,
    /// Diferente de 0: é um gesto da pessoa neste plugin (libera larper.send etc.).
    token: u32 = 0,
    /// A resposta de um pedido feito num gesto: só libera pôr texto na caixa.
    carry: u32 = 0,
};

pub const Rt = struct {
    w: *Worker,
    run: u32,
    slot: u16,
    account: u64,
    budget: u32,
    name: []u8,
    /// Capacidades e hosts pedidos (os hosts são cópias: o fonte não fica guardado).
    m: manifest.Manifest = .{},
    host_copies: [manifest.max_hosts][]u8 = undefined,
    cred_copies: [manifest.max_hosts][]u8 = undefined,
    /// Os itens de `@hosts` que a pessoa aprovou (nomes ou curingas).
    approved: [][]u8 = &.{},
    L: ?*lua.State = null,
    dead: bool = false,
    /// Bytes que o Lua deste plugin está usando.
    mem: usize = 0,
    steps: u32 = 0,
    timed_out: bool = false,
    /// O gesto da chamada de agora (0 = não veio da pessoa).
    gesture: u32 = 0,
    /// A chamada de agora é a resposta de um pedido feito num gesto.
    carry: u32 = 0,
    sends: u8 = 0,
    /// Ações na conta nesta chamada e no último minuto, de cada tipo (ActKind).
    acts: [act_per_gesture.len]u8 = @splat(0),
    act_from: i64 = 0,
    act_min: [act_per_minute.len]u8 = @splat(0),
    cmds: u32 = 0,
    errors: u8 = 0,
    n_message: u16 = 0,
    n_ready: u16 = 0,
    n_delete: u16 = 0,
    n_channel: u16 = 0,
    n_lang: u16 = 0,
    n_panel: u16 = 0,
    n_edit: u16 = 0,
    n_dismiss: u16 = 0,
    n_hosts: u16 = 0,
    /// O `contains` de cada função de "message" e "edit", na mesma ordem (vazio = todas).
    msg_filters: std.ArrayList([][]u8) = .empty,
    edit_filters: std.ArrayList([][]u8) = .empty,
    /// Quanto cada mensagem tem custado (ms, na média).
    msg_ms: f32 = 0,
    commands: std.ArrayList([]u8) = .empty,
    keys: std.ArrayList(wire.Keybind) = .empty,
    lsp: std.ArrayList(wire.LspServer) = .empty,
    menus: std.ArrayList(wire.MenuEntry) = .empty,
    /// Algo acima mudou: a interface precisa saber.
    reg_dirty: bool = false,
    timers: std.ArrayList(Timer) = .empty,
    next_id: u32 = 1,
    store_bytes: usize = 0,
    store_dirty: bool = false,
    store_flush_at: i64 = 0,
    /// Rascunho do que o Zig monta com o Lua no meio (um erro pula as limpezas:
    /// fica aqui até a próxima vez ou até o plugin parar).
    scratch: std.ArrayList(u8) = .empty,
    scratch2: std.ArrayList(u8) = .empty,
    wip: ?*panel.Tree = null,
    /// Árvore pronta: sai ao fim da chamada (publicar 100 vezes conta uma só).
    tree_ready: ?*panel.Tree = null,
    settings_ready: ?*panel.Tree = null,
    /// A árvore sendo montada: as funções dela vão para esta tabela.
    cb_field: [*:0]const u8 = "cb_now",
    tree_api: []const u8 = "larper.panel.set",
    notify_from: i64 = 0,
    notify_n: u8 = 0,
    messages_at: i64 = 0,
    http_flying: u8 = 0,
    http_from: i64 = 0,
    http_n: u8 = 0,

    fn gpa(rt: *const Rt) std.mem.Allocator {
        return rt.w.gpa;
    }

    fn freeApproved(rt: *Rt) void {
        freeList(rt.gpa(), rt.approved);
        rt.approved = &.{};
    }

    fn destroy(rt: *Rt) void {
        const a = rt.gpa();
        rt.closeLua();
        a.free(rt.name);
        freeList(a, rt.approved);
        for (rt.m.hostList(), 0..) |_, i| a.free(rt.host_copies[i]);
        for (rt.m.credList(), 0..) |_, i| a.free(rt.cred_copies[i]);
        rt.commands.deinit(a);
        rt.keys.deinit(a);
        rt.lsp.deinit(a);
        rt.menus.deinit(a);
        rt.msg_filters.deinit(a);
        rt.edit_filters.deinit(a);
        rt.timers.deinit(a);
        rt.scratch.deinit(a);
        rt.scratch2.deinit(a);
        a.destroy(rt);
    }

    fn clearLists(rt: *Rt) void {
        const a = rt.gpa();
        for (rt.commands.items) |s| a.free(s);
        rt.commands.clearRetainingCapacity();
        rt.keys.clearRetainingCapacity();
        rt.lsp.clearRetainingCapacity();
        for (rt.menus.items) |*m| m.free(a);
        rt.menus.clearRetainingCapacity();
        rt.timers.clearRetainingCapacity();
        rt.n_message = 0;
        rt.n_ready = 0;
        rt.n_delete = 0;
        rt.n_channel = 0;
        rt.n_lang = 0;
        rt.n_panel = 0;
        rt.n_edit = 0;
        rt.n_dismiss = 0;
        rt.n_hosts = 0;
        for (rt.msg_filters.items) |f| wire.freeNeedles(a, f);
        rt.msg_filters.clearRetainingCapacity();
        for (rt.edit_filters.items) |f| wire.freeNeedles(a, f);
        rt.edit_filters.clearRetainingCapacity();
    }

    fn closeLua(rt: *Rt) void {
        if (rt.L) |L| {
            // __gc não existe aqui (ver lSetmetatable): fechar não roda código do plugin.
            rt.L = null;
            lua.lua_close(L);
            // Só agora: mais tarde a posição pode já ser de quem carregou no lugar dele.
            rt.w.mem[rt.slot].store(0, .monotonic);
        }
        if (rt.wip) |t| t.destroy();
        rt.wip = null;
        if (rt.tree_ready) |t| t.destroy();
        rt.tree_ready = null;
        if (rt.settings_ready) |t| t.destroy();
        rt.settings_ready = null;
        rt.clearLists();
    }

    /// Parou (desligado, erro ou o app fechando): grava o que falta e fecha o Lua.
    fn close(rt: *Rt) void {
        if (rt.dead) return;
        if (rt.store_dirty) rt.flushStorage();
        rt.dead = true;
        rt.closeLua();
    }

    fn boot(rt: *Rt, src: []const u8, fire_ready: bool) void {
        rt.m = manifest.parse(src);
        // O cabeçalho aponta para o fonte, que não fica: copia só o que serve depois.
        const m_hosts = rt.m.n_hosts;
        const m_creds = rt.m.n_creds;
        // As contagens só sobem com a cópia feita: parando no meio, `destroy` solta só o copiado.
        rt.m.n_hosts = 0;
        rt.m.n_creds = 0;
        for (rt.m.hosts[0..m_hosts]) |h| {
            const own = rt.gpa().dupe(u8, h) catch return rt.fail(tr("sem memória", "out of memory"));
            rt.host_copies[rt.m.n_hosts] = own;
            rt.m.hosts[rt.m.n_hosts] = own;
            rt.m.n_hosts += 1;
        }
        for (rt.m.creds[0..m_creds]) |h| {
            const own = rt.gpa().dupe(u8, h) catch return rt.fail(tr("sem memória", "out of memory"));
            rt.cred_copies[rt.m.n_creds] = own;
            rt.m.creds[rt.m.n_creds] = own;
            rt.m.n_creds += 1;
        }
        var pb: [300]u8 = undefined;
        if (rt.m.problemText(&pb, lang_en())) |msg| return rt.fail(msg);
        rt.m.name = "";
        rt.m.description = "";
        rt.m.n_names = 0;
        rt.m.n_descs = 0;
        rt.m.version = "";
        rt.m.problem = .none;

        const L = lua.lua_newstate(&alloc, rt) orelse return rt.fail(tr("sem memória para o Lua", "out of memory for Lua"));
        _ = lua.lua_atpanic(L, &panicFn);
        rt.L = L;
        lua.lua_sethook(L, &hook, lua.MASKCOUNT, hook_every);
        if (!rt.protected(.{ .kind = .setup })) return;
        rt.loadStorage();
        if (rt.dead) return;
        var nbuf: [160]u8 = undefined;
        const chunk = std.fmt.bufPrintSentinel(&nbuf, "@{s}", .{rt.name}, 0) catch "@plugin";
        // Só texto: bytecode pré-compilado poderia burlar o sandbox.
        if (lua.luaL_loadbufferx(L, src.ptr, src.len, chunk.ptr, "t") != lua.OK) {
            return rt.fail(lua.toSlice(L, -1) orelse "?");
        }
        rt.steps = 0;
        rt.timed_out = false;
        rt.cmds = 0;
        // Erro aqui em cima deixaria o plugin pela metade: para e mostra o erro.
        if (lua.pcall(L, 0, 0) != lua.OK) {
            const raw = (if (lua.lua_type(L, -1) == lua.TSTRING) lua.toSlice(L, -1) else null) orelse tr("erro sem mensagem", "error without a message");
            return rt.fail(raw);
        }
        if (fire_ready and rt.n_ready > 0) rt.invoke(.{ .kind = .ready }) else rt.publish();
    }

    fn fail(rt: *Rt, msg: []const u8) void {
        const own = rt.gpa().dupe(u8, msg) catch "";
        _ = rt.w.emit(rt.run, .{ .failed = .{ .msg = @constCast(own), .stopped = true } });
        rt.close();
    }

    fn report(rt: *Rt, msg: []const u8) void {
        const own = rt.gpa().dupe(u8, msg) catch return;
        _ = rt.w.emit(rt.run, .{ .failed = .{ .msg = own, .stopped = false } });
    }

    /// Roda `call` num pcall. false = deu erro (já tratado).
    fn protected(rt: *Rt, call: Call) bool {
        const L = rt.L orelse return false;
        var cl = call;
        rt.steps = 0;
        rt.timed_out = false;
        rt.sends = 0;
        rt.acts = @splat(0);
        rt.cmds = 0;
        rt.gesture = call.token;
        rt.carry = call.carry;
        defer {
            rt.gesture = 0;
            rt.carry = 0;
        }
        lua.pushcfunction(L, &trampoline);
        lua.lua_pushlightuserdata(L, &cl);
        if (lua.pcall(L, 1, 0) == lua.OK) return true;
        rt.afterError();
        return false;
    }

    fn invoke(rt: *Rt, call: Call) void {
        _ = rt.protected(call);
        if (!rt.dead) rt.publish();
    }

    /// O erro está no topo da pilha do plugin.
    fn afterError(rt: *Rt) void {
        const L = rt.L.?;
        // Só texto: converter um número aloca, e sem pcall um erro de memória aqui derruba o app.
        const raw = (if (lua.lua_type(L, -1) == lua.TSTRING) lua.toSlice(L, -1) else null) orelse tr("erro sem mensagem", "error without a message");
        var buf: [300]u8 = undefined;
        if (rt.timed_out) {
            const msg = std.fmt.bufPrint(&buf, "{s} {s}", .{ tr("parado:", "stopped:"), raw }) catch raw;
            return rt.fail(msg);
        }
        rt.errors += 1;
        if (rt.errors >= max_errors) {
            const msg = std.fmt.bufPrint(&buf, "{s} {s}", .{ tr("parado depois de 10 erros:", "stopped after 10 errors:"), raw }) catch raw;
            return rt.fail(msg);
        }
        rt.report(raw);
        lua.pop(L, 1);
    }

    /// Ao fim de cada chamada: o que mudou vai para a interface, de uma vez.
    fn publish(rt: *Rt) void {
        rt.w.mem[rt.slot].store(rt.mem, .monotonic);
        if (rt.tree_ready) |t| {
            rt.tree_ready = null;
            _ = rt.w.emit(rt.run, .{ .panel_tree = t });
        }
        if (rt.settings_ready) |t| {
            rt.settings_ready = null;
            _ = rt.w.emit(rt.run, .{ .settings_tree = t });
        }
        if (!rt.reg_dirty) return;
        rt.reg_dirty = false;
        const reg = rt.buildReg() catch return;
        _ = rt.w.emit(rt.run, .{ .reg = reg });
    }

    fn buildReg(rt: *Rt) !*wire.Reg {
        const a = rt.gpa();
        const reg = try a.create(wire.Reg);
        reg.* = .{ .n_message = rt.n_message, .n_ready = rt.n_ready, .n_delete = rt.n_delete, .n_channel = rt.n_channel, .n_lang = rt.n_lang, .n_edit = rt.n_edit, .n_dismiss = rt.n_dismiss };
        errdefer reg.free(a);
        var cmds: std.ArrayList([]u8) = .empty;
        for (rt.commands.items) |s| try cmds.append(a, try a.dupe(u8, s));
        reg.commands = try cmds.toOwnedSlice(a);
        reg.keys = try a.dupe(wire.Keybind, rt.keys.items);
        reg.lsp = try a.dupe(wire.LspServer, rt.lsp.items);
        var mens: std.ArrayList(wire.MenuEntry) = .empty;
        errdefer {
            for (mens.items) |*m| m.free(a);
            mens.deinit(a);
        }
        for (rt.menus.items) |*m| {
            var copy = try m.dup(a);
            mens.append(a, copy) catch |err| {
                copy.free(a);
                return err;
            };
        }
        reg.menus = try mens.toOwnedSlice(a);
        return reg;
    }

    fn loadStorage(rt: *Rt) void {
        if (!rt.m.has(.storage)) return;
        const bytes = rt.w.host.read_data(rt.w.host.ctx, rt.gpa(), rt.account, rt.name) orelse return;
        defer rt.gpa().free(bytes);
        _ = rt.protected(.{ .kind = .store_load, .bytes = bytes });
    }

    fn flushStorage(rt: *Rt) void {
        rt.store_dirty = false;
        if (rt.L == null) return;
        if (!rt.protected(.{ .kind = .store_flush })) return;
        if (!rt.w.host.write_data(rt.w.host.ctx, rt.account, rt.name, rt.scratch.items)) {
            rt.report(tr("larper.storage: não consegui gravar no disco", "larper.storage: couldn't write to disk"));
        }
    }

    /// Algum item aprovado vale para este host (nome exato ou curinga).
    fn hostApproved(rt: *const Rt, host: []const u8) bool {
        return http_policy.anyMatches(rt.approved, host);
    }

    /// Algum item aprovado que leva credenciais vale para este host.
    fn credsApproved(rt: *const Rt, host: []const u8) bool {
        for (rt.approved) |h| {
            if (rt.m.credentialPattern(h) and http_policy.matches(h, host)) return !manifest.isDiscord(host);
        }
        return false;
    }

    fn patternApproved(rt: *const Rt, pattern: []const u8) bool {
        for (rt.approved) |h| if (std.ascii.eqlIgnoreCase(h, pattern)) return true;
        return false;
    }

    /// Mais um pedido à interface. Sem isso um laço encheria a fila dela.
    fn budgetCmd(rt: *Rt, L: ?*lua.State) void {
        rt.cmds += 1;
        if (rt.cmds > max_cmds_per_call) raise(L, tr("pedidos demais à interface numa chamada só", "too many requests to the interface in a single call"));
    }

    fn dupText(rt: *const Rt, L: ?*lua.State, s: []const u8) []u8 {
        return rt.gpa().dupe(u8, s) catch raise(L, tr("sem memória", "out of memory"));
    }
};

/// A função `i` quer este texto? (Sem filtro registrado, quer tudo.)
fn filterWants(filters: []const [][]u8, i: usize, text: []const u8) bool {
    if (i >= filters.len or filters[i].len == 0) return true;
    return wire.hasAny(text, filters[i]);
}

/// Alguma das `n` funções quer este texto?
fn anyWants(filters: []const [][]u8, n: u16, text: []const u8) bool {
    for (0..n) |i| {
        if (filterWants(filters, i, text)) return true;
    }
    return false;
}

// --- Ponte C -> Zig ------------------------------------------------------------

fn plug(L: ?*lua.State) *Rt {
    var ud: ?*anyopaque = null;
    _ = lua.lua_getallocf(L, &ud);
    return @ptrCast(@alignCast(ud.?));
}

/// Erro de Lua com "arquivo:linha:" na frente. Não volta (longjmp).
fn raise(L: ?*lua.State, msg: []const u8) noreturn {
    lua.luaL_where(L, 1);
    lua.pushSlice(L, msg);
    lua.lua_concat(L, 2);
    _ = lua.lua_error(L);
    unreachable;
}

fn raiseFmt(L: ?*lua.State, comptime pt: []const u8, comptime en: []const u8, args: anytype) noreturn {
    var buf: [400]u8 = undefined;
    const msg = (if (lang_en()) std.fmt.bufPrint(&buf, en, args) else std.fmt.bufPrint(&buf, pt, args)) catch "larper";
    raise(L, msg);
}

/// A função pede uma capacidade que o cabeçalho não declara: explica como pedir.
fn need(L: ?*lua.State, rt: *const Rt, cap: manifest.Cap, api: []const u8) void {
    if (rt.m.has(cap)) return;
    if (rt.m.legacy) raiseFmt(L, "{s} precisa de um cabeçalho: acrescente \"-- @capabilities {t}\" no começo do arquivo (veja docs/plugins.md)", "{s} needs a manifest: add \"-- @capabilities {t}\" at the top of the file (see docs/plugins.md)", .{ api, cap });
    raiseFmt(L, "{s}: acrescente \"{t}\" em @capabilities no cabeçalho do plugin", "{s}: add \"{t}\" to @capabilities in the plugin's manifest", .{ api, cap });
}

fn alloc(ud: ?*anyopaque, ptr: ?*anyopaque, osize: usize, nsize: usize) callconv(.c) ?*anyopaque {
    const p: *Rt = @ptrCast(@alignCast(ud.?));
    // Com ptr nulo, osize diz o tipo do objeto, não o tamanho.
    const old: usize = if (ptr == null) 0 else osize;
    if (nsize == 0) {
        std.c.free(ptr);
        p.mem -|= old;
        return null;
    }
    if (nsize > old and p.mem - old + nsize > mem_cap) return null;
    const np = std.c.realloc(ptr, nsize) orelse return null;
    p.mem = p.mem - old + nsize;
    return np;
}

fn panicFn(L: ?*lua.State) callconv(.c) c_int {
    // Não deveria acontecer: toda entrada no Lua é protegida.
    std.log.err("lua: erro sem proteção: {s}", .{lua.toSlice(L, -1) orelse "?"});
    return 0;
}

fn hook(L: ?*lua.State, _: ?*lua.Debug) callconv(.c) void {
    const p = plug(L);
    p.steps +|= hook_every;
    if (p.timed_out or p.steps > p.budget or p.w.closing.load(.monotonic)) {
        // Continua valendo até a chamada acabar: o erro sai de qualquer pcall.
        p.timed_out = true;
        lua.luaL_where(L, 0);
        lua.pushSlice(L, tr("passou do limite de instruções (laço infinito?)", "went over the instruction limit (infinite loop?)"));
        lua.lua_concat(L, 2);
        _ = lua.lua_error(L);
    }
}

/// Primeira função de toda chamada: já dentro do pcall, então até faltar
/// memória montando uma tabela vira um erro normal.
fn trampoline(L: ?*lua.State) callconv(.c) c_int {
    const call: *const Call = @ptrCast(@alignCast(lua.lua_touserdata(L, 1).?));
    if (call.kind == .setup) {
        setup(L);
        return 0;
    }
    _ = lua.lua_getfield(L, lua.REGISTRYINDEX, "larper"); // 2
    switch (call.kind) {
        .setup => unreachable,
        .store_load => storageRead(L, plug(L), call.bytes),
        .store_flush => storageWrite(L, plug(L)),
        .message, .edit, .dismiss, .hosts, .ready, .delete, .channel, .lang, .panel_state => {
            const field: [*:0]const u8 = switch (call.kind) {
                .message => "message",
                .edit => "edit",
                .dismiss => "dismiss",
                .hosts => "hosts",
                .ready => "ready",
                .delete => "delete",
                .channel => "channel",
                .panel_state => "panel",
                else => "lang",
            };
            _ = lua.lua_getfield(L, 2, field); // 3
            switch (call.kind) {
                .message, .edit => pushMessage(L, call.msg.?),
                .dismiss => {
                    lua.lua_createtable(L, 0, 1);
                    pushId(L, call.id);
                    lua.lua_setfield(L, -2, "id");
                },
                .delete => {
                    lua.lua_createtable(L, 0, 2);
                    pushId(L, call.id);
                    lua.lua_setfield(L, -2, "id");
                    pushId(L, call.channel);
                    lua.lua_setfield(L, -2, "channel");
                },
                .channel => pushChannel(L, plug(L)),
                .panel_state => lua.lua_pushboolean(L, @intFromBool(call.flag)),
                else => lua.lua_pushnil(L),
            } // 4
            const n: lua.Integer = @intCast(lua.lua_rawlen(L, 3));
            const filters: []const [][]u8 = switch (call.kind) {
                .message => plug(L).msg_filters.items,
                .edit => plug(L).edit_filters.items,
                else => &.{},
            };
            var i: lua.Integer = 1;
            while (i <= n) : (i += 1) {
                if (call.msg) |m| {
                    if (!filterWants(filters, @intCast(i - 1), m.content)) continue;
                }
                _ = lua.lua_rawgeti(L, 3, i);
                lua.lua_pushvalue(L, 4);
                lua.call(L, 1, 0);
            }
        },
        .command => {
            _ = lua.lua_getfield(L, 2, "commands");
            lua.pushSlice(L, call.name);
            _ = lua.lua_rawget(L, -2);
            lua.pushSlice(L, call.args);
            lua.call(L, 1, 0);
        },
        .key => {
            _ = lua.lua_getfield(L, 2, "keys");
            _ = lua.lua_rawgeti(L, -1, call.slot);
            lua.call(L, 0, 0);
        },
        .menu_message, .menu_user => {
            _ = lua.lua_getfield(L, 2, "menus");
            _ = lua.lua_rawgeti(L, -1, call.slot);
            if (call.kind == .menu_message) pushMessage(L, call.msg.?) else pushRef(L, call.id, call.name);
            if (call.value) |v| lua.pushSlice(L, v) else lua.lua_pushnil(L);
            lua.call(L, 2, 0);
        },
        .panel => {
            // A função pode ser da árvore de agora ou da anterior (o clique veio
            // de um quadro de antes da troca).
            for ([_][*:0]const u8{ "cb_now", "cb_prev", "opt_now", "opt_prev" }) |t| {
                _ = lua.lua_getfield(L, 2, t);
                _ = lua.lua_rawgeti(L, -1, call.handle);
                if (lua.lua_type(L, -1) == lua.TFUNCTION) {
                    if (call.toggled) |on| {
                        lua.lua_pushboolean(L, @intFromBool(on));
                    } else if (call.value) |v| lua.pushSlice(L, v) else lua.lua_pushnil(L);
                    lua.call(L, 1, 0);
                    break;
                }
                lua.pop(L, 2);
            }
        },
        .timer => {
            _ = lua.lua_getfield(L, 2, "timers");
            const timers = lua.lua_gettop(L);
            _ = lua.lua_rawgeti(L, timers, call.slot);
            if (lua.lua_type(L, -1) != lua.TFUNCTION) return 0;
            // De uma vez só: `after` sai da tabela antes de rodar.
            const still = for (plug(L).timers.items) |t| {
                if (t.id == call.slot) break true;
            } else false;
            if (!still) {
                lua.lua_pushnil(L);
                lua.lua_rawseti(L, timers, call.slot);
            }
            lua.call(L, 0, 0);
        },
        .http => {
            const res = call.res.?;
            _ = lua.lua_getfield(L, 2, "http");
            _ = lua.lua_rawgeti(L, -1, res.id);
            lua.lua_pushnil(L);
            lua.lua_rawseti(L, -3, res.id);
            if (lua.lua_type(L, -1) != lua.TFUNCTION) return 0;
            lua.lua_createtable(L, 0, 4);
            lua.lua_pushboolean(L, @intFromBool(res.err == .none and res.status >= 200 and res.status < 300));
            lua.lua_setfield(L, -2, "ok");
            lua.lua_pushinteger(L, res.status);
            lua.lua_setfield(L, -2, "status");
            lua.pushSlice(L, res.body);
            lua.lua_setfield(L, -2, "body");
            // res.headers: os da lista (http_policy.responseHeader), nome em minúsculas.
            lua.lua_createtable(L, 0, 4);
            var hs = std.mem.splitScalar(u8, res.headers, 0);
            while (hs.next()) |name| {
                const value = hs.next() orelse break;
                if (name.len == 0) continue;
                lua.pushSlice(L, name);
                lua.pushSlice(L, value);
                lua.lua_rawset(L, -3);
            }
            lua.lua_setfield(L, -2, "headers");
            if (res.err != .none) {
                _ = lua.lua_pushstring(L, @tagName(res.err));
                lua.lua_setfield(L, -2, "error");
            }
            lua.call(L, 1, 0);
        },
        .messages => {
            const list = call.list.?;
            _ = lua.lua_getfield(L, 2, "msgs");
            _ = lua.lua_rawgeti(L, -1, call.slot);
            lua.lua_pushnil(L);
            lua.lua_rawseti(L, -3, call.slot);
            if (lua.lua_type(L, -1) != lua.TFUNCTION) return 0;
            lua.lua_createtable(L, @intCast(list.items.items.len), 0);
            for (list.items.items, 1..) |o, i| {
                pushMessage(L, &o.msg);
                lua.lua_rawseti(L, -2, @intCast(i));
            }
            if (list.last_read != 0) {
                pushId(L, list.last_read);
                lua.lua_setfield(L, -2, "last_read");
            }
            lua.call(L, 1, 0);
        },
    }
    return 0;
}

fn pushId(L: ?*lua.State, id: u64) void {
    var b: [24]u8 = undefined;
    lua.pushSlice(L, std.fmt.bufPrint(&b, "{d}", .{id}) catch "0");
}

/// {id="123", name="geral"}
fn pushRef(L: ?*lua.State, id: u64, name: []const u8) void {
    lua.lua_createtable(L, 0, 2);
    pushId(L, id);
    lua.lua_setfield(L, -2, "id");
    lua.pushSlice(L, name);
    lua.lua_setfield(L, -2, "name");
}

fn pushMessage(L: ?*lua.State, m: *const wire.Message) void {
    lua.lua_createtable(L, 0, 9);
    pushId(L, m.id);
    lua.lua_setfield(L, -2, "id");
    lua.pushSlice(L, m.content);
    lua.lua_setfield(L, -2, "content");
    pushRef(L, m.author, m.author_name);
    lua.lua_setfield(L, -2, "author");
    pushRef(L, m.channel, m.channel_name);
    lua.lua_setfield(L, -2, "channel");
    if (m.guild != 0) {
        pushRef(L, m.guild, m.guild_name);
        lua.lua_setfield(L, -2, "guild");
    }
    lua.lua_pushboolean(L, @intFromBool(m.mine));
    lua.lua_setfield(L, -2, "mine");
    lua.lua_pushboolean(L, @intFromBool(m.ignored));
    lua.lua_setfield(L, -2, "ignored");
    lua.lua_pushinteger(L, m.timestamp);
    lua.lua_setfield(L, -2, "time");
    lua.lua_pushinteger(L, m.attachments);
    lua.lua_setfield(L, -2, "attachments");
    if (m.reply_to != 0) {
        pushId(L, m.reply_to);
        lua.lua_setfield(L, -2, "reply_to");
    }
    if (m.mentions_me) {
        lua.lua_pushboolean(L, 1);
        lua.lua_setfield(L, -2, "mentions_me");
    }
    if (m.files.len > 0) {
        lua.lua_createtable(L, @intCast(m.files.len), 0);
        for (m.files, 1..) |f, i| {
            lua.lua_createtable(L, 0, 3);
            lua.pushSlice(L, f.name);
            lua.lua_setfield(L, -2, "name");
            lua.pushSlice(L, f.url);
            lua.lua_setfield(L, -2, "url");
            lua.lua_pushinteger(L, f.size);
            lua.lua_setfield(L, -2, "size");
            lua.lua_rawseti(L, -2, @intCast(i));
        }
        lua.lua_setfield(L, -2, "files");
    }
}

/// Abre só o que o sandbox permite e cria a tabela `larper`.
fn setup(L: ?*lua.State) void {
    lua.pushcfunction(L, &lua.luaopen_base);
    lua.call(L, 0, 1);
    lua.pop(L, 1);
    const libs = [_]struct { name: [*:0]const u8, open: lua.CFunction }{
        .{ .name = "string", .open = &lua.luaopen_string },
        .{ .name = "table", .open = &lua.luaopen_table },
        .{ .name = "math", .open = &lua.luaopen_math },
        .{ .name = "utf8", .open = &lua.luaopen_utf8 },
    };
    for (libs) |lib| {
        lua.pushcfunction(L, lib.open);
        lua.call(L, 0, 1);
        lua.lua_setglobal(L, lib.name);
    }
    // string.dump gera bytecode (que nem dá para carregar aqui, mas fora).
    _ = lua.lua_getglobal(L, "string");
    lua.lua_pushnil(L);
    lua.lua_setfield(L, -2, "dump");
    lua.pop(L, 1);
    // os: só o relógio.
    lua.pushcfunction(L, &lua.luaopen_os);
    lua.call(L, 0, 1);
    lua.newtable(L);
    for ([_][*:0]const u8{ "time", "date", "clock", "difftime" }) |f| {
        _ = lua.lua_getfield(L, -2, f);
        lua.lua_setfield(L, -2, f);
    }
    lua.lua_setglobal(L, "os");
    lua.pop(L, 1);
    // Fora da base: ler/rodar arquivos e código, e desligar o coletor.
    for ([_][*:0]const u8{ "dofile", "loadfile", "load", "collectgarbage" }) |f| {
        lua.lua_pushnil(L);
        lua.lua_setglobal(L, f);
    }
    const Fn = struct { name: [*:0]const u8, f: lua.CFunction };
    const base = [_]Fn{
        .{ .name = "print", .f = &lPrint },
        .{ .name = "pcall", .f = &lPcall },
        .{ .name = "xpcall", .f = &lXpcall },
        .{ .name = "setmetatable", .f = &lSetmetatable },
    };
    for (base) |b| {
        lua.pushcfunction(L, b.f);
        lua.lua_setglobal(L, b.name);
    }
    const api = [_]Fn{
        .{ .name = "on", .f = &lOn },
        .{ .name = "command", .f = &lCommand },
        .{ .name = "keybind", .f = &lKeybind },
        .{ .name = "notify", .f = &lNotify },
        .{ .name = "send", .f = &lSend },
        .{ .name = "reply", .f = &lReply },
        .{ .name = "react", .f = &lReact },
        .{ .name = "edit", .f = &lEdit },
        .{ .name = "delete", .f = &lDelete },
        .{ .name = "pin", .f = &lPin },
        .{ .name = "unpin", .f = &lUnpin },
        .{ .name = "thread", .f = &lThread },
        .{ .name = "attach", .f = &lAttach },
        .{ .name = "channel", .f = &lChannel },
        .{ .name = "guild", .f = &lGuild },
        .{ .name = "lsp", .f = &lLsp },
        .{ .name = "lang", .f = &lLang },
        .{ .name = "tr", .f = &lTr },
        .{ .name = "after", .f = &lAfter },
        .{ .name = "every", .f = &lEvery },
        .{ .name = "cancel", .f = &lCancel },
        .{ .name = "menu", .f = &lMenu },
        .{ .name = "decorate", .f = &lDecorate },
        .{ .name = "undecorate", .f = &lUndecorate },
        .{ .name = "rules", .f = &lRules },
        .{ .name = "messages", .f = &lMessages },
        .{ .name = "jump", .f = &lJump },
        .{ .name = "insert", .f = &lInsert },
        .{ .name = "copy", .f = &lCopy },
        .{ .name = "open", .f = &lOpen },
        .{ .name = "completions", .f = &lCompletions },
        .{ .name = "rewrite", .f = &lRewrite },
        .{ .name = "urlencode", .f = &lUrlencode },
    };
    lua.lua_createtable(L, 0, api.len + 6);
    for (api) |a| {
        lua.pushcfunction(L, a.f);
        lua.lua_setfield(L, -2, a.name);
    }
    const groups = [_]struct { name: [*:0]const u8, fns: []const Fn }{
        .{ .name = "storage", .fns = &.{
            .{ .name = "get", .f = &lStoreGet },
            .{ .name = "set", .f = &lStoreSet },
            .{ .name = "delete", .f = &lStoreDelete },
            .{ .name = "keys", .f = &lStoreKeys },
            .{ .name = "clear", .f = &lStoreClear },
        } },
        .{ .name = "panel", .fns = &.{
            .{ .name = "set", .f = &lPanelSet },
            .{ .name = "open", .f = &lPanelOpen },
            .{ .name = "close", .f = &lPanelClose },
        } },
        .{ .name = "settings", .fns = &.{
            .{ .name = "set", .f = &lSettingsSet },
        } },
        .{ .name = "http", .fns = &.{
            .{ .name = "get", .f = &lHttpGet },
            .{ .name = "post", .f = &lHttpPost },
            .{ .name = "put", .f = &lHttpPut },
            .{ .name = "patch", .f = &lHttpPatch },
            .{ .name = "delete", .f = &lHttpDelete },
            .{ .name = "head", .f = &lHttpHead },
            .{ .name = "request", .f = &lHttpRequest },
            .{ .name = "allowed", .f = &lHttpAllowed },
        } },
        .{ .name = "secrets", .fns = &.{
            .{ .name = "get", .f = &lSecretGet },
            .{ .name = "set", .f = &lSecretSet },
            .{ .name = "delete", .f = &lSecretDelete },
        } },
        .{ .name = "json", .fns = &.{
            .{ .name = "encode", .f = &lJsonEncode },
            .{ .name = "decode", .f = &lJsonDecode },
        } },
    };
    for (groups) |g| {
        lua.lua_createtable(L, 0, @intCast(g.fns.len));
        for (g.fns) |a| {
            lua.pushcfunction(L, a.f);
            lua.lua_setfield(L, -2, a.name);
        }
        lua.lua_setfield(L, -2, g.name);
    }
    lua.lua_setglobal(L, "larper");
    // As funções registradas ficam no registro, longe do script.
    const lists = [_][*:0]const u8{ "message", "edit", "dismiss", "hosts", "ready", "delete", "channel", "lang", "panel", "commands", "keys", "menus", "timers", "http", "msgs", "cb_now", "cb_prev", "opt_now", "opt_prev", "storage" };
    lua.lua_createtable(L, 0, lists.len);
    for (lists) |k| {
        lua.newtable(L);
        lua.lua_setfield(L, -2, k);
    }
    lua.lua_setfield(L, lua.REGISTRYINDEX, "larper");
}

// --- Funções do Lua ----------------------------------------------------------

/// setmetatable sem `__gc`: o finalizador roda com o gancho de instruções
/// desligado, então um `while true do end` nele prenderia a thread para sempre.
/// O Lua só registra finalizador nesta chamada; criar o campo depois não vale.
fn lSetmetatable(L: ?*lua.State) callconv(.c) c_int {
    lua.luaL_checktype(L, 1, lua.TTABLE);
    const kind = lua.lua_type(L, 2);
    if (kind != lua.TNIL and kind != lua.TTABLE) raise(L, tr("setmetatable: a metatabela precisa ser uma tabela ou nil", "setmetatable: the metatable must be a table or nil"));
    if (kind == lua.TTABLE) {
        _ = lua.lua_pushstring(L, "__gc");
        const has_gc = lua.lua_rawget(L, 2) != lua.TNIL;
        lua.pop(L, 1);
        if (has_gc) raise(L, tr("setmetatable: __gc não é permitido em plugins", "setmetatable: __gc isn't allowed in plugins"));
    }
    if (lua.lua_getmetatable(L, 1) != 0) {
        _ = lua.lua_pushstring(L, "__metatable");
        const protected_mt = lua.lua_rawget(L, -2) != lua.TNIL;
        lua.pop(L, 2);
        if (protected_mt) raise(L, tr("setmetatable: metatabela protegida", "setmetatable: protected metatable"));
    }
    lua.lua_settop(L, 2);
    _ = lua.lua_setmetatable(L, 1);
    return 1;
}

fn lPrint(L: ?*lua.State) callconv(.c) c_int {
    const p = plug(L);
    var buf: [512]u8 = undefined;
    var n: usize = 0;
    const top = lua.lua_gettop(L);
    var i: c_int = 1;
    while (i <= top) : (i += 1) {
        var len: usize = 0;
        const s = lua.luaL_tolstring(L, i, &len);
        if (i > 1 and n < buf.len) {
            buf[n] = '\t';
            n += 1;
        }
        const k = @min(len, buf.len - n);
        @memcpy(buf[n..][0..k], s[0..k]);
        n += k;
        lua.pop(L, 1);
    }
    std.log.info("[{s}] {s}", .{ p.name, buf[0..n] });
    return 0;
}

/// pcall que não segura o erro de "travou": esse sempre sai até o app.
fn lPcall(L: ?*lua.State) callconv(.c) c_int {
    lua.luaL_checkany(L, 1);
    const rc = lua.lua_pcallk(L, lua.lua_gettop(L) - 1, lua.MULTRET, 0, 0, null);
    if (plug(L).timed_out) return lua.lua_error(L);
    if (rc == lua.OK) {
        lua.lua_pushboolean(L, 1);
        lua.insert(L, 1);
        return lua.lua_gettop(L);
    }
    lua.lua_pushboolean(L, 0);
    lua.insert(L, -2);
    return 2;
}

fn lXpcall(L: ?*lua.State) callconv(.c) c_int {
    const n = lua.lua_gettop(L);
    lua.luaL_checktype(L, 2, lua.TFUNCTION);
    // [f, msgh, args…] -> [f, msgh, true, f, args…]
    lua.lua_pushboolean(L, 1);
    lua.lua_pushvalue(L, 1);
    lua.lua_rotate(L, 3, 2);
    const rc = lua.lua_pcallk(L, n - 2, lua.MULTRET, 2, 0, null);
    if (plug(L).timed_out) return lua.lua_error(L);
    if (rc == lua.OK) return lua.lua_gettop(L) - 2;
    lua.lua_pushboolean(L, 0);
    lua.lua_pushvalue(L, -2);
    return 2;
}

fn registryList(L: ?*lua.State, field: [*:0]const u8) void {
    _ = lua.lua_getfield(L, lua.REGISTRYINDEX, "larper");
    _ = lua.lua_getfield(L, -1, field);
}

/// O `contains` de uma tabela de opções: até 16 pedaços de texto. Vazio = sem filtro.
fn optNeedles(L: ?*lua.State, p: *Rt, opts: c_int, api: []const u8) [][]u8 {
    _ = lua.lua_pushstring(L, "contains");
    if (lua.lua_rawget(L, opts) != lua.TTABLE) {
        lua.pop(L, 1);
        return &.{};
    }
    const t = lua.lua_gettop(L);
    const n: usize = @intCast(lua.lua_rawlen(L, t));
    if (n == 0 or n > 16) raiseFmt(L, "{s}: `contains` é uma lista de 1 a 16 textos", "{s}: `contains` is a list of 1 to 16 strings", .{api});
    // Lê tudo antes de alocar (os textos continuam na tabela, que é argumento).
    var raw: [16][]const u8 = undefined;
    for (raw[0..n], 1..) |*r, i| {
        const kind = lua.lua_rawgeti(L, t, @intCast(i));
        const s = (if (kind == lua.TSTRING) lua.toSlice(L, -1) else null) orelse "";
        if (s.len == 0 or s.len > 64) raiseFmt(L, "{s}: `contains` é uma lista de textos de 1 a 64 bytes", "{s}: `contains` is a list of strings of 1 to 64 bytes", .{api});
        r.* = s;
        lua.pop(L, 1);
    }
    lua.pop(L, 1);
    const a = p.gpa();
    const list = a.alloc([]u8, n) catch raise(L, tr("sem memória", "out of memory"));
    var made: usize = 0;
    for (raw[0..n], list) |r, *to| {
        to.* = a.dupe(u8, r) catch {
            for (list[0..made]) |x| a.free(x);
            a.free(list);
            raise(L, tr("sem memória", "out of memory"));
        };
        made += 1;
    }
    return list;
}

/// larper.on("message" | "edit" | "dismiss" | "hosts" | "ready" | "delete" | "channel" | "lang" | "panel", fn, [opções])
/// Em "message" e "edit", {contains={"texto", …}} só chama a função para o que tem um
/// deles: o resto nem chega ao Lua.
fn lOn(L: ?*lua.State) callconv(.c) c_int {
    const p = plug(L);
    const event = lua.checkSlice(L, 1);
    lua.luaL_checktype(L, 2, lua.TFUNCTION);
    const eql = std.mem.eql;
    const field: [*:0]const u8, const counter: *u16 = if (eql(u8, event, "message"))
        .{ "message", &p.n_message }
    else if (eql(u8, event, "edit"))
        .{ "edit", &p.n_edit }
    else if (eql(u8, event, "dismiss"))
        .{ "dismiss", &p.n_dismiss }
    else if (eql(u8, event, "hosts"))
        .{ "hosts", &p.n_hosts }
    else if (eql(u8, event, "ready"))
        .{ "ready", &p.n_ready }
    else if (eql(u8, event, "delete"))
        .{ "delete", &p.n_delete }
    else if (eql(u8, event, "channel"))
        .{ "channel", &p.n_channel }
    else if (eql(u8, event, "lang"))
        .{ "lang", &p.n_lang }
    else if (eql(u8, event, "panel"))
        .{ "panel", &p.n_panel }
    else
        raise(L, tr("larper.on: evento desconhecido (use \"message\", \"edit\", \"dismiss\", \"hosts\", \"ready\", \"delete\", \"channel\", \"lang\" ou \"panel\")", "larper.on: unknown event (use \"message\", \"edit\", \"dismiss\", \"hosts\", \"ready\", \"delete\", \"channel\", \"lang\" or \"panel\")"));
    if (eql(u8, event, "message") or eql(u8, event, "edit") or eql(u8, event, "delete")) need(L, p, .messages, "larper.on");
    if (eql(u8, event, "dismiss")) need(L, p, .decorate, "larper.on");
    if (eql(u8, event, "hosts")) need(L, p, .http, "larper.on");
    if (counter.* >= 64) raise(L, tr("larper.on: funções demais para esse evento", "larper.on: too many functions for that event"));
    const filters: ?*std.ArrayList([][]u8) = if (eql(u8, event, "message")) &p.msg_filters else if (eql(u8, event, "edit")) &p.edit_filters else null;
    const has_opts = lua.lua_type(L, 3) == lua.TTABLE;
    if (has_opts and filters == null) raise(L, tr("larper.on: `contains` só vale em \"message\" e \"edit\"", "larper.on: `contains` only works on \"message\" and \"edit\""));
    if (filters) |list| {
        // Antes de registrar: um `contains` errado não deixa a função valendo para tudo.
        while (list.items.len > counter.*) wire.freeNeedles(p.gpa(), list.pop().?);
        const needles = if (has_opts) optNeedles(L, p, 3, "larper.on") else @as([][]u8, &.{});
        list.append(p.gpa(), needles) catch {
            wire.freeNeedles(p.gpa(), needles);
            raise(L, tr("sem memória", "out of memory"));
        };
    }
    registryList(L, field);
    const list_at = lua.lua_gettop(L);
    const n = lua.lua_rawlen(L, list_at);
    lua.lua_pushvalue(L, 2);
    lua.lua_rawseti(L, list_at, @intCast(n + 1));
    counter.* += 1;
    p.reg_dirty = true;
    return 0;
}

pub fn validCommand(name: []const u8) bool {
    if (name.len < 2 or name.len > 32 or name[0] != '/') return false;
    for (name[1..]) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '-') return false;
    return true;
}

/// larper.command("/nome", fn(args))
fn lCommand(L: ?*lua.State) callconv(.c) c_int {
    const p = plug(L);
    const name = lua.checkSlice(L, 1);
    lua.luaL_checktype(L, 2, lua.TFUNCTION);
    if (!validCommand(name)) raise(L, tr("larper.command: o nome é \"/\" seguido de letras, números, _ ou - (até 32)", "larper.command: the name is \"/\" followed by letters, digits, _ or - (up to 32)"));
    const known = for (p.commands.items) |cmd| {
        if (std.mem.eql(u8, cmd, name)) break true;
    } else false;
    if (!known and p.commands.items.len >= max_commands) raise(L, tr("larper.command: comandos demais", "larper.command: too many commands"));
    registryList(L, "commands");
    lua.lua_pushvalue(L, 1);
    lua.lua_pushvalue(L, 2);
    lua.lua_rawset(L, -3);
    if (!known) {
        const own = p.dupText(L, name);
        p.commands.append(p.gpa(), own) catch {
            p.gpa().free(own);
            raise(L, tr("sem memória", "out of memory"));
        };
        p.reg_dirty = true;
    }
    return 0;
}

/// "ctrl+shift+x" -> Keybind (sem a tecla resolvida). null = inválido.
pub fn parseKeys(spec: []const u8, key_name: *[16]u8, key_len: *usize) ?wire.Keybind {
    var kb: wire.Keybind = .{};
    var have_key = false;
    var it = std.mem.splitScalar(u8, spec, '+');
    while (it.next()) |raw| {
        const part = std.mem.trim(u8, raw, " ");
        if (part.len == 0 or part.len > key_name.len) return null;
        var low: [16]u8 = undefined;
        for (part, 0..) |ch, i| low[i] = std.ascii.toLower(ch);
        const w = low[0..part.len];
        if (std.mem.eql(u8, w, "ctrl") or std.mem.eql(u8, w, "control")) {
            kb.ctrl = true;
        } else if (std.mem.eql(u8, w, "shift")) {
            kb.shift = true;
        } else if (std.mem.eql(u8, w, "alt")) {
            kb.alt = true;
        } else if (std.mem.eql(u8, w, "super") or std.mem.eql(u8, w, "meta") or std.mem.eql(u8, w, "win") or std.mem.eql(u8, w, "cmd")) {
            kb.super = true;
        } else {
            if (have_key) return null;
            have_key = true;
            @memcpy(key_name[0..w.len], w);
            key_len.* = w.len;
        }
    }
    if (!have_key) return null;
    // Sem Ctrl/Alt/Super, uma letra dispararia enquanto se digita: só F1–F24.
    const name = key_name[0..key_len.*];
    const fkey = name.len >= 2 and name[0] == 'f' and std.ascii.isDigit(name[1]);
    if (!kb.ctrl and !kb.alt and !kb.super and !fkey) return null;
    // Ctrl+V e cia. acontecem o tempo todo digitando: um atalho aí seria um
    // "a pessoa pediu" que ela nunca pediu (e libera larper.send).
    if (kb.ctrl and !kb.shift and !kb.alt and !kb.super and name.len == 1 and std.mem.indexOfScalar(u8, "acvxyz", name[0]) != null) return null;
    var n: usize = 0;
    for ([_]struct { on: bool, s: []const u8 }{
        .{ .on = kb.ctrl, .s = "Ctrl+" },
        .{ .on = kb.alt, .s = "Alt+" },
        .{ .on = kb.shift, .s = "Shift+" },
        .{ .on = kb.super, .s = "Super+" },
    }) |m| if (m.on) {
        @memcpy(kb.label_buf[n..][0..m.s.len], m.s);
        n += m.s.len;
    };
    for (name, 0..) |ch, i| {
        kb.label_buf[n] = if (i == 0 or fkey) std.ascii.toUpper(ch) else ch;
        n += 1;
    }
    kb.label_len = @intCast(n);
    return kb;
}

/// larper.keybind("ctrl+shift+x", fn)
fn lKeybind(L: ?*lua.State) callconv(.c) c_int {
    const p = plug(L);
    const spec = lua.checkSlice(L, 1);
    lua.luaL_checktype(L, 2, lua.TFUNCTION);
    var name: [16]u8 = undefined;
    var len: usize = 0;
    var kb = parseKeys(spec, &name, &len) orelse
        raise(L, tr("larper.keybind: use algo como \"ctrl+shift+x\" (letras e números pedem Ctrl, Alt ou Super; F1–F24 podem ir sozinhas)", "larper.keybind: use something like \"ctrl+shift+x\" (letters and digits need Ctrl, Alt or Super; F1–F24 can go alone)"));
    kb.key = p.w.host.key(name[0..len]) orelse raise(L, tr("larper.keybind: tecla desconhecida", "larper.keybind: unknown key"));
    if (p.keys.items.len >= max_keys) raise(L, tr("larper.keybind: atalhos demais", "larper.keybind: too many keybinds"));
    registryList(L, "keys");
    const n = lua.lua_rawlen(L, -1);
    lua.lua_pushvalue(L, 2);
    lua.lua_rawseti(L, -2, @intCast(n + 1));
    kb.slot = @intCast(n + 1);
    p.keys.append(p.gpa(), kb) catch raise(L, tr("sem memória", "out of memory"));
    p.reg_dirty = true;
    return 0;
}

/// larper.notify(texto, {desktop=true})
fn lNotify(L: ?*lua.State) callconv(.c) c_int {
    const p = plug(L);
    need(L, p, .notify, "larper.notify");
    const text = lua.checkSlice(L, 1);
    var desktop = false;
    if (lua.lua_type(L, 2) == lua.TTABLE) {
        _ = lua.lua_pushstring(L, "desktop");
        _ = lua.lua_rawget(L, 2);
        desktop = lua.lua_toboolean(L, -1) != 0;
        lua.pop(L, 1);
    }
    const now = sync.nowMs();
    if (now - p.notify_from >= 10_000) {
        p.notify_from = now;
        p.notify_n = 0;
    }
    // Uma rajada não vira uma fila de avisos: o resto se perde, sem erro.
    if (p.notify_n >= notify_burst) return 0;
    p.notify_n += 1;
    p.budgetCmd(L);
    const cut = clip(text, 600);
    _ = p.w.emit(p.run, .{ .notify = .{ .text = p.dupText(L, cut), .desktop = desktop } });
    return 0;
}

fn clip(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var n = max;
    while (n > 0 and (s[n] & 0xC0) == 0x80) n -= 1;
    return s[0..n];
}

fn parseId(s: []const u8) ?u64 {
    return std.fmt.parseInt(u64, std.mem.trim(u8, s, " "), 10) catch null;
}

/// Um ID em forma de argumento: nil (0), "123", 123 ou {id="123"}.
fn idArg(L: ?*lua.State, idx: c_int) ?u64 {
    switch (lua.lua_type(L, idx)) {
        lua.TNIL => return 0,
        lua.TSTRING => return parseId(lua.toSlice(L, idx).?),
        lua.TNUMBER => {
            var ok: c_int = 0;
            const v = lua.lua_tointegerx(L, idx, &ok);
            return if (ok != 0 and v > 0) @intCast(v) else null;
        },
        lua.TTABLE => {
            _ = lua.lua_pushstring(L, "id");
            _ = lua.lua_rawget(L, idx);
            defer lua.pop(L, 1);
            return if (lua.lua_type(L, -1) == lua.TSTRING) parseId(lua.toSlice(L, -1).?) else null;
        },
        else => return null,
    }
}

/// O ID num campo da tabela em `t`: texto, número ou outra tabela com `id` (uma
/// mensagem, um canal). null = não veio; erro de Lua se veio e não é um ID.
fn fieldId(L: ?*lua.State, t: c_int, name: [*:0]const u8, api: []const u8) ?u64 {
    _ = lua.lua_pushstring(L, name);
    const kind = lua.lua_rawget(L, t);
    defer lua.pop(L, 1);
    if (kind == lua.TNIL) return null;
    const id = idArg(L, lua.lua_gettop(L)) orelse 0;
    if (id == 0) raiseFmt(L, "{s}: `{s}` precisa ser um ID (texto, ou uma tabela com `id`)", "{s}: `{s}` must be an ID (a string, or a table with `id`)", .{ api, std.mem.span(name) });
    return id;
}

/// Um envio que já passou pela capacidade e pelo gesto. Até 5 por gesto, somando
/// larper.send e larper.reply.
fn sendOne(L: ?*lua.State, p: *Rt, ch: u64, text: []const u8, reply_to: u64, api: []const u8) void {
    if (text.len == 0 or text.len > 2000) raiseFmt(L, "{s}: o texto precisa ter de 1 a 2000 bytes", "{s}: the text must be 1 to 2000 bytes", .{api});
    if (p.sends >= max_sends) raiseFmt(L, "{s}: no máximo 5 mensagens por comando", "{s}: at most 5 messages per command", .{api});
    p.sends += 1;
    _ = p.w.emit(p.run, .{ .send = .{ .channel = ch, .text = p.dupText(L, text), .token = p.gesture, .reply_to = reply_to } });
}

/// larper.send(canal, texto, [{reply_to=id}]): só quando a própria pessoa fez algo no plugin.
fn lSend(L: ?*lua.State) callconv(.c) c_int {
    const p = plug(L);
    need(L, p, .send, "larper.send");
    if (p.gesture == 0) raise(L, tr("larper.send só funciona dentro de larper.command, larper.keybind, de um botão ou de um menu do plugin (nunca em resposta automática)", "larper.send only works inside larper.command, larper.keybind, or one of the plugin's buttons or menus (never as an automatic reply)"));
    const ch = idArg(L, 1) orelse raise(L, tr("larper.send: canal inválido", "larper.send: invalid channel"));
    const text = lua.checkSlice(L, 2);
    const reply_to = if (lua.lua_type(L, 3) == lua.TTABLE) fieldId(L, 3, "reply_to", "larper.send") orelse 0 else 0;
    sendOne(L, p, ch, text, reply_to, "larper.send");
    return 0;
}

/// O canal de uma mensagem passada como tabela (`msg.channel.id`); 0 = a interface acha.
fn msgChannel(L: ?*lua.State, idx: c_int) u64 {
    if (lua.lua_type(L, idx) != lua.TTABLE) return 0;
    return fieldId(L, idx, "channel", "larper") orelse 0;
}

/// larper.reply(mensagem, texto): responde à mensagem, no canal dela. É um envio:
/// só num gesto e contando no limite de larper.send.
fn lReply(L: ?*lua.State) callconv(.c) c_int {
    const p = plug(L);
    need(L, p, .send, "larper.reply");
    needGesture(L, p, "larper.reply");
    const id = msgIdArg(L, "larper.reply");
    const text = lua.checkSlice(L, 2);
    sendOne(L, p, msgChannel(L, 1), text, id, "larper.reply");
    return 0;
}

// --- Ações na conta ------------------------------------------------------------------

/// Mais uma ação deste tipo: até tantas por gesto e por minuto (act_per_*). Um plugin
/// com defeito, ou mal-intencionado, não apaga nem reage em massa.
fn takeAct(L: ?*lua.State, p: *Rt, kind: ActKind, api: []const u8) void {
    const k = @backingInt(kind);
    const now = sync.nowMs();
    if (now - p.act_from >= 60_000) {
        p.act_from = now;
        p.act_min = @splat(0);
    }
    if (p.acts[k] >= act_per_gesture[k] or p.act_min[k] >= act_per_minute[k]) raiseFmt(L, "{s}: no máximo {d} por gesto e {d} por minuto", "{s}: at most {d} per gesture and {d} per minute", .{ api, act_per_gesture[k], act_per_minute[k] });
    p.acts[k] += 1;
    p.act_min[k] += 1;
}

/// Capacidade, gesto e limite: o que toda ação na conta confere antes de sair.
fn actionStart(L: ?*lua.State, p: *Rt, cap: manifest.Cap, kind: ActKind, api: []const u8) void {
    need(L, p, cap, api);
    if (p.gesture == 0) raiseFmt(L, "{s} só funciona num comando, atalho, botão ou menu do plugin (nunca num evento, temporizador ou resposta HTTP)", "{s} only works inside one of the plugin's commands, keybinds, buttons or menus (never in an event, timer or HTTP reply)", .{api});
    takeAct(L, p, kind, api);
}

fn emitAction(L: ?*lua.State, p: *Rt, a: wire.Action) void {
    p.budgetCmd(L);
    _ = p.w.emit(p.run, .{ .action = .{ .what = a, .token = p.gesture } });
}

/// "nome:123", "<:nome:123>" ou "<a:nome:123>": um emoji personalizado.
pub fn customEmoji(s_in: []const u8) ?struct { name: []const u8, id: u64, animated: bool } {
    var s = s_in;
    var animated = false;
    if (std.mem.startsWith(u8, s, "<") and std.mem.endsWith(u8, s, ">")) {
        s = s[1 .. s.len - 1];
        if (std.mem.startsWith(u8, s, "a:")) {
            animated = true;
            s = s[2..];
        } else if (std.mem.startsWith(u8, s, ":")) s = s[1..] else return null;
    }
    const colon = std.mem.lastIndexOfScalar(u8, s, ':') orelse return null;
    const name = s[0..colon];
    if (name.len < 2 or name.len > 32) return null;
    for (name) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_') return null;
    const id = std.fmt.parseInt(u64, s[colon + 1 ..], 10) catch return null;
    if (id == 0) return null;
    return .{ .name = name, .id = id, .animated = animated };
}

/// Um emoji para reagir: um de verdade ("👍", "1️⃣") ou um personalizado. Nada de
/// texto solto ("lol").
pub fn validEmoji(s: []const u8) bool {
    if (customEmoji(s) != null) return true;
    if (s.len == 0 or s.len > 32) return false;
    for (s) |ch| if (ch <= 0x20 or ch == 0x7F) return false;
    return s[0] >= 0x80 or std.mem.indexOf(u8, s, "\u{20E3}") != null;
}

/// larper.react(mensagem, "👍"): põe a reação (já estando lá, nada muda). Num gesto.
fn lReact(L: ?*lua.State) callconv(.c) c_int {
    const p = plug(L);
    actionStart(L, p, .actions, .react, "larper.react");
    const id = msgIdArg(L, "larper.react");
    const emoji = lua.checkSlice(L, 2);
    if (!validEmoji(emoji)) raise(L, tr("larper.react: use um emoji (\"👍\") ou um personalizado (\"nome:123\")", "larper.react: use an emoji (\"👍\") or a custom one (\"name:123\")"));
    emitAction(L, p, .{ .react = .{ .id = id, .emoji = p.dupText(L, emoji) } });
    return 0;
}

/// larper.edit(mensagem, texto): só uma mensagem sua (a interface confere), num gesto.
fn lEdit(L: ?*lua.State) callconv(.c) c_int {
    const p = plug(L);
    actionStart(L, p, .actions, .edit, "larper.edit");
    const id = msgIdArg(L, "larper.edit");
    const text = lua.checkSlice(L, 2);
    if (text.len == 0 or text.len > 2000) raise(L, tr("larper.edit: o texto precisa ter de 1 a 2000 bytes", "larper.edit: the text must be 1 to 2000 bytes"));
    emitAction(L, p, .{ .edit = .{ .id = id, .text = p.dupText(L, text) } });
    return 0;
}

/// larper.delete(mensagem): a interface pergunta antes de apagar. Uma por gesto.
fn lDelete(L: ?*lua.State) callconv(.c) c_int {
    const p = plug(L);
    actionStart(L, p, .actions, .delete, "larper.delete");
    emitAction(L, p, .{ .delete = .{ .id = msgIdArg(L, "larper.delete") } });
    return 0;
}

fn pinCall(L: ?*lua.State, add: bool) c_int {
    const p = plug(L);
    const api = if (add) "larper.pin" else "larper.unpin";
    actionStart(L, p, .actions, .pin, api);
    emitAction(L, p, .{ .pin = .{ .id = msgIdArg(L, api), .add = add } });
    return 0;
}

/// larper.pin(mensagem) e larper.unpin(mensagem): pede "gerenciar mensagens" no canal.
fn lPin(L: ?*lua.State) callconv(.c) c_int {
    return pinCall(L, true);
}

fn lUnpin(L: ?*lua.State) callconv(.c) c_int {
    return pinCall(L, false);
}

/// larper.thread(mensagem, nome): cria uma thread a partir da mensagem.
fn lThread(L: ?*lua.State) callconv(.c) c_int {
    const p = plug(L);
    actionStart(L, p, .actions, .thread, "larper.thread");
    const id = msgIdArg(L, "larper.thread");
    const name = std.mem.trim(u8, lua.checkSlice(L, 2), " \t\r\n");
    if (name.len == 0 or name.len > 100) raise(L, tr("larper.thread: o nome tem de 1 a 100 bytes", "larper.thread: the name is 1 to 100 bytes"));
    emitAction(L, p, .{ .thread = .{ .id = id, .name = p.dupText(L, name) } });
    return 0;
}

/// larper.attach(canal): a interface pergunta e abre o seletor de arquivos do app; o
/// arquivo escolhido vai para a caixa daquele canal. O plugin nunca vê o caminho.
fn lAttach(L: ?*lua.State) callconv(.c) c_int {
    const p = plug(L);
    actionStart(L, p, .composer, .attach, "larper.attach");
    const ch = idArg(L, 1) orelse raise(L, tr("larper.attach: canal inválido", "larper.attach: invalid channel"));
    emitAction(L, p, .{ .attach = .{ .channel = ch } });
    return 0;
}

/// larper.lsp("zig", {"zls", "--flag"}): propõe um servidor de linguagem. Aqui
/// nada roda: a proposta aparece nas Configurações e só vale depois que a pessoa
/// ligar, para este plugin, esta linguagem e este argv.
fn lLsp(L: ?*lua.State) callconv(.c) c_int {
    const p = plug(L);
    need(L, p, .lsp, "larper.lsp");
    const lang = lua.checkSlice(L, 1);
    lua.luaL_checktype(L, 2, lua.TTABLE);
    if (!lsp_core.validLang(lang)) raise(L, tr("larper.lsp: a linguagem é a etiqueta do bloco: até 16 letras minúsculas, números, _, - ou +", "larper.lsp: the language is the block tag: up to 16 lowercase letters, digits, _, - or +"));
    const n = lua.lua_rawlen(L, 2);
    if (n == 0 or n > lsp_core.max_argv) raise(L, tr("larper.lsp: o comando é uma lista de 1 a 32 textos", "larper.lsp: the command is a list of 1 to 32 strings"));
    var cmd: lsp_core.Command = .{};
    var i: lua.Integer = 1;
    while (i <= @as(lua.Integer, @intCast(n))) : (i += 1) {
        const kind = lua.lua_rawgeti(L, 2, i);
        const arg = (if (kind == lua.TSTRING) lua.toSlice(L, -1) else null) orelse raise(L, tr("larper.lsp: o comando é uma lista de textos", "larper.lsp: the command is a list of strings"));
        if ((i == 1 and arg.len == 0) or !cmd.add(arg)) raise(L, tr("larper.lsp: comando vazio, longo demais ou com um byte nulo", "larper.lsp: command empty, too long or with a null byte"));
        lua.pop(L, 1);
    }
    const entry: wire.LspServer = .{ .lang = lsp_core.Short.of(lang), .cmd = cmd };
    p.reg_dirty = true;
    for (p.lsp.items) |*old| {
        if (old.lang.eql(lang)) {
            old.* = entry;
            return 0;
        }
    }
    if (p.lsp.items.len >= max_lsp) raise(L, tr("larper.lsp: servidores demais", "larper.lsp: too many servers"));
    p.lsp.append(p.gpa(), entry) catch raise(L, tr("sem memória", "out of memory"));
    return 0;
}

fn pushChannel(L: ?*lua.State, p: *Rt) void {
    var wb: WhereBuf = undefined;
    p.w.lock.lock();
    wb = p.w.where;
    p.w.lock.unlock();
    if (wb.channel == 0) lua.lua_pushnil(L) else pushRef(L, wb.channel, wb.channel_name[0..wb.channel_len]);
}

/// larper.channel() -> {id, name} ou nil
fn lChannel(L: ?*lua.State) callconv(.c) c_int {
    pushChannel(L, plug(L));
    return 1;
}

/// larper.guild() -> {id, name} ou nil (mensagens diretas)
fn lGuild(L: ?*lua.State) callconv(.c) c_int {
    const p = plug(L);
    var wb: WhereBuf = undefined;
    p.w.lock.lock();
    wb = p.w.where;
    p.w.lock.unlock();
    if (wb.guild == 0) lua.lua_pushnil(L) else pushRef(L, wb.guild, wb.guild_name[0..wb.guild_len]);
    return 1;
}

/// larper.lang() -> "pt", "en", "ja", "ru"…: o idioma da interface.
fn lLang(L: ?*lua.State) callconv(.c) c_int {
    _ = lua.lua_pushstring(L, lang_code());
    return 1;
}

/// Um rótulo: texto (ou número), ou uma tabela {pt=…, en=…, ja=…} com códigos de
/// idioma (loc.validCode; o resto da tabela fica de fora). Os textos são emprestados
/// do Lua (vivos enquanto o valor em `idx` estiver na pilha ou numa tabela que é
/// argumento), cortados em `max` bytes e em ordem de código.
fn labelPairs(L: ?*lua.State, idx: c_int, out: *[loc.max_langs]loc.Pair, max: usize) []loc.Pair {
    switch (lua.lua_type(L, idx)) {
        lua.TSTRING => {
            out[0] = .{ .code = "", .text = clip(lua.toSlice(L, idx).?, max) };
            return out[0..1];
        },
        lua.TTABLE => {},
        else => return out[0..0],
    }
    const t = lua.lua_absindex(L, idx);
    var n: usize = 0;
    lua.lua_pushnil(L);
    while (lua.lua_next(L, t) != 0) {
        defer lua.pop(L, 1);
        if (lua.lua_type(L, -2) != lua.TSTRING or lua.lua_type(L, -1) != lua.TSTRING) continue;
        const code = lua.toSlice(L, -2).?;
        if (!loc.validCode(code) or n == out.len) continue;
        out[n] = .{ .code = code, .text = clip(lua.toSlice(L, -1).?, max) };
        n += 1;
    }
    loc.sortPairs(out[0..n]);
    return out[0..n];
}

/// O texto de um rótulo no idioma da interface ("" sem nenhum).
fn labelText(L: ?*lua.State, idx: c_int, max: usize) []const u8 {
    if (lua.lua_type(L, idx) == lua.TNUMBER) return clip(lua.toSlice(L, idx) orelse "", max);
    var buf: [loc.max_langs]loc.Pair = undefined;
    return loc.pickPair(uiLang(), labelPairs(L, idx, &buf, max));
}

/// larper.tr("texto", "text") ou larper.tr{pt="…", en="…", ja="…"}: o texto no
/// idioma da interface. Na forma de tabela: o código exato, o idioma base (pt-BR →
/// pt), o inglês e, sem eles, o primeiro. Na de dois textos, qualquer idioma que não
/// seja o português fica com o inglês.
fn lTr(L: ?*lua.State) callconv(.c) c_int {
    if (lua.lua_type(L, 1) == lua.TTABLE) {
        var buf: [loc.max_langs]loc.Pair = undefined;
        const pairs = labelPairs(L, 1, &buf, 64 * 1024);
        if (pairs.len == 0) raise(L, tr("larper.tr: a tabela precisa de pelo menos um idioma, como {en = \"…\"}", "larper.tr: the table needs at least one language, like {en = \"…\"}"));
        lua.pushSlice(L, loc.pickPair(uiLang(), pairs));
        return 1;
    }
    lua.luaL_checkany(L, 1);
    lua.luaL_checkany(L, 2);
    lua.lua_pushvalue(L, if (lang_en()) 2 else 1);
    return 1;
}

// --- Temporizadores --------------------------------------------------------------

fn addTimer(L: ?*lua.State, every: bool) c_int {
    const p = plug(L);
    need(L, p, .timers, if (every) "larper.every" else "larper.after");
    var ok: c_int = 0;
    const secs = lua.lua_tonumberx(L, 1, &ok);
    if (ok == 0 or std.math.isNan(secs)) raise(L, tr("o tempo é um número de segundos", "the time is a number of seconds"));
    lua.luaL_checktype(L, 2, lua.TFUNCTION);
    if (p.timers.items.len >= max_timers) raise(L, tr("temporizadores demais (no máximo 64)", "too many timers (at most 64)"));
    // Um pouco de folga: `after(0)` chamando a si mesmo não vira um laço a toda velocidade.
    const ms: i64 = @intFromFloat(std.math.clamp(secs * 1000, 10, 365.0 * 86400 * 1000));
    if (every and ms < every_min_ms) raise(L, tr("larper.every: o menor intervalo é 1 segundo", "larper.every: the shortest interval is 1 second"));
    const id = p.next_id;
    p.next_id +%= 1;
    registryList(L, "timers");
    lua.lua_pushvalue(L, 2);
    lua.lua_rawseti(L, -2, id);
    p.timers.append(p.gpa(), .{ .id = id, .due_ms = sync.nowMs() + ms, .every_ms = if (every) ms else 0 }) catch raise(L, tr("sem memória", "out of memory"));
    lua.lua_pushinteger(L, id);
    return 1;
}

/// larper.after(segundos, fn) -> id
fn lAfter(L: ?*lua.State) callconv(.c) c_int {
    return addTimer(L, false);
}

/// larper.every(segundos, fn) -> id
fn lEvery(L: ?*lua.State) callconv(.c) c_int {
    return addTimer(L, true);
}

/// larper.cancel(id)
fn lCancel(L: ?*lua.State) callconv(.c) c_int {
    const p = plug(L);
    var ok: c_int = 0;
    const id = lua.lua_tointegerx(L, 1, &ok);
    if (ok == 0) return 0;
    for (p.timers.items, 0..) |t, i| if (t.id == id) {
        _ = p.timers.swapRemove(i);
        registryList(L, "timers");
        lua.lua_pushnil(L);
        lua.lua_rawseti(L, -2, id);
        break;
    };
    return 0;
}

// --- Armazenamento ---------------------------------------------------------------

fn encodeValue(L: ?*lua.State, p: *Rt, idx: c_int, max: usize, api: []const u8) []const u8 {
    p.scratch.clearRetainingCapacity();
    json.encode(L, p.gpa(), &p.scratch, max, idx) catch |e| switch (e) {
        error.TooBig => raiseFmt(L, "{s}: grande demais", "{s}: too big", .{api}),
        error.TooDeep => raiseFmt(L, "{s}: tabelas aninhadas demais (ou uma tabela dentro dela mesma)", "{s}: tables nested too deep (or a table inside itself)", .{api}),
        error.OutOfMemory => raise(L, tr("sem memória", "out of memory")),
        else => raiseFmt(L, "{s}: só texto, número, booleano e tabela (lista ou com chaves de texto)", "{s}: only strings, numbers, booleans and tables (lists or with string keys)", .{api}),
    };
    return p.scratch.items;
}

fn storageList(L: ?*lua.State) c_int {
    registryList(L, "storage");
    return lua.lua_gettop(L);
}

/// larper.storage.get(chave) -> valor (uma cópia: mudar não grava)
fn lStoreGet(L: ?*lua.State) callconv(.c) c_int {
    const p = plug(L);
    need(L, p, .storage, "larper.storage");
    _ = lua.checkSlice(L, 1);
    const t = storageList(L);
    lua.lua_pushvalue(L, 1);
    if (lua.lua_rawget(L, t) != lua.TSTRING) {
        lua.lua_pushnil(L);
        return 1;
    }
    const text = lua.toSlice(L, -1).?;
    json.decode(L, p.gpa(), &p.scratch, text) catch raise(L, tr("larper.storage: valor ilegível", "larper.storage: unreadable value"));
    return 1;
}

/// Quanto a chave em 1 ocupa agora (0 = não existe).
fn storeOld(L: ?*lua.State, t: c_int) usize {
    lua.lua_pushvalue(L, 1);
    defer lua.pop(L, 1);
    if (lua.lua_rawget(L, t) != lua.TSTRING) return 0;
    return lua.toSlice(L, -1).?.len + lua.checkSlice(L, 1).len;
}

fn storeTouch(p: *Rt) void {
    if (!p.store_dirty) p.store_flush_at = sync.nowMs() + storage_flush_ms;
    p.store_dirty = true;
}

/// larper.storage.set(chave, valor): nil apaga.
fn lStoreSet(L: ?*lua.State) callconv(.c) c_int {
    const p = plug(L);
    need(L, p, .storage, "larper.storage");
    const key = lua.checkSlice(L, 1);
    if (key.len == 0 or key.len > 256) raise(L, tr("larper.storage: a chave tem de 1 a 256 bytes", "larper.storage: the key is 1 to 256 bytes"));
    const t = storageList(L);
    const old = storeOld(L, t);
    lua.lua_pushvalue(L, 1);
    if (lua.lua_type(L, 2) == lua.TNIL) {
        lua.lua_pushnil(L);
        lua.lua_rawset(L, t);
        p.store_bytes -|= old;
        storeTouch(p);
        return 0;
    }
    const text = encodeValue(L, p, 2, storage_cap, "larper.storage");
    // Sem espaço, o valor antigo continua lá.
    if ((p.store_bytes -| old) + text.len + key.len > storage_cap) raise(L, tr("larper.storage: cheio (1 MB por plugin)", "larper.storage: full (1 MB per plugin)"));
    lua.pushSlice(L, text);
    lua.lua_rawset(L, t);
    p.store_bytes = (p.store_bytes -| old) + text.len + key.len;
    storeTouch(p);
    return 0;
}

/// larper.storage.delete(chave)
fn lStoreDelete(L: ?*lua.State) callconv(.c) c_int {
    lua.lua_settop(L, 1);
    lua.lua_pushnil(L);
    return lStoreSet(L);
}

/// larper.storage.keys() -> lista de chaves
fn lStoreKeys(L: ?*lua.State) callconv(.c) c_int {
    need(L, plug(L), .storage, "larper.storage");
    const t = storageList(L);
    lua.newtable(L);
    const out = lua.lua_gettop(L);
    var i: lua.Integer = 1;
    lua.lua_pushnil(L);
    while (lua.lua_next(L, t) != 0) {
        lua.pop(L, 1);
        lua.lua_pushvalue(L, -1);
        lua.lua_rawseti(L, out, i);
        i += 1;
    }
    return 1;
}

/// larper.storage.clear()
fn lStoreClear(L: ?*lua.State) callconv(.c) c_int {
    const p = plug(L);
    need(L, p, .storage, "larper.storage");
    _ = lua.lua_getfield(L, lua.REGISTRYINDEX, "larper");
    lua.newtable(L);
    lua.lua_setfield(L, -2, "storage");
    p.store_bytes = 0;
    storeTouch(p);
    return 0;
}

fn storageRead(L: ?*lua.State, p: *Rt, bytes: []const u8) void {
    const t = storageList(L);
    var f = json.Fields.init(p.gpa(), &p.scratch, &p.scratch2, bytes) catch return storageBroken(L, p);
    var total: usize = 0;
    while (true) {
        const field = (f.next() catch return storageBroken(L, p)) orelse break;
        lua.pushSlice(L, field.key);
        lua.pushSlice(L, field.value);
        lua.lua_rawset(L, t);
        total += field.key.len + field.value.len;
    }
    p.store_bytes = total;
}

/// Arquivo que não dá para ler: fica guardado à parte (não some o que a pessoa
/// tinha) e o plugin começa do zero, com o erro na página.
fn storageBroken(L: ?*lua.State, p: *Rt) void {
    _ = lua.lua_getfield(L, lua.REGISTRYINDEX, "larper");
    lua.newtable(L);
    lua.lua_setfield(L, -2, "storage");
    p.store_bytes = 0;
    p.w.host.keep_broken_data(p.w.host.ctx, p.account, p.name);
    p.report(tr("larper.storage: o arquivo estava ilegível; guardei uma cópia .bad e comecei do zero", "larper.storage: the file was unreadable; kept a .bad copy and started empty"));
}

fn storageWrite(L: ?*lua.State, p: *Rt) void {
    p.scratch.clearRetainingCapacity();
    const a = p.gpa();
    const t = storageList(L);
    const max = storage_cap * 2;
    json_or(L, p.scratch.append(a, '{'));
    var first = true;
    lua.lua_pushnil(L);
    while (lua.lua_next(L, t) != 0) {
        const key = lua.toSlice(L, -2).?;
        const val = lua.toSlice(L, -1).?;
        if (!first) json_or(L, p.scratch.append(a, ','));
        first = false;
        json.quote(a, &p.scratch, max, key) catch raise(L, "storage");
        json_or(L, p.scratch.append(a, ':'));
        json_or(L, p.scratch.appendSlice(a, val));
        lua.pop(L, 1);
    }
    json_or(L, p.scratch.append(a, '}'));
}

fn json_or(L: ?*lua.State, r: anyerror!void) void {
    r catch raise(L, tr("sem memória", "out of memory"));
}

/// larper.json.encode(valor) -> texto
fn lJsonEncode(L: ?*lua.State) callconv(.c) c_int {
    const p = plug(L);
    lua.luaL_checkany(L, 1);
    lua.pushSlice(L, encodeValue(L, p, 1, storage_cap, "larper.json.encode"));
    return 1;
}

/// larper.json.decode(texto) -> valor, ou nil e o erro
fn lJsonDecode(L: ?*lua.State) callconv(.c) c_int {
    const p = plug(L);
    const text = lua.checkSlice(L, 1);
    json.decode(L, p.gpa(), &p.scratch, text) catch |e| {
        lua.lua_settop(L, 1);
        lua.lua_pushnil(L);
        _ = lua.lua_pushstring(L, if (e == error.TooDeep) "too deep" else "invalid json");
        return 2;
    };
    return 1;
}

/// larper.urlencode(texto): pronto para ir numa URL.
fn lUrlencode(L: ?*lua.State) callconv(.c) c_int {
    const p = plug(L);
    const text = lua.checkSlice(L, 1);
    if (text.len > 64 * 1024) raise(L, tr("larper.urlencode: texto longo demais", "larper.urlencode: text too long"));
    p.scratch.clearRetainingCapacity();
    const a = p.gpa();
    for (text) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '~') {
            json_or(L, p.scratch.append(a, ch));
        } else {
            var b: [3]u8 = undefined;
            json_or(L, p.scratch.appendSlice(a, std.fmt.bufPrint(&b, "%{X:0>2}", .{ch}) catch unreachable));
        }
    }
    lua.pushSlice(L, p.scratch.items);
    return 1;
}

// --- Painel ----------------------------------------------------------------------

/// Texto (ou número) de um campo da tabela em `t`, sem passar por metatabela.
fn fieldText(L: ?*lua.State, t: c_int, name: [*:0]const u8) []const u8 {
    _ = lua.lua_pushstring(L, name);
    const kind = lua.lua_rawget(L, t);
    defer lua.pop(L, 1);
    if (kind != lua.TSTRING and kind != lua.TNUMBER) return "";
    return lua.toSlice(L, -1) orelse "";
}

/// Só texto de verdade: o número viraria uma cópia que não dura até o fim da leitura.
fn fieldStr(L: ?*lua.State, t: c_int, name: [*:0]const u8) []const u8 {
    _ = lua.lua_pushstring(L, name);
    const kind = lua.lua_rawget(L, t);
    defer lua.pop(L, 1);
    if (kind != lua.TSTRING) return "";
    return lua.toSlice(L, -1) orelse "";
}

/// Um texto que a pessoa lê: texto, número ou {pt=…, en=…, ja=…} (no idioma da
/// interface; o plugin publica de novo em larper.on("lang")).
fn fieldLabel(L: ?*lua.State, t: c_int, name: [*:0]const u8) []const u8 {
    _ = lua.lua_pushstring(L, name);
    _ = lua.lua_rawget(L, t);
    defer lua.pop(L, 1);
    return labelText(L, lua.lua_gettop(L), std.math.maxInt(usize));
}

fn fieldBool(L: ?*lua.State, t: c_int, name: [*:0]const u8) bool {
    _ = lua.lua_pushstring(L, name);
    _ = lua.lua_rawget(L, t);
    defer lua.pop(L, 1);
    return lua.lua_toboolean(L, -1) != 0;
}

fn fieldNum(L: ?*lua.State, t: c_int, name: [*:0]const u8) f32 {
    _ = lua.lua_pushstring(L, name);
    _ = lua.lua_rawget(L, t);
    defer lua.pop(L, 1);
    var ok: c_int = 0;
    const v = lua.lua_tonumberx(L, -1, &ok);
    return if (ok != 0 and !std.math.isNan(v)) @floatCast(std.math.clamp(v, -1e12, 1e12)) else 0;
}

/// A função de um campo vira um número que a interface manda de volta.
fn fieldFn(L: ?*lua.State, p: *Rt, t: c_int, name: [*:0]const u8) u32 {
    _ = lua.lua_pushstring(L, name);
    _ = lua.lua_rawget(L, t);
    defer lua.pop(L, 1);
    if (lua.lua_type(L, -1) != lua.TFUNCTION) return 0;
    const handle = p.next_id;
    p.next_id +%= 1;
    registryList(L, p.cb_field);
    lua.lua_pushvalue(L, -3);
    lua.lua_rawseti(L, -2, handle);
    lua.pop(L, 2);
    return handle;
}

fn tooBig(L: ?*lua.State) noreturn {
    raiseFmt(L, "{s}: grande demais", "{s}: too big", .{plug(L).tree_api});
}

fn treeText(L: ?*lua.State, tree: *panel.Tree, s: []const u8) []const u8 {
    return tree.text(s) catch tooBig(L);
}

fn treeAdd(L: ?*lua.State, tree: *panel.Tree, n: panel.Node) u32 {
    return tree.add(n) catch tooBig(L);
}

fn styleOf(L: ?*lua.State, t: c_int) panel.Style {
    return std.meta.stringToEnum(panel.Style, fieldText(L, t, "style")) orelse .normal;
}

/// Os filhos que estão na parte de lista da tabela em `t`.
fn treeChildren(L: ?*lua.State, p: *Rt, tree: *panel.Tree, t: c_int, depth: u8) u32 {
    if (depth > 6) raiseFmt(L, "{s}: fundo demais", "{s}: nested too deep", .{p.tree_api});
    lua.luaL_checkstack(L, 12, "panel");
    var first = panel.none;
    var last = panel.none;
    const n = lua.lua_rawlen(L, t);
    var i: lua.Integer = 1;
    while (i <= @as(lua.Integer, @intCast(n))) : (i += 1) {
        if (lua.lua_rawgeti(L, t, i) != lua.TTABLE) raiseFmt(L, "{s}: cada item é uma tabela com `type`", "{s}: each item is a table with `type`", .{p.tree_api});
        const top = lua.lua_gettop(L);
        if (std.mem.eql(u8, fieldText(L, top, "type"), "option")) raiseFmt(L, "{s}: `option` só dentro de `options` de um `select`", "{s}: `option` only inside the `options` of a `select`", .{p.tree_api});
        const at = treeNode(L, p, tree, top, depth);
        lua.pop(L, 1);
        if (last == panel.none) first = at else tree.nodes.items[last].next = at;
        last = at;
    }
    return first;
}

fn treeNode(L: ?*lua.State, p: *Rt, tree: *panel.Tree, t: c_int, depth: u8) u32 {
    const type_name = fieldText(L, t, "type");
    const kind = std.meta.stringToEnum(panel.Kind, type_name) orelse
        raiseFmt(L, "{s}: tipo desconhecido \"{s}\"", "{s}: unknown type \"{s}\"", .{ p.tree_api, type_name });
    var node: panel.Node = .{ .kind = kind, .style = styleOf(L, t), .key = treeText(L, tree, fieldText(L, t, "key")) };
    switch (kind) {
        .text, .heading => node.text = treeText(L, tree, fieldLabel(L, t, "text")),
        .separator => {},
        .button => {
            node.text = treeText(L, tree, fieldLabel(L, t, "label"));
            node.click = fieldFn(L, p, t, "on_click");
        },
        .input => {
            node.sub = treeText(L, tree, fieldLabel(L, t, "placeholder"));
            node.meta = treeText(L, tree, fieldText(L, t, "value"));
            node.change = fieldFn(L, p, t, "on_change");
            node.submit = fieldFn(L, p, t, "on_submit");
            node.clear = fieldBool(L, t, "clear");
            if (node.key.len == 0) raiseFmt(L, "{s}: um campo de texto precisa de `key`", "{s}: an input needs a `key`", .{p.tree_api});
        },
        .select => {
            node.text = treeText(L, tree, fieldLabel(L, t, "label"));
            node.meta = treeText(L, tree, fieldText(L, t, "value"));
            node.change = fieldFn(L, p, t, "on_change");
            if (node.key.len == 0) raiseFmt(L, "{s}: um `select` precisa de `key`", "{s}: a `select` needs a `key`", .{p.tree_api});
        },
        .option => {
            node.text = treeText(L, tree, fieldLabel(L, t, "label"));
            node.meta = treeText(L, tree, fieldText(L, t, "value"));
        },
        .toggle => {
            node.text = treeText(L, tree, fieldLabel(L, t, "label"));
            node.sub = treeText(L, tree, fieldLabel(L, t, "hint"));
            node.value = if (fieldBool(L, t, "value")) 1 else 0;
            node.change = fieldFn(L, p, t, "on_change");
            if (node.key.len == 0) raiseFmt(L, "{s}: um `toggle` precisa de `key`", "{s}: a `toggle` needs a `key`", .{p.tree_api});
        },
        .bar => {
            node.text = treeText(L, tree, fieldLabel(L, t, "label"));
            node.meta = treeText(L, tree, fieldLabel(L, t, "text"));
            node.value = fieldNum(L, t, "value");
            node.max = fieldNum(L, t, "max");
        },
        .item => {
            node.text = treeText(L, tree, fieldLabel(L, t, "title"));
            node.sub = treeText(L, tree, fieldLabel(L, t, "subtitle"));
            node.meta = treeText(L, tree, fieldLabel(L, t, "meta"));
            node.click = fieldFn(L, p, t, "on_click");
        },
        .row, .list => {},
    }
    const at = treeAdd(L, tree, node);
    switch (kind) {
        .row => {
            // Separado: montar os filhos pode realocar a lista de nós.
            const child = treeChildren(L, p, tree, t, depth + 1);
            tree.nodes.items[at].child = child;
        },
        .list, .item => {
            // list: `items`; item: `actions` (botões).
            _ = lua.lua_pushstring(L, if (kind == .list) "items" else "actions");
            const tp = lua.lua_rawget(L, t);
            if (tp == lua.TTABLE) {
                const child = treeChildrenAs(L, p, tree, lua.lua_gettop(L), depth + 1, if (kind == .list) .item else .button);
                tree.nodes.items[at].child = child;
            }
            lua.pop(L, 1);
            if (kind == .list) tree.nodes.items[at].text = treeText(L, tree, fieldLabel(L, t, "empty"));
        },
        .select => {
            _ = lua.lua_pushstring(L, "options");
            const tp = lua.lua_rawget(L, t);
            if (tp != lua.TTABLE or lua.lua_rawlen(L, -1) == 0) raiseFmt(L, "{s}: um `select` precisa de `options`", "{s}: a `select` needs `options`", .{p.tree_api});
            const child = treeChildrenAs(L, p, tree, lua.lua_gettop(L), depth + 1, .option);
            tree.nodes.items[at].child = child;
            lua.pop(L, 1);
        },
        else => {},
    }
    return at;
}

/// Lista em que o tipo de cada item já se sabe (`items` de uma lista, `actions` de um item).
fn treeChildrenAs(L: ?*lua.State, p: *Rt, tree: *panel.Tree, t: c_int, depth: u8, kind: panel.Kind) u32 {
    if (depth > 6) raiseFmt(L, "{s}: fundo demais", "{s}: nested too deep", .{p.tree_api});
    lua.luaL_checkstack(L, 12, "panel");
    var first = panel.none;
    var last = panel.none;
    const n = lua.lua_rawlen(L, t);
    var i: lua.Integer = 1;
    while (i <= @as(lua.Integer, @intCast(n))) : (i += 1) {
        if (lua.lua_rawgeti(L, t, i) != lua.TTABLE) raiseFmt(L, "{s}: cada item é uma tabela", "{s}: each item is a table", .{p.tree_api});
        const it = lua.lua_gettop(L);
        // Assume o tipo sem exigir que venha escrito.
        _ = lua.lua_pushstring(L, "type");
        _ = lua.lua_pushstring(L, @tagName(kind));
        lua.lua_rawset(L, it);
        const at = treeNode(L, p, tree, it, depth);
        lua.pop(L, 1);
        if (last == panel.none) first = at else tree.nodes.items[last].next = at;
        last = at;
    }
    return first;
}

/// larper.panel.set({ title = "…", {type="text", text="…"}, … })
fn lPanelSet(L: ?*lua.State) callconv(.c) c_int {
    const p = plug(L);
    need(L, p, .panel, "larper.panel");
    lua.luaL_checktype(L, 1, lua.TTABLE);
    if (p.wip) |old| {
        old.destroy();
        p.wip = null;
    }
    const tree = panel.Tree.create(p.gpa()) catch raise(L, tr("sem memória", "out of memory"));
    p.wip = tree;
    p.cb_field = "cb_now";
    p.tree_api = "larper.panel.set";
    // As funções da árvore passada continuam valendo até a próxima troca.
    _ = lua.lua_getfield(L, lua.REGISTRYINDEX, "larper");
    _ = lua.lua_getfield(L, -1, "cb_now");
    lua.lua_setfield(L, -2, "cb_prev");
    lua.newtable(L);
    lua.lua_setfield(L, -2, "cb_now");
    lua.pop(L, 1);
    tree.title = treeText(L, tree, fieldLabel(L, 1, "title"));
    tree.badge = treeText(L, tree, clip(fieldText(L, 1, "badge"), 8));
    tree.first = treeChildren(L, p, tree, 1, 0);
    if (p.tree_ready) |old| old.destroy();
    p.tree_ready = tree;
    p.wip = null;
    return 0;
}

/// larper.settings.set({ {type="select", key=, label=, value=, options={…}, on_change=fn}, … })
/// Aparece no cartão do plugin em Configurações → Plugins, enquanto ele está ligado.
/// Quem guarda o valor é o plugin. Tem as próprias funções: um larper.panel.set
/// não mata as daqui, nem o contrário.
fn lSettingsSet(L: ?*lua.State) callconv(.c) c_int {
    const p = plug(L);
    need(L, p, .settings, "larper.settings");
    lua.luaL_checktype(L, 1, lua.TTABLE);
    if (p.wip) |old| {
        old.destroy();
        p.wip = null;
    }
    const tree = panel.Tree.create(p.gpa()) catch raise(L, tr("sem memória", "out of memory"));
    p.wip = tree;
    tree.settings = true;
    p.cb_field = "opt_now";
    p.tree_api = "larper.settings.set";
    _ = lua.lua_getfield(L, lua.REGISTRYINDEX, "larper");
    _ = lua.lua_getfield(L, -1, "opt_now");
    lua.lua_setfield(L, -2, "opt_prev");
    lua.newtable(L);
    lua.lua_setfield(L, -2, "opt_now");
    lua.pop(L, 1);
    tree.first = treeChildren(L, p, tree, 1, 0);
    if (p.settings_ready) |old| old.destroy();
    p.settings_ready = tree;
    p.wip = null;
    return 0;
}

fn panelShow(L: ?*lua.State, open: bool) c_int {
    const p = plug(L);
    need(L, p, .panel, "larper.panel");
    // Abrir na cara da pessoa só quando foi ela quem pediu.
    if (open and p.gesture == 0) raise(L, tr("larper.panel.open só funciona num comando, atalho, botão ou menu do plugin", "larper.panel.open only works inside one of the plugin's commands, keybinds, buttons or menus"));
    p.budgetCmd(L);
    _ = p.w.emit(p.run, .{ .panel_show = .{ .open = open, .token = p.gesture } });
    return 0;
}

fn lPanelOpen(L: ?*lua.State) callconv(.c) c_int {
    return panelShow(L, true);
}

fn lPanelClose(L: ?*lua.State) callconv(.c) c_int {
    return panelShow(L, false);
}

// --- Menus e decoração ------------------------------------------------------------

/// Lê `choices` da tabela em `t` para `raw`. Devolve quantas.
fn menuChoices(L: ?*lua.State, t: c_int, raw: *[max_choices]RawChoice) usize {
    _ = lua.lua_pushstring(L, "choices");
    if (lua.lua_rawget(L, t) != lua.TTABLE) {
        lua.pop(L, 1);
        return 0;
    }
    // A tabela fica na pilha: os textos lidos continuam vivos até o fim da chamada.
    const list = lua.lua_gettop(L);
    const n: usize = @intCast(lua.lua_rawlen(L, list));
    if (n > max_choices) raise(L, tr("larper.menu: no máximo 16 escolhas", "larper.menu: at most 16 choices"));
    for (raw[0..n], 1..) |*r, i| {
        if (lua.lua_rawgeti(L, list, @intCast(i)) != lua.TTABLE) raise(L, tr("larper.menu: cada escolha é uma tabela {value=, pt=, en=}", "larper.menu: each choice is a table {value=, pt=, en=}"));
        const it = lua.lua_gettop(L);
        const value = fieldStr(L, it, "value");
        // O rótulo: `label` (texto ou tabela de idiomas) ou os idiomas na própria
        // escolha ({value=, pt=, en=, ja=}).
        _ = lua.lua_pushstring(L, "label");
        const has_label = lua.lua_rawget(L, it) != lua.TNIL;
        const pairs = labelPairs(L, if (has_label) lua.lua_gettop(L) else it, &r.labels, 80);
        lua.pop(L, 1);
        if (value.len == 0 or pairs.len == 0) raise(L, tr("larper.menu: cada escolha precisa de `value` e de um rótulo", "larper.menu: each choice needs a `value` and a label"));
        r.value = clip(value, 64);
        r.n = pairs.len;
        lua.pop(L, 1);
    }
    return n;
}

const RawChoice = struct { value: []const u8 = "", labels: [loc.max_langs]loc.Pair = undefined, n: usize = 0 };

/// larper.menu("message" | "user", "rótulo" ou {pt=, en=, ja=, …}, fn(alvo, escolha),
///   [{choices={{value=, pt=, en=, …}, …}, toolbar="🌐"}])
fn lMenu(L: ?*lua.State) callconv(.c) c_int {
    const p = plug(L);
    need(L, p, .menu, "larper.menu");
    const kind_s = lua.checkSlice(L, 1);
    const kind = std.meta.stringToEnum(wire.MenuKind, kind_s) orelse raise(L, tr("larper.menu: use \"message\" ou \"user\"", "larper.menu: use \"message\" or \"user\""));
    lua.luaL_checktype(L, 3, lua.TFUNCTION);
    var label_buf: [loc.max_langs]loc.Pair = undefined;
    const label = labelPairs(L, 2, &label_buf, 80);
    if (label.len == 0 or label[0].text.len == 0) raise(L, tr("larper.menu: falta o rótulo", "larper.menu: the label is missing"));
    if (p.menus.items.len >= max_menus) raise(L, tr("larper.menu: no máximo 4 entradas por plugin", "larper.menu: at most 4 entries per plugin"));
    var raw: [max_choices]RawChoice = undefined;
    var n_choices: usize = 0;
    var toolbar: []const u8 = "";
    if (lua.lua_type(L, 4) == lua.TTABLE) {
        toolbar = clip(fieldStr(L, 4, "toolbar"), 16);
        if (toolbar.len > 0 and kind != .message) raise(L, tr("larper.menu: `toolbar` só vale em \"message\"", "larper.menu: `toolbar` only works on \"message\""));
        n_choices = menuChoices(L, 4, &raw);
    }
    registryList(L, "menus");
    const n = lua.lua_rawlen(L, -1);
    lua.lua_pushvalue(L, 3);
    lua.lua_rawseti(L, -2, @intCast(n + 1));
    // Daqui para baixo nada solta erro de Lua com memória na mão.
    if (!addMenu(p, kind, @intCast(n + 1), label, raw[0..n_choices], toolbar)) raise(L, tr("sem memória", "out of memory"));
    p.reg_dirty = true;
    return 0;
}

/// A entrada, com cópias de tudo (os textos vieram emprestados do Lua).
fn addMenu(p: *Rt, kind: wire.MenuKind, slot: u32, label: []const loc.Pair, raw: []const RawChoice, toolbar: []const u8) bool {
    const a = p.gpa();
    var own: wire.MenuEntry = .{ .kind = kind, .slot = slot };
    own.label = loc.Text.make(a, label) catch return false;
    own.toolbar = a.dupe(u8, toolbar) catch {
        own.free(a);
        return false;
    };
    own.choices = a.alloc(wire.MenuChoice, raw.len) catch {
        own.free(a);
        return false;
    };
    for (own.choices) |*ch| ch.* = .{ .value = &.{} };
    for (raw, own.choices) |r, *to| {
        to.value = a.dupe(u8, r.value) catch {
            own.free(a);
            return false;
        };
        to.label = loc.Text.make(a, r.labels[0..r.n]) catch {
            own.free(a);
            return false;
        };
    }
    p.menus.append(a, own) catch {
        own.free(a);
        return false;
    };
    return true;
}

fn msgIdArg(L: ?*lua.State, api: []const u8) u64 {
    const id = idArg(L, 1) orelse 0;
    if (id == 0) raiseFmt(L, "{s}: falta o ID da mensagem (texto, ou a tabela da mensagem)", "{s}: the message ID is missing (a string, or the message table)", .{api});
    return id;
}

/// larper.decorate(mensagem, {badge=, note=, collapse=, label=})
fn lDecorate(L: ?*lua.State) callconv(.c) c_int {
    const p = plug(L);
    need(L, p, .decorate, "larper.decorate");
    const id = msgIdArg(L, "larper.decorate");
    lua.luaL_checktype(L, 2, lua.TTABLE);
    p.budgetCmd(L);
    // Lê tudo antes de alocar: o que pode dar erro de Lua vem primeiro.
    const badge_s = clip(fieldLabel(L, 2, "badge"), 48);
    const note_s = clip(fieldLabel(L, 2, "note"), 2000);
    const label_s = clip(fieldLabel(L, 2, "label"), 80);
    const collapse = fieldBool(L, 2, "collapse");
    const danger = std.mem.eql(u8, fieldText(L, 2, "style"), "danger");
    const a = p.gpa();
    const badge = a.dupe(u8, badge_s) catch return 0;
    const note = a.dupe(u8, note_s) catch {
        a.free(badge);
        return 0;
    };
    const label = a.dupe(u8, label_s) catch {
        a.free(badge);
        a.free(note);
        return 0;
    };
    _ = p.w.emit(p.run, .{ .deco_set = .{ .id = id, .badge = badge, .note = note, .label = label, .collapse = collapse, .danger = danger } });
    return 0;
}

/// larper.undecorate(mensagem)
fn lUndecorate(L: ?*lua.State) callconv(.c) c_int {
    const p = plug(L);
    need(L, p, .decorate, "larper.undecorate");
    const id = msgIdArg(L, "larper.undecorate");
    p.budgetCmd(L);
    _ = p.w.emit(p.run, .{ .deco_remove = id });
    return 0;
}

/// larper.rules({ {word="x", collapse=true, label="…"}, {user="123", badge="…"} })
/// A interface aplica sozinha, sem chamar o plugin a cada mensagem.
fn lRules(L: ?*lua.State) callconv(.c) c_int {
    const p = plug(L);
    need(L, p, .decorate, "larper.rules");
    lua.luaL_checktype(L, 1, lua.TTABLE);
    p.budgetCmd(L);
    const a = p.gpa();
    const n: usize = @intCast(lua.lua_rawlen(L, 1));
    if (n > deco.max_rules) raise(L, tr("larper.rules: no máximo 256 regras", "larper.rules: at most 256 rules"));
    // Lê tudo antes de alocar: um erro de Lua no meio não deixa nada para trás.
    // (Os textos continuam vivos: estão na tabela, que é o argumento.)
    const Raw = struct { word: []const u8, user: u64, badge: []const u8, note: []const u8, label: []const u8, collapse: bool };
    var raw: [deco.max_rules]Raw = undefined;
    for (raw[0..n], 1..) |*r, i| {
        if (lua.lua_rawgeti(L, 1, @intCast(i)) != lua.TTABLE) raise(L, tr("larper.rules: cada regra é uma tabela", "larper.rules: each rule is a table"));
        const t = lua.lua_gettop(L);
        r.* = .{
            .word = std.mem.trim(u8, fieldText(L, t, "word"), " \t\r\n"),
            .user = parseId(fieldText(L, t, "user")) orelse 0,
            .badge = clip(fieldLabel(L, t, "badge"), 48),
            .note = clip(fieldLabel(L, t, "note"), 500),
            .label = clip(fieldLabel(L, t, "label"), 80),
            .collapse = fieldBool(L, t, "collapse"),
        };
        lua.pop(L, 1);
    }
    const list = a.alloc(deco.Rule, n) catch return 0;
    var built: usize = 0;
    for (raw[0..n]) |r| {
        var fb: [64]u8 = undefined;
        const rule = dupRule(a, filtros.fold(&fb, r.word), r.badge, r.note, r.label) orelse break;
        list[built] = rule;
        list[built].user = r.user;
        list[built].collapse = r.collapse;
        built += 1;
    }
    _ = p.w.emit(p.run, .{ .deco_rules = a.realloc(list, built) catch list[0..built] });
    return 0;
}

fn dupRule(a: std.mem.Allocator, word: []const u8, badge: []const u8, note: []const u8, label: []const u8) ?deco.Rule {
    const w = a.dupe(u8, word) catch return null;
    const b = a.dupe(u8, badge) catch {
        a.free(w);
        return null;
    };
    const n = a.dupe(u8, note) catch {
        a.free(w);
        a.free(b);
        return null;
    };
    const l = a.dupe(u8, label) catch {
        a.free(w);
        a.free(b);
        a.free(n);
        return null;
    };
    return .{ .word = w, .badge = b, .note = n, .label = l };
}

// --- Mensagens, composição e pulo ---------------------------------------------------

/// larper.messages([{channel=id, limit=n}], fn(lista)) -> true, ou false se pediu
/// cedo demais. A interface copia as carregadas e o resultado chega por `fn`.
fn lMessages(L: ?*lua.State) callconv(.c) c_int {
    const p = plug(L);
    need(L, p, .messages, "larper.messages");
    var channel: u64 = 0;
    var limit: u32 = messages_default;
    var cb: c_int = 1;
    var files = false;
    if (lua.lua_type(L, 1) == lua.TTABLE) {
        cb = 2;
        files = fieldBool(L, 1, "files");
        const ch_text = fieldText(L, 1, "channel");
        if (ch_text.len > 0) channel = parseId(ch_text) orelse raise(L, tr("larper.messages: canal inválido", "larper.messages: invalid channel"));
        const n = fieldNum(L, 1, "limit");
        if (n > 0) limit = @intFromFloat(@min(n, messages_max));
    }
    lua.luaL_checktype(L, cb, lua.TFUNCTION);
    const now = sync.nowMs();
    if (now - p.messages_at < messages_gap_ms) {
        lua.lua_pushboolean(L, 0);
        return 1;
    }
    p.messages_at = now;
    const id = p.next_id;
    p.next_id +%= 1;
    registryList(L, "msgs");
    lua.lua_pushvalue(L, cb);
    lua.lua_rawseti(L, -2, id);
    p.budgetCmd(L);
    const needles = if (cb == 2) optNeedles(L, p, 1, "larper.messages") else @as([][]u8, &.{});
    _ = p.w.emit(p.run, .{ .want_messages = .{ .req = id, .channel = channel, .limit = limit, .files = files, .needles = needles } });
    lua.lua_pushboolean(L, 1);
    return 1;
}

fn needGesture(L: ?*lua.State, p: *const Rt, api: []const u8) void {
    if (p.gesture == 0) raiseFmt(L, "{s} só funciona num comando, atalho, botão ou menu do plugin", "{s} only works inside one of the plugin's commands, keybinds, buttons or menus", .{api});
}

/// larper.jump(canal, mensagem): abre o canal e vai até a mensagem.
fn lJump(L: ?*lua.State) callconv(.c) c_int {
    const p = plug(L);
    needGesture(L, p, "larper.jump");
    const ch = idArg(L, 1) orelse 0;
    const id = idArg(L, 2) orelse raise(L, tr("larper.jump: mensagem inválida", "larper.jump: invalid message"));
    if (ch == 0) raise(L, tr("larper.jump: falta o canal", "larper.jump: the channel is missing"));
    p.budgetCmd(L);
    _ = p.w.emit(p.run, .{ .jump = .{ .channel = ch, .id = id, .token = p.gesture } });
    return 0;
}

/// larper.insert(texto): põe na caixa de mensagem (nunca envia). Só num gesto: um
/// plugin em segundo plano escrevendo ali faria a pessoa mandar o que não pediu.
fn lInsert(L: ?*lua.State) callconv(.c) c_int {
    const p = plug(L);
    need(L, p, .composer, "larper.insert");
    // A resposta de um pedido feito num gesto também vale: a pessoa pediu, e a caixa
    // não envia sozinha. Enviar (larper.send) continua pedindo o gesto em si.
    const token = if (p.gesture != 0) p.gesture else p.carry;
    if (token == 0) needGesture(L, p, "larper.insert");
    const text = lua.checkSlice(L, 1);
    p.budgetCmd(L);
    _ = p.w.emit(p.run, .{ .insert = .{ .text = p.dupText(L, clip(text, 2000)), .token = token } });
    return 0;
}

/// larper.copy(texto): para a área de transferência. Só num gesto.
fn lCopy(L: ?*lua.State) callconv(.c) c_int {
    const p = plug(L);
    needGesture(L, p, "larper.copy");
    const text = lua.checkSlice(L, 1);
    if (text.len == 0 or text.len > 64 * 1024) raise(L, tr("larper.copy: o texto precisa ter de 1 byte a 64 KB", "larper.copy: the text must be 1 byte to 64 KB"));
    p.budgetCmd(L);
    _ = p.w.emit(p.run, .{ .copy = .{ .text = p.dupText(L, text), .token = p.gesture } });
    return 0;
}

/// Só http e https, sem espaço nem caractere de controle.
pub fn validOpenUrl(url: []const u8) bool {
    if (url.len > 2000) return false;
    const scheme: usize = if (std.ascii.startsWithIgnoreCase(url, "https://")) 8 else if (std.ascii.startsWithIgnoreCase(url, "http://")) 7 else return false;
    if (url.len <= scheme) return false;
    for (url) |ch| if (ch <= 0x20 or ch == 0x7F) return false;
    return true;
}

/// larper.open(url): abre no navegador. Só num gesto, e só com a capacidade `links`:
/// um endereço pode levar dados embutidos, então a página avisa quem também lê mensagens.
fn lOpen(L: ?*lua.State) callconv(.c) c_int {
    const p = plug(L);
    need(L, p, .links, "larper.open");
    needGesture(L, p, "larper.open");
    const url = lua.checkSlice(L, 1);
    if (!validOpenUrl(url)) raise(L, tr("larper.open: só endereços http:// ou https://", "larper.open: only http:// or https:// addresses"));
    p.budgetCmd(L);
    _ = p.w.emit(p.run, .{ .open_url = .{ .url = p.dupText(L, url), .token = p.gesture } });
    return 0;
}

fn validTrigger(s: []const u8) bool {
    return s.len == 1 and std.mem.indexOfScalar(u8, ";!$%&+=?^", s[0]) != null;
}

/// larper.completions(";", { {name=, text=, hint=}, … }): sugestões na caixa de
/// mensagem ao digitar o gatilho. É uma lista pronta: a busca roda na interface, a
/// cada tecla, sem chamar o plugin. Escolher põe `text` na caixa; nunca envia.
fn lCompletions(L: ?*lua.State) callconv(.c) c_int {
    const p = plug(L);
    need(L, p, .completions, "larper.completions");
    const trig = lua.checkSlice(L, 1);
    if (!validTrigger(trig)) raise(L, tr("larper.completions: o gatilho é um destes: ; ! $ % & + = ? ^", "larper.completions: the trigger is one of: ; ! $ % & + = ? ^"));
    lua.luaL_checktype(L, 2, lua.TTABLE);
    p.budgetCmd(L);
    const n: usize = @intCast(lua.lua_rawlen(L, 2));
    if (n > max_completions) raise(L, tr("larper.completions: no máximo 256 sugestões", "larper.completions: at most 256 suggestions"));
    // Lê tudo antes de alocar (os textos continuam vivos: estão na tabela).
    const Raw = struct { name: []const u8, text: []const u8, hint: []const u8 };
    var raw: [max_completions]Raw = undefined;
    var total: usize = 0;
    for (raw[0..n], 1..) |*r, i| {
        if (lua.lua_rawgeti(L, 2, @intCast(i)) != lua.TTABLE) raise(L, tr("larper.completions: cada sugestão é uma tabela {name=, text=}", "larper.completions: each suggestion is a table {name=, text=}"));
        const t = lua.lua_gettop(L);
        r.* = .{ .name = clip(fieldStr(L, t, "name"), 48), .text = clip(fieldStr(L, t, "text"), 2000), .hint = clip(fieldLabel(L, t, "hint"), 48) };
        if (r.name.len == 0 or r.text.len == 0) raise(L, tr("larper.completions: cada sugestão precisa de `name` e `text`", "larper.completions: each suggestion needs `name` and `text`"));
        total += r.name.len + r.text.len + r.hint.len;
        lua.pop(L, 1);
    }
    if (total > completions_bytes) raise(L, tr("larper.completions: texto demais (até 256 KB)", "larper.completions: too much text (up to 256 KB)"));
    const a = p.gpa();
    const set = a.create(wire.CompletionSet) catch return 0;
    const items = a.alloc(wire.Completion, n) catch {
        a.destroy(set);
        return 0;
    };
    for (items) |*it| it.* = .{ .name = &.{}, .text = &.{}, .hint = &.{} };
    set.* = .{ .trigger = trig[0], .items = items };
    for (raw[0..n], items) |r, *it| {
        it.name = a.dupe(u8, r.name) catch return completionsFailed(set, a);
        it.text = a.dupe(u8, r.text) catch return completionsFailed(set, a);
        it.hint = a.dupe(u8, r.hint) catch return completionsFailed(set, a);
    }
    _ = p.w.emit(p.run, .{ .completions = set });
    return 0;
}

fn completionsFailed(set: *wire.CompletionSet, a: std.mem.Allocator) c_int {
    set.free(a);
    return 0;
}

/// Uma regra de larper.rewrite, depois de lida (os textos estão na tabela).
const RawRule = struct { kind: rewrite.Kind, from: []const u8, to: []const u8 };

fn rewriteAdd(L: ?*lua.State, raw: *[rewrite.max_rules]RawRule, n: *usize, r: RawRule) void {
    if (n.* >= raw.len) raise(L, tr("larper.rewrite: no máximo 256 regras", "larper.rewrite: at most 256 rules"));
    raw[n.*] = r;
    n.* += 1;
}

/// larper.rewrite({ {strip_params={"utm_*", "fbclid"}, host="exemplo.com"},
///   {replace_host="a.com", with="b.com"}, {word="vc", with="você"} })
/// Regras fixas para o texto que a pessoa envia: o app aplica sozinho, sem o Lua ver
/// o que ela escreveu. Chamar de novo troca as regras todas.
fn lRewrite(L: ?*lua.State) callconv(.c) c_int {
    const p = plug(L);
    need(L, p, .rewrite, "larper.rewrite");
    lua.luaL_checktype(L, 1, lua.TTABLE);
    p.budgetCmd(L);
    var raw: [rewrite.max_rules]RawRule = undefined;
    var count: usize = 0;
    const total: usize = @intCast(lua.lua_rawlen(L, 1));
    if (total > rewrite.max_rules) raise(L, tr("larper.rewrite: no máximo 256 regras", "larper.rewrite: at most 256 rules"));
    for (0..total) |i| {
        if (lua.lua_rawgeti(L, 1, @intCast(i + 1)) != lua.TTABLE) raise(L, tr("larper.rewrite: cada regra é uma tabela", "larper.rewrite: each rule is a table"));
        const t = lua.lua_gettop(L);
        const word = fieldStr(L, t, "word");
        const from_host = fieldStr(L, t, "replace_host");
        const with = fieldStr(L, t, "with");
        if (word.len > 0) {
            if (!rewrite.validWord(word)) raise(L, tr("larper.rewrite: `word` é uma palavra só, sem espaço", "larper.rewrite: `word` is a single word, no spaces"));
            if (!rewrite.validWith(with)) raise(L, tr("larper.rewrite: `with` tem de 1 a 200 bytes, sem menção nem link", "larper.rewrite: `with` is 1 to 200 bytes, with no mention or link"));
            rewriteAdd(L, &raw, &count, .{ .kind = .word, .from = word, .to = with });
        } else if (from_host.len > 0) {
            if (!manifest.validHost(from_host) or !manifest.validHost(with)) raise(L, tr("larper.rewrite: `replace_host` e `with` são só o nome (a.com), sem https:// nem caminho", "larper.rewrite: `replace_host` and `with` are just the name (a.com), no https:// or path"));
            rewriteAdd(L, &raw, &count, .{ .kind = .replace_host, .from = from_host, .to = with });
        } else {
            _ = lua.lua_pushstring(L, "strip_params");
            if (lua.lua_rawget(L, t) != lua.TTABLE) raise(L, tr("larper.rewrite: a regra precisa de `strip_params`, `replace_host` ou `word`", "larper.rewrite: a rule needs `strip_params`, `replace_host` or `word`"));
            const list = lua.lua_gettop(L);
            const host = fieldStr(L, t, "host");
            if (host.len > 0 and !manifest.validHost(host)) raise(L, tr("larper.rewrite: `host` é só o nome (a.com)", "larper.rewrite: `host` is just the name (a.com)"));
            const m: usize = @intCast(lua.lua_rawlen(L, list));
            for (0..m) |k| {
                const tp = lua.lua_rawgeti(L, list, @intCast(k + 1));
                const name = (if (tp == lua.TSTRING) lua.toSlice(L, -1) else null) orelse "";
                if (!rewrite.validParam(name)) raise(L, tr("larper.rewrite: nome de parâmetro inválido", "larper.rewrite: invalid parameter name"));
                rewriteAdd(L, &raw, &count, .{ .kind = .strip_param, .from = name, .to = host });
                lua.pop(L, 1);
            }
            lua.pop(L, 1);
        }
        lua.pop(L, 1);
    }
    const a = p.gpa();
    const list = a.alloc(rewrite.Rule, count) catch return 0;
    var built: usize = 0;
    for (raw[0..count]) |r| {
        list[built] = rewrite.dupRule(a, r.kind, r.from, r.to) orelse break;
        built += 1;
    }
    _ = p.w.emit(p.run, .{ .rewrite = a.realloc(list, built) catch list[0..built] });
    return 0;
}

// --- HTTP --------------------------------------------------------------------------

fn httpDone(ctx: *anyopaque, res: *wire.HttpRes) void {
    const w: *Worker = @ptrCast(@alignCast(ctx));
    w.push(.{ .http = res });
}

/// Resposta que nem chegou a sair: entra na fila, como uma de verdade (e no registro
/// de rede, com o motivo).
fn httpRefuse(L: ?*lua.State, p: *Rt, id: u32, err: wire.HttpError, log: wire.NetEntry) void {
    const res = p.gpa().create(wire.HttpRes) catch raise(L, tr("sem memória", "out of memory"));
    res.* = .{ .run = p.run, .id = id, .err = err, .refused = true, .token = if (p.gesture != 0) p.gesture else p.carry, .log = log };
    p.w.push(.{ .http = res });
}

/// Confere os cabeçalhos pedidos antes de qualquer coisa sair (sem alocar: um erro
/// aqui não deixa nada para trás). Credencial para um host fora de `@credentials` é
/// erro; o que não está na lista é ignorado, como sempre foi.
fn checkHeaders(L: ?*lua.State, p: *Rt, opts: c_int, host: []const u8, api: []const u8) bool {
    if (opts == 0) return false;
    _ = lua.lua_pushstring(L, "headers");
    defer lua.pop(L, 1);
    if (lua.lua_rawget(L, opts) != lua.TTABLE) return false;
    const t = lua.lua_gettop(L);
    var creds = false;
    lua.lua_pushnil(L);
    while (lua.lua_next(L, t) != 0) {
        defer lua.pop(L, 1);
        if (lua.lua_type(L, -2) != lua.TSTRING) continue;
        const k = lua.toSlice(L, -2).?;
        if (http_policy.requestHeader(k) != .credential) continue;
        if (!p.m.sendsCredentials(host)) raiseFmt(L, "{s}: {s} só vai para os hosts de @credentials no cabeçalho (\"{s}\" não está lá)", "{s}: {s} only goes to the hosts in @credentials in the manifest (\"{s}\" isn't there)", .{ api, k, host });
        creds = true;
    }
    return creds;
}

/// Os cabeçalhos pedidos, só os da lista: nada de Cookie, Host ou os do Discord.
/// Authorization e X-API-Key só com `with_creds` (host de @credentials aprovado). O
/// app também não acrescenta nenhum desses.
fn httpHeaders(L: ?*lua.State, p: *Rt, opts: c_int, with_creds: bool) [][:0]u8 {
    const a = p.gpa();
    if (opts == 0) return &.{};
    _ = lua.lua_pushstring(L, "headers");
    if (lua.lua_rawget(L, opts) != lua.TTABLE) {
        lua.pop(L, 1);
        return &.{};
    }
    const t = lua.lua_gettop(L);
    var list: std.ArrayList([:0]u8) = .empty;
    lua.lua_pushnil(L);
    while (list.items.len < http_max_headers and lua.lua_next(L, t) != 0) {
        defer lua.pop(L, 1);
        if (lua.lua_type(L, -2) != lua.TSTRING or lua.lua_type(L, -1) != lua.TSTRING) continue;
        const k = lua.toSlice(L, -2).?;
        const v = lua.toSlice(L, -1).?;
        const kind = http_policy.requestHeader(k);
        if (kind == .refused or (kind == .credential and !with_creds)) continue;
        const max: usize = if (kind == .credential) http_credential_value else http_header_value;
        if (std.mem.indexOfAny(u8, v, "\r\n\x00") != null or v.len > max) continue;
        const line = std.fmt.allocPrintSentinel(a, "{s}: {s}", .{ k, v }, 0) catch continue;
        list.append(a, line) catch a.free(line);
    }
    lua.lua_settop(L, t - 1);
    return list.toOwnedSlice(a) catch &.{};
}

/// Os itens aprovados (todos, ou só os que levam credenciais), copiados para o pedido:
/// a thread do pedido confere os redirecionamentos com eles.
fn approvedCopy(p: *Rt, only_creds: bool) [][]u8 {
    const a = p.gpa();
    var out: std.ArrayList([]u8) = .empty;
    for (p.approved) |h| {
        if (only_creds and !p.m.credentialPattern(h)) continue;
        const own = a.dupe(u8, h) catch continue;
        out.append(a, own) catch a.free(own);
    }
    return out.toOwnedSlice(a) catch &.{};
}

const http_apis = [_][]const u8{ "larper.http.get", "larper.http.post", "larper.http.put", "larper.http.patch", "larper.http.delete", "larper.http.head" };

/// larper.http.<método>(url, [opções], fn) e larper.http.request(url, {method=…}, fn).
fn httpCall(L: ?*lua.State, fixed: ?wire.Method) c_int {
    const p = plug(L);
    const api = if (fixed) |m| http_apis[@backingInt(m)] else "larper.http.request";
    need(L, p, .http, api);
    const url = lua.checkSlice(L, 1);
    const opts: c_int = if (lua.lua_type(L, 2) == lua.TTABLE) 2 else 0;
    const cb: c_int = if (opts != 0) 3 else 2;
    lua.luaL_checktype(L, cb, lua.TFUNCTION);
    const method = fixed orelse blk: {
        if (opts == 0) raise(L, tr("larper.http.request: as opções precisam de `method`", "larper.http.request: the options need a `method`"));
        var mb: [8]u8 = undefined;
        const raw = fieldStr(L, opts, "method");
        if (raw.len == 0 or raw.len > mb.len) raise(L, tr("larper.http.request: `method` é GET, POST, PUT, PATCH, DELETE ou HEAD", "larper.http.request: `method` is GET, POST, PUT, PATCH, DELETE or HEAD"));
        break :blk std.meta.stringToEnum(wire.Method, std.ascii.upperString(&mb, raw)) orelse
            raise(L, tr("larper.http.request: `method` é GET, POST, PUT, PATCH, DELETE ou HEAD", "larper.http.request: `method` is GET, POST, PUT, PATCH, DELETE or HEAD"));
    };
    const parsed = manifest.parseHttps(url) orelse
        raiseFmt(L, "{s}: a URL precisa ser https://nome/caminho, sem porta nem usuário e com o texto codificado (larper.urlencode)", "{s}: the URL must be https://name/path, with no port or user and with the text encoded (larper.urlencode)", .{api});
    if (!p.m.declares(parsed.host)) raiseFmt(L, "{s}: \"{s}\" não está em @hosts no cabeçalho", "{s}: \"{s}\" isn't in @hosts in the manifest", .{ api, parsed.host });
    var body: []const u8 = "";
    if (opts != 0) body = fieldText(L, opts, "body");
    if (body.len > http_body_max) raiseFmt(L, "{s}: o corpo tem no máximo 64 KB", "{s}: the body is at most 64 KB", .{api});
    if (body.len > 0 and !method.hasBody()) raiseFmt(L, "{s}: {t} não leva corpo", "{s}: {t} doesn't take a body", .{ api, method });
    const wants_creds = checkHeaders(L, p, opts, parsed.host, api);
    p.budgetCmd(L);

    const id = p.next_id;
    p.next_id +%= 1;
    registryList(L, "http");
    lua.lua_pushvalue(L, cb);
    lua.lua_rawseti(L, -2, id);
    lua.pop(L, 2);

    var log: wire.NetEntry = .{ .method = method, .time = @divTrunc(sync.nowMs(), 1000) };
    log.setUrl(url);
    // Credencial sem a aprovação do host que leva credenciais: não sai nada.
    if (!p.hostApproved(parsed.host) or (wants_creds and !p.credsApproved(parsed.host))) {
        httpRefuse(L, p, id, .not_approved, log);
        return 0;
    }
    const now = sync.nowMs();
    if (now - p.http_from >= 60_000) {
        p.http_from = now;
        p.http_n = 0;
    }
    if (p.http_n >= http_per_minute or p.http_flying >= http_in_flight) {
        httpRefuse(L, p, id, .rate_limited, log);
        return 0;
    }
    p.http_n += 1;

    const a = p.gpa();
    const url_own = a.dupeSentinel(u8, url, 0) catch raise(L, tr("sem memória", "out of memory"));
    const body_own = a.dupe(u8, body) catch {
        a.free(url_own);
        raise(L, tr("sem memória", "out of memory"));
    };
    const req = a.create(wire.HttpReq) catch {
        a.free(url_own);
        a.free(body_own);
        raise(L, tr("sem memória", "out of memory"));
    };
    req.* = .{
        .gpa = a,
        .run = p.run,
        .id = id,
        .method = method,
        .token = if (p.gesture != 0) p.gesture else p.carry,
        .url = url_own,
        .body = body_own,
        .headers = &.{},
        .done_ctx = p.w,
        .done = &httpDone,
        .log = log,
    };
    // Daqui para baixo, sem erro de Lua com o pedido na mão.
    req.headers = httpHeaders(L, p, opts, wants_creds);
    req.allow = approvedCopy(p, false);
    req.creds = approvedCopy(p, true);
    if (p.w.host.http_start(req)) {
        p.http_flying += 1;
    } else {
        req.free();
        httpRefuse(L, p, id, .network, log);
    }
    return 0;
}

/// larper.http.get(url, [opções], fn(resposta))
fn lHttpGet(L: ?*lua.State) callconv(.c) c_int {
    return httpCall(L, .GET);
}

/// larper.http.post(url, {body=, headers=}, fn(resposta))
fn lHttpPost(L: ?*lua.State) callconv(.c) c_int {
    return httpCall(L, .POST);
}

fn lHttpPut(L: ?*lua.State) callconv(.c) c_int {
    return httpCall(L, .PUT);
}

fn lHttpPatch(L: ?*lua.State) callconv(.c) c_int {
    return httpCall(L, .PATCH);
}

fn lHttpDelete(L: ?*lua.State) callconv(.c) c_int {
    return httpCall(L, .DELETE);
}

/// larper.http.head(url, [opções], fn(resposta)): só o status e os cabeçalhos.
fn lHttpHead(L: ?*lua.State) callconv(.c) c_int {
    return httpCall(L, .HEAD);
}

/// larper.http.request(url, {method="PUT", body=, headers=}, fn(resposta))
fn lHttpRequest(L: ?*lua.State) callconv(.c) c_int {
    return httpCall(L, null);
}

/// larper.http.allowed("host" ou "*.exemplo.com") -> a pessoa já aprovou?
fn lHttpAllowed(L: ?*lua.State) callconv(.c) c_int {
    const p = plug(L);
    need(L, p, .http, "larper.http.allowed");
    const host = lua.checkSlice(L, 1);
    const ok = if (http_policy.isWildcard(host)) p.m.declaresPattern(host) and p.patternApproved(host) else p.m.declares(host) and p.hostApproved(host);
    lua.lua_pushboolean(L, @intFromBool(ok));
    return 1;
}

// --- Segredos ----------------------------------------------------------------------

/// Letras, números, ".", "_" e "-": o que pode ir para o chaveiro sem escapar nada
/// (no Linux o nome vai na linha de comando do secret-tool).
pub fn safeName(s: []const u8, max: usize) bool {
    if (s.len == 0 or s.len > max) return false;
    for (s) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '.' and ch != '_' and ch != '-') return false;
    return true;
}

fn secretKey(L: ?*lua.State, p: *Rt) []const u8 {
    need(L, p, .secrets, "larper.secrets");
    if (!safeName(p.name, 120)) raise(L, tr("larper.secrets: o nome do arquivo do plugin só pode ter letras, números, ., _ e -", "larper.secrets: the plugin's file name can only have letters, digits, ., _ and -"));
    const key = lua.checkSlice(L, 1);
    if (!safeName(key, secret_key_max)) raise(L, tr("larper.secrets: a chave tem de 1 a 64 letras, números, ., _ ou -", "larper.secrets: the key is 1 to 64 letters, digits, ., _ or -"));
    return key;
}

/// larper.secrets.get(chave) -> texto, ou nil. Lê o chaveiro do sistema a cada vez:
/// guarde numa variável. Cada plugin só vê os dele.
fn lSecretGet(L: ?*lua.State) callconv(.c) c_int {
    const p = plug(L);
    const key = secretKey(L, p);
    const value = p.w.host.secret_get(p.w.host.ctx, p.gpa(), p.name, key) orelse {
        lua.lua_pushnil(L);
        return 1;
    };
    defer {
        std.crypto.secureZero(u8, value);
        p.gpa().free(value);
    }
    lua.pushSlice(L, value);
    return 1;
}

/// larper.secrets.set(chave, texto): nil apaga. Erro se o chaveiro recusar.
fn lSecretSet(L: ?*lua.State) callconv(.c) c_int {
    const p = plug(L);
    const key = secretKey(L, p);
    if (lua.lua_type(L, 2) == lua.TNIL) {
        p.w.host.secret_delete(p.w.host.ctx, p.name, key);
        return 0;
    }
    const value = lua.checkSlice(L, 2);
    if (value.len == 0 or value.len > secret_value_max or std.mem.indexOfScalar(u8, value, 0) != null) raise(L, tr("larper.secrets: o valor tem de 1 a 2048 bytes, sem byte nulo", "larper.secrets: the value is 1 to 2048 bytes, with no null byte"));
    if (!p.w.host.secret_set(p.w.host.ctx, p.name, key, value)) raise(L, tr("larper.secrets: o chaveiro do sistema recusou", "larper.secrets: the system keyring refused"));
    return 0;
}

/// larper.secrets.delete(chave)
fn lSecretDelete(L: ?*lua.State) callconv(.c) c_int {
    const p = plug(L);
    const key = secretKey(L, p);
    p.w.host.secret_delete(p.w.host.ctx, p.name, key);
    return 0;
}
