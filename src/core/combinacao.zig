//! Uma combinação de teclas ("Ctrl+Shift+P", "F2", "Alt+Enter"): o que os atalhos
//! personalizáveis guardam no settings.kdl e mostram na tela (ui/atalhos.zig e
//! ui/teclas.zig). Só texto e números: quem liga cada tecla ao ImGui é ui/teclas.zig.
//!
//! O texto é o mesmo da lista de atalhos: modificadores na ordem Ctrl, Shift, Alt,
//! separados por "+", e a tecla no fim com o nome de `Key` ("Ctrl+,", "F11",
//! "Ctrl+Tab"). Várias alternativas vêm separadas por " / " ("F2 / Ctrl+T").
const std = @import("std");

/// As teclas que um atalho pode usar (letras, números, F1..F12 e algumas outras).
pub const Key = enum {
    a, b, c, d, e, f, g, h, i, j, k, l, m, n, o, p, q, r, s, t, u, v, w, x, y, z,
    @"0", @"1", @"2", @"3", @"4", @"5", @"6", @"7", @"8", @"9",
    f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12,
    tab, enter, space, backspace, delete, insert, home, end, pageup, pagedown,
    up, down, left, right, comma, period, slash, semicolon, minus, equal, backslash, apostrophe, grave,
    escape,

    /// Como aparece na tela e no settings.kdl.
    pub fn label(key: Key) []const u8 {
        return switch (key) {
            .tab => "Tab",
            .enter => "Enter",
            .space => "Space",
            .backspace => "Backspace",
            .delete => "Delete",
            .insert => "Insert",
            .home => "Home",
            .end => "End",
            .pageup => "PageUp",
            .pagedown => "PageDown",
            .up => "↑",
            .down => "↓",
            .left => "←",
            .right => "→",
            .comma => ",",
            .period => ".",
            .slash => "/",
            .semicolon => ";",
            .minus => "-",
            .equal => "=",
            .backslash => "\\",
            .apostrophe => "'",
            .grave => "`",
            .escape => "Esc",
            inline else => |k| comptime upper(@tagName(k)),
        };
    }

    fn upper(comptime s: []const u8) []const u8 {
        var out: [s.len]u8 = undefined;
        for (s, 0..) |ch, idx| out[idx] = std.ascii.toUpper(ch);
        const final = out;
        return &final;
    }

    pub fn fromLabel(text: []const u8) ?Key {
        inline for (@typeInfo(Key).@"enum".field_names) |name| {
            const key = @field(Key, name);
            if (std.ascii.eqlIgnoreCase(text, key.label())) return key;
        }
        return null;
    }

    pub fn isF(key: Key) bool {
        return @intFromEnum(key) >= @intFromEnum(Key.f1) and @intFromEnum(key) <= @intFromEnum(Key.f12);
    }
};

pub const Combinacao = struct {
    key: Key,
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,

    pub fn eql(a: Combinacao, b: Combinacao) bool {
        return a.key == b.key and a.ctrl == b.ctrl and a.shift == b.shift and a.alt == b.alt;
    }

    /// "Ctrl+Shift+P". Devolve o pedaço usado de `buf`.
    pub fn format(cb: Combinacao, buf: []u8) []const u8 {
        var n: usize = 0;
        const parts = [_]struct { bool, []const u8 }{ .{ cb.ctrl, "Ctrl+" }, .{ cb.shift, "Shift+" }, .{ cb.alt, "Alt+" }, .{ true, cb.key.label() } };
        for (parts) |p| {
            if (!p[0]) continue;
            if (n + p[1].len > buf.len) break;
            @memcpy(buf[n..][0..p[1].len], p[1]);
            n += p[1].len;
        }
        return buf[0..n];
    }

    /// O contrário de `format`. Aceita os modificadores em qualquer ordem e sem
    /// diferença de maiúsculas; "+" sozinho no fim é a tecla de igual com Shift no
    /// teclado americano, e por isso não é aceito (use "=").
    pub fn parse(text: []const u8) ?Combinacao {
        const t = std.mem.trim(u8, text, " ");
        if (t.len == 0) return null;
        var cb: Combinacao = .{ .key = .a };
        var rest = t;
        while (true) {
            const plus = std.mem.indexOfScalar(u8, rest, '+') orelse break;
            // "Ctrl++" não existe: um "+" vazio no meio.
            if (plus == 0) return null;
            const mod = rest[0..plus];
            if (std.ascii.eqlIgnoreCase(mod, "ctrl")) {
                cb.ctrl = true;
            } else if (std.ascii.eqlIgnoreCase(mod, "shift")) {
                cb.shift = true;
            } else if (std.ascii.eqlIgnoreCase(mod, "alt")) {
                cb.alt = true;
            } else return null;
            rest = rest[plus + 1 ..];
        }
        cb.key = Key.fromLabel(rest) orelse return null;
        return cb;
    }

    /// Serve de atalho global: com Ctrl ou Alt, ou uma tecla F (uma letra sozinha
    /// dispararia ao digitar).
    pub fn usable(cb: Combinacao) bool {
        return cb.ctrl or cb.alt or cb.key.isF();
    }
};

/// As alternativas de "F2 / Ctrl+T", até `out.len`. As que não forem combinação de
/// verdade ("Ctrl+Click", "Alt+1…9") ficam de fora.
pub fn parseList(text: []const u8, out: []Combinacao) []Combinacao {
    var n: usize = 0;
    var it = std.mem.splitSequence(u8, text, " / ");
    while (it.next()) |piece| {
        if (n == out.len) break;
        if (Combinacao.parse(piece)) |cb| {
            out[n] = cb;
            n += 1;
        }
    }
    return out[0..n];
}

// --- Testes -----------------------------------------------------------------

test "combinação: vai para texto e volta, como na lista de atalhos" {
    var buf: [32]u8 = undefined;
    for ([_][]const u8{ "Ctrl+K", "Ctrl+Shift+P", "Ctrl+,", "F11", "Alt+Enter", "Ctrl+Shift+Tab", "Shift+F2" }) |t| {
        const cb = Combinacao.parse(t) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(t, cb.format(&buf));
    }
    // Ordem e maiúsculas livres na entrada; a saída é sempre a mesma.
    try std.testing.expectEqualStrings("Ctrl+Shift+M", (Combinacao.parse("shift+ctrl+m") orelse unreachable).format(&buf));
    try std.testing.expect(Combinacao.parse("Ctrl+Shift+M").?.eql(Combinacao.parse("SHIFT+CTRL+M").?));
}

test "combinação: o que não é combinação não passa" {
    for ([_][]const u8{ "", "Ctrl+", "Ctrl++", "Hyper+K", "Ctrl+Click", "Alt+1…9", "Ctrl+KK" }) |t|
        try std.testing.expect(Combinacao.parse(t) == null);
}

test "lista de alternativas e o que serve de atalho global" {
    var out: [4]Combinacao = undefined;
    const l = parseList("F2 / Ctrl+T", &out);
    try std.testing.expectEqual(@as(usize, 2), l.len);
    try std.testing.expectEqual(Key.f2, l[0].key);
    try std.testing.expect(l[1].ctrl and l[1].key == .t);
    try std.testing.expectEqual(@as(usize, 0), parseList("Ctrl+Click", &out).len);
    try std.testing.expect((Combinacao.parse("F5") orelse unreachable).usable());
    try std.testing.expect((Combinacao.parse("Alt+J") orelse unreachable).usable());
    try std.testing.expect(!(Combinacao.parse("J") orelse unreachable).usable());
    try std.testing.expect(!(Combinacao.parse("Shift+J") orelse unreachable).usable());
}
