//! A cor de uma imagem por alto (sem SDL, para dar para testar).
const std = @import("std");

/// A cor de uma imagem por alto: 12×12 pontos espalhados, os mais vivos pesando
/// mais (uma foto com fundo cinza e camisa vermelha dá vermelho). O fundo do quadro
/// de cada um na tela da call. Bit 24 ligado; 0 = só transparência.
pub fn tintOf(data: []const u8, w: u16, h: u16) u32 {
    const W: usize = w;
    const H: usize = h;
    if (W == 0 or H == 0 or data.len < W * H * 4) return 0;
    var sum = [3]f32{ 0, 0, 0 };
    var total: f32 = 0;
    for (0..12) |sy| for (0..12) |sx| {
        const x = (sx * 2 + 1) * W / 24;
        const y = (sy * 2 + 1) * H / 24;
        const p = data[(y * W + x) * 4 ..][0..4];
        if (p[3] < 128) continue;
        const rgb = [3]f32{ @floatFromInt(p[0]), @floatFromInt(p[1]), @floatFromInt(p[2]) };
        const hi = @max(rgb[0], @max(rgb[1], rgb[2]));
        const lo = @min(rgb[0], @min(rgb[1], rgb[2]));
        const wt = 0.15 + (if (hi > 0) (hi - lo) / hi else 0);
        for (0..3) |i| sum[i] += rgb[i] * wt;
        total += wt;
    };
    if (total == 0) return 0;
    var out: u32 = 1 << 24;
    for (0..3) |i| out |= @as(u32, @intFromFloat(std.math.clamp(sum[i] / total, 0, 255))) << @intCast(16 - 8 * i);
    return out;
}


test "cor de uma imagem: os pontos vivos pesam mais, transparente não conta" {
    // 2×1: um vermelho vivo e um cinza; o resultado puxa para o vermelho.
    const px = [_]u8{ 230, 20, 20, 255, 128, 128, 128, 255 };
    const t = tintOf(&px, 2, 1);
    try std.testing.expect(t & (1 << 24) != 0);
    const r = (t >> 16) & 0xff;
    const g = (t >> 8) & 0xff;
    try std.testing.expect(r > 160 and g < 90);
    const clear = [_]u8{ 255, 255, 255, 0 };
    try std.testing.expectEqual(@as(u32, 0), tintOf(&clear, 1, 1));
}
