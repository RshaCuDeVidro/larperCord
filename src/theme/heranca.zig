//! Herança e variáveis dos temas, resolvidas na hora de carregar (nunca por quadro):
//!
//!   extends "classico"                    parte de outro tema e muda só o que for diferente
//!   vars { gap 8; card "mix(@surface, @accent, 0.06)" }   `$gap` e `$card` nos valores
//!
//! Regras de `extends` (README "Building on another theme"): os metadados vêm do tema (o
//! `preview` da base fica se ele não disser outro); `palette`, `roles` e `layout` do tema
//! trocam os da base inteiros; `colors` troca token por token; `fonts`, `metrics` e
//! `window` propriedade por propriedade; `styles` estilo por estilo, e dentro de um estilo
//! propriedade por propriedade (theme.zig junta as duas listas); `options` e `vars` nome por
//! nome. `mode=`/`when=` nos nós do topo continuam valendo. Até `max_depth` bases.
//!
//! As variáveis e as opções dividem o `$nome`: uma variável com o nome de uma opção é erro.
//! A variável do tema troca a da base com o mesmo nome, também onde a base a usa.
const std = @import("std");
const kdl = @import("kdl.zig");
const schema = @import("schema.zig");

pub const max_depth = 4;

/// Um tema que pode servir de base.
pub const Base = struct {
    src: []const u8,
    /// Quem é (o caminho do arquivo, ou "builtin:nome"): um nome que já está na corrente
    /// leva ao tema de baixo com o mesmo nome (o embutido), não a ele mesmo.
    id: []const u8,
    /// Como aparece nas mensagens.
    label: []const u8,
};

/// De onde vêm as bases (bases.zig tem a dos embutidos e a das pastas).
pub const Bases = struct {
    ctx: *const anyopaque,
    /// O `i`-ésimo tema chamado `name`, do que vence para o de baixo (0 = o que o app
    /// usaria). null = não há mais. O texto pode ser alocado em `a` (a arena do tema).
    find: *const fn (ctx: *const anyopaque, a: std.mem.Allocator, name: []const u8, i: usize) ?Base,
};

/// Um arquivo da corrente. O índice dele em `Prepared.files` é o `file` dos nós.
pub const File = struct {
    /// Vazio no próprio tema.
    label: []const u8,
    id: []const u8,
    nodes: []const kdl.Node,
};

pub const Prepared = struct {
    /// Os nós do topo já juntados (base antes) e com as variáveis trocadas.
    nodes: []const kdl.Node,
    files: []const File,
    var_names: []const []const u8,
    warnings: []const schema.Issue,
};

pub const Options = struct {
    bases: ?Bases = null,
    self: []const u8 = "",
    light: bool = false,
    report: ?*schema.Report = null,
};

/// O erro que para o carregamento (arquivo, linha e coluna). A mensagem pode estar na
/// arena do tema: quem chama copia antes de ela sumir.
pub const Problem = struct {
    file: []const u8 = "",
    line: u32 = 0,
    col: u32 = 0,
    message: []const u8 = "",
};

pub const Error = error{ OutOfMemory, InvalidTheme };

const Cx = struct {
    a: std.mem.Allocator,
    files: std.ArrayList(File) = .empty,
    problem: *Problem,

    fn fail(cx: *Cx, file: u8, line: u32, col: u32, comptime fmt: []const u8, args: anytype) Error {
        cx.problem.* = .{
            .file = cx.files.items[file].label,
            .line = line,
            .col = col,
            .message = std.fmt.allocPrint(cx.a, fmt, args) catch "out of memory",
        };
        return error.InvalidTheme;
    }
};

