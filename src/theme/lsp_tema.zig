//! Servidor de linguagem dos .kdl de tema (`larpercord --theme-lsp`): os erros e avisos do
//! carregador e do esquema enquanto a pessoa digita, completar (nós, propriedades,
//! valores, tokens depois de `@`, opções e variáveis depois de `$`) e a descrição de cada
//! coisa ao passar o mouse. Esta é a parte pura: theme_cli.zig lê a entrada padrão,
//! entrega cada mensagem a `Server.handle` e escreve o que ela devolve.
const std = @import("std");
const kdl = @import("kdl.zig");
const theme = @import("theme.zig");
const schema = @import("schema.zig");
const bases = @import("bases.zig");
const lsp = @import("../core/lsp.zig");
const jsonx = @import("../net/jsonx.zig");

const Value = std.json.Value;

pub const Server = struct {
    gpa: std.mem.Allocator,
    /// Texto de cada documento aberto (uri → texto).
    docs: std.StringHashMapUnmanaged([]u8) = .empty,
    shutdown: bool = false,
    /// Depois do `exit`: 0 se veio depois do `shutdown`, 1 se não.
    exit_code: ?u8 = null,
    /// Para achar a base de `extends`: lê um arquivo (null = só os temas embutidos) e as
    /// pastas a olhar depois da do próprio arquivo (a de temas do usuário).
    read: ?*const fn (a: std.mem.Allocator, path: []const u8) ?[]const u8 = null,
    dirs: []const []const u8 = &.{},

    pub fn deinit(s: *Server) void {
        var it = s.docs.iterator();
        while (it.next()) |e| {
            s.gpa.free(e.key_ptr.*);
            s.gpa.free(e.value_ptr.*);
        }
        s.docs.deinit(s.gpa);
    }

    /// Uma mensagem do cliente (o corpo, sem o cabeçalho). O que sai vai em `out`, já
    /// com o Content-Length.
    pub fn handle(s: *Server, body: []const u8, out: *std.ArrayList(u8)) !void {
        var arena = std.heap.ArenaAllocator.init(s.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const root = std.json.parseFromSliceLeaky(Value, a, body, .{}) catch return s.replyError(out, null, -32700, "parse error");
        if (root != .object) return s.replyError(out, null, -32600, "invalid request");
        const method = jsonx.str(jsonx.get(root, "method")) orelse return;
        const id = jsonx.get(root, "id");
        const params = jsonx.get(root, "params") orelse Value{ .null = {} };
        if (std.mem.eql(u8, method, "initialize")) {
            return s.reply(out, id, "{\"capabilities\":{\"positionEncoding\":\"utf-16\",\"textDocumentSync\":{\"openClose\":true,\"change\":1}," ++
                "\"completionProvider\":{\"triggerCharacters\":[\"=\",\"@\",\"$\",\"\\\"\"]},\"hoverProvider\":true}," ++
                "\"serverInfo\":{\"name\":\"larpercord-theme\"}}");
        }
        if (std.mem.eql(u8, method, "shutdown")) {
            s.shutdown = true;
            return s.reply(out, id, "null");
        }
        if (std.mem.eql(u8, method, "exit")) {
            s.exit_code = if (s.shutdown) 0 else 1;
            return;
        }
        const doc = jsonx.get(params, "textDocument") orelse Value{ .null = {} };
        const uri = jsonx.str(jsonx.get(doc, "uri")) orelse "";
        if (std.mem.eql(u8, method, "textDocument/didOpen")) {
            try s.store(uri, jsonx.str(jsonx.get(doc, "text")) orelse "");
            return s.publish(out, uri);
        }
        if (std.mem.eql(u8, method, "textDocument/didChange")) {
            // Sincronia completa: a última mudança tem o texto inteiro.
            const changes = jsonx.array(jsonx.get(params, "contentChanges"));
            if (changes.len == 0) return;
            try s.store(uri, jsonx.str(jsonx.get(changes[changes.len - 1], "text")) orelse "");
            return s.publish(out, uri);
        }
        if (std.mem.eql(u8, method, "textDocument/didClose")) {
            if (s.docs.fetchRemove(uri)) |kv| {
                s.gpa.free(kv.key);
                s.gpa.free(kv.value);
            }
            return notifyDiagnostics(s.gpa, out, uri, "[]");
        }
        const text = s.docs.get(uri) orelse "";
        const pos = jsonx.get(params, "position") orelse Value{ .null = {} };
        const offset = offsetOf(text, jsonx.int(jsonx.get(pos, "line")) orelse 0, jsonx.int(jsonx.get(pos, "character")) orelse 0);
        if (std.mem.eql(u8, method, "textDocument/completion")) {
            var items: std.ArrayList(u8) = .empty;
            try completion(s, a, uri, text, offset, &items);
            return s.reply(out, id, items.items);
        }
        if (std.mem.eql(u8, method, "textDocument/hover")) {
            var md: std.ArrayList(u8) = .empty;
            try hover(a, text, offset, &md);
            if (md.items.len == 0) return s.reply(out, id, "null");
            var b: std.ArrayList(u8) = .empty;
            try b.appendSlice(a, "{\"contents\":{\"kind\":\"markdown\",\"value\":");
            try jsonx.writeString(&b, a, md.items);
            try b.appendSlice(a, "}}");
            return s.reply(out, id, b.items);
        }
        // Pedido que não conhecemos ganha resposta (o cliente não fica esperando);
        // aviso que não conhecemos, nada.
        if (id != null) return s.replyError(out, id, -32601, "method not found");
    }

    fn store(s: *Server, uri: []const u8, text: []const u8) !void {
        const copy = try s.gpa.dupe(u8, text);
        errdefer s.gpa.free(copy);
        const gop = try s.docs.getOrPut(s.gpa, uri);
        if (gop.found_existing) {
            s.gpa.free(gop.value_ptr.*);
        } else {
            gop.key_ptr.* = s.gpa.dupe(u8, uri) catch |err| {
                _ = s.docs.remove(uri);
                return err;
            };
        }
        gop.value_ptr.* = copy;
    }

    fn reply(s: *Server, out: *std.ArrayList(u8), id: ?Value, result: []const u8) !void {
        var b: std.ArrayList(u8) = .empty;
        defer b.deinit(s.gpa);
        try b.appendSlice(s.gpa, "{\"jsonrpc\":\"2.0\",\"id\":");
        try writeId(&b, s.gpa, id);
        try b.print(s.gpa, ",\"result\":{s}}}", .{result});
        try frame(out, s.gpa, b.items);
    }

    fn replyError(s: *Server, out: *std.ArrayList(u8), id: ?Value, code: i32, msg: []const u8) !void {
        var b: std.ArrayList(u8) = .empty;
        defer b.deinit(s.gpa);
        try b.appendSlice(s.gpa, "{\"jsonrpc\":\"2.0\",\"id\":");
        try writeId(&b, s.gpa, id);
        try b.print(s.gpa, ",\"error\":{{\"code\":{d},\"message\":", .{code});
        try jsonx.writeString(&b, s.gpa, msg);
        try b.appendSlice(s.gpa, "}}");
        try frame(out, s.gpa, b.items);
    }

    /// Os erros e avisos do documento: o carregador do app nos dois modos, com as opções no
    /// padrão (um erro de sintaxe para tudo; uma cor errada num bloco do claro só aparece lá).
    fn publish(s: *Server, out: *std.ArrayList(u8), uri: []const u8) !void {
        const text = s.docs.get(uri) orelse return;
        var report: schema.Report = .{ .gpa = s.gpa };
        defer report.deinit();
        var arena = std.heap.ArenaAllocator.init(s.gpa);
        defer arena.deinit();
        var look: Lookup = .{};
        const lo = try s.baseOptions(arena.allocator(), uri, &look);
        for ([_]theme.Mode{ .dark, .light }) |mode| {
            var diag: theme.Diagnostic = .{};
            var opts = lo;
            opts.mode = mode;
            opts.report = &report;
            var t = theme.loadWith(s.gpa, text, opts, &diag) catch |err| {
                if (err == error.OutOfMemory) return err;
                try report.add(.{ .severity = .@"error", .file = diag.file, .line = diag.line, .col = diag.column, .message = diag.message });
                continue;
            };
            t.deinit();
        }
        var b: std.ArrayList(u8) = .empty;
        defer b.deinit(s.gpa);
        try b.append(s.gpa, '[');
        for (report.items.items, 0..) |it, i| {
            if (i > 0) try b.append(s.gpa, ',');
            try writeDiagnostic(&b, s.gpa, text, it);
        }
        try b.append(s.gpa, ']');
        try notifyDiagnostics(s.gpa, out, uri, b.items);
    }

    /// `extends` olha a pasta do próprio arquivo, depois as de `dirs`, depois os embutidos.
    fn baseOptions(s: *const Server, a: std.mem.Allocator, uri: []const u8, look: *Lookup) !theme.LoadOptions {
        const path = try uriPath(a, uri);
        const read = s.read orelse return .{ .bases = bases.builtin, .self = path };
        var n: usize = 0;
        look.order[n] = std.fs.path.dirname(path) orelse ".";
        n += 1;
        for (s.dirs) |d| if (n < look.order.len) {
            look.order[n] = d;
            n += 1;
        };
        look.dirs = .{ .dirs = look.order[0..n], .read = read };
        return .{ .bases = look.dirs.bases(), .self = path };
    }
};

/// A entrada e a saída do servidor: a padrão no app (theme_cli.zig), de mentira nos testes.
pub const Io = struct {
    ctx: *anyopaque,
    /// Lê o que chegou (0 = a entrada fechou).
    read: *const fn (ctx: *anyopaque, buf: []u8) usize,
    /// Escreve tudo (false = a saída fechou).
    write: *const fn (ctx: *anyopaque, bytes: []const u8) bool,
};

/// O laço do servidor: separa as mensagens pelo Content-Length (podem chegar em pedaços,
/// ou várias de uma vez), entrega cada uma a `handle` e escreve a resposta. Devolve o código
/// de saída: o do `exit` (0 depois do `shutdown`, 1 sem ele), 1 se a entrada fechar antes
/// do `shutdown` ou vier um cabeçalho quebrado.
pub fn serve(s: *Server, io: Io) u8 {
    var framer: lsp.Framer = .{};
    defer framer.deinit(s.gpa);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(s.gpa);
    var buf: [16 * 1024]u8 = undefined;
    while (true) {
        const got = io.read(io.ctx, &buf);
        if (got == 0) return s.exit_code orelse @intFromBool(!s.shutdown);
        framer.feed(s.gpa, buf[0..got]) catch return 1;
        while (framer.next() catch return 1) |body| {
            out.clearRetainingCapacity();
            // Sem memória no meio de uma resposta: nada sai (nunca um quadro pela metade).
            s.handle(body, &out) catch out.clearRetainingCapacity();
            if (out.items.len > 0 and !io.write(io.ctx, out.items)) return 1;
            if (s.exit_code) |code| return code;
        }
    }
}

const Lookup = struct {
    order: [4][]const u8 = undefined,
    dirs: bases.Dirs = undefined,
};

fn frame(out: *std.ArrayList(u8), gpa: std.mem.Allocator, body: []const u8) !void {
    try out.print(gpa, "Content-Length: {d}\r\n\r\n", .{body.len});
    try out.appendSlice(gpa, body);
}

fn writeId(b: *std.ArrayList(u8), gpa: std.mem.Allocator, id: ?Value) !void {
    const v = id orelse return b.appendSlice(gpa, "null");
    switch (v) {
        .integer => |n| try b.print(gpa, "{d}", .{n}),
        .string => |x| try jsonx.writeString(b, gpa, x),
        else => try b.appendSlice(gpa, "null"),
    }
}

fn notifyDiagnostics(gpa: std.mem.Allocator, out: *std.ArrayList(u8), uri: []const u8, list: []const u8) !void {
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(gpa);
    try b.appendSlice(gpa, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":");
    try jsonx.writeString(&b, gpa, uri);
    try b.print(gpa, ",\"diagnostics\":{s}}}}}", .{list});
    try frame(out, gpa, b.items);
}

/// Caminho de um `file://` (para achar a base de `extends` na mesma pasta), com os `%20`
/// desfeitos.
pub fn uriPath(a: std.mem.Allocator, uri: []const u8) ![]const u8 {
    if (!std.mem.startsWith(u8, uri, "file://")) return uri;
    const raw = uri["file://".len..];
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] == '%' and i + 2 < raw.len) if (std.fmt.parseInt(u8, raw[i + 1 .. i + 3], 16)) |b| {
            try out.append(a, b);
            i += 2;
            continue;
        } else |_| {};
        try out.append(a, raw[i]);
    }
    var p = out.items;
    // file:///C:/… no Windows.
    if (p.len >= 3 and p[0] == '/' and p[2] == ':') p = p[1..];
    return p;
}

