//! Conjuntos de abas, do lado do app (core/conjuntos.zig): salvar as abas com um
//! nome, trocar de conjunto, sair dele, e guardar sozinho o que muda nas abas
//! enquanto um está em uso.
//!
//! Trocar de conjunto não sai buscando o histórico de cada aba: só o canal que
//! aparece carrega, como num clique na aba (com a tela dividida, os painéis que
//! aparecem). As outras carregam quando forem abertas. Um conjunto de 10 abas não
//! vira 10 pedidos ao Discord de uma vez.
const std = @import("std");
const App = @import("app.zig").App;
const cj = @import("core/conjuntos.zig");
const ui = @import("ui/conjuntos.zig");
const mosaic = @import("ui/mosaic.zig");
const anim = @import("ui/anim.zig");
const accounts_store = @import("net/accounts_store.zig");
const types = @import("core/types.zig");
const nowMs = @import("net/fake_gateway.zig").nowMs;
const Id = types.Id;

comptime {
    std.debug.assert(mosaic.max == cj.max_panes);
}

fn split() cj.Split {
    const p = mosaic.panes;
    return .{ .ids = p.ids, .count = p.count, .focus = p.focus };
}

/// Gravar o arquivo espera um pouco depois da primeira mudança nas abas: passar
/// por vários canais em seguida (J/K do vim, cliques na lista) grava uma vez só.
const save_delay_ms: i64 = 1200;
var save_at_ms: ?i64 = null;

/// Os prints da documentação não gravam nada.
fn persist(app: *App) void {
    save_at_ms = null;
    if (app.opts.shot != null) {
        app.st.conjuntos.dirty = false;
        return;
    }
    ui.persist(&app.st.conjuntos, app.gpa);
}

/// Dá para abrir numa aba: o canal existe, é de texto (ou fórum) e temos acesso.
fn usable(app: *App, id: Id) bool {
    const cs = app.store.channel(id) orelse return false;
    if (cs.info.kind != .text and cs.info.kind != .forum) return false;
    return app.store.canAccess(&cs.info);
}

/// O nome para os avisos (cortado: o aviso tem 160 bytes).
fn short(name: []const u8) []const u8 {
    return @import("ui/draw.zig").utf8Prefix(name, 32);
}

pub fn handle(app: *App, a: cj.Action) void {
    const st = &app.st;
    const list = &st.conjuntos;
    switch (a) {
        .save => |raw| {
            defer st.gpa.free(raw);
            // A janela do nome já não deixa salvar com nome repetido, acima do limite
            // ou sem aba nenhuma (e diz por quê).
            const name = cj.cleanName(raw);
            if (list.owner == 0 or list.check(name, null) != .ok or st.tabs.items.len == 0) return;
            // Das abas soltas para um conjunto: "Sair do conjunto" volta para elas como estão agora.
            if (list.active == null) list.loose.set(app.gpa, st.tabs.items, st.tab, split()) catch return;
            const i = list.add(app.gpa, name, st.tabs.items, st.tab, split()) catch return;
            list.active = i;
            persist(app);
            st.showToast(nowMs(), false, "conjunto «{s}» salvo", "tab set “{s}” saved", .{short(name)});
        },
        .open => |i| open(app, i),
        .next => {
            const n = list.sets.items.len;
            if (n == 0) return st.showToast(nowMs(), true, "nenhum conjunto de abas salvo", "no tab sets saved", .{});
            const i = if (list.active) |k| (k + 1) % n else 0;
            if (list.active == i) return st.showToast(nowMs(), false, "só tem o conjunto «{s}»", "“{s}” is the only tab set", .{short(list.sets.items[i].name)});
            open(app, i);
        },
        .rename => |rn| {
            defer st.gpa.free(rn.name);
            list.rename(app.gpa, rn.index, rn.name) catch return;
            persist(app);
            st.showToast(nowMs(), false, "conjunto renomeado para «{s}»", "tab set renamed to “{s}”", .{short(list.sets.items[rn.index].name)});
        },
        .delete => |i| {
            if (i >= list.sets.items.len) return;
            var nb: [cj.max_name]u8 = undefined;
            const name = copyName(&nb, list.sets.items[i].name);
            // As abas abertas ficam, soltas.
            list.remove(app.gpa, i);
            persist(app);
            st.showToast(nowMs(), false, "conjunto «{s}» excluído", "tab set “{s}” deleted", .{short(name)});
        },
        .leave => leave(app),
    }
}

fn copyName(buf: []u8, name: []const u8) []const u8 {
    const n = @min(buf.len, name.len);
    @memcpy(buf[0..n], name[0..n]);
    return buf[0..n];
}

/// Mostra `abas` no lugar das abas abertas, pulando o canal que sumiu ou que
/// perdemos acesso. Só a aba ativa abre de verdade (e pede o histórico, se ainda
/// não veio). Devolve quantos canais ficaram de fora, ou null se nenhum sobrou
/// (nada muda).
fn show(app: *App, abas: *const cj.Abas) ?usize {
    const st = &app.st;
    var kept: [cj.max_tabs]Id = undefined;
    var n: usize = 0;
    var tab: ?usize = null;
    for (abas.ids.items, 0..) |id, k| {
        if (n == kept.len or !usable(app, id)) continue;
        // A ativa sumiu: fica a que estava antes dela.
        if (k <= abas.tab) tab = n;
        kept[n] = id;
        n += 1;
    }
    if (n == 0) return null;
    st.tabs.clearRetainingCapacity();
    st.tabs.appendSlice(app.gpa, kept[0..n]) catch return null;
    st.tab = tab orelse 0;
    // A tela dividida, com os painéis que ainda valem (com menos de 2, nenhuma).
    var sp: mosaic.Panes = .{};
    const want = abas.split.norm();
    for (want.ids[0..want.count], 0..) |id, k| {
        if (!usable(app, id)) continue;
        if (k == want.focus) sp.focus = sp.count;
        sp.ids[sp.count] = id;
        sp.count += 1;
    }
    mosaic.panes = if (sp.count >= 2) sp else .{};
    // Como o clique na aba: a lista de membros, o rascunho e o histórico dela.
    app.openChannel(st.tabs.items[st.tab], false);
    return abas.ids.items.len - n;
}