pub fn prepare(a: std.mem.Allocator, own: []const kdl.Node, o: Options, problem: *Problem) Error!Prepared {
    var cx: Cx = .{ .a = a, .problem = problem };
    try cx.files.append(a, .{ .label = "", .id = o.self, .nodes = own });
    try resolveChain(&cx, o.bases);

    // Variáveis (da base para o tema: o mais perto ganha) e os nomes que o `$` alcança.
    var options: std.ArrayList([]const u8) = .empty;
    var styles: std.ArrayList([]const u8) = .empty;
    var vars: std.ArrayList(Var) = .empty;
    var fi = cx.files.items.len;
    while (fi > 0) {
        fi -= 1;
        for (cx.files.items[fi].nodes) |*n| {
            if (std.mem.eql(u8, n.name, "options")) {
                for (n.children) |*ch| if (ch.arg(0)) |v| if (v.asString()) |name| try options.append(a, name);
            } else if (std.mem.eql(u8, n.name, "styles")) {
                for (n.children) |*ch| if (ch.arg(0)) |v| if (v.asString()) |name| try styles.append(a, name);
            } else if (std.mem.eql(u8, n.name, "vars")) {
                if (n.str("mode")) |m| if (!std.mem.eql(u8, m, if (o.light) "light" else "dark")) continue;
                for (n.children) |*ch| try defineVar(&cx, &vars, ch);
            }
        }
    }
    for (vars.items) |v| {
        if (isOption(options.items, v.name))
            return cx.fail(v.node.file, v.node.line, v.node.col, "variable '{s}' has the same name as an option ($ means both)", .{v.name});
    }
    try resolveVars(&cx, vars.items, options.items);

    // Troca as variáveis e confere cada arquivo com o esquema.
    var warnings: std.ArrayList(schema.Issue) = .empty;
    for (cx.files.items, 0..) |*f, i| {
        var sub: Subst = .{ .cx = &cx, .vars = vars.items, .options = options.items, .out = &warnings, .file = @intCast(i) };
        if (vars.items.len > 0) f.nodes = try sub.list(f.nodes);
        var ck: schema.Checker = .{ .a = a, .out = &warnings, .options = options.items, .styles = styles.items, .file = f.label };
        for (f.nodes) |*n| try ck.topNode(n);
    }
    if (o.report) |r| for (warnings.items) |it| try r.add(it);

    var names: std.ArrayList([]const u8) = .empty;
    for (vars.items) |v| try names.append(a, v.name);
    return .{ .nodes = try merge(&cx), .files = cx.files.items, .var_names = names.items, .warnings = warnings.items };
}

// --- extends ------------------------------------------------------------------------------

fn extendsOf(cx: *Cx, file: u8) Error!?*const kdl.Node {
    var found: ?*const kdl.Node = null;
    for (cx.files.items[file].nodes) |*n| {
        if (!std.mem.eql(u8, n.name, "extends")) continue;
        if (found != null) return cx.fail(file, n.line, n.col, "a theme extends a single base (one extends node)", .{});
        found = n;
    }
    return found;
}

fn resolveChain(cx: *Cx, bases: ?Bases) Error!void {
    var cur: u8 = 0;
    while (try extendsOf(cx, cur)) |ext| {
        const name = (if (ext.arg(0)) |v| v.asString() else null) orelse
            return cx.fail(cur, ext.line, ext.col, "extends needs the name of a theme in quotes: extends \"classico\"", .{});
        if (cx.files.items.len > max_depth)
            return cx.fail(cur, ext.line, ext.col, "extends goes deeper than {d} levels", .{max_depth});
        const r = bases orelse return cx.fail(cur, ext.line, ext.col, "unknown base theme '{s}'", .{name});
        var skipped: ?Base = null;
        var i: usize = 0;
        const base: Base = while (r.find(r.ctx, cx.a, name, i)) |cand| : (i += 1) {
            if (inChain(cx, cand.id)) {
                skipped = cand;
                continue;
            }
            break cand;
        } else {
            if (skipped) |s| {
                var chain: std.ArrayList(u8) = .empty;
                for (cx.files.items) |f| try chain.print(cx.a, "{s} → ", .{nameOf(f)});
                try chain.appendSlice(cx.a, s.label);
                return cx.fail(cur, ext.line, ext.col, "extends cycle: {s}", .{chain.items});
            }
            return cx.fail(cur, ext.line, ext.col, "unknown base theme '{s}'", .{name});
        };
        const index: u8 = @intCast(cx.files.items.len);
        var kd: kdl.Diagnostic = .{};
        const nodes = kdl.parseIn(cx.a, base.src, &kd, index) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            try cx.files.append(cx.a, .{ .label = base.label, .id = base.id, .nodes = &.{} });
            return cx.fail(index, kd.line, kd.column, "{s}", .{kd.message});
        };
        try cx.files.append(cx.a, .{ .label = base.label, .id = base.id, .nodes = nodes });
        cur = index;
    }
}