/// Linha e coluna do LSP (a partir de 0, coluna em UTF-16) → byte no texto.
fn offsetOf(text: []const u8, line: i64, character: i64) usize {
    if (line < 0) return 0;
    var start: usize = 0;
    var l: i64 = 0;
    while (l < line) : (l += 1) {
        const nl = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse return text.len;
        start = nl + 1;
    }
    const line_text = lsp.lineAt(text[start..], 0) orelse "";
    return start + lsp.utf16ToByte(line_text, @intCast(@max(character, 0)));
}

/// Byte de uma linha → coluna em UTF-16.
fn utf16Col(line: []const u8, byte: usize) usize {
    var units: usize = 0;
    var i: usize = 0;
    while (i < byte and i < line.len) {
        const n = std.unicode.utf8ByteSequenceLength(line[i]) catch 1;
        units += if (n == 4) 2 else 1;
        i += n;
    }
    return units;
}

fn isWord(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '#' or ch >= 0x80;
}

fn writeDiagnostic(b: *std.ArrayList(u8), gpa: std.mem.Allocator, text: []const u8, it: schema.Issue) !void {
    var line0: usize = if (it.line > 0) it.line - 1 else 0;
    var line = lsp.lineAt(text, line0) orelse "";
    var start: usize = @min(if (it.col > 0) it.col - 1 else 0, line.len);
    var end: usize = start;
    while (end < line.len and isWord(line[end])) end += 1;
    if (end == start) end = @min(start + 1, line.len);
    // De uma base de `extends`: a linha e a coluna são do outro arquivo (vão na mensagem), e
    // o sublinhado fica no `extends` deste.
    if (it.file.len > 0) {
        const at = extendsLine(text);
        line0 = if (at) |x| x.line else 0;
        line = lsp.lineAt(text, line0) orelse "";
        start = if (at) |x| x.start else 0;
        end = if (at) |x| x.end else @min(1, line.len);
    }
    try b.print(gpa, "{{\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}},\"severity\":{d},\"source\":\"larpercord\",\"message\":", .{
        line0, utf16Col(line, start), line0, utf16Col(line, end), @as(u8, if (it.severity == .@"error") 1 else 2),
    });
    if (it.file.len > 0) {
        const msg = try std.fmt.allocPrint(gpa, "{s}:{d}:{d}: {s}", .{ it.file, it.line, it.col, it.message });
        defer gpa.free(msg);
        try jsonx.writeString(b, gpa, msg);
    } else try jsonx.writeString(b, gpa, it.message);
    try b.append(gpa, '}');
}

