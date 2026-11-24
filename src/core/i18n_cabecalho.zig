//! O cabeçalho de um arquivo de tradução (i18n/*.kdl): as linhas do começo, antes da
//! primeira entrada entre aspas, sem os comentários e as linhas vazias. É onde o arquivo
//! diz quem é (`language "日本語" code="ja"`). O build guarda o cabeçalho fora da parte
//! comprimida (tools/comprimir.zig --i18n): o app monta a lista de idiomas sem abrir
//! nenhum arquivo inteiro (src/ui/i18n.zig). Só a biblioteca padrão: o build usa também.
const std = @import("std");

/// As linhas antes da primeira que começa com `"` (uma entrada) ou `/-"` (uma entrada
/// comentada), tirando as de comentário `//` e as vazias, em `out`. Cabe sempre num
/// buffer do tamanho de `src`; num menor, para na última linha inteira que coube.
pub fn extract(src: []const u8, out: []u8) []const u8 {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or std.mem.startsWith(u8, line, "//")) continue;
        if (line[0] == '"' or std.mem.startsWith(u8, line, "/-")) break;
        if (n + line.len + 1 > out.len) break;
        @memcpy(out[n..][0..line.len], line);
        out[n + line.len] = '\n';
        n += line.len + 1;
    }
    return out[0..n];
}

/// O que o build embute de cada arquivo: 4 bytes com o tamanho do cabeçalho (little
/// endian), o cabeçalho e o arquivo inteiro em deflate puro.
pub const Packed = struct { header: []const u8, data: []const u8 };

pub fn split(bytes: []const u8) ?Packed {
    if (bytes.len < 4) return null;
    const len = std.mem.readInt(u32, bytes[0..4], .little);
    if (len > bytes.len - 4) return null;
    return .{ .header = bytes[4..][0..len], .data = bytes[4 + len ..] };
}

const t = std.testing;

test "cabeçalho: as linhas antes da primeira entrada, sem comentários" {
    const src =
        \\// larperCord — teste
        \\
        \\language "Teste" code="xx"
        \\  direction "rtl"
        \\// outro comentário
        \\"Sign in" "Entrar"
        \\font-script "ja"
        \\
    ;
    var buf: [256]u8 = undefined;
    try t.expectEqualStrings("language \"Teste\" code=\"xx\"\ndirection \"rtl\"\n", extract(src, &buf));
    // Uma entrada comentada também encerra o cabeçalho.
    try t.expectEqualStrings("language \"A\"\n", extract("language \"A\"\n/-\"x\" \"y\"\nplurals \"ru\"\n", &buf));
    // Sem espaço: só as linhas inteiras que couberam.
    var small: [20]u8 = undefined;
    try t.expectEqualStrings("", extract(src, &small));
    var mid: [30]u8 = undefined;
    try t.expectEqualStrings("language \"Teste\" code=\"xx\"\n", extract(src, &mid));
}

test "formato embutido: tamanho, cabeçalho e o resto" {
    const bytes = [_]u8{ 3, 0, 0, 0, 'a', 'b', 'c', 9, 8 };
    const p = split(&bytes).?;
    try t.expectEqualStrings("abc", p.header);
    try t.expectEqualSlices(u8, &.{ 9, 8 }, p.data);
    try t.expect(split(&.{ 9, 0, 0, 0, 1 }) == null);
    try t.expect(split(&.{ 1, 0 }) == null);
}
