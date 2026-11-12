//! Volume de cada pessoa na call e o "Silenciar para mim", só neste computador
//! (nada disso vai para o Discord). São separados, como no Discord: silenciar não
//! mexe no volume guardado, e tirar o silêncio volta exatamente para ele. O mixer da
//! call e o menu do botão direito leem e mudam os mesmos valores (ui/popup.zig).
//! No settings.kdl:
//!
//!     voice-volumes 2
//!     voice-volume "1234" 0.8
//!     voice-mute "1234"
//!     voice-denoise "1234"
//!     voice-level "1234"
//!
//! `voice-denoise` (tirar ruído) e `voice-level` (igualar volume) são escolhas por
//! pessoa no mixer, desligadas de começo: só quem aparece nessas linhas tem.
//!
//! Até a 0.6.3 silenciar era só o volume em zero, e o arquivo não tinha a linha
//! `voice-volumes 2`: sem ela, um volume zero vira "Silenciar para mim" com o volume
//! normal, que é o que a pessoa tinha pedido no mixer de antes. Com ela, zero é zero.
const std = @import("std");
const kdl = @import("../theme/kdl.zig");
const Id = @import("types.zig").Id;

pub const Volumes = struct {
    /// 0..2; quem não está aqui fica no normal (1).
    level: std.AutoHashMapUnmanaged(Id, f32) = .empty,
    /// Silenciados só para nós.
    muted: std.AutoHashMapUnmanaged(Id, void) = .empty,
    /// Com "Tirar ruído" e com "Igualar volume" (mixer da call).
    denoise: std.AutoHashMapUnmanaged(Id, void) = .empty,
    leveled: std.AutoHashMapUnmanaged(Id, void) = .empty,
    /// O arquivo é desta versão (a linha `voice-volumes 2` vem antes das outras).
    v2: bool = false,

    pub fn deinit(v: *Volumes, gpa: std.mem.Allocator) void {
        v.level.deinit(gpa);
        v.muted.deinit(gpa);
        v.denoise.deinit(gpa);
        v.leveled.deinit(gpa);
    }

    /// O volume guardado (o que o controle mostra), silenciado ou não.
    pub fn volume(v: *const Volumes, uid: Id) f32 {
        return v.level.get(uid) orelse 1.0;
    }

    pub fn isMuted(v: *const Volumes, uid: Id) bool {
        return v.muted.contains(uid);
    }

    /// O que vai para o motor de voz: zero silenciado, senão o volume guardado.
    pub fn gain(v: *const Volumes, uid: Id) f32 {
        return if (v.isMuted(uid)) 0 else v.volume(uid);
    }

    pub fn setVolume(v: *Volumes, gpa: std.mem.Allocator, uid: Id, value: f32) void {
        v.level.put(gpa, uid, std.math.clamp(value, 0, 2)) catch {};
    }

    pub fn setMuted(v: *Volumes, gpa: std.mem.Allocator, uid: Id, on: bool) void {
        if (on) v.muted.put(gpa, uid, {}) catch {} else _ = v.muted.remove(uid);
    }

    pub fn denoiseOn(v: *const Volumes, uid: Id) bool {
        return v.denoise.contains(uid);
    }

    pub fn levelOn(v: *const Volumes, uid: Id) bool {
        return v.leveled.contains(uid);
    }

    pub fn setDenoise(v: *Volumes, gpa: std.mem.Allocator, uid: Id, on: bool) void {
        if (on) v.denoise.put(gpa, uid, {}) catch {} else _ = v.denoise.remove(uid);
    }

    pub fn setLevel(v: *Volumes, gpa: std.mem.Allocator, uid: Id, on: bool) void {
        if (on) v.leveled.put(gpa, uid, {}) catch {} else _ = v.leveled.remove(uid);
    }

    /// Escreve as linhas do settings.kdl.
    pub fn write(v: *const Volumes, out: *std.ArrayList(u8), gpa: std.mem.Allocator) !void {
        try out.appendSlice(gpa, "voice-volumes 2\n");
        var it = v.level.iterator();
        while (it.next()) |e| try out.print(gpa, "voice-volume \"{d}\" {d:.3}\n", .{ e.key_ptr.*, e.value_ptr.* });
        var mit = v.muted.keyIterator();
        while (mit.next()) |uid| try out.print(gpa, "voice-mute \"{d}\"\n", .{uid.*});
        var dit = v.denoise.keyIterator();
        while (dit.next()) |uid| try out.print(gpa, "voice-denoise \"{d}\"\n", .{uid.*});
        var lit = v.leveled.keyIterator();
        while (lit.next()) |uid| try out.print(gpa, "voice-level \"{d}\"\n", .{uid.*});
    }

    /// Lê um nó do settings.kdl. Retorna false se não é nosso.
    pub fn applyNode(v: *Volumes, gpa: std.mem.Allocator, n: *const kdl.Node) bool {
        if (std.mem.eql(u8, n.name, "voice-volumes")) {
            v.v2 = true;
            return true;
        }
        const is_volume = std.mem.eql(u8, n.name, "voice-volume");
        const is_denoise = std.mem.eql(u8, n.name, "voice-denoise");
        const is_level = std.mem.eql(u8, n.name, "voice-level");
        if (!is_volume and !is_denoise and !is_level and !std.mem.eql(u8, n.name, "voice-mute")) return false;
        const sid = (n.arg(0) orelse return true).asString() orelse return true;
        const uid = std.fmt.parseInt(Id, sid, 10) catch return true;
        if (is_denoise) {
            v.setDenoise(gpa, uid, true);
            return true;
        }
        if (is_level) {
            v.setLevel(gpa, uid, true);
            return true;
        }
        if (is_volume) {
            const value = (n.arg(1) orelse return true).asNumber() orelse return true;
            if (!v.v2 and value <= 0.0005) {
                // O mudo do mixer de até a 0.6.3.
                v.setVolume(gpa, uid, 1.0);
                v.setMuted(gpa, uid, true);
            } else v.setVolume(gpa, uid, @floatCast(value));
        } else v.setMuted(gpa, uid, true);
        return true;
    }
};