/// A linha do `extends` no documento (a partir de 0), do começo do nó ao fim da linha.
fn extendsLine(text: []const u8) ?struct { line: usize, start: usize, end: usize } {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var i: usize = 0;
    while (lines.next()) |raw| : (i += 1) {
        const t = std.mem.trimEnd(u8, raw, " \t\r");
        const lead = t.len - std.mem.trimStart(u8, t, " \t").len;
        if (std.mem.startsWith(u8, t[lead..], "extends")) return .{ .line = i, .start = lead, .end = t.len };
    }
    return null;
}

// --- Onde está o cursor -----------------------------------------------------------------

const max_depth = 32;

pub const Where = enum { none, node_name, prop_name, value, in_string };

pub const Context = struct {
    /// Blocos abertos, de fora para dentro (`layout`, `row`, …).
    path: [max_depth][]const u8 = undefined,
    depth: usize = 0,
    /// O nó da linha do cursor (já escrito antes dele).
    node: []const u8 = "",
    where: Where = .none,
    /// O pedaço que já foi digitado (para filtrar).
    word: []const u8 = "",
    /// Em `value` e `in_string`: a propriedade (vazia num argumento).
    key: []const u8 = "",
    /// Em `in_string`: a string até o cursor.
    prefix: []const u8 = "",

    pub fn parent(c: *const Context) []const u8 {
        return if (c.depth > 0) c.path[c.depth - 1] else "";
    }

    pub fn inLayout(c: *const Context) bool {
        return c.depth > 0 and std.mem.eql(u8, c.path[0], "layout");
    }
};

/// Lê o texto até `offset` como o parser lê, sem precisar que ele esteja certo: o que está
/// aberto, o nó da linha e o que vem antes do cursor.
pub fn contextAt(text: []const u8, offset_in: usize) Context {
    const offset = @min(offset_in, text.len);
    var c: Context = .{};
    var stmt_name: ?[]const u8 = null;
    var tok_start: ?usize = null;
    var last_tok: []const u8 = "";
    var i: usize = 0;
    while (i < offset) {
        const ch = text[i];
        if (ch == '/' and i + 1 < text.len and text[i + 1] == '/') {
            const nl = std.mem.indexOfScalarPos(u8, text, i, '\n') orelse text.len;
            if (nl >= offset) return .{};
            i = nl;
            continue;
        }
        if (ch == '/' and i + 1 < text.len and text[i + 1] == '*') {
            const close = std.mem.indexOfPos(u8, text, i + 2, "*/") orelse return .{};
            if (close + 2 > offset) return .{};
            i = close + 2;
            continue;
        }
        if (ch == '"') {
            const key = if (tok_start) |ts| text[ts..i] else "";
            tok_start = null;
            var j = i + 1;
            while (j < text.len and text[j] != '"') : (j += 1) {
                if (text[j] == '\\') j += 1;
            }
            if (j >= offset) {
                c.where = .in_string;
                c.node = stmt_name orelse "";
                c.key = if (std.mem.endsWith(u8, key, "=")) key[0 .. key.len - 1] else "";
                c.prefix = text[i + 1 .. offset];
                return c;
            }
            const str = text[i .. j + 1];
            if (stmt_name == null and key.len == 0) stmt_name = str[1 .. str.len - 1];
            last_tok = str;
            i = j + 1;
            continue;
        }
        const boundary = ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n' or ch == ';' or ch == '{' or ch == '}' or ch == '\\';
        if (boundary) {
            if (tok_start) |ts| {
                if (stmt_name == null) stmt_name = text[ts..i];
                last_tok = text[ts..i];
                tok_start = null;
            }
            switch (ch) {
                '{' => {
                    if (c.depth < max_depth) {
                        c.path[c.depth] = stmt_name orelse "";
                        c.depth += 1;
                    }
                    stmt_name = null;
                },
                '}' => {
                    if (c.depth > 0) c.depth -= 1;
                    stmt_name = null;
                },
                '\n', ';' => stmt_name = null,
                '\\' => {
                    // Continuação: a linha de baixo é do mesmo nó.
                    const nl = std.mem.indexOfScalarPos(u8, text, i, '\n') orelse text.len;
                    if (nl >= offset) return .{};
                    i = nl + 1;
                    continue;
                },
                else => {},
            }
            i += 1;
            continue;
        }
        if (tok_start == null) tok_start = i;
        i += 1;
    }
    const partial = if (tok_start) |ts| text[ts..offset] else "";
    c.node = stmt_name orelse "";
    if (stmt_name == null) {
        c.where = .node_name;
        c.word = partial;
    } else if (std.mem.indexOfScalar(u8, partial, '=')) |eq| {
        c.where = .value;
        c.key = partial[0..eq];
        c.word = partial[eq + 1 ..];
    } else {
        c.where = .prop_name;
        c.word = partial;
    }
    return c;
}

