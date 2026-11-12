//! Conjuntos de abas: grupos de abas com nome ("trabalho", "jogo") para trocar
//! todas de uma vez, como áreas de trabalho. Com um conjunto em uso, as abas que
//! se abrem, fecham e trocam são dele e ficam salvas nele; sem nenhum, as abas são
//! soltas, como sempre foram. Ficam só neste computador (nada vai para o Discord),
//! num JSON por conta: quem lê e grava o arquivo é ui/conjuntos.zig, quem troca as
//! abas é app_conjuntos.zig.
const std = @import("std");
const Id = @import("types.zig").Id;
const j = @import("../net/jsonx.zig");

/// O menu da barra de abas lista todos, e um arquivo editado à mão não vira
/// centenas de abas.
pub const max_sets = 10;
pub const max_tabs = 30;
/// Bytes do nome (UTF-8; corta sem partir um caractere).
pub const max_name = 48;
/// Painéis da tela dividida (o `max` de ui/mosaic.zig).
pub const max_panes = 3;

/// A tela dividida guardada: os canais lado a lado e o focado.
pub const Split = struct {
    ids: [max_panes]Id = @splat(0),
    /// Menos de 2 = sem tela dividida.
    count: u8 = 0,
    focus: u8 = 0,

    /// Sem tela dividida, tudo zerado: duas "nenhuma" são sempre iguais.
    pub fn norm(s: Split) Split {
        if (s.count < 2) return .{};
        const n = @min(s.count, max_panes);
        var out: Split = .{ .count = n, .focus = @min(s.focus, n - 1) };
        @memcpy(out.ids[0..n], s.ids[0..n]);
        return out;
    }

    pub fn eql(a: Split, b: Split) bool {
        return std.meta.eql(a.norm(), b.norm());
    }
};

/// Abas abertas: os canais, a ativa e a tela dividida.
pub const Abas = struct {
    ids: std.ArrayList(Id) = .empty,
    tab: usize = 0,
    split: Split = .{},

    pub fn deinit(a: *Abas, gpa: std.mem.Allocator) void {
        a.ids.deinit(gpa);
    }

    pub fn clear(a: *Abas) void {
        a.ids.clearRetainingCapacity();
        a.tab = 0;
        a.split = .{};
    }

    /// Guardar `ids`, `tab` e `split` daria exatamente isto (até `max_tabs` abas).
    pub fn same(a: *const Abas, ids: []const Id, tab: usize, split: Split) bool {
        const n = @min(ids.len, max_tabs);
        return std.mem.eql(Id, a.ids.items, ids[0..n]) and a.tab == clampTab(tab, n) and a.split.eql(split);
    }

    pub fn set(a: *Abas, gpa: std.mem.Allocator, ids: []const Id, tab: usize, split: Split) !void {
        const n = @min(ids.len, max_tabs);
        a.ids.clearRetainingCapacity();
        try a.ids.appendSlice(gpa, ids[0..n]);
        a.tab = clampTab(tab, n);
        a.split = split.norm();
    }
};

fn clampTab(tab: usize, n: usize) usize {
    return if (n == 0) 0 else @min(tab, n - 1);
}

pub const Set = struct {
    /// Alocado com o gpa da lista.
    name: []u8,
    abas: Abas = .{},

    fn deinit(s: *Set, gpa: std.mem.Allocator) void {
        gpa.free(s.name);
        s.abas.deinit(gpa);
    }
};

/// O nome como fica guardado: sem espaço nas pontas, até `max_name` bytes.
pub fn cleanName(raw: []const u8) []const u8 {
    const t = std.mem.trim(u8, raw, " \t\r\n");
    if (t.len <= max_name) return t;
    var end: usize = max_name;
    while (end > 0 and (t[end] & 0xC0) == 0x80) end -= 1;
    return std.mem.trimEnd(u8, t[0..end], " ");
}

/// O que impede salvar (ou renomear) com esse nome.
pub const Check = enum { ok, empty, exists, full };