fn inChain(cx: *const Cx, id: []const u8) bool {
    if (id.len == 0) return false;
    for (cx.files.items) |f| if (sameFile(f.id, id)) return true;
    return false;
}

/// O mesmo arquivo escrito de dois jeitos: `\` e `/` (no Windows, também maiúsculas).
fn sameFile(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    const windows = @import("builtin").os.tag == .windows;
    for (a, b) |x, y| {
        const xs = if (x == '\\') '/' else x;
        const ys = if (y == '\\') '/' else y;
        if (xs == ys) continue;
        if (windows and std.ascii.toLower(xs) == std.ascii.toLower(ys)) continue;
        return false;
    }
    return true;
}

fn nameOf(f: File) []const u8 {
    return if (f.label.len > 0) f.label else if (f.id.len > 0) f.id else "this theme";
}

/// A corrente juntada: a base mais de baixo primeiro, o próprio tema por último. Com uma
/// base, os `styles` vão depois de todos os outros nós: um estilo da base que usa `@accent`
/// segue o accent que o tema escolheu (theme.zig avalia bg, border e glow na hora).
fn merge(cx: *Cx) Error![]const kdl.Node {
    const all = try joined(cx);
    if (cx.files.items.len == 1) return all;
    const out = try cx.a.alloc(kdl.Node, all.len);
    var k: usize = 0;
    for ([_]bool{ false, true }) |styles| for (all) |n| {
        if (std.mem.eql(u8, n.name, "styles") != styles) continue;
        out[k] = n;
        k += 1;
    };
    return out;
}

fn joined(cx: *Cx) Error![]const kdl.Node {
    var acc: std.ArrayList(kdl.Node) = .empty;
    var fi = cx.files.items.len;
    while (fi > 0) {
        fi -= 1;
        const child = cx.files.items[fi].nodes;
        if (fi + 1 == cx.files.items.len) {
            for (child) |n| if (keep(n)) try acc.append(cx.a, n);
            continue;
        }
        var next: std.ArrayList(kdl.Node) = .empty;
        for (acc.items) |n| {
            const replaced = std.mem.eql(u8, n.name, "palette") or std.mem.eql(u8, n.name, "roles") or std.mem.eql(u8, n.name, "layout");
            if (replaced and has(child, n.name)) continue;
            if (std.mem.eql(u8, n.name, "theme")) {
                // Os metadados são do tema; só a miniatura da base fica (o layout pode ser o dela).
                if (try preview(cx.a, n)) |p| try next.append(cx.a, p);
                continue;
            }
            try next.append(cx.a, n);
        }
        for (child) |n| if (keep(n)) try next.append(cx.a, n);
        acc = next;
    }
    return acc.items;
}

/// `extends` e `theme-api` valem só para o próprio arquivo.
fn keep(n: kdl.Node) bool {
    return !std.mem.eql(u8, n.name, "extends") and !std.mem.eql(u8, n.name, "theme-api");
}

fn has(nodes: []const kdl.Node, name: []const u8) bool {
    for (nodes) |n| if (std.mem.eql(u8, n.name, name)) return true;
    return false;
}

/// O nó `theme` da base só com o `preview` (e as condições dele).
fn preview(a: std.mem.Allocator, n: kdl.Node) Error!?kdl.Node {
    var props: [4]kdl.Prop = undefined;
    var k: usize = 0;
    var found = false;
    for (n.props) |p| {
        const wanted = std.mem.eql(u8, p.key, "preview") or std.mem.eql(u8, p.key, "mode") or std.mem.eql(u8, p.key, "when") or std.mem.eql(u8, p.key, "unless");
        if (!wanted or k == props.len) continue;
        found = found or std.mem.eql(u8, p.key, "preview");
        props[k] = p;
        k += 1;
    }
    if (!found) return null;
    var out = n;
    out.args = &.{};
    out.props = try a.dupe(kdl.Prop, props[0..k]);
    return out;
}

// --- vars ---------------------------------------------------------------------------------

const Var = struct {
    name: []const u8,
    value: kdl.Value,
    node: *const kdl.Node,
    /// Já trocou os `$` de dentro (resolveVars).
    done: bool = false,
};

fn validName(s: []const u8) bool {
    if (s.len == 0 or !(std.ascii.isAlphabetic(s[0]) or s[0] == '_')) return false;
    for (s) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-')) return false;
    return true;
}