/// O nó do esquema da linha do cursor, pelo caminho até ela.
pub fn specFor(c: *const Context) ?*const schema.NodeSpec {
    if (c.depth == 0) return schema.topSpec(c.node);
    const parent = c.parent();
    if (schema.childSpec(parent, c.node)) |s| return s;
    if (c.inLayout()) return schema.layoutSpec(c.node);
    return null;
}

// --- Completar --------------------------------------------------------------------------

const Kind = enum(u8) { variable = 6, class = 7, property = 10, value = 12, keyword = 14, color = 16, enum_member = 20 };

const Items = struct {
    a: std.mem.Allocator,
    out: *std.ArrayList(u8),
    n: usize = 0,

    fn add(it: *Items, label: []const u8, kind: Kind, detail: []const u8, doc: []const u8) !void {
        try it.out.appendSlice(it.a, if (it.n == 0) "{\"isIncomplete\":false,\"items\":[" else ",");
        it.n += 1;
        try it.out.appendSlice(it.a, "{\"label\":");
        try jsonx.writeString(it.out, it.a, label);
        try it.out.print(it.a, ",\"kind\":{d}", .{@intFromEnum(kind)});
        if (detail.len > 0) {
            try it.out.appendSlice(it.a, ",\"detail\":");
            try jsonx.writeString(it.out, it.a, detail);
        }
        if (doc.len > 0) {
            try it.out.appendSlice(it.a, ",\"documentation\":");
            try jsonx.writeString(it.out, it.a, doc);
        }
        try it.out.append(it.a, '}');
    }

    fn finish(it: *Items) !void {
        if (it.n == 0) try it.out.appendSlice(it.a, "{\"isIncomplete\":false,\"items\":[");
        try it.out.appendSlice(it.a, "]}");
    }
};

/// Nomes que o documento define: opções, estilos e variáveis (com os da base de `extends`
/// quando o tema carrega; senão, o que dá para achar no texto).
pub const Names = struct {
    options: std.ArrayList([]const u8) = .empty,
    styles: std.ArrayList([]const u8) = .empty,
    vars: std.ArrayList([]const u8) = .empty,
};

pub fn namesOf(s: *const Server, a: std.mem.Allocator, uri: []const u8, text: []const u8, offset: usize) !Names {
    var out: Names = .{};
    var look: Lookup = .{};
    const lo = try s.baseOptions(a, uri, &look);
    // Enquanto a pessoa digita, a linha do cursor quase nunca fecha (`sheen="$`): sem ela, e
    // com os blocos abertos fechados, o resto do tema costuma carregar.
    const before = upToLine(a, text, offset) catch text;
    var t = theme.loadWith(a, text, lo, null) catch theme.loadWith(a, before, lo, null) catch {
        try scanNames(a, before, &out);
        // O texto ainda não fecha (está sendo digitado): os nomes da base de `extends` valem igual.
        const name = extendsName(text) orelse return out;
        const b = lo.bases orelse return out;
        var i: usize = 0;
        while (b.find(b.ctx, a, name, i)) |base| : (i += 1) {
            if (std.mem.eql(u8, base.id, lo.self)) continue;
            var bt = theme.loadWith(a, base.src, .{ .bases = lo.bases, .self = base.id }, null) catch return out;
            defer bt.deinit();
            try addNames(a, &bt, &out);
            break;
        }
        return out;
    };
    defer t.deinit();
    try addNames(a, &t, &out);
    return out;
}

/// O texto até o começo da linha do cursor, com um `}` para cada bloco aberto ali.
fn upToLine(a: std.mem.Allocator, text: []const u8, offset: usize) ![]const u8 {
    const at = @min(offset, text.len);
    const start = if (std.mem.lastIndexOfScalar(u8, text[0..at], '\n')) |nl| nl + 1 else 0;
    const open = contextAt(text, start).depth;
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, text[0..start]);
    for (0..open) |_| try out.appendSlice(a, "}\n");
    return out.items;
}

fn addNames(a: std.mem.Allocator, t: *const theme.Theme, out: *Names) !void {
    for (t.options) |o| try out.options.append(a, try a.dupe(u8, o.name));
    var it = t.styles.keyIterator();
    while (it.next()) |k| try out.styles.append(a, try a.dupe(u8, k.*));
    for (t.var_names) |v| try out.vars.append(a, try a.dupe(u8, v));
}

/// O nome em `extends "nome"`, procurado linha por linha (o texto pode não abrir no parser).
fn extendsName(text: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, "extends \"")) continue;
        const rest = line["extends \"".len..];
        const end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
        return rest[0..end];
    }
    return null;
}

/// Sem um tema que carregue: `option "x"`, `style "x"` e os filhos de `vars { … }` no texto.
fn scanNames(a: std.mem.Allocator, text: []const u8, out: *Names) !void {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    if (kdl.parse(arena.allocator(), text, null)) |nodes| {
        for (nodes) |*n| {
            const list = if (std.mem.eql(u8, n.name, "options")) &out.options else if (std.mem.eql(u8, n.name, "styles")) &out.styles else if (std.mem.eql(u8, n.name, "vars")) &out.vars else continue;
            for (n.children) |*ch| {
                const name = if (list == &out.vars) ch.name else (if (ch.arg(0)) |v| v.asString() orelse continue else continue);
                try list.append(a, try a.dupe(u8, name));
            }
        }
        return;
    } else |_| {}
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        for ([_]struct { []const u8, *std.ArrayList([]const u8) }{ .{ "option \"", &out.options }, .{ "style \"", &out.styles } }) |p| {
            if (!std.mem.startsWith(u8, line, p[0])) continue;
            const rest = line[p[0].len..];
            const end = std.mem.indexOfScalar(u8, rest, '"') orelse continue;
            try p[1].append(a, try a.dupe(u8, rest[0..end]));
        }
    }
}