/// O que a interface pede (ui/conjuntos.zig) e o app faz (app_conjuntos.zig).
pub const Action = union(enum) {
    /// "Salvar abas como conjunto…": as abas abertas viram um conjunto novo, que
    /// passa a ser o em uso. Nome alocado com o gpa da interface.
    save: []const u8,
    /// Troca para o conjunto `i` (índice em `List.sets`).
    open: usize,
    /// O seguinte da lista (o atalho), ou o primeiro sem nenhum em uso.
    next,
    rename: struct { index: usize, name: []const u8 },
    delete: usize,
    /// "Sair do conjunto": volta para as abas soltas de quando entrou nele.
    leave,
};

pub const List = struct {
    sets: std.ArrayList(Set) = .empty,
    /// O conjunto em uso (índice em `sets`); null = abas soltas.
    active: ?usize = null,
    /// As abas soltas de quando entrou num conjunto: "Sair do conjunto" volta
    /// para elas. Vazio sem conjunto em uso.
    loose: Abas = .{},
    /// Conta dona da lista (cada conta tem o seu arquivo); 0 = nenhuma.
    owner: Id = 0,
    /// Mudou algo que ainda não foi para o arquivo (app_conjuntos.zig grava logo depois).
    dirty: bool = false,

    pub fn deinit(l: *List, gpa: std.mem.Allocator) void {
        l.clear(gpa);
        l.sets.deinit(gpa);
        l.loose.deinit(gpa);
    }

    pub fn clear(l: *List, gpa: std.mem.Allocator) void {
        for (l.sets.items) |*s| s.deinit(gpa);
        l.sets.clearRetainingCapacity();
        l.loose.clear();
        l.active = null;
        l.dirty = false;
    }

    pub fn activeSet(l: *List) ?*Set {
        const i = l.active orelse return null;
        return if (i < l.sets.items.len) &l.sets.items[i] else null;
    }

    /// Nomes não diferenciam maiúsculas ("Jogo" e "jogo" são o mesmo).
    pub fn find(l: *const List, name: []const u8) ?usize {
        for (l.sets.items, 0..) |s, i| if (std.ascii.eqlIgnoreCase(s.name, name)) return i;
        return null;
    }

    /// Dá para salvar um conjunto novo com esse nome (`renaming` null) ou dar esse
    /// nome ao conjunto `renaming`? Já limpo por `cleanName`.
    pub fn check(l: *const List, name: []const u8, renaming: ?usize) Check {
        if (name.len == 0) return .empty;
        if (l.find(name)) |i| if (renaming == null or i != renaming.?) return .exists;
        if (renaming == null and l.sets.items.len >= max_sets) return .full;
        return .ok;
    }

    /// Um conjunto novo no fim da lista, com as abas dadas. Devolve o índice.
    pub fn add(l: *List, gpa: std.mem.Allocator, raw_name: []const u8, ids: []const Id, tab: usize, split: Split) !usize {
        const name = cleanName(raw_name);
        if (l.check(name, null) != .ok or ids.len == 0) return error.Refused;
        var s: Set = .{ .name = try gpa.dupe(u8, name) };
        errdefer s.deinit(gpa);
        try s.abas.set(gpa, ids, tab, split);
        try l.sets.append(gpa, s);
        return l.sets.items.len - 1;
    }

    pub fn rename(l: *List, gpa: std.mem.Allocator, i: usize, raw_name: []const u8) !void {
        const name = cleanName(raw_name);
        if (i >= l.sets.items.len or l.check(name, i) != .ok) return error.Refused;
        const owned = try gpa.dupe(u8, name);
        gpa.free(l.sets.items[i].name);
        l.sets.items[i].name = owned;
    }

    /// Tira o conjunto `i`. Era o em uso: as abas ficam soltas.
    pub fn remove(l: *List, gpa: std.mem.Allocator, i: usize) void {
        if (i >= l.sets.items.len) return;
        var s = l.sets.orderedRemove(i);
        s.deinit(gpa);
        if (l.active) |a| {
            if (a == i) {
                l.active = null;
                l.loose.clear();
            } else if (a > i) l.active = a - 1;
        }
    }

    /// `{"version":1,"active":"nome","sets":[…],"loose":{…}}`, com os IDs como
    /// texto (como o Discord). Só o que vale: sem tela dividida, sem "split".
    pub fn write(l: *const List, gpa: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        try out.appendSlice(gpa, "{\"version\":1");
        if (l.active) |a| if (a < l.sets.items.len) {
            try out.appendSlice(gpa, ",\"active\":");
            try j.writeString(out, gpa, l.sets.items[a].name);
        };
        try out.appendSlice(gpa, ",\"sets\":[");
        for (l.sets.items, 0..) |s, i| {
            if (i > 0) try out.append(gpa, ',');
            try out.appendSlice(gpa, "\n{\"name\":");
            try j.writeString(out, gpa, s.name);
            try out.append(gpa, ',');
            try writeAbas(&s.abas, gpa, out);
            try out.append(gpa, '}');
        }
        try out.appendSlice(gpa, "\n]");
        if (l.active != null and l.loose.ids.items.len > 0) {
            try out.appendSlice(gpa, ",\n\"loose\":{");
            try writeAbas(&l.loose, gpa, out);
            try out.append(gpa, '}');
        }
        try out.appendSlice(gpa, "}\n");
    }

    /// Lê o arquivo (substitui a lista). JSON quebrado ou sem objeto no topo é
    /// erro (quem chama guarda a cópia); o resto que não vale é pulado: conjunto
    /// sem nome, com nome repetido ou sem nenhuma aba, ID que não é número, aba
    /// repetida, o que passa dos limites.
    pub fn read(l: *List, gpa: std.mem.Allocator, text: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const root = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), text, .{});
        if (root != .object) return error.InvalidFormat;
        l.clear(gpa);
        for (j.array(j.get(root, "sets"))) |v| {
            if (l.sets.items.len >= max_sets) break;
            const name = cleanName(j.str(j.get(v, "name")) orelse continue);
            if (l.check(name, null) != .ok) continue;
            var abas: Abas = .{};
            defer abas.deinit(gpa);
            try readAbas(&abas, gpa, v);
            if (abas.ids.items.len == 0) continue;
            _ = try l.add(gpa, name, abas.ids.items, abas.tab, abas.split);
        }
        if (j.str(j.get(root, "active"))) |name| l.active = l.find(cleanName(name));
        if (l.active != null) if (j.get(root, "loose")) |lv| try readAbas(&l.loose, gpa, lv);
        l.dirty = false;
    }
};