fn defineVar(cx: *Cx, vars: *std.ArrayList(Var), ch: *const kdl.Node) Error!void {
    if (!validName(ch.name)) return cx.fail(ch.file, ch.line, ch.col, "'{s}' isn't a valid variable name (letters, digits, - and _)", .{ch.name});
    const value = ch.arg(0) orelse return cx.fail(ch.file, ch.line, ch.col, "variable '{s}' needs a value: {s} 8, or {s} \"#ff0000\"", .{ ch.name, ch.name, ch.name });
    if (value == .null) return cx.fail(ch.file, ch.line, ch.col, "variable '{s}' needs a value", .{ch.name});
    for (vars.items) |*v| if (std.mem.eql(u8, v.name, ch.name)) {
        v.* = .{ .name = ch.name, .value = value, .node = ch };
        return;
    };
    try vars.append(cx.a, .{ .name = ch.name, .value = value, .node = ch });
}

fn isOption(options: []const []const u8, name: []const u8) bool {
    if (std.mem.eql(u8, name, "modo-claro") or std.mem.eql(u8, name, "modo-escuro")) return true;
    for (options) |o| if (std.mem.eql(u8, o, name)) return true;
    return false;
}

fn findVar(vars: []Var, name: []const u8) ?*Var {
    for (vars) |*v| if (std.mem.eql(u8, v.name, name)) return v;
    return null;
}

/// Uma variável pode usar outra (`card "mix($base, @bg, 0.1)"`), inclusive uma que o tema
/// trocou na base. Laço é erro.
fn resolveVars(cx: *Cx, vars: []Var, options: []const []const u8) Error!void {
    var stack: [16]*Var = undefined;
    for (vars) |*v| try resolveOne(cx, vars, options, v, &stack, 0);
}

fn resolveOne(cx: *Cx, vars: []Var, options: []const []const u8, v: *Var, stack: *[16]*Var, depth: usize) Error!void {
    if (v.done) return;
    for (stack[0..depth]) |s| if (s == v) {
        var path: std.ArrayList(u8) = .empty;
        for (stack[0..depth]) |x| try path.print(cx.a, "${s} → ", .{x.name});
        try path.print(cx.a, "${s}", .{v.name});
        return cx.fail(v.node.file, v.node.line, v.node.col, "variables use each other in a loop: {s}", .{path.items});
    };
    if (depth == stack.len) return cx.fail(v.node.file, v.node.line, v.node.col, "variables nested too deep", .{});
    stack[depth] = v;
    const s = v.value.asString() orelse {
        v.done = true;
        return;
    };
    if (std.mem.indexOfScalar(u8, s, '$') == null) {
        v.done = true;
        return;
    }
    // Primeiro as que esta usa.
    var it = refs(s);
    while (it.next()) |r| if (findVar(vars, r.name)) |dep| try resolveOne(cx, vars, options, dep, stack, depth + 1);
    var sub: Subst = .{ .cx = cx, .vars = vars, .options = options, .out = null, .file = v.node.file };
    v.value = try sub.value(v.value, v.node.line, v.node.col);
    v.done = true;
}

/// Os `$nome` de uma string (sem os `$!` das opções).
const Refs = struct {
    s: []const u8,
    i: usize = 0,

    const Ref = struct { start: usize, end: usize, name: []const u8 };

    fn next(r: *Refs) ?Ref {
        while (std.mem.indexOfScalarPos(u8, r.s, r.i, '$')) |at| {
            r.i = at + 1;
            if (at + 1 < r.s.len and r.s[at + 1] == '$') {
                r.i = at + 2;
                continue;
            }
            var end = at + 1;
            while (end < r.s.len and (std.ascii.isAlphanumeric(r.s[end]) or r.s[end] == '_' or r.s[end] == '-')) end += 1;
            if (end == at + 1) continue;
            r.i = end;
            return .{ .start = at, .end = end, .name = r.s[at + 1 .. end] };
        }
        return null;
    }
};

fn refs(s: []const u8) Refs {
    return .{ .s = s };
}