fn completion(s: *const Server, a: std.mem.Allocator, uri: []const u8, text: []const u8, offset: usize, out: *std.ArrayList(u8)) !void {
    var it: Items = .{ .a = a, .out = out };
    defer it.finish() catch {};
    const c = contextAt(text, offset);
    switch (c.where) {
        .none => {},
        .node_name => try nodeNames(&it, &c),
        .prop_name => {
            const spec = specFor(&c) orelse return;
            for (spec.props) |*p| try propItem(&it, p);
            for (spec.sets) |set| for (schema.setProps(set)) |*p| try propItem(&it, p);
            if (schema.takesPatterns(spec)) for (schema.patterns) |pt| {
                if (!std.mem.startsWith(u8, c.word, pt.prefix)) continue;
                for (schema.token_names) |tok| try it.add(try std.fmt.allocPrint(a, "{s}{s}", .{ pt.prefix, tok }), .property, "color", pt.desc);
            };
        },
        .value => {
            const spec = specFor(&c) orelse return;
            const p = schema.findProp(spec, c.key) orelse return;
            const names = try namesOf(s, a, uri, text, offset);
            try values(&it, a, p, &names, false);
            for (names.vars.items) |v| try it.add(try std.fmt.allocPrint(a, "${s}", .{v}), .variable, "variable", "");
        },
        .in_string => {
            const names = try namesOf(s, a, uri, text, offset);
            // O pedaço depois do último separador: `mix(@sur` → `@sur`.
            var k = c.prefix.len;
            while (k > 0 and !(c.prefix[k - 1] == ' ' or c.prefix[k - 1] == '(' or c.prefix[k - 1] == ',')) k -= 1;
            const piece = c.prefix[k..];
            if (std.mem.startsWith(u8, piece, "@")) {
                for (schema.token_names, 0..) |tok, i| try it.add(tok, .color, "color token", schema.token_desc.values[i]);
            } else if (std.mem.startsWith(u8, piece, "$")) {
                for (names.vars.items) |v| try it.add(v, .variable, "variable", "");
                for (names.options.items) |o| try it.add(o, .variable, "option", "");
                if (std.mem.startsWith(u8, piece, "$!")) {} else for (names.options.items) |o| try it.add(try std.fmt.allocPrint(a, "!{s}", .{o}), .variable, "option, inverted", "");
            } else if (c.key.len > 0) {
                const spec = specFor(&c) orelse return;
                const p = schema.findProp(spec, c.key) orelse return;
                try values(&it, a, p, &names, true);
            }
        },
    }
}

fn nodeNames(it: *Items, c: *const Context) !void {
    if (c.depth == 0) {
        for (&schema.top) |*s| try it.add(s.name, .class, "top-level node", s.desc);
        return;
    }
    const parent = c.parent();
    const children: schema.Children = if (c.depth == 1) (if (schema.topSpec(parent)) |s| s.children else .none) else if (schema.childSpec(c.path[c.depth - 2], parent)) |s| s.children else if (c.inLayout()) (if (schema.layoutSpec(parent)) |s| s.children else .none) else .none;
    switch (children) {
        .layout, .layout_root => {
            for (&schema.containers) |*s| try it.add(s.name, .class, "container", s.desc);
            for (&schema.components) |*s| try it.add(s.name, .class, "component", s.desc);
        },
        .named => |names| for (names) |n| {
            const s = schema.childSpec(parent, n);
            try it.add(n, .class, "", if (s) |x| x.desc else "");
        },
        .tokens => for (schema.token_names, 0..) |tok, i| try it.add(tok, .color, "color token", schema.token_desc.values[i]),
        .free, .none => {},
    }
}

fn propItem(it: *Items, p: *const schema.Prop) !void {
    try it.add(p.key, .property, @tagName(p.kind), p.desc);
}

/// Os valores de uma propriedade. `quoted`: já dentro das aspas (sem pôr aspas de novo).
fn values(it: *Items, a: std.mem.Allocator, p: *const schema.Prop, names: *const Names, quoted: bool) !void {
    switch (p.kind) {
        .@"enum", .words => for (p.values) |v| try it.add(v, .enum_member, p.key, ""),
        .boolean => {
            if (!quoted) {
                try it.add("#true", .keyword, p.key, "");
                try it.add("#false", .keyword, p.key, "");
            }
            if (p.option_ref) for (names.options.items) |o| {
                try it.add(if (quoted) try std.fmt.allocPrint(a, "${s}", .{o}) else try std.fmt.allocPrint(a, "\"${s}\"", .{o}), .variable, "option", "");
            };
        },
        .style => for (names.styles.items) |st| try it.add(st, .value, "style", ""),
        .option => {
            for (names.options.items) |o| try it.add(o, .value, "option", "");
            try it.add("modo-claro", .value, "light mode", "");
            try it.add("modo-escuro", .value, "dark mode", "");
        },
        .color, .token => for (schema.token_names, 0..) |tok, i| try it.add(tok, .color, "color token", schema.token_desc.values[i]),
        .font => {
            try it.add("mono", .value, "the theme's mono font", "");
            try it.add("ui", .value, "the theme's interface font", "");
        },
        .number, .string, .colors => {},
    }
}

// --- Passar o mouse ---------------------------------------------------------------------

fn hover(a: std.mem.Allocator, text: []const u8, offset: usize, md: *std.ArrayList(u8)) !void {
    if (offset > text.len) return;
    var start = offset;
    while (start > 0 and (isWord(text[start - 1]) or text[start - 1] == '@')) start -= 1;
    var end = offset;
    while (end < text.len and isWord(text[end])) end += 1;
    if (end == start) return;
    const word = text[start..end];
    if (word[0] == '@') return tokenDoc(a, word[1..], md);
    const c = contextAt(text, start);
    const is_prop = end < text.len and text[end] == '=';
    if (is_prop and c.where == .prop_name) {
        var cc = c;
        cc.word = word;
        const spec = specFor(&cc) orelse return;
        if (schema.findProp(spec, word)) |p| return propDoc(a, p, md);
        if (schema.takesPatterns(spec)) for (schema.patterns) |pt| if (std.mem.startsWith(u8, word, pt.prefix)) {
            return md.print(a, "**{s}** (color)\n\n{s}", .{ word, pt.desc });
        };
        return;
    }
    if (c.where == .node_name) {
        var cc = c;
        cc.node = word;
        if (c.depth > 0 and std.mem.eql(u8, c.parent(), "colors")) return tokenDoc(a, word, md);
        const spec = specFor(&cc) orelse return;
        try md.print(a, "**{s}**\n\n{s}", .{ spec.name, spec.desc });
    }
}

