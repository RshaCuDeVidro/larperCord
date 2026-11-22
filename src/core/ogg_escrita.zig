//! Escrita de Ogg (RFC 3533) para o áudio gravado na caixa de texto
//! (ui/gravar_audio.zig): os pacotes viram páginas com a tabela de segmentos,
//! o pacote grande atravessa páginas (com a marca de continuação), a granule
//! de cada página é a do último pacote que termina nela (-1 quando nenhum
//! termina), a primeira página leva BOS, a última EOS, e cada uma o CRC do
//! Ogg. Mais o OpusHead e o OpusTags do Ogg Opus (RFC 7845). Tudo puro: quem
//! codifica é a libopus, quem lê de volta é core/ogg_opus.zig (o CRC daqui é
//! outra conta, então um confere o outro nos testes).
const std = @import("std");

pub const flag_continued: u8 = 1;
pub const flag_bos: u8 = 2;
pub const flag_eos: u8 = 4;
/// Granule de uma página onde nenhum pacote termina.
pub const no_granule: u64 = std.math.maxInt(u64);
/// Segmentos por página: o tamanho da tabela cabe num byte.
pub const max_segments = 255;

// --- CRC do Ogg ------------------------------------------------------------------

/// Polinômio 0x04C11DB7, começando em zero, sem inverter bits nem o resultado.
const crc_table: [256]u32 = blk: {
    @setEvalBranchQuota(4000);
    var t: [256]u32 = undefined;
    for (&t, 0..) |*e, i| {
        var r: u32 = @as(u32, @intCast(i)) << 24;
        for (0..8) |_| r = (r << 1) ^ (if (r & 0x8000_0000 != 0) @as(u32, 0x04C1_1DB7) else 0);
        e.* = r;
    }
    break :blk t;
};

pub fn crc(start: u32, bytes: []const u8) u32 {
    var v = start;
    for (bytes) |b| v = (v << 8) ^ crc_table[@as(u8, @truncate(v >> 24)) ^ b];
    return v;
}

/// O CRC de uma página inteira, com o próprio campo do CRC valendo zero.
pub fn pageCrc(p: []const u8) u32 {
    var v = crc(0, p[0..22]);
    v = crc(v, &.{ 0, 0, 0, 0 });
    return crc(v, p[26..]);
}

// --- Páginas ---------------------------------------------------------------------

pub const Writer = struct {
    gpa: std.mem.Allocator,
    out: std.ArrayList(u8) = .empty,
    /// O número do fluxo (sorteado por quem cria: dois arquivos juntos não se confundem).
    serial: u32,
    seq: u32 = 0,
    /// A página em montagem: a tabela, o corpo e a granule do último pacote que
    /// terminou nela.
    lacing: [max_segments]u8 = undefined,
    n_lacing: usize = 0,
    body: std.ArrayList(u8) = .empty,
    granule: u64 = no_granule,
    /// Esta página começa com o resto de um pacote da anterior.
    continued: bool = false,
    /// Um pacote está pela metade (a página fechou no meio dele).
    open: bool = false,
    ended: bool = false,

    pub fn init(gpa: std.mem.Allocator, serial: u32) Writer {
        return .{ .gpa = gpa, .serial = serial };
    }

    pub fn deinit(w: *Writer) void {
        w.out.deinit(w.gpa);
        w.body.deinit(w.gpa);
        w.* = undefined;
    }

    /// Um pacote inteiro, que termina na amostra `granule` (contando desde o
    /// começo do fluxo). Página cheia fecha sozinha, mesmo no meio do pacote.
    /// `last`: o último do fluxo (a página sai com EOS e nada mais entra).
    pub fn packet(w: *Writer, data: []const u8, granule: u64, last: bool) !void {
        std.debug.assert(!w.ended);
        var rest = data;
        w.open = true;
        while (true) {
            if (w.n_lacing == max_segments) try w.emit(false);
            const take = @min(rest.len, 255);
            w.lacing[w.n_lacing] = @intCast(take);
            w.n_lacing += 1;
            try w.body.appendSlice(w.gpa, rest[0..take]);
            rest = rest[take..];
            // Um segmento menor que 255 (até de zero) fecha o pacote: um pacote
            // com tamanho múltiplo de 255 termina num segmento vazio.
            if (take < 255) break;
        }
        w.open = false;
        w.granule = granule;
        if (last) try w.emit(true);
    }

    /// Fecha a página em montagem (nada a fazer se ela está vazia). Os
    /// cabeçalhos do Opus pedem página própria; o áudio fecha uma a cada tanto.
    pub fn flush(w: *Writer) !void {
        if (w.n_lacing > 0) try w.emit(false);
    }

    fn emit(w: *Writer, eos: bool) !void {
        const start = w.out.items.len;
        var flags: u8 = 0;
        if (w.continued) flags |= flag_continued;
        if (w.seq == 0) flags |= flag_bos;
        if (eos) flags |= flag_eos;
        var h: [27]u8 = undefined;
        @memcpy(h[0..4], "OggS");
        h[4] = 0;
        h[5] = flags;
        std.mem.writeInt(u64, h[6..14], w.granule, .little);
        std.mem.writeInt(u32, h[14..18], w.serial, .little);
        std.mem.writeInt(u32, h[18..22], w.seq, .little);
        @memset(h[22..26], 0);
        h[26] = @intCast(w.n_lacing);
        try w.out.ensureUnusedCapacity(w.gpa, h.len + w.n_lacing + w.body.items.len);
        w.out.appendSliceAssumeCapacity(&h);
        w.out.appendSliceAssumeCapacity(w.lacing[0..w.n_lacing]);
        w.out.appendSliceAssumeCapacity(w.body.items);
        const sum = pageCrc(w.out.items[start..]);
        std.mem.writeInt(u32, w.out.items[start + 22 ..][0..4], sum, .little);
        w.seq += 1;
        // A próxima continua o pacote que ficou pela metade.
        w.continued = w.open;
        w.n_lacing = 0;
        w.body.clearRetainingCapacity();
        w.granule = no_granule;
        if (eos) w.ended = true;
    }
};

