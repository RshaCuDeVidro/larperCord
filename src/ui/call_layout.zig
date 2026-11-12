//! O tamanho dos quadros da tela da call (sem SDL, para dar para testar).
const std = @import("std");

pub const Grid = struct { cols: usize = 0, rows: usize = 0, tile_w: f32 = 0, tile_h: f32 = 0 };

/// Colunas e tamanho do quadro (16:9) para `n` pessoas em `area_w`×`area_h`: o maior
/// que cabe, até `max_w`. Abaixo de `min_w`, fica no mínimo, com quantas colunas
/// couberem, e a grade rola.
pub fn layout(n: usize, area_w: f32, area_h: f32, gap: f32, min_w: f32, max_w: f32) Grid {
    if (n == 0) return .{};
    // Sem largura nenhuma (a janela arrastada bem estreita): uma coluna de 1 px, sem
    // dividir por zero lá fora.
    if (area_w < 1) return .{ .cols = 1, .rows = n, .tile_w = 1, .tile_h = 9.0 / 16.0 };
    var best: Grid = .{};
    var cols: usize = 1;
    while (cols <= n) : (cols += 1) {
        const rows = (n + cols - 1) / cols;
        const fc: f32 = @floatFromInt(cols);
        const fr: f32 = @floatFromInt(rows);
        const by_w = (area_w - gap * (fc - 1)) / fc;
        const by_h = (area_h - gap * (fr - 1)) / fr * 16.0 / 9.0;
        const tw = @min(@min(by_w, by_h), max_w);
        // Empate (os dois no máximo): mais colunas, e duas pessoas ficam lado a lado.
        if (tw >= best.tile_w) best = .{ .cols = cols, .rows = rows, .tile_w = tw, .tile_h = tw * 9.0 / 16.0 };
    }
    if (best.tile_w >= min_w) return best;
    const tw = @min(min_w, area_w);
    const fit: usize = @intFromFloat(@max(1, @floor((area_w + gap) / (tw + gap))));
    const cols_fit = @min(fit, n);
    return .{ .cols = cols_fit, .rows = (n + cols_fit - 1) / cols_fit, .tile_w = tw, .tile_h = tw * 9.0 / 16.0 };
}

test "grade da call: o maior quadro que cabe, e o mínimo com rolagem" {
    // Uma pessoa: o quadro inteiro, até o máximo.
    const one = layout(1, 1000, 600, 10, 176, 560);
    try std.testing.expectEqual(@as(usize, 1), one.cols);
    try std.testing.expectEqual(@as(f32, 560), one.tile_w);
    // Quatro numa área larga: 2×2 ganha de 4×1 e de 3+1.
    const four = layout(4, 1000, 600, 10, 176, 560);
    try std.testing.expectEqual(@as(usize, 2), four.cols);
    try std.testing.expectEqual(@as(usize, 2), four.rows);
    try std.testing.expect(four.tile_w > 450 and four.tile_h * 16 / 9 - four.tile_w < 0.01);
    // Muita gente numa área pequena: o mínimo, 3 colunas, e linhas a mais (rola).
    const many = layout(20, 600, 400, 10, 176, 560);
    try std.testing.expectEqual(@as(f32, 176), many.tile_w);
    try std.testing.expectEqual(@as(usize, 3), many.cols);
    try std.testing.expectEqual(@as(usize, 7), many.rows);
    // Mais estreita que o mínimo: uma coluna da largura que tem.
    const narrow = layout(3, 120, 400, 10, 176, 560);
    try std.testing.expectEqual(@as(usize, 1), narrow.cols);
    try std.testing.expectEqual(@as(f32, 120), narrow.tile_w);
    try std.testing.expectEqual(@as(usize, 0), layout(0, 500, 500, 10, 176, 560).cols);
    // Janela maximizada (1336×918): duas pessoas lado a lado, não empilhadas; três, 2+1.
    const two = layout(2, 1336, 918, 10, 176, 560);
    try std.testing.expectEqual(@as(usize, 2), two.cols);
    try std.testing.expectEqual(@as(usize, 1), two.rows);
    const three = layout(3, 1336, 1000, 10, 176, 560);
    try std.testing.expectEqual(@as(usize, 2), three.cols);
    // Área de largura zero ou negativa: uma coluna, nada de zero (quem chama divide).
    const none = layout(4, -20, 300, 10, 176, 560);
    try std.testing.expect(none.cols >= 1 and none.rows >= 1);
}