const Subst = struct {
    cx: *Cx,
    vars: []Var,
    options: []const []const u8,
    /// Onde vão os avisos (null nas próprias variáveis: o aviso sai onde ela é usada).
    out: ?*std.ArrayList(schema.Issue),
    file: u8,

    fn list(sb: *Subst, nodes: []const kdl.Node) Error![]const kdl.Node {
        const out = try sb.cx.a.alloc(kdl.Node, nodes.len);
        for (nodes, out) |*n, *o| {
            o.* = n.*;
            // As próprias definições e o nome da base não passam por aqui.
            if (std.mem.eql(u8, n.name, "vars") or std.mem.eql(u8, n.name, "extends") or std.mem.eql(u8, n.name, "theme-api")) continue;
            o.* = try sb.node(n);
        }
        return out;
    }

    fn node(sb: *Subst, n: *const kdl.Node) Error!kdl.Node {
        var o = n.*;
        if (n.args.len > 0) {
            const args = try sb.cx.a.alloc(kdl.Value, n.args.len);
            for (n.args, args) |v, *x| x.* = try sb.valueIn(v, n.line, n.col, true);
            o.args = args;
        }
        if (n.props.len > 0) {
            const props = try sb.cx.a.alloc(kdl.Prop, n.props.len);
            for (n.props, props) |p, *x| {
                x.* = p;
                x.value = try sb.value(p.value, p.line, p.col);
            }
            o.props = props;
        }
        if (n.children.len > 0) {
            const kids = try sb.cx.a.alloc(kdl.Node, n.children.len);
            for (n.children, kids) |*ch, *x| x.* = try sb.node(ch);
            o.children = kids;
        }
        return o;
    }

    fn value(sb: *Subst, v: kdl.Value, line: u32, col: u32) Error!kdl.Value {
        return sb.valueIn(v, line, col, false);
    }

    /// `arg`: um argumento (numa propriedade, quem avisa do `$` desconhecido é o esquema).
    fn valueIn(sb: *Subst, v: kdl.Value, line: u32, col: u32, arg: bool) Error!kdl.Value {
        const s = v.asString() orelse return v;
        if (std.mem.indexOfScalar(u8, s, '$') == null) return v;
        // O valor inteiro é uma variável: fica com o tipo dela (`gap=$gap` vira número).
        if (s.len > 1 and s[0] == '$' and validName(s[1..])) {
            if (findVar(sb.vars, s[1..])) |x| return x.value;
            if (isOption(sb.options, s[1..])) return v;
            if (arg) try sb.warn(line, col, "unknown variable or option '{s}'", .{s});
            return v;
        }
        if (s.len > 2 and s[0] == '$' and s[1] == '!') {
            if (findVar(sb.vars, s[2..]) != null) try sb.warn(line, col, "$! only inverts an option, and '{s}' is a variable", .{s[2..]});
            return v;
        }
        // Dentro de um texto maior (`"mix($card, @bg, 0.5)"`): troca só as variáveis.
        var out: std.ArrayList(u8) = .empty;
        var it = refs(s);
        var last: usize = 0;
        var changed = false;
        while (it.next()) |r| {
            const x = findVar(sb.vars, r.name) orelse continue;
            try out.appendSlice(sb.cx.a, s[last..r.start]);
            switch (x.value) {
                .string => |t| try out.appendSlice(sb.cx.a, t),
                .number => |f| try out.print(sb.cx.a, "{d}", .{f}),
                .boolean => |b| try out.appendSlice(sb.cx.a, if (b) "true" else "false"),
                .null => {},
            }
            last = r.end;
            changed = true;
        }
        if (!changed) return v;
        try out.appendSlice(sb.cx.a, s[last..]);
        return .{ .string = out.items };
    }

    fn warn(sb: *Subst, line: u32, col: u32, comptime fmt: []const u8, args: anytype) Error!void {
        const out = sb.out orelse return;
        try out.append(sb.cx.a, .{
            .severity = .warning,
            .file = sb.cx.files.items[sb.file].label,
            .line = line,
            .col = col,
            .message = try std.fmt.allocPrint(sb.cx.a, fmt, args),
        });
    }
};

// --- Testes -------------------------------------------------------------------------------

const testing = std.testing;
const theme = @import("theme.zig");
const bases_mod = @import("bases.zig");