// --- Ogg Opus --------------------------------------------------------------------

/// O OpusHead (versão 1, mapeamento 0: mono ou estéreo).
pub fn opusHead(buf: *[19]u8, channels: u8, pre_skip: u16, input_rate: u32) []const u8 {
    @memcpy(buf[0..8], "OpusHead");
    buf[8] = 1;
    buf[9] = channels;
    std.mem.writeInt(u16, buf[10..12], pre_skip, .little);
    std.mem.writeInt(u32, buf[12..16], input_rate, .little);
    // Ganho de saída zero, mapeamento 0.
    @memset(buf[16..19], 0);
    return buf;
}

/// O OpusTags: quem gravou e os comentários (`CHAVE=valor`).
pub fn opusTags(gpa: std.mem.Allocator, vendor: []const u8, comments: []const []const u8) ![]u8 {
    var b: std.ArrayList(u8) = .empty;
    errdefer b.deinit(gpa);
    try b.appendSlice(gpa, "OpusTags");
    var n: [4]u8 = undefined;
    std.mem.writeInt(u32, &n, @intCast(vendor.len), .little);
    try b.appendSlice(gpa, &n);
    try b.appendSlice(gpa, vendor);
    std.mem.writeInt(u32, &n, @intCast(comments.len), .little);
    try b.appendSlice(gpa, &n);
    for (comments) |cm| {
        std.mem.writeInt(u32, &n, @intCast(cm.len), .little);
        try b.appendSlice(gpa, &n);
        try b.appendSlice(gpa, cm);
    }
    return b.toOwnedSlice(gpa);
}

// --- Testes ----------------------------------------------------------------------

const testing = std.testing;
const leitor = @import("ogg_opus.zig");

const PageView = struct { flags: u8, granule: u64, seq: u32, lacing: []const u8, body: []const u8, len: usize };

/// Lê a página em `at` sem o leitor do app (só para conferir campo a campo).
fn view(file: []const u8, at: usize) PageView {
    const h = file[at..];
    const n: usize = h[26];
    var body_len: usize = 0;
    for (h[27..][0..n]) |l| body_len += l;
    return .{
        .flags = h[5],
        .granule = std.mem.readInt(u64, h[6..14], .little),
        .seq = std.mem.readInt(u32, h[18..22], .little),
        .lacing = h[27..][0..n],
        .body = h[27 + n ..][0..body_len],
        .len = 27 + n + body_len,
    };
}