fn writeAbas(a: *const Abas, gpa: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
    try out.print(gpa, "\"tab\":{d},\"tabs\":[", .{a.tab});
    for (a.ids.items, 0..) |id, k| try out.print(gpa, "{s}\"{d}\"", .{ if (k > 0) "," else "", id });
    try out.append(gpa, ']');
    const sp = a.split.norm();
    if (sp.count >= 2) {
        try out.appendSlice(gpa, ",\"split\":{\"panes\":[");
        for (sp.ids[0..sp.count], 0..) |id, k| try out.print(gpa, "{s}\"{d}\"", .{ if (k > 0) "," else "", id });
        try out.print(gpa, "],\"focus\":{d}}}", .{sp.focus});
    }
}

/// `tabs` (sem repetidas, até `max_tabs`), `tab` (dentro delas) e `split`.
fn readAbas(a: *Abas, gpa: std.mem.Allocator, v: std.json.Value) !void {
    a.clear();
    for (j.array(j.get(v, "tabs"))) |t| {
        if (a.ids.items.len >= max_tabs) break;
        const id = j.id(t) orelse continue;
        if (id == 0 or std.mem.indexOfScalar(Id, a.ids.items, id) != null) continue;
        try a.ids.append(gpa, id);
    }
    const tab = j.int(j.get(v, "tab")) orelse 0;
    a.tab = clampTab(if (tab < 0) 0 else @intCast(tab), a.ids.items.len);
    const sv = j.get(v, "split") orelse return;
    var sp: Split = .{};
    for (j.array(j.get(sv, "panes"))) |p| {
        if (sp.count >= max_panes) break;
        const id = j.id(p) orelse continue;
        if (id == 0 or std.mem.indexOfScalar(Id, sp.ids[0..sp.count], id) != null) continue;
        sp.ids[sp.count] = id;
        sp.count += 1;
    }
    const f = j.int(j.get(sv, "focus")) orelse 0;
    sp.focus = if (f < 0) 0 else @intCast(@min(f, max_panes));
    a.split = sp.norm();
}

// --- Testes ------------------------------------------------------------------

const testing = std.testing;

