//! A forma de onda dos anexos de áudio e as contas da barra: o arquivo inteiro
//! resumido uma vez em `fina` pontos (o volume de cada pedaço, mono, em escala
//! que mostra também as partes baixas), reduzido na hora de desenhar para as
//! barras que cabem; e o tempo, o ponto do clique e quando o desenho muda.
const std = @import("std");

/// Pontos guardados por áudio (o desenho junta em menos barras).
pub const fina = 256;
/// Quadros por pedaço medido: ~20 ms a 48 kHz.
pub const pedaco = 1024;

/// Junta o volume (RMS) de cada pedaço enquanto o arquivo é decodificado.
pub const Acumulador = struct {
    pedacos: std.ArrayList(f32) = .empty,
    soma: f64 = 0,
    cont: u32 = 0,

    pub fn deinit(a: *Acumulador, gpa: std.mem.Allocator) void {
        a.pedacos.deinit(gpa);
    }

    /// `samples` intercaladas, `channels` por quadro.
    pub fn add(a: *Acumulador, gpa: std.mem.Allocator, samples: []const f32, channels: usize) !void {
        const frames = samples.len / channels;
        const inv = 1.0 / @as(f32, @floatFromInt(channels));
        for (0..frames) |i| {
            var m: f32 = 0;
            for (samples[i * channels ..][0..channels]) |s| m += s;
            m *= inv;
            a.soma += m * m;
            a.cont += 1;
            if (a.cont == pedaco) try a.fechar(gpa);
        }
    }

    fn fechar(a: *Acumulador, gpa: std.mem.Allocator) !void {
        try a.pedacos.append(gpa, @floatCast(@sqrt(a.soma / @as(f64, @floatFromInt(a.cont)))));
        a.soma = 0;
        a.cont = 0;
    }

    /// O resumo: `fina` pontos de 0 a 255 (o mais alto do arquivo vira 255). false =
    /// nada medido.
    pub fn terminar(a: *Acumulador, gpa: std.mem.Allocator, out: *[fina]u8) !bool {
        if (a.cont > 0) try a.fechar(gpa);
        const src = a.pedacos.items;
        if (src.len == 0) return false;
        var picos: [fina]f32 = undefined;
        var top: f32 = 0;
        for (&picos, 0..) |*p, i| {
            // Cada ponto pega o pedaço mais alto do trecho dele (arquivo curto: repete).
            const lo = i * src.len / fina;
            const hi = @max(lo + 1, (i + 1) * src.len / fina);
            p.* = std.mem.max(f32, src[@min(lo, src.len - 1)..@min(hi, src.len)]);
            top = @max(top, p.*);
        }
        for (picos, out) |p, *o| {
            // A raiz levanta as partes baixas (no linear, um trecho a -20 dB some).
            const k = if (top > 1e-6) std.math.pow(f32, p / top, 0.6) else 0;
            o.* = @intFromFloat(@round(std.math.clamp(k, 0, 1) * 255));
        }
        return true;
    }
};

/// Junta `src` em `dst.len` barras, cada uma o máximo do seu trecho.
pub fn reduzir(src: []const u8, dst: []u8) void {
    if (dst.len == 0) return;
    if (src.len == 0) return @memset(dst, 0);
    for (dst, 0..) |*d, i| {
        const lo = i * src.len / dst.len;
        const hi = @max(lo + 1, (i + 1) * src.len / dst.len);
        d.* = std.mem.max(u8, src[@min(lo, src.len - 1)..@min(hi, src.len)]);
    }
}

/// O ponto do áudio sob o mouse: `x` dentro da barra que começa em `x0` e tem `w`
/// de largura. Fora dela, o começo ou o fim.
pub fn msNoPonto(x: f32, x0: f32, w: f32, total_ms: u32) u32 {
    if (w <= 0 or total_ms == 0) return 0;
    const k = std.math.clamp((x - x0) / w, 0, 1);
    return @intFromFloat(@round(k * @as(f32, @floatFromInt(total_ms))));
}

/// Quanto da barra já tocou (0–1).
pub fn fracao(pos_ms: u32, total_ms: u32) f32 {
    if (total_ms == 0) return 0;
    return std.math.clamp(@as(f32, @floatFromInt(pos_ms)) / @as(f32, @floatFromInt(total_ms)), 0, 1);
}

/// "1:05", ou "1:02:05" de uma hora para cima.
pub fn tempo(buf: []u8, ms: u32) []const u8 {
    const s = ms / 1000;
    if (s >= 3600) return std.fmt.bufPrint(buf, "{d}:{d:0>2}:{d:0>2}", .{ s / 3600, s / 60 % 60, s % 60 }) catch "";
    return std.fmt.bufPrint(buf, "{d}:{d:0>2}", .{ s / 60, s % 60 }) catch "";
}