test "CRC do Ogg: o valor de conferência e uma página feita pelo ffmpeg" {
    // CRC-32 com o polinômio do Ogg, sem inverter nada: "123456789" dá 0x89A1897F.
    try testing.expectEqual(@as(u32, 0x89A1_897F), crc(0, "123456789"));
    try testing.expectEqual(@as(u32, 0), crc(0, ""));
    // A primeira página (OpusHead) de um .ogg que o ffmpeg/libopus gravou.
    const hex = "4f67675300020000000000000000c45edc0e000000007fd50ea601134f707573486561640101380180bb0000000000";
    var real: [hex.len / 2]u8 = undefined;
    _ = try std.fmt.hexToBytes(&real, hex);
    try testing.expectEqual(std.mem.readInt(u32, real[22..26], .little), pageCrc(&real));
    // Um bit trocado muda o CRC.
    real[30] ^= 1;
    try testing.expect(std.mem.readInt(u32, real[22..26], .little) != pageCrc(&real));
}

test "páginas: cabeçalhos em páginas próprias, BOS, EOS, granule e sequência" {
    const gpa = testing.allocator;
    var w: Writer = .init(gpa, 0xC0FFEE);
    defer w.deinit();
    var hb: [19]u8 = undefined;
    try w.packet(opusHead(&hb, 1, 312, 48000), 0, false);
    try w.flush();
    const tags = try opusTags(gpa, "larperCord", &.{"ENCODER=larperCord"});
    defer gpa.free(tags);
    try w.packet(tags, 0, false);
    try w.flush();
    // Dois pacotes de 20 ms numa página e o último noutra, com o fim cortado.
    try w.packet(&.{ 8, 1, 2 }, 312 + 960, false);
    try w.packet(&.{ 8, 3 }, 312 + 1920, false);
    try w.flush();
    try w.flush(); // página vazia não sai
    try w.packet(&.{8}, 312 + 2500, true);

    const f = w.out.items;
    const p0 = view(f, 0);
    try testing.expectEqual(flag_bos, p0.flags);
    try testing.expectEqual(@as(u64, 0), p0.granule);
    try testing.expectEqualSlices(u8, &.{19}, p0.lacing);
    try testing.expectEqualStrings("OpusHead", p0.body[0..8]);
    try testing.expectEqual(@as(u16, 312), std.mem.readInt(u16, p0.body[10..12], .little));
    const p1 = view(f, p0.len);
    try testing.expectEqual(@as(u8, 0), p1.flags);
    try testing.expectEqual(@as(u32, 1), p1.seq);
    try testing.expectEqualStrings("OpusTags", p1.body[0..8]);
    const p2 = view(f, p0.len + p1.len);
    try testing.expectEqualSlices(u8, &.{ 3, 2 }, p2.lacing);
    try testing.expectEqual(@as(u64, 312 + 1920), p2.granule);
    const p3 = view(f, p0.len + p1.len + p2.len);
    try testing.expectEqual(flag_eos, p3.flags);
    try testing.expectEqual(@as(u32, 3), p3.seq);
    try testing.expectEqual(@as(u64, 312 + 2500), p3.granule);
    try testing.expectEqual(f.len, p0.len + p1.len + p2.len + p3.len);
    // O serial é o mesmo em todas.
    try testing.expectEqual(@as(u32, 0xC0FFEE), std.mem.readInt(u32, f[p0.len + 14 ..][0..4], .little));

    // O leitor do app (outro CRC) aceita e entende igual.
    var s = try leitor.index(gpa, f);
    defer s.deinit(gpa);
    try testing.expectEqual(@as(u8, 1), s.channels);
    try testing.expectEqual(@as(u16, 312), s.pre_skip);
    try testing.expectEqual(@as(usize, 3), s.packets.len);
    try testing.expectEqual(@as(u64, 960), s.packets[1].start);
    try testing.expectEqual(@as(u64, 312 + 2500), s.end);
    try testing.expectEqual(@as(u32, 2500 / 48), s.durationMs());
}

test "segmentos: múltiplo de 255 termina num segmento vazio" {
    const gpa = testing.allocator;
    var w: Writer = .init(gpa, 1);
    defer w.deinit();
    const p255: [255]u8 = @splat(7);
    const p510: [510]u8 = @splat(9);
    try w.packet(&p255, 10, false);
    try w.packet(&p510, 20, false);
    try w.packet("", 30, false);
    try w.packet(&.{ 1, 2, 3 }, 40, true);
    const p = view(w.out.items, 0);
    try testing.expectEqualSlices(u8, &.{ 255, 0, 255, 255, 0, 0, 3 }, p.lacing);
    try testing.expectEqual(@as(usize, 255 + 510 + 3), p.body.len);
    try testing.expectEqual(@as(u64, 40), p.granule);
    try testing.expectEqual(flag_bos | flag_eos, p.flags);
}