test "conjuntos: salvar, achar sem maiúsculas, recusar repetido, vazio e acima do limite" {
    const gpa = testing.allocator;
    var l: List = .{};
    defer l.deinit(gpa);
    const ids = [_]Id{ 11, 12, 13 };
    try testing.expectEqual(@as(usize, 0), try l.add(gpa, "  trabalho ", &ids, 1, .{}));
    try testing.expectEqualStrings("trabalho", l.sets.items[0].name);
    try testing.expectEqual(@as(?usize, 0), l.find("TRABALHO"));
    try testing.expectEqual(Check.exists, l.check("Trabalho", null));
    // Renomear para o próprio nome (outra caixa) pode.
    try testing.expectEqual(Check.ok, l.check("Trabalho", 0));
    try testing.expectEqual(Check.empty, l.check(cleanName("   "), null));
    try testing.expectError(error.Refused, l.add(gpa, "trabalho", &ids, 0, .{}));
    try testing.expectError(error.Refused, l.add(gpa, "sem abas", &.{}, 0, .{}));
    var nb: [8]u8 = undefined;
    for (1..max_sets) |k| _ = try l.add(gpa, try std.fmt.bufPrint(&nb, "c{d}", .{k}), &ids, 0, .{});
    try testing.expectEqual(Check.full, l.check("mais um", null));
    try testing.expectError(error.Refused, l.add(gpa, "mais um", &ids, 0, .{}));
    // Cheia, renomear ainda pode.
    try l.rename(gpa, 3, "jogo");
    try testing.expectEqual(@as(?usize, 3), l.find("jogo"));
    try testing.expectError(error.Refused, l.rename(gpa, 4, "JOGO"));
}

test "conjuntos: nome comprido corta sem partir caractere; abas acima do limite ficam de fora" {
    const gpa = testing.allocator;
    var long: [80]u8 = undefined;
    for (0..40) |k| @memcpy(long[2 * k ..][0..2], "ã");
    const n = cleanName(&long);
    try testing.expect(n.len <= max_name);
    try testing.expect(std.unicode.utf8ValidateSlice(n));
    var many: [max_tabs + 5]Id = undefined;
    for (&many, 0..) |*x, k| x.* = 100 + k;
    var a: Abas = .{};
    defer a.deinit(gpa);
    try a.set(gpa, &many, max_tabs + 3, .{});
    try testing.expectEqual(@as(usize, max_tabs), a.ids.items.len);
    try testing.expectEqual(@as(usize, max_tabs - 1), a.tab);
    // Comparar com o que gerou dá igual (senão o app regravaria a cada quadro).
    try testing.expect(a.same(&many, max_tabs + 3, .{}));
    try testing.expect(!a.same(many[0..3], 0, .{}));
}

test "conjuntos: excluir ajusta o em uso; excluir o em uso deixa as abas soltas" {
    const gpa = testing.allocator;
    var l: List = .{};
    defer l.deinit(gpa);
    const ids = [_]Id{ 1, 2 };
    _ = try l.add(gpa, "a", &ids, 0, .{});
    _ = try l.add(gpa, "b", &ids, 0, .{});
    _ = try l.add(gpa, "c", &ids, 0, .{});
    l.active = 2;
    try l.loose.set(gpa, &ids, 1, .{});
    l.remove(gpa, 0);
    try testing.expectEqual(@as(?usize, 1), l.active);
    try testing.expectEqualStrings("c", l.activeSet().?.name);
    l.remove(gpa, 1);
    try testing.expectEqual(@as(?usize, null), l.active);
    try testing.expectEqual(@as(usize, 0), l.loose.ids.items.len);
    try testing.expectEqual(@as(usize, 1), l.sets.items.len);
}