fn tokenDoc(a: std.mem.Allocator, name: []const u8, md: *std.ArrayList(u8)) !void {
    for (schema.token_names, 0..) |tok, i| if (std.mem.eql(u8, tok, name)) {
        return md.print(a, "**@{s}** (color token)\n\n{s}", .{ tok, schema.token_desc.values[i] });
    };
}

fn propDoc(a: std.mem.Allocator, p: *const schema.Prop, md: *std.ArrayList(u8)) !void {
    try md.print(a, "**{s}** ({s}", .{ p.key, @tagName(p.kind) });
    if (p.min != null and p.max != null) try md.print(a, ", {d} to {d}", .{ p.min.?, p.max.? }) else if (p.min) |x| try md.print(a, ", at least {d}", .{x});
    switch (p.default) {
        .none => {},
        .num => |x| try md.print(a, ", default {d}", .{x}),
        .flag => |b| try md.print(a, ", default {s}", .{if (b) "#true" else "#false"}),
        .text => |s| try md.print(a, ", default {s}", .{s}),
    }
    try md.print(a, ")\n\n{s}", .{p.desc});
    if (p.values.len > 0) {
        try md.appendSlice(a, "\n\nValues: ");
        for (p.values, 0..) |v, i| try md.print(a, "{s}`{s}`", .{ if (i > 0) ", " else "", v });
    }
    if (p.option_ref) try md.appendSlice(a, "\n\nAlso takes \"$option\" (or \"$!option\") from the theme's options.");
}

// --- Testes -------------------------------------------------------------------------------

const testing = std.testing;

/// Uma sessão de mentira: manda as mensagens e devolve o que saiu, quadro a quadro.
fn session(s: *Server, bodies: []const []const u8, out: *std.ArrayList(u8)) !void {
    for (bodies) |b| try s.handle(b, out);
}

fn frames(gpa: std.mem.Allocator, raw: []const u8) !std.ArrayList([]const u8) {
    var list: std.ArrayList([]const u8) = .empty;
    var f: lsp.Framer = .{};
    defer f.deinit(gpa);
    try f.feed(gpa, raw);
    while (try f.next()) |body| try list.append(gpa, try gpa.dupe(u8, body));
    return list;
}

test "sessão: initialize, diagnósticos com linha e coluna, completar, hover, shutdown e exit" {
    const gpa = testing.allocator;
    var s: Server = .{ .gpa = gpa };
    defer s.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const doc =
        \\options { option "brilho" label="Brilho" }
        \\styles { style "card" bg="@surface" }
        \\layout {
        \\    row {
        \\        messages varient=cozy
        \\        composer variant=box
        \\    }
        \\}
    ;
    // A pessoa apaga o valor para escolher outro: `composer variant=` não fecha.
    const half =
        \\options { option "brilho" label="Brilho" }
        \\styles { style "card" bg="@surface" }
        \\layout {
        \\    row {
        \\        messages varient=cozy
        \\        composer variant=
        \\    }
        \\}
    ;
    const open = try didOpen(gpa, "file:///tmp/t.kdl", doc);
    defer gpa.free(open);
    const change = try didChange(gpa, "file:///tmp/t.kdl", half);
    defer gpa.free(change);
    try session(&s, &.{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"capabilities\":{}}}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"initialized\",\"params\":{}}",
        open,
        change,
        // `composer variant=` → os valores do variant.
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file:///tmp/t.kdl\"},\"position\":{\"line\":5,\"character\":25}}}",
        // Começo de uma linha dentro do row → contêineres e componentes.
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file:///tmp/t.kdl\"},\"position\":{\"line\":4,\"character\":8}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file:///tmp/t.kdl\"},\"position\":{\"line\":4,\"character\":10}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"textDocument/formatting\",\"params\":{}}",
        "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"shutdown\"}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}",
    }, &out);
    var fs = try frames(gpa, out.items);
    defer {
        for (fs.items) |f| gpa.free(f);
        fs.deinit(gpa);
    }
    try testing.expectEqual(@as(usize, 8), fs.items.len);
    try testing.expect(std.mem.indexOf(u8, fs.items[0], "\"hoverProvider\":true") != null);
    // O aviso do `varient`, na linha 4 (a partir de 0), coluna 17, até o fim da palavra.
    const d = fs.items[1];
    try testing.expect(std.mem.indexOf(u8, d, "publishDiagnostics") != null);
    try testing.expect(std.mem.indexOf(u8, d, "{\"start\":{\"line\":4,\"character\":17},\"end\":{\"line\":4,\"character\":24}}") != null);
    try testing.expect(std.mem.indexOf(u8, d, "did you mean 'variant'") != null);
    try testing.expect(std.mem.indexOf(u8, d, "\"severity\":2") != null);
    // Pela metade, o erro de sintaxe na linha do `variant=` (o aviso volta quando fechar).
    const e = fs.items[2];
    try testing.expectEqual(@as(usize, 1), count(e, "\"range\""));
    try testing.expect(std.mem.indexOf(u8, e, "\"severity\":1") != null);
    try testing.expect(std.mem.indexOf(u8, e, "\"start\":{\"line\":5,") != null);
    try testing.expect(std.mem.indexOf(u8, fs.items[3], "\"label\":\"pill\"") != null);
    try testing.expect(std.mem.indexOf(u8, fs.items[3], "\"label\":\"prompt\"") != null);
    try testing.expect(std.mem.indexOf(u8, fs.items[4], "\"label\":\"guild-bar\"") != null);
    try testing.expect(std.mem.indexOf(u8, fs.items[4], "\"label\":\"column\"") != null);
    try testing.expect(std.mem.indexOf(u8, fs.items[5], "The conversation") != null);
    try testing.expect(std.mem.indexOf(u8, fs.items[6], "-32601") != null);
    try testing.expect(std.mem.indexOf(u8, fs.items[7], "\"id\":6,\"result\":null") != null);
    try testing.expectEqual(@as(?u8, 0), s.exit_code);
}