test "pacote maior que uma página: continua na seguinte, com granule -1 onde nada termina" {
    const gpa = testing.allocator;
    var w: Writer = .init(gpa, 2);
    defer w.deinit();
    // 600 segmentos de 255 e mais 100 bytes: atravessa três páginas.
    const big = try gpa.alloc(u8, 255 * 600 + 100);
    defer gpa.free(big);
    for (big, 0..) |*b, i| b.* = @truncate(i *% 31);
    try w.packet(big, 960, false);
    try w.packet(&.{8}, 1920, true);

    const f = w.out.items;
    const a = view(f, 0);
    try testing.expectEqual(@as(usize, 255), a.lacing.len);
    try testing.expectEqual(flag_bos, a.flags);
    try testing.expectEqual(no_granule, a.granule);
    const b = view(f, a.len);
    try testing.expectEqual(flag_continued, b.flags);
    try testing.expectEqual(@as(usize, 255), b.lacing.len);
    try testing.expectEqual(no_granule, b.granule);
    const cpage = view(f, a.len + b.len);
    // 90 segmentos de 255, o de 100 (o fim do pacote grande) e o pacote de 1 byte.
    try testing.expectEqual(flag_continued | flag_eos, cpage.flags);
    try testing.expectEqual(@as(usize, 92), cpage.lacing.len);
    try testing.expectEqual(@as(u8, 100), cpage.lacing[90]);
    try testing.expectEqual(@as(u64, 1920), cpage.granule);
    try testing.expectEqual(f.len, a.len + b.len + cpage.len);
    // Os pedaços, juntos, são o pacote.
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(gpa);
    try joined.appendSlice(gpa, a.body);
    try joined.appendSlice(gpa, b.body);
    try joined.appendSlice(gpa, cpage.body[0 .. cpage.body.len - 1]);
    try testing.expectEqualSlices(u8, big, joined.items);
}

test "pacote que cruza a página cheia: o leitor do app junta os pedaços" {
    const gpa = testing.allocator;
    var w: Writer = .init(gpa, 3);
    defer w.deinit();
    var hb: [19]u8 = undefined;
    try w.packet(opusHead(&hb, 1, 0, 48000), 0, false);
    try w.flush();
    try w.packet("OpusTags\x00\x00\x00\x00\x00\x00\x00\x00", 0, false);
    try w.flush();
    // 200 pacotes de 20 ms de um byte; o de 101 segmentos não cabe no resto da página.
    var g: u64 = 0;
    for (0..200) |_| {
        g += 960;
        try w.packet(&.{8}, g, false);
    }
    var mid: [255 * 100 + 50]u8 = undefined;
    for (&mid, 0..) |*x, i| x.* = @truncate(i *% 7);
    mid[0] = 8;
    try w.packet(&mid, g + 960, false);
    try w.packet(&.{8}, g + 1920, true);

    const f = w.out.items;
    var at = view(f, 0).len;
    at += view(f, at).len;
    const a = view(f, at);
    try testing.expectEqual(@as(usize, 255), a.lacing.len);
    // A granule é a do último pacote que terminou nela (o 200º).
    try testing.expectEqual(@as(u64, 960 * 200), a.granule);
    const b = view(f, at + a.len);
    try testing.expectEqual(flag_continued | flag_eos, b.flags);
    // Na página seguinte: os 46 segmentos que sobraram do grande e o último pacote.
    try testing.expectEqual(@as(usize, 47), b.lacing.len);

    var s = try leitor.index(gpa, f);
    defer s.deinit(gpa);
    try testing.expectEqual(@as(usize, 202), s.packets.len);
    try testing.expect(s.packets[200].spill);
    try testing.expectEqualSlices(u8, &mid, s.data(f, s.packets[200]));
    try testing.expectEqual(@as(u64, 960 * 200), s.packets[200].start);
    try testing.expectEqual(g + 1920, s.end);
}

test "OpusTags: vendor e comentários com os tamanhos em little endian" {
    const gpa = testing.allocator;
    const t = try opusTags(gpa, "ab", &.{ "X=1", "TITLE=oi" });
    defer gpa.free(t);
    try testing.expectEqualStrings("OpusTags\x02\x00\x00\x00ab\x02\x00\x00\x00\x03\x00\x00\x00X=1\x08\x00\x00\x00TITLE=oi", t);
}