test "conjuntos: o arquivo vai e volta igual, com a tela dividida e as abas soltas" {
    const gpa = testing.allocator;
    var l: List = .{};
    defer l.deinit(gpa);
    const work = [_]Id{ 500005, 500010, 500006 };
    const game = [_]Id{ 503005, 503006 };
    _ = try l.add(gpa, "trabalho", &work, 2, .{ .ids = .{ 500006, 500005, 0 }, .count = 2, .focus = 0 });
    _ = try l.add(gpa, "jogo \"do\" fim\\", &game, 1, .{});
    l.active = 1;
    try l.loose.set(gpa, &.{ 1, 2, 3 }, 2, .{});
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try l.write(gpa, &out);
    var back: List = .{};
    defer back.deinit(gpa);
    try back.read(gpa, out.items);
    try testing.expectEqual(@as(usize, 2), back.sets.items.len);
    try testing.expectEqual(@as(?usize, 1), back.active);
    try testing.expectEqualStrings("jogo \"do\" fim\\", back.sets.items[1].name);
    try testing.expectEqualSlices(Id, &work, back.sets.items[0].abas.ids.items);
    try testing.expectEqual(@as(usize, 2), back.sets.items[0].abas.tab);
    const sp = back.sets.items[0].abas.split;
    try testing.expectEqual(@as(u8, 2), sp.count);
    try testing.expectEqual(@as(Id, 500006), sp.ids[0]);
    try testing.expectEqualSlices(Id, &.{ 1, 2, 3 }, back.loose.ids.items);
    try testing.expectEqual(@as(usize, 2), back.loose.tab);
    // Sem conjunto em uso, não sobra "active" nem "loose" no arquivo.
    l.active = null;
    out.clearRetainingCapacity();
    try l.write(gpa, &out);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"active\"") == null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"loose\"") == null);
}

test "conjuntos: arquivo estragado ou editado à mão" {
    const gpa = testing.allocator;
    var l: List = .{};
    defer l.deinit(gpa);
    // JSON quebrado e topo que não é objeto: erro (quem chama guarda o arquivo).
    try testing.expect(std.meta.isError(l.read(gpa, "{\"sets\":[")));
    try testing.expectError(error.InvalidFormat, l.read(gpa, "[1,2,3]"));
    try testing.expectError(error.InvalidFormat, l.read(gpa, "\"oi\""));
    // Sem "sets", ou "sets" que não é lista: lista vazia.
    try l.read(gpa, "{\"version\":1}");
    try testing.expectEqual(@as(usize, 0), l.sets.items.len);
    try l.read(gpa, "{\"sets\":{\"name\":\"x\"}}");
    try testing.expectEqual(@as(usize, 0), l.sets.items.len);
    // Pula: sem nome, nome vazio, repetido, sem abas válidas; IDs ruins, repetidos e
    // zero saem; aba ativa fora do lugar volta para dentro; "active" que não existe
    // não vale; tela dividida com um painel só não é tela dividida.
    const text =
        \\{"version":1,"active":"nao-existe","sets":[
        \\{"tabs":["1"]},
        \\{"name":"   ","tabs":["1"]},
        \\{"name":"ok","tab":99,"tabs":["5","x",7,"5","0","-3","6"],"split":{"panes":["5"],"focus":3}},
        \\{"name":"OK","tabs":["9"]},
        \\{"name":"vazio","tabs":["abc",null,{}]},
        \\{"name":"div","tab":-4,"tabs":["8","9"],"split":{"panes":["8","9","10","11"],"focus":9}},
        \\42
        \\]}
    ;
    try l.read(gpa, text);
    try testing.expectEqual(@as(usize, 2), l.sets.items.len);
    try testing.expectEqual(@as(?usize, null), l.active);
    const ok = l.sets.items[0];
    try testing.expectEqualStrings("ok", ok.name);
    try testing.expectEqualSlices(Id, &.{ 5, 6 }, ok.abas.ids.items);
    try testing.expectEqual(@as(usize, 1), ok.abas.tab);
    try testing.expectEqual(@as(u8, 0), ok.abas.split.count);
    const div = l.sets.items[1].abas;
    try testing.expectEqual(@as(usize, 0), div.tab);
    try testing.expectEqual(@as(u8, 3), div.split.count);
    try testing.expectEqual(@as(u8, 2), div.split.focus);
    // Mais conjuntos que o limite: os primeiros ficam.
    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(gpa);
    try big.appendSlice(gpa, "{\"sets\":[");
    for (0..max_sets + 4) |k| try big.print(gpa, "{s}{{\"name\":\"s{d}\",\"tabs\":[\"{d}\"]}}", .{ if (k > 0) "," else "", k, k + 1 });
    try big.appendSlice(gpa, "],\"active\":\"S3\"}");
    try l.read(gpa, big.items);
    try testing.expectEqual(@as(usize, max_sets), l.sets.items.len);
    try testing.expectEqual(@as(?usize, 3), l.active);
}