test "contexto: nó, propriedade, valor, string e @token" {
    const t =
        \\colors {
        \\    accent "mix(@sur
    ;
    var c = contextAt(t, t.len);
    try testing.expectEqual(Where.in_string, c.where);
    try testing.expectEqualStrings("colors", c.parent());
    try testing.expectEqualStrings("accent", c.node);
    try testing.expectEqualStrings("mix(@sur", c.prefix);

    const t2 = "layout {\n  row gap=4 {\n    messages ava";
    c = contextAt(t2, t2.len);
    try testing.expectEqual(Where.prop_name, c.where);
    try testing.expectEqualStrings("messages", c.node);
    try testing.expectEqualStrings("ava", c.word);
    try testing.expectEqual(@as(usize, 2), c.depth);
    try testing.expect(specFor(&c) != null);

    const t3 = "styles {\n  style \"card\" sheen=";
    c = contextAt(t3, t3.len);
    try testing.expectEqual(Where.value, c.where);
    try testing.expectEqualStrings("sheen", c.key);
    try testing.expectEqualStrings("style", specFor(&c).?.name);

    // Um comentário com chaves não abre bloco.
    const t4 = "// layout {\nfon";
    c = contextAt(t4, t4.len);
    try testing.expectEqual(Where.node_name, c.where);
    try testing.expectEqual(@as(usize, 0), c.depth);
}

test "caminho do file:// com %20 e com letra de unidade" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("/home/a b/t.kdl", try uriPath(arena.allocator(), "file:///home/a%20b/t.kdl"));
    try testing.expectEqualStrings("c:/x/t.kdl", try uriPath(arena.allocator(), "file:///c%3A/x/t.kdl"));
}

test "a base de extends vem dos temas embutidos: completar acha as opções e os estilos dela" {
    const gpa = testing.allocator;
    var s: Server = .{ .gpa = gpa };
    defer s.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    // O terminal tem a opção "crt": um filho dele a vê em `when=`.
    const doc = "extends \"terminal\"\nlayout { column { crt when=";
    var out: std.ArrayList(u8) = .empty;
    try completion(&s, arena.allocator(), "file:///tmp/filho.kdl", doc, doc.len, &out);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"label\":\"crt\"") != null);
}

test "completar $ dentro de uma string traz opções e variáveis; @ traz os tokens" {
    const gpa = testing.allocator;
    var s: Server = .{ .gpa = gpa };
    defer s.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const doc = "options { option \"brilho\" }\nvars { borda 2 }\nstyles { style \"card\" sheen=\"$";
    var out: std.ArrayList(u8) = .empty;
    try completion(&s, a, "file:///x.kdl", doc, doc.len, &out);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"label\":\"brilho\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"label\":\"borda\"") != null);
    out.clearRetainingCapacity();
    const doc2 = "colors { accent \"alpha(@";
    try completion(&s, a, "file:///x.kdl", doc2, doc2.len, &out);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"label\":\"bubble-self-text\"") != null);
}

/// A entrada e a saída padrão de mentira: a entrada sai em pedaços de `chunk` bytes (uma
/// mensagem cortada no meio do cabeçalho ou do corpo, ou várias num pedaço só); a saída
/// guarda tudo.
const FakeIo = struct {
    gpa: std.mem.Allocator,
    in: []const u8,
    at: usize = 0,
    chunk: usize,
    out: std.ArrayList(u8) = .empty,
    /// A saída fecha depois de tantas escritas (null = nunca).
    writes_left: ?usize = null,

    fn read(ctx: *anyopaque, buf: []u8) usize {
        const f: *FakeIo = @ptrCast(@alignCast(ctx));
        const n = @min(f.chunk, buf.len, f.in.len - f.at);
        @memcpy(buf[0..n], f.in[f.at..][0..n]);
        f.at += n;
        return n;
    }

    fn write(ctx: *anyopaque, bytes: []const u8) bool {
        const f: *FakeIo = @ptrCast(@alignCast(ctx));
        if (f.writes_left) |*w| {
            if (w.* == 0) return false;
            w.* -= 1;
        }
        f.out.appendSlice(f.gpa, bytes) catch return false;
        return true;
    }

    fn io(f: *FakeIo) Io {
        return .{ .ctx = f, .read = read, .write = write };
    }
};

/// As mensagens com o cabeçalho, como um editor manda.
fn wire(gpa: std.mem.Allocator, bodies: []const []const u8) !std.ArrayList(u8) {
    var in: std.ArrayList(u8) = .empty;
    for (bodies) |b| try frame(&in, gpa, b);
    return in;
}

fn didOpen(gpa: std.mem.Allocator, uri: []const u8, text: []const u8) ![]u8 {
    var b: std.ArrayList(u8) = .empty;
    try b.appendSlice(gpa, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"");
    try b.appendSlice(gpa, uri);
    try b.appendSlice(gpa, "\",\"languageId\":\"kdl\",\"version\":1,\"text\":");
    try jsonx.writeString(&b, gpa, text);
    try b.appendSlice(gpa, "}}}");
    return b.toOwnedSlice(gpa);
}

fn didChange(gpa: std.mem.Allocator, uri: []const u8, text: []const u8) ![]u8 {
    var b: std.ArrayList(u8) = .empty;
    try b.appendSlice(gpa, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"");
    try b.appendSlice(gpa, uri);
    try b.appendSlice(gpa, "\",\"version\":2},\"contentChanges\":[{\"text\":");
    try jsonx.writeString(&b, gpa, text);
    try b.appendSlice(gpa, "}]}}");
    return b.toOwnedSlice(gpa);
}

fn count(hay: []const u8, needle: []const u8) usize {
    return std.mem.count(u8, hay, needle);
}