/// Os canais que ficaram de fora (o aviso curto que a pessoa pediu).
fn tellSkipped(app: *App, name: []const u8, skipped: usize) void {
    if (skipped == 0) return;
    if (skipped == 1)
        app.st.showToast(nowMs(), true, "«{s}»: um canal não está mais disponível e ficou de fora", "“{s}”: one channel is no longer available and was left out", .{short(name)})
    else
        app.st.showToast(nowMs(), true, "«{s}»: {d} canais não estão mais disponíveis e ficaram de fora", "“{s}”: {d} channels are no longer available and were left out", .{ short(name), skipped });
}

/// Troca para o conjunto `i`. O que estava aberto fica guardado antes: no
/// conjunto de agora, ou nas abas soltas para quando sair.
pub fn open(app: *App, i: usize) void {
    const st = &app.st;
    const list = &st.conjuntos;
    if (i >= list.sets.items.len) return;
    if (list.active == i) return st.showToast(nowMs(), false, "o conjunto «{s}» já está em uso", "tab set “{s}” is already in use", .{short(list.sets.items[i].name)});
    sync(app);
    var loose: cj.Abas = .{};
    defer loose.deinit(app.gpa);
    if (list.active == null) loose.set(app.gpa, st.tabs.items, st.tab, split()) catch return;
    const set = &list.sets.items[i];
    const skipped = show(app, &set.abas) orelse {
        return st.showToast(nowMs(), true, "nenhum canal de «{s}» está disponível", "no channel from “{s}” is available", .{short(set.name)});
    };
    if (list.active == null) std.mem.swap(cj.Abas, &list.loose, &loose);
    list.active = i;
    // O que ficou de fora sai do conjunto (as abas dele são as abertas agora).
    sync(app);
    persist(app);
    if (skipped > 0) tellSkipped(app, set.name, skipped) else st.showToast(nowMs(), false, "conjunto: {s}", "tab set: {s}", .{short(set.name)});
}

/// "Sair do conjunto": guarda o que está aberto nele e volta para as abas soltas
/// de quando entrou (o canal que sumiu delas fica de fora sem aviso). Sem elas
/// (nenhuma sobrou), as abas abertas ficam, soltas.
fn leave(app: *App) void {
    const st = &app.st;
    const list = &st.conjuntos;
    const set = list.activeSet() orelse return;
    sync(app);
    var nb: [cj.max_name]u8 = undefined;
    const name = copyName(&nb, set.name);
    list.active = null;
    if (list.loose.ids.items.len > 0) _ = show(app, &list.loose);
    list.loose.clear();
    persist(app);
    st.showToast(nowMs(), false, "saiu do conjunto «{s}»", "left tab set “{s}”", .{short(name)});
}

/// A cada quadro: com um conjunto em uso, o que mudou nas abas (abriu, fechou,
/// trocou a ativa, a tela dividida) vai para ele, e para o arquivo um pouco depois
/// (um quadro marcado para a hora, e não um a cada quadro).
pub fn sync(app: *App) void {
    const st = &app.st;
    const list = &st.conjuntos;
    // Sem aba nenhuma (todos os canais sumiram): nada a guardar.
    if (list.activeSet()) |set| if (st.tabs.items.len > 0) {
        const sp = split();
        if (!set.abas.same(st.tabs.items, st.tab, sp)) {
            set.abas.set(app.gpa, st.tabs.items, st.tab, sp) catch return;
            list.dirty = true;
        }
    };
    if (!list.dirty) return;
    const now = nowMs();
    const due = save_at_ms orelse now + save_delay_ms;
    save_at_ms = due;
    if (now >= due) persist(app) else anim.at(due);
}

/// Grava o que estava esperando, ao fechar o app ou trocar de conta.
pub fn flush(app: *App) void {
    sync(app);
    if (app.st.conjuntos.dirty) persist(app);
}

/// Antes de esvaziar a sessão (outra conta, sair): grava e esquece a lista.
pub fn reset(app: *App) void {
    flush(app);
    save_at_ms = null;
    app.st.conjuntos.clear(app.gpa);
    app.st.conjuntos.owner = 0;
}

/// A conta entrou (READY): os conjuntos dela e, se um estava em uso quando o app
/// fechou, ele de volta (só a aba ativa carrega). true: abriu um conjunto.
pub fn ready(app: *App) bool {
    const st = &app.st;
    const list = &st.conjuntos;
    const owner = if (accounts_store.session != 0) accounts_store.session else app.store.me;
    const read = app.opts.shot == null and (!app.opts.qa or ui.qa_read);
    ui.load(list, app.gpa, owner, read);
    const i = list.active orelse return false;
    const set = &list.sets.items[i];
    // Até mostrar, nenhum em uso: as abas da abertura não vão para ele.
    list.active = null;
    const skipped = show(app, &set.abas) orelse {
        // Nada dele sobrou: abre como sempre, e as abas soltas guardadas não valem mais.
        list.loose.clear();
        persist(app);
        return false;
    };
    list.active = i;
    sync(app);
    if (skipped > 0) {
        persist(app);
        tellSkipped(app, set.name, skipped);
    }
    return true;
}