/// Temas "da pasta" de mentira, na frente dos embutidos.
const Mem = struct {
    files: []const [2][]const u8,

    fn find(ctx: *const anyopaque, a: std.mem.Allocator, name: []const u8, i: usize) ?Base {
        const m: *const Mem = @ptrCast(@alignCast(ctx));
        var k: usize = 0;
        for (m.files) |f| if (std.mem.eql(u8, f[0], name)) {
            if (k == i) return .{ .src = f[1], .id = std.fmt.allocPrint(a, "mem:{s}", .{name}) catch return null, .label = std.fmt.allocPrint(a, "{s}.kdl", .{name}) catch return null };
            k += 1;
        };
        return if (k == i) bases_mod.builtinBase(a, name) else null;
    }

    fn bases_(m: *const Mem) Bases {
        return .{ .ctx = m, .find = find };
    }
};

const base_a =
    \\theme "base-a" description="A base" author="eu" preview=glass
    \\palette "#101010" "#ff0000" "#00ff00" "#0000ff" "#ffff00"
    \\colors { accent "#112233"; text "#eeeeee" }
    \\colors mode=light { accent "#334455"; link "#010203" }
    \\roles "#aa0000" "#00aa00"
    \\fonts ui="Base UI" mono="Base Mono" size=15
    \\metrics radius=9
    \\window transparent=#true
    \\styles { style "card" bg="@accent" radius=12 border="@text" glow="@accent"; style "outra" radius=3 }
    \\options { option "brilho" label="Brilho base" default=#false; option "extra" label="Extra" }
    \\vars { gap 7; card "mix(@surface, @accent, 0.5)" }
    \\layout { row gap="$gap" { messages; composer style=card } }
;

fn load(src: []const u8, mode: theme.Mode, mem: *const Mem, diag: ?*theme.Diagnostic) !theme.Theme {
    return theme.loadWith(testing.allocator, src, .{ .mode = mode, .bases = mem.bases_(), .self = "mem:filho" }, diag);
}

fn eqColor(want: u32, got: theme.Rgba) !void {
    const w = theme.Rgba.hex(want);
    try testing.expectApproxEqAbs(w.r, got.r, 0.003);
    try testing.expectApproxEqAbs(w.g, got.g, 0.003);
    try testing.expectApproxEqAbs(w.b, got.b, 0.003);
}

test "extends: cada regra de junção" {
    const mem: Mem = .{ .files = &.{.{ "base-a", base_a }} };
    const filho =
        \\extends "base-a"
        \\theme "filho" description="Filho"
        \\colors { accent "#abcdef" }
        \\fonts size=18
        \\styles { style "card" radius=4 }
        \\options { option "brilho" label="Brilho filho" default=#true }
        \\vars { gap 11 }
    ;
    var t = try load(filho, .dark, &mem, null);
    defer t.deinit();
    // Metadados do filho; a miniatura da base fica.
    try testing.expectEqualStrings("filho", t.name);
    try testing.expectEqualStrings("Filho", t.description);
    try testing.expectEqualStrings("", t.author);
    try testing.expectEqualStrings("glass", t.preview);
    // Paleta e cargos da base (o filho não tem).
    try eqColor(0xaa0000, t.roles[0]);
    // Cores token por token: accent do filho, text da base.
    try eqColor(0xabcdef, t.c(.accent));
    try eqColor(0xeeeeee, t.c(.text));
    // Fontes, métricas e janela propriedade por propriedade.
    try testing.expectEqualStrings("Base UI", t.font_ui);
    try testing.expectEqualStrings("Base Mono", t.font_mono);
    try testing.expectEqual(@as(f32, 18), t.font_size);
    try testing.expectEqual(@as(f32, 9), t.radius);
    try testing.expect(t.transparent);
    // Estilo por nome, propriedade por propriedade; e o da base segue o accent do filho.
    const card = t.style("card").?;
    try testing.expectEqual(@as(f32, 4), card.radius);
    try eqColor(0xabcdef, card.bg.?);
    try eqColor(0xeeeeee, card.border.?);
    try testing.expectEqual(@as(f32, 3), t.style("outra").?.radius);
    // Opções por nome: a do filho no lugar da da base.
    try testing.expectEqual(@as(usize, 2), t.options.len);
    try testing.expectEqualStrings("Brilho filho", t.options[0].label);
    try testing.expect(t.option("brilho").?);
    try testing.expectEqualStrings("extra", t.options[1].name);
    // Variável trocada pelo filho, também onde a base usa: o layout é o da base.
    const row = &t.layout.?.children[0];
    try testing.expectEqual(@as(f64, 11), row.num("gap").?);
    try testing.expectEqualStrings("composer", row.children[1].name);
    try testing.expectEqual(@as(usize, 0), t.warnings.len);

    // `mode=` da base continua valendo: no claro o link é o dela, o accent é o do filho.
    var l = try load(filho, .light, &mem, null);
    defer l.deinit();
    try eqColor(0x010203, l.c(.link));
    try eqColor(0xabcdef, l.c(.accent));
}

test "extends: palette, roles e layout do filho trocam os da base inteiros" {
    const mem: Mem = .{ .files = &.{.{ "base-a", base_a }} };
    var t = try load(
        \\extends "base-a"
        \\palette "#000000" "#00ffff"
        \\roles "#123456"
        \\layout { column { messages } }
    , .dark, &mem, null);
    defer t.deinit();
    try testing.expectEqualStrings("column", t.layout.?.children[0].name);
    try eqColor(0x123456, t.roles[0]);
    // O segundo cargo não vem da base: vem da paleta do filho (wal:1).
    try eqColor(0x00ffff, t.roles[1]);
    // Sem o `theme`, nada dos metadados da base (só a miniatura).
    try testing.expectEqualStrings("sem nome", t.name);
    try testing.expectEqualStrings("glass", t.preview);
}

test "extends: um embutido, e o nome do próprio tema leva ao embutido" {
    const mem: Mem = .{ .files = &.{.{ "classico", "extends \"classico\"\ncolors { accent \"#ff00aa\" }" }} };
    var t = try theme.loadWith(testing.allocator, "extends \"classico\"\ncolors { accent \"#ff00aa\" }", .{ .bases = mem.bases_(), .self = "mem:classico" }, null);
    defer t.deinit();
    try eqColor(0xff00aa, t.c(.accent));
    try testing.expect(t.has_user_panel);
    try testing.expectEqual(@as(usize, 0), t.warnings.len);
}

test "extends: base desconhecida, laço e fundo demais dão erro com a linha" {
    const mem: Mem = .{ .files = &.{
        .{ "x", "extends \"y\"\nlayout { messages }" },
        .{ "y", "extends \"x\"" },
        .{ "l1", "extends \"l2\"" },
        .{ "l2", "extends \"l3\"" },
        .{ "l3", "extends \"l4\"" },
        .{ "l4", "extends \"l5\"" },
        .{ "l5", "layout { messages }" },
    } };
    var d: theme.Diagnostic = .{};
    try testing.expectError(error.InvalidTheme, load("theme \"t\"\nextends \"nao-existe\"\nlayout { messages }", .dark, &mem, &d));
    try testing.expectEqual(@as(u32, 2), d.line);
    try testing.expectEqual(@as(u32, 1), d.column);
    try testing.expect(std.mem.indexOf(u8, d.message, "unknown base theme 'nao-existe'") != null);

    try testing.expectError(error.InvalidTheme, theme.loadWith(testing.allocator, "extends \"y\"", .{ .bases = mem.bases_(), .self = "mem:x" }, &d));
    try testing.expect(std.mem.indexOf(u8, d.message, "extends cycle") != null);
    try testing.expectEqualStrings("y.kdl", d.file);

    // Quatro bases passam; a quinta não.
    var ok = try load("extends \"l2\"", .dark, &mem, null);
    ok.deinit();
    try testing.expectError(error.InvalidTheme, load("extends \"l1\"", .dark, &mem, &d));
    try testing.expect(std.mem.indexOf(u8, d.message, "deeper than 4") != null);

    // Erro dentro da base aponta o arquivo dela.
    const bad: Mem = .{ .files = &.{.{ "quebrada", "layout { messages }\ncolors {\n  nada \"#fff\"\n}" }} };
    try testing.expectError(error.InvalidTheme, load("extends \"quebrada\"", .dark, &bad, &d));
    try testing.expectEqualStrings("quebrada.kdl", d.file);
    try testing.expectEqual(@as(u32, 3), d.line);
}

test "vars: número, cor, dentro de expressões, uma usando outra" {
    const mem: Mem = .{ .files = &.{} };
    var t = try load(
        \\vars { g 8; vermelho "#ff0000"; meio "mix($vermelho, #0000ff, 0.5)"; borda 2 }
        \\colors { accent "$vermelho"; link "$meio"; mention "mix($vermelho, black, 0.5)" }
        \\styles { style "card" border-width=$borda bg="alpha($vermelho, 0.5)" }
        \\layout { row gap=$g { messages } }
    , .dark, &mem, null);
    defer t.deinit();
    try testing.expectEqual(@as(f64, 8), t.layout.?.children[0].num("gap").?);
    try eqColor(0xff0000, t.c(.accent));
    try testing.expectApproxEqAbs(@as(f32, 0.5), t.c(.link).r, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0.5), t.c(.link).b, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0.5), t.c(.mention).r, 0.01);
    try testing.expectEqual(@as(f32, 2), t.style("card").?.border_width);
    try testing.expectApproxEqAbs(@as(f32, 0.5), t.style("card").?.bg.?.a, 0.01);
    try testing.expectEqual(@as(usize, 4), t.var_names.len);
    try testing.expectEqual(@as(usize, 0), t.warnings.len);
}