test "silenciar não mexe no volume e as duas coisas vão e voltam pelo settings.kdl" {
    const gpa = std.testing.allocator;
    var v: Volumes = .{};
    defer v.deinit(gpa);
    v.setVolume(gpa, 5, 0.57);
    v.setMuted(gpa, 5, true);
    v.setVolume(gpa, 6, 3);
    try std.testing.expectEqual(@as(f32, 0), v.gain(5));
    try std.testing.expectEqual(@as(f32, 0.57), v.volume(5));
    try std.testing.expectEqual(@as(f32, 2), v.gain(6));
    try std.testing.expectEqual(@as(f32, 1), v.gain(7));

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try v.write(&out, gpa);
    // Um arquivo da 0.6.3: o mudo era o volume em zero, e continua mudo.
    try out.appendSlice(gpa, "voice-volume \"8\" 0\nvoice-mute \"x\"\n");
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const nodes = try kdl.parse(arena.allocator(), out.items, null);
    var back: Volumes = .{};
    defer back.deinit(gpa);
    for (nodes) |*n| try std.testing.expect(back.applyNode(gpa, n));
    try std.testing.expect(back.isMuted(5));
    // O `voice-mute "x"` não vale: só a 5 está silenciada.
    try std.testing.expectEqual(@as(u32, 1), back.muted.count());
    try std.testing.expectEqual(@as(f32, 0), back.gain(5));
    back.setMuted(gpa, 5, false);
    try std.testing.expectApproxEqAbs(@as(f32, 0.57), back.gain(5), 0.0005);
    try std.testing.expectEqual(@as(f32, 2), back.gain(6));
    try std.testing.expect(!back.isMuted(8));
    try std.testing.expectEqual(@as(f32, 0), back.gain(8));
}

test "arquivo de até a 0.6.3: volume zero vira silenciado com o volume normal; desta versão, zero é zero" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const old = try kdl.parse(arena.allocator(), "voice-volume \"8\" 0\nvoice-volume \"9\" 0.5\n", null);
    var a: Volumes = .{};
    defer a.deinit(gpa);
    for (old) |*n| try std.testing.expect(a.applyNode(gpa, n));
    try std.testing.expect(a.isMuted(8));
    try std.testing.expectEqual(@as(f32, 1), a.volume(8));
    try std.testing.expectEqual(@as(f32, 0), a.gain(8));
    try std.testing.expect(!a.isMuted(9));
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), a.gain(9), 0.0005);
    a.setMuted(gpa, 8, false);
    try std.testing.expectEqual(@as(f32, 1), a.gain(8));

    // Desta versão: arrastar até zero sem silenciar continua zero depois de salvar e ler.
    var b: Volumes = .{};
    defer b.deinit(gpa);
    b.setVolume(gpa, 10, 0);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try b.write(&out, gpa);
    const nodes = try kdl.parse(arena.allocator(), out.items, null);
    var c: Volumes = .{};
    defer c.deinit(gpa);
    for (nodes) |*n| try std.testing.expect(c.applyNode(gpa, n));
    try std.testing.expect(!c.isMuted(10));
    try std.testing.expectEqual(@as(f32, 0), c.gain(10));
}

test "tirar ruído e igualar volume: desligados de começo, por pessoa, e vão e voltam pelo settings.kdl" {
    const gpa = std.testing.allocator;
    var v: Volumes = .{};
    defer v.deinit(gpa);
    try std.testing.expect(!v.denoiseOn(5) and !v.levelOn(5));
    v.setDenoise(gpa, 5, true);
    v.setLevel(gpa, 6, true);
    v.setLevel(gpa, 7, true);
    v.setLevel(gpa, 7, false);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try v.write(&out, gpa);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const nodes = try kdl.parse(arena.allocator(), out.items, null);
    var back: Volumes = .{};
    defer back.deinit(gpa);
    for (nodes) |*n| try std.testing.expect(back.applyNode(gpa, n));
    try std.testing.expect(back.denoiseOn(5) and !back.levelOn(5));
    try std.testing.expect(back.levelOn(6) and !back.denoiseOn(6));
    try std.testing.expect(!back.levelOn(7));
    // O volume de quem só tem as escolhas novas continua o normal.
    try std.testing.expectEqual(@as(f32, 1), back.gain(5));
}