/// Daqui a quantos ms (no relógio, com a velocidade `vel`) o desenho parado muda:
/// o segundo do tempo vira ou a próxima das `barras` acende. Para quem não anima
/// (reduzir movimento, janela sem foco): acorda só quando precisa.
pub fn proximaMudanca(pos_ms: u32, total_ms: u32, barras: usize, vel: f32) u32 {
    var falta: u32 = 1000 - pos_ms % 1000;
    if (barras > 0 and total_ms > 0) {
        // A barra i acende quando o meio dela passa: (i + 0,5) / barras do total.
        const b: f64 = @floatFromInt(barras);
        const t: f64 = @floatFromInt(total_ms);
        const p: f64 = @floatFromInt(pos_ms);
        const i = @floor(p / t * b + 0.5);
        const next = (i + 0.5) / b * t;
        if (next > p) falta = @min(falta, @as(u32, @intFromFloat(@ceil(next - p))));
    }
    if (total_ms > pos_ms) falta = @min(falta, total_ms - pos_ms);
    const real = @as(f32, @floatFromInt(falta)) / @max(vel, 0.25);
    return @max(16, @as(u32, @intFromFloat(@ceil(real))));
}

test "tempo: minutos e horas" {
    var b: [16]u8 = undefined;
    try std.testing.expectEqualStrings("0:00", tempo(&b, 0));
    try std.testing.expectEqualStrings("0:59", tempo(&b, 59_999));
    try std.testing.expectEqualStrings("1:05", tempo(&b, 65_000));
    try std.testing.expectEqualStrings("59:59", tempo(&b, 3_599_000));
    try std.testing.expectEqualStrings("1:02:05", tempo(&b, 3_725_000));
}

test "clique na barra: ponto, começo e fim" {
    try std.testing.expectEqual(@as(u32, 0), msNoPonto(100, 100, 200, 60_000));
    try std.testing.expectEqual(@as(u32, 30_000), msNoPonto(200, 100, 200, 60_000));
    try std.testing.expectEqual(@as(u32, 45_000), msNoPonto(250, 100, 200, 60_000));
    // Fora da barra: o começo ou o fim, nunca além.
    try std.testing.expectEqual(@as(u32, 0), msNoPonto(20, 100, 200, 60_000));
    try std.testing.expectEqual(@as(u32, 60_000), msNoPonto(900, 100, 200, 60_000));
    // Sem duração ou sem largura: zero.
    try std.testing.expectEqual(@as(u32, 0), msNoPonto(150, 100, 200, 0));
    try std.testing.expectEqual(@as(u32, 0), msNoPonto(150, 100, 0, 1000));
    try std.testing.expectEqual(@as(f32, 0.25), fracao(15_000, 60_000));
    try std.testing.expectEqual(@as(f32, 1), fracao(90_000, 60_000));
}

test "resumo do arquivo: o trecho alto vira 255 e o silêncio, 0" {
    const gpa = std.testing.allocator;
    var a: Acumulador = .{};
    defer a.deinit(gpa);
    // Estéreo: metade em silêncio, metade com um tom (a média dos canais conta).
    var buf: [2 * pedaco]f32 = undefined;
    for (0..20) |k| {
        for (0..pedaco) |i| {
            const v: f32 = if (k < 10) 0 else 0.5 * @sin(@as(f32, @floatFromInt(i)) * 0.3);
            buf[i * 2] = v;
            buf[i * 2 + 1] = v;
        }
        try a.add(gpa, &buf, 2);
    }
    var out: [fina]u8 = undefined;
    try std.testing.expect(try a.terminar(gpa, &out));
    try std.testing.expectEqual(@as(u8, 0), out[0]);
    try std.testing.expectEqual(@as(u8, 0), out[fina / 2 - 2]);
    try std.testing.expectEqual(@as(u8, 255), out[fina - 1]);
    // Nada medido: sem resumo.
    var empty: Acumulador = .{};
    defer empty.deinit(gpa);
    try std.testing.expect(!try empty.terminar(gpa, &out));
}

test "reduzir: cada barra fica com o máximo do seu trecho" {
    const src = [_]u8{ 1, 9, 2, 3, 8, 4, 0, 0 };
    var four: [4]u8 = undefined;
    reduzir(&src, &four);
    try std.testing.expectEqualSlices(u8, &.{ 9, 3, 8, 0 }, &four);
    // Mais barras que pontos: repete, sem ler fora.
    var many: [16]u8 = undefined;
    reduzir(&src, &many);
    try std.testing.expectEqual(@as(u8, 1), many[0]);
    try std.testing.expectEqual(@as(u8, 0), many[15]);
    var none: [3]u8 = undefined;
    reduzir(&.{}, &none);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0 }, &none);
}

test "parado sem animar: acorda na virada do segundo ou na próxima barra" {
    // Áudio de 60 s em 60 barras: a próxima barra acende a cada 1 s, no meio dela.
    try std.testing.expectEqual(@as(u32, 500), proximaMudanca(0, 60_000, 60, 1));
    try std.testing.expectEqual(@as(u32, 300), proximaMudanca(1200, 60_000, 60, 1));
    // Em 2x, o relógio anda metade.
    try std.testing.expectEqual(@as(u32, 150), proximaMudanca(1200, 60_000, 60, 2));
    // Áudio longo com poucas barras: o segundo manda.
    try std.testing.expectEqual(@as(u32, 800), proximaMudanca(10_200, 3_600_000, 40, 1));
    // Perto do fim, o fim.
    try std.testing.expectEqual(@as(u32, 100), proximaMudanca(59_900, 60_000, 0, 1));
    // Nunca menos que um quadro.
    try std.testing.expectEqual(@as(u32, 16), proximaMudanca(999, 60_000, 0, 1));
}