test "entrada e saída padrão de mentira: theme-api 2 dá erro, 1 dá aviso, completar, hover e exit" {
    const gpa = testing.allocator;
    const uri = "file:///tmp/estrito.kdl";
    // A linha 5 tem acento e um emoji antes do nome errado: a coluna sai em UTF-16.
    const body =
        \\layout {
        \\  row {
        \\    messages varient=cozy
        \\    composer variant=box
        \\    label text="pão 🍞" tamanho=1
        \\  }
        \\}
    ;
    const open = try didOpen(gpa, uri, "theme-api 2\n" ++ body);
    defer gpa.free(open);
    const change = try didChange(gpa, uri, "theme-api 1\n" ++ body);
    defer gpa.free(change);
    var in = try wire(gpa, &.{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"capabilities\":{}}}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"initialized\",\"params\":{}}",
        open,
        // Logo depois de `messages `: as propriedades dele.
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file:///tmp/estrito.kdl\"},\"position\":{\"line\":3,\"character\":13}}}",
        // O mouse em `variant` do composer.
        "{\"jsonrpc\":\"2.0\",\"id\":\"h\",\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file:///tmp/estrito.kdl\"},\"position\":{\"line\":4,\"character\":15}}}",
        change,
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"shutdown\"}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}",
        // Depois do exit, nada mais é lido.
        "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"shutdown\"}",
    });
    defer in.deinit(gpa);
    // Em pedaços de 7 bytes e tudo de uma vez: o mesmo resultado.
    for ([_]usize{ 7, in.items.len }) |chunk| {
        var s: Server = .{ .gpa = gpa };
        defer s.deinit();
        var f: FakeIo = .{ .gpa = gpa, .in = in.items, .chunk = chunk };
        defer f.out.deinit(gpa);
        try testing.expectEqual(@as(u8, 0), serve(&s, f.io()));
        var fs = try frames(gpa, f.out.items);
        defer {
            for (fs.items) |x| gpa.free(x);
            fs.deinit(gpa);
        }
        try testing.expectEqual(@as(usize, 6), fs.items.len);
        try testing.expect(std.mem.indexOf(u8, fs.items[0], "\"id\":1,\"result\":{\"capabilities\"") != null);
        // Estrito: os dois nomes desconhecidos são erros (severity 1), com linha e coluna.
        const strict = fs.items[1];
        try testing.expectEqual(@as(usize, 2), count(strict, "\"range\""));
        try testing.expectEqual(@as(usize, 2), count(strict, "\"severity\":1"));
        try testing.expect(std.mem.indexOf(u8, strict, "{\"start\":{\"line\":3,\"character\":13},\"end\":{\"line\":3,\"character\":20}}") != null);
        try testing.expect(std.mem.indexOf(u8, strict, "{\"start\":{\"line\":5,\"character\":24},\"end\":{\"line\":5,\"character\":31}}") != null);
        try testing.expect(std.mem.indexOf(u8, strict, "unknown property 'tamanho' on label") != null);
        try testing.expect(std.mem.indexOf(u8, fs.items[2], "\"id\":2") != null);
        try testing.expect(std.mem.indexOf(u8, fs.items[2], "\"label\":\"variant\"") != null);
        try testing.expect(std.mem.indexOf(u8, fs.items[3], "\"id\":\"h\"") != null);
        try testing.expect(std.mem.indexOf(u8, fs.items[3], "**variant** (enum") != null);
        try testing.expect(std.mem.indexOf(u8, fs.items[3], "`prompt`") != null);
        // theme-api 1: os mesmos dois, agora avisos (severity 2).
        try testing.expectEqual(@as(usize, 2), count(fs.items[4], "\"severity\":2"));
        try testing.expectEqual(@as(usize, 0), count(fs.items[4], "\"severity\":1"));
        try testing.expect(std.mem.indexOf(u8, fs.items[5], "\"id\":3,\"result\":null") != null);
    }
}

test "entrada que fecha, exit sem shutdown, cabeçalho quebrado e saída fechada" {
    const gpa = testing.allocator;
    const init_msg = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}";
    // A entrada fecha sem shutdown: 1. Depois do shutdown: 0.
    inline for (.{ .{ &[_][]const u8{init_msg}, 1 }, .{ &[_][]const u8{ init_msg, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"shutdown\"}" }, 0 } }) |case| {
        var in = try wire(gpa, case[0]);
        defer in.deinit(gpa);
        var s: Server = .{ .gpa = gpa };
        defer s.deinit();
        var f: FakeIo = .{ .gpa = gpa, .in = in.items, .chunk = 5 };
        defer f.out.deinit(gpa);
        try testing.expectEqual(@as(u8, case[1]), serve(&s, f.io()));
    }
    // exit sem shutdown: 1, na hora.
    {
        var in = try wire(gpa, &.{ init_msg, "{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}", init_msg });
        defer in.deinit(gpa);
        var s: Server = .{ .gpa = gpa };
        defer s.deinit();
        var f: FakeIo = .{ .gpa = gpa, .in = in.items, .chunk = 1 << 20 };
        defer f.out.deinit(gpa);
        try testing.expectEqual(@as(u8, 1), serve(&s, f.io()));
        try testing.expectEqual(@as(usize, 1), count(f.out.items, "Content-Length:"));
    }
    // Sem Content-Length, e JSON quebrado (esse ganha o erro -32700 e o servidor segue).
    {
        var s: Server = .{ .gpa = gpa };
        defer s.deinit();
        var f: FakeIo = .{ .gpa = gpa, .in = "Content-Type: x\r\n\r\n{}", .chunk = 64 };
        defer f.out.deinit(gpa);
        try testing.expectEqual(@as(u8, 1), serve(&s, f.io()));
        var in = try wire(gpa, &.{ "{nada", "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"shutdown\"}" });
        defer in.deinit(gpa);
        var f2: FakeIo = .{ .gpa = gpa, .in = in.items, .chunk = 3 };
        defer f2.out.deinit(gpa);
        try testing.expectEqual(@as(u8, 0), serve(&s, f2.io()));
        try testing.expect(std.mem.indexOf(u8, f2.out.items, "-32700") != null);
        try testing.expect(std.mem.indexOf(u8, f2.out.items, "\"id\":7,\"result\":null") != null);
    }
    // O editor fechou a saída: o servidor para.
    {
        var in = try wire(gpa, &.{ init_msg, init_msg });
        defer in.deinit(gpa);
        var s: Server = .{ .gpa = gpa };
        defer s.deinit();
        var f: FakeIo = .{ .gpa = gpa, .in = in.items, .chunk = 1 << 20, .writes_left = 0 };
        defer f.out.deinit(gpa);
        try testing.expectEqual(@as(u8, 1), serve(&s, f.io()));
    }
}

test "uma base de extends na pasta do arquivo: os avisos dela aparecem com o nome do arquivo" {
    const gpa = testing.allocator;
    const Disk = struct {
        fn read(a: std.mem.Allocator, path: []const u8) ?[]const u8 {
            if (!std.mem.eql(u8, path, "/temas/base-quebrada.kdl")) return null;
            return a.dupe(u8, "layout {\n  messages tamanho=3\n}") catch null;
        }
    };
    var s: Server = .{ .gpa = gpa, .read = Disk.read };
    defer s.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const open = try didOpen(gpa, "file:///temas/filho.kdl", "extends \"base-quebrada\"\ncolors { accent \"#ff0000\" }");
    defer gpa.free(open);
    try s.handle(open, &out);
    try testing.expect(std.mem.indexOf(u8, out.items, "/temas/base-quebrada.kdl:2:12: unknown property 'tamanho' on messages") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"severity\":2") != null);
    // O sublinhado fica no `extends` deste arquivo, não na linha 2 dele.
    try testing.expect(std.mem.indexOf(u8, out.items, "{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":23}}") != null);
}