test "vars: o filho troca a da base, também nas cores que a base calcula" {
    const mem: Mem = .{ .files = &.{.{ "base-v", "vars { tom \"#ff0000\" }\ncolors { accent \"$tom\"; link \"mix($tom, white, 0.5)\" }\nlayout { messages }" }} };
    var t = try load("extends \"base-v\"\nvars { tom \"#00ff00\" }", .dark, &mem, null);
    defer t.deinit();
    try eqColor(0x00ff00, t.c(.accent));
    try testing.expectApproxEqAbs(@as(f32, 1), t.c(.link).g, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0.5), t.c(.link).r, 0.01);
}

test "vars: mode=, nome igual a opção, indefinida, laço" {
    const mem: Mem = .{ .files = &.{} };
    const src = "vars { c \"#ff0000\" }\nvars mode=light { c \"#0000ff\" }\ncolors { accent \"$c\" }\nlayout { messages }";
    var dk = try load(src, .dark, &mem, null);
    defer dk.deinit();
    try eqColor(0xff0000, dk.c(.accent));
    var lt = try load(src, .light, &mem, null);
    defer lt.deinit();
    try eqColor(0x0000ff, lt.c(.accent));

    var d: theme.Diagnostic = .{};
    try testing.expectError(error.InvalidTheme, load("options { option \"x\" }\nvars {\n  x 1\n}\nlayout { messages }", .dark, &mem, &d));
    try testing.expectEqual(@as(u32, 3), d.line);
    try testing.expect(std.mem.indexOf(u8, d.message, "same name as an option") != null);

    // Indefinida: aviso no theme-api 1 (o tema carrega).
    var w = try load("vars { a 1 }\nlayout {\n  row gap=$nada { messages }\n}", .dark, &mem, null);
    defer w.deinit();
    try testing.expectEqual(@as(usize, 1), w.warnings.len);
    try testing.expectEqual(@as(u32, 3), w.warnings[0].line);
    try testing.expectEqual(@as(u32, 7), w.warnings[0].col);
    try testing.expect(std.mem.indexOf(u8, w.warnings[0].message, "'$nada'") != null);

    try testing.expectError(error.InvalidTheme, load("vars { a \"$b\"; b \"$a\" }\nlayout { messages }", .dark, &mem, &d));
    try testing.expect(std.mem.indexOf(u8, d.message, "loop") != null);
    // A opção continua com o `$` dela.
    var o = try load("options { option \"brilho\" default=#false }\nvars { a 1 }\nstyles { style \"s\" sheen=\"$brilho\" }\nlayout { messages }", .dark, &mem, null);
    defer o.deinit();
    try testing.expect(!o.style("s").?.sheen);
    try testing.expectEqual(@as(usize, 0), o.warnings.len);
}

test "o mesmo arquivo com barras diferentes" {
    try testing.expect(sameFile("C:\\x\\themes/a.kdl", "C:/x/themes/a.kdl"));
    try testing.expect(!sameFile("/x/a.kdl", "/x/b.kdl"));
}

test "temas sem extends nem vars ficam como eram (mesma ordem dos nós)" {
    const mem: Mem = .{ .files = &.{} };
    // Estilo antes das cores: avaliado com o accent de antes, como sempre foi.
    var t = try load("styles { style \"s\" bg=\"@accent\" }\ncolors { accent \"#ff0000\" }\nlayout { messages }", .dark, &mem, null);
    defer t.deinit();
    try testing.expect(t.style("s").?.bg.?.r < 0.9);
}
