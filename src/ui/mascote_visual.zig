//! O visual do mascote Terminal (Configurações → Mascote → Personalizar): as peças
//! (olhos, boca, chapéu, acessórios e orelhas), as cores, as paletas prontas e os
//! visuais prontos; o sorteio; o texto curto que fica no settings.kdl; e os arquivos
//! de mascote (<config>/larpercord/mascots/*.kdl), que escolhem peças e cores e podem
//! desenhar peças próprias com formas, por expressão. Só dados: nada de janela e nada
//! de código vindo do arquivo. ui/mascote_partes.zig desenha; os testes rodam sem o ImGui.
const std = @import("std");
const kdl = @import("../theme/kdl.zig");
const color = @import("../theme/color.zig");

pub const Rgba = color.Rgba;

/// As caras do mascote (ui/mascote_terminal.zig). A ordem é a dos bits de `When`.
pub const Face = enum(u4) {
    /// ">_", a de sempre.
    prompt,
    /// "- -" de olhos fechados, boquinha "o".
    sleep,
    /// "^ ^" com sorriso grande.
    happy,
    /// "> <" apertado, boca tremida.
    worried,
    /// "o o" de susto, boquinha "o".
    startled,
    /// Sobrancelhas em "\ /" e boca para baixo.
    angry,
    /// "; ;" com uma lágrima.
    sad,
    /// Olhos em espiral, tonto.
    dizzy,
    /// "^ ^" de olhos fechados e boca aberta, rindo.
    laugh,
};

/// O que um bloco `when` de um arquivo aceita: as caras e mais dois momentos, o erro
/// (olhos de "x") e a boca aberta (comendo, bocejando).
pub const When = enum(u4) { normal, sleep, happy, worried, startled, angry, sad, dizzy, laugh, @"error", eat };

pub fn whenOf(f: Face) When {
    return @enumFromInt(@intFromEnum(f));
}

/// Nome de uma peça: o do arquivo (`id`) e os da interface.
pub const Info = struct { id: []const u8, pt: []const u8, en: []const u8 };

pub const Eyes = enum(u8) { prompt, dots, ovals, big, cat, sleepy, happy, wink, stars, hearts, pixel, binary, cyclops, lashes, visor, custom };
pub const eyes_info = [_]Info{
    .{ .id = "prompt", .pt = "Terminal", .en = "Terminal" },
    .{ .id = "dots", .pt = "Bolinhas", .en = "Dots" },
    .{ .id = "ovals", .pt = "Ovais", .en = "Ovals" },
    .{ .id = "big", .pt = "Brilhantes", .en = "Sparkly" },
    .{ .id = "cat", .pt = "De gato", .en = "Cat eyes" },
    .{ .id = "sleepy", .pt = "Sonolentos", .en = "Sleepy" },
    .{ .id = "happy", .pt = "Sorridentes", .en = "Smiling" },
    .{ .id = "wink", .pt = "Piscadinha", .en = "Wink" },
    .{ .id = "stars", .pt = "Estrelas", .en = "Stars" },
    .{ .id = "hearts", .pt = "Corações", .en = "Hearts" },
    .{ .id = "pixel", .pt = "Pixel", .en = "Pixel" },
    .{ .id = "binary", .pt = "Binário", .en = "Binary" },
    .{ .id = "cyclops", .pt = "Ciclope", .en = "Cyclops" },
    .{ .id = "lashes", .pt = "Cílios", .en = "Lashes" },
    .{ .id = "visor", .pt = "Visor", .en = "Visor" },
    .{ .id = "custom", .pt = "Do arquivo", .en = "From the file" },
};

pub const Mouth = enum(u8) { smile, cursor, cat, uwu, tongue, fang, vampire, open, o, flat, wavy, smirk, grin, pout, whistle, bunny, custom };
pub const mouth_info = [_]Info{
    .{ .id = "smile", .pt = "Sorriso", .en = "Smile" },
    .{ .id = "cursor", .pt = "Cursor", .en = "Cursor" },
    .{ .id = "cat", .pt = "Gatinho :3", .en = "Kitty :3" },
    .{ .id = "uwu", .pt = "uwu", .en = "uwu" },
    .{ .id = "tongue", .pt = "Língua", .en = "Tongue out" },
    .{ .id = "fang", .pt = "Dentinho", .en = "Little fang" },
    .{ .id = "vampire", .pt = "Vampiro", .en = "Vampire" },
    .{ .id = "open", .pt = "Aberta", .en = "Open grin" },
    .{ .id = "o", .pt = "Boquinha", .en = "Tiny o" },
    .{ .id = "flat", .pt = "Reta", .en = "Flat" },
    .{ .id = "wavy", .pt = "Ondulada", .en = "Wavy" },
    .{ .id = "smirk", .pt = "De lado", .en = "Smirk" },
    .{ .id = "grin", .pt = "Dentes", .en = "Toothy grin" },
    .{ .id = "pout", .pt = "Biquinho", .en = "Pout" },
    .{ .id = "whistle", .pt = "Assobio", .en = "Whistle" },
    .{ .id = "bunny", .pt = "Dentuço", .en = "Buck teeth" },
    .{ .id = "custom", .pt = "Do arquivo", .en = "From the file" },
};

/// Os chapéus. Os três do fim são os das datas especiais (que também dá para escolher).
pub const Hat = enum(u8) { none, crown, tophat, beanie, cap, cowboy, chef, halo, horns, flowers, viking, wizard, bow, propeller, beret, tiara, pirate, helmet, sprout, antenna, santa, witch, party };
pub const hat_info = [_]Info{
    .{ .id = "none", .pt = "Nenhum", .en = "None" },
    .{ .id = "crown", .pt = "Coroa", .en = "Crown" },
    .{ .id = "tophat", .pt = "Cartola", .en = "Top hat" },
    .{ .id = "beanie", .pt = "Touca", .en = "Beanie" },
    .{ .id = "cap", .pt = "Boné", .en = "Cap" },
    .{ .id = "cowboy", .pt = "Caubói", .en = "Cowboy" },
    .{ .id = "chef", .pt = "Chef", .en = "Chef" },
    .{ .id = "halo", .pt = "Auréola", .en = "Halo" },
    .{ .id = "horns", .pt = "Chifrinhos", .en = "Devil horns" },
    .{ .id = "flowers", .pt = "Coroa de flores", .en = "Flower crown" },
    .{ .id = "viking", .pt = "Viking", .en = "Viking" },
    .{ .id = "wizard", .pt = "Mago", .en = "Wizard" },
    .{ .id = "bow", .pt = "Laço", .en = "Bow" },
    .{ .id = "propeller", .pt = "Hélice", .en = "Propeller" },
    .{ .id = "beret", .pt = "Boina", .en = "Beret" },
    .{ .id = "tiara", .pt = "Tiara", .en = "Tiara" },
    .{ .id = "pirate", .pt = "Pirata", .en = "Pirate" },
    .{ .id = "helmet", .pt = "Capacete", .en = "Space helmet" },
    .{ .id = "sprout", .pt = "Brotinho", .en = "Sprout" },
    .{ .id = "antenna", .pt = "Antenas", .en = "Antennae" },
    .{ .id = "santa", .pt = "Gorro de Natal", .en = "Santa hat" },
    .{ .id = "witch", .pt = "Chapéu de bruxa", .en = "Witch hat" },
    .{ .id = "party", .pt = "Chapéu de festa", .en = "Party hat" },
};

/// Os acessórios (vários ao mesmo tempo; os do mesmo grupo se excluem).
pub const Acc = enum(u4) { glasses, shades, monocle, eyepatch, blush, freckles, bandaid, mustache, bowtie, scarf, bandana, earring };
pub const acc_info = [_]Info{
    .{ .id = "glasses", .pt = "Óculos", .en = "Glasses" },
    .{ .id = "shades", .pt = "Óculos escuros", .en = "Sunglasses" },
    .{ .id = "monocle", .pt = "Monóculo", .en = "Monocle" },
    .{ .id = "eyepatch", .pt = "Tapa-olho", .en = "Eye patch" },
    .{ .id = "blush", .pt = "Bochechas", .en = "Blush" },
    .{ .id = "freckles", .pt = "Sardas", .en = "Freckles" },
    .{ .id = "bandaid", .pt = "Curativo", .en = "Band-aid" },
    .{ .id = "mustache", .pt = "Bigode", .en = "Mustache" },
    .{ .id = "bowtie", .pt = "Gravatinha", .en = "Bow tie" },
    .{ .id = "scarf", .pt = "Cachecol", .en = "Scarf" },
    .{ .id = "bandana", .pt = "Bandana", .en = "Bandana" },
    .{ .id = "earring", .pt = "Brinco", .en = "Earring" },
};

pub fn bit(a: Acc) u16 {
    return @as(u16, 1) << @intFromEnum(a);
}
pub fn bits(comptime list: []const Acc) u16 {
    var b: u16 = 0;
    for (list) |a| b |= bit(a);
    return b;
}
/// Os do rosto (um par de óculos de cada vez) e os do pescoço.
pub const eyewear = bits(&.{ .glasses, .shades, .monocle, .eyepatch });
pub const neckwear = bits(&.{ .bowtie, .scarf, .bandana });
const all_acc: u16 = (1 << acc_info.len) - 1;

pub const Ears = enum(u8) { pointy, round, floppy, bunny, tiny, none };
pub const ears_info = [_]Info{
    .{ .id = "pointy", .pt = "Pontudas", .en = "Pointy" },
    .{ .id = "round", .pt = "Redondas", .en = "Round" },
    .{ .id = "floppy", .pt = "Caídas", .en = "Floppy" },
    .{ .id = "bunny", .pt = "De coelho", .en = "Bunny" },
    .{ .id = "tiny", .pt = "Miudinhas", .en = "Tiny" },
    .{ .id = "none", .pt = "Sem orelhas", .en = "No ears" },
};

/// De onde vêm as cores: as da marca (o roxo; o do canto segue a cor de destaque do
/// tema, como sempre foi), as do tema em todo lugar, ou as próprias (de uma paleta
/// pronta ou escolhidas uma a uma).
pub const Paint = enum(u8) { brand, theme, custom };

/// As cinco cores do mascote, na ordem de `Role`.
pub const Role = enum(u3) { top, bottom, ink, tufts, accent };
pub const role_info = [_]Info{
    .{ .id = "body-top", .pt = "Corpo (em cima)", .en = "Body (top)" },
    .{ .id = "body-bottom", .pt = "Corpo (embaixo)", .en = "Body (bottom)" },
    .{ .id = "ink", .pt = "Rosto", .en = "Face" },
    .{ .id = "tufts", .pt = "Pelinhos", .en = "Tufts" },
    .{ .id = "accent", .pt = "Detalhes", .en = "Details" },
};
pub const Colors = [5]Rgba;

fn hexColors(v: [5]u32) Colors {
    var out: Colors = undefined;
    for (v, 0..) |x, i| out[i] = Rgba.hex(x);
    return out;
}

/// As cores do SVG do mascote (o padrão de sempre).
pub const brand_colors = hexColors(.{ 0x9D40FF, 0x7A1FE6, 0x12061F, 0xF7A8FF, 0x29E6FF });
const ink_dark = Rgba.hex(0x12061F);
const ink_light = Rgba.hex(0xF8F0FF);

pub const Palette = struct { id: []const u8, pt: []const u8, en: []const u8, hex: [5]u32 };
/// Paletas prontas: o corpo em degradê, o traço do rosto com contraste (os testes
/// conferem), os pelinhos das orelhas e uma cor de detalhe que combina.
pub const palettes = [_]Palette{
    .{ .id = "uva", .pt = "Uva", .en = "Grape", .hex = .{ 0x9D40FF, 0x7A1FE6, 0x12061F, 0xF7A8FF, 0x29E6FF } },
    .{ .id = "menta", .pt = "Menta", .en = "Mint", .hex = .{ 0x6EE7D3, 0x14B8A6, 0x05302B, 0xD5FBF3, 0xFF6FB0 } },
    .{ .id = "por-do-sol", .pt = "Pôr do sol", .en = "Sunset", .hex = .{ 0xFFB45C, 0xFF5C7A, 0x2B0716, 0xFFE6A8, 0x7B3FF2 } },
    .{ .id = "oceano", .pt = "Oceano", .en = "Ocean", .hex = .{ 0x5FB2FF, 0x2F6BEA, 0x07122E, 0xCFE6FF, 0xFFD23F } },
    .{ .id = "morango", .pt = "Morango", .en = "Strawberry", .hex = .{ 0xFF86B0, 0xE8416F, 0x2E0716, 0xFFD6E5, 0x5BE08A } },
    .{ .id = "limao", .pt = "Limão", .en = "Lime", .hex = .{ 0xDDF58A, 0x8BCB1A, 0x1B2C05, 0xF6FFD9, 0xFF7A1A } },
    .{ .id = "grafite", .pt = "Grafite", .en = "Graphite", .hex = .{ 0x59606B, 0x2A2F38, 0xF1F3F6, 0xA7AEB9, 0x3EE0FF } },
    .{ .id = "neve", .pt = "Neve", .en = "Snow", .hex = .{ 0xFFFFFF, 0xD9E1EC, 0x1D2738, 0xFFC4DE, 0x5B9DFF } },
    .{ .id = "caramelo", .pt = "Caramelo", .en = "Caramel", .hex = .{ 0xF7C77E, 0xD98A3D, 0x3A1D08, 0xFFEBC7, 0x2BC9B4 } },
    .{ .id = "matrix", .pt = "Matrix", .en = "Matrix", .hex = .{ 0x1C4D30, 0x0A2616, 0x56F08A, 0x8CF5B0, 0x2AE36A } },
    .{ .id = "algodao-doce", .pt = "Algodão-doce", .en = "Cotton candy", .hex = .{ 0xFFC6E4, 0xA9B6FF, 0x3D0F5C, 0xFFFFFF, 0xFF5FAE } },
    .{ .id = "lava", .pt = "Lava", .en = "Lava", .hex = .{ 0xFF9A3C, 0xC21E26, 0x1F0800, 0xFFE08A, 0xFFD21F } },
    .{ .id = "meia-noite", .pt = "Meia-noite", .en = "Midnight", .hex = .{ 0x3B36B0, 0x1C1A4F, 0xFFE27A, 0xA8B0FF, 0xFFC23D } },
    .{ .id = "floresta", .pt = "Floresta", .en = "Forest", .hex = .{ 0x5BE38A, 0x1F8A45, 0x06301A, 0xC7F9D7, 0xFFD54A } },
};
pub const no_palette: u8 = 0xff;

pub fn paletteIndex(comptime id: []const u8) u8 {
    for (palettes, 0..) |p, i| if (std.mem.eql(u8, p.id, id)) return @intCast(i);
    @compileError("paleta inexistente: " ++ id);
}
pub fn paletteColors(i: u8) Colors {
    return hexColors(palettes[i].hex);
}

/// Nome curto guardado num tamanho fixo (o visual é copiado e comparado inteiro).
pub const Name = struct {
    len: u8 = 0,
    buf: [max_name]u8 = @splat(0),

    pub const max_name = 40;

    pub fn slice(n: *const Name) []const u8 {
        return n.buf[0..n.len];
    }
    pub fn set(n: *Name, s: []const u8) void {
        n.* = .{};
        const k = utf8Cut(s, max_name);
        @memcpy(n.buf[0..k], s[0..k]);
        n.len = @intCast(k);
    }
    pub fn eql(a: *const Name, b: *const Name) bool {
        return std.mem.eql(u8, a.slice(), b.slice());
    }
};

/// Quantos bytes de `s` cabem em `max` sem cortar uma letra no meio.
fn utf8Cut(s: []const u8, max: usize) usize {
    if (s.len <= max) return s.len;
    var k = max;
    while (k > 0 and (s[k] & 0xC0) == 0x80) k -= 1;
    return k;
}

/// Um visual inteiro.
pub const Look = struct {
    eyes: Eyes = .prompt,
    mouth: Mouth = .smile,
    hat: Hat = .none,
    ears: Ears = .pointy,
    /// Um bit por `Acc`.
    acc: u16 = 0,
    paint: Paint = .brand,
    /// A paleta pronta de onde vieram as cores (`no_palette`: escolhidas uma a uma).
    palette: u8 = no_palette,
    /// As cores próprias (valem com `paint` = custom).
    colors: Colors = brand_colors,
    /// O arquivo de onde vêm os desenhos próprios (olhos, boca e camadas), e os
    /// desenhos já lidos dele (quem resolve o visual preenche; não é salvo).
    draw_from: Name = .{},
    drawing: ?*const Drawing = null,

    pub fn has(l: *const Look, a: Acc) bool {
        return l.acc & bit(a) != 0;
    }

    /// Liga ou desliga um acessório; ligar um tira os outros do mesmo grupo.
    pub fn toggle(l: *Look, a: Acc) void {
        const b = bit(a);
        if (l.acc & b != 0) {
            l.acc &= ~b;
            return;
        }
        if (eyewear & b != 0) l.acc &= ~eyewear;
        if (neckwear & b != 0) l.acc &= ~neckwear;
        l.acc |= b;
    }

    /// Mesmo visual (os desenhos contam pelo arquivo de onde vêm).
    pub fn eql(a: *const Look, b: *const Look) bool {
        if (a.eyes != b.eyes or a.mouth != b.mouth or a.hat != b.hat or a.ears != b.ears or a.acc != b.acc or a.paint != b.paint) return false;
        if (!a.draw_from.eql(&b.draw_from)) return false;
        if (a.paint != .custom) return true;
        if (a.palette != b.palette) return false;
        for (a.colors, b.colors) |x, y| if (x.col(1) != y.col(1)) return false;
        return true;
    }

    pub fn isDefault(l: *const Look) bool {
        return l.eql(&.{});
    }

    /// Escolhe as cores de uma paleta pronta.
    pub fn usePalette(l: *Look, i: u8) void {
        if (i >= palettes.len) return;
        l.paint = .custom;
        l.palette = i;
        l.colors = paletteColors(i);
    }

    /// As cores deste quadro. `accent`: a cor de destaque do tema; `pet`: o mascote do
    /// canto, que com as cores da marca segue o tema (como sempre foi).
    pub fn colorsFor(l: *const Look, accent: Rgba, pet: bool) Colors {
        return switch (l.paint) {
            .custom => l.colors,
            .theme => themeColors(accent),
            .brand => if (pet) blk: {
                var out = brand_colors;
                out[@intFromEnum(Role.top)] = accent.mix(Rgba.white, 0.28);
                out[@intFromEnum(Role.bottom)] = accent.mix(Rgba.black, 0.1);
                break :blk out;
            } else brand_colors,
        };
    }
};

/// As cores a partir da cor de destaque do tema: o corpo como o do canto sempre foi, e
/// o traço do rosto escuro ou claro, o que tiver mais contraste.
pub fn themeColors(accent: Rgba) Colors {
    const acc: Rgba = .{ .r = accent.r, .g = accent.g, .b = accent.b };
    var out = brand_colors;
    out[0] = acc.mix(Rgba.white, 0.28);
    out[1] = acc.mix(Rgba.black, 0.1);
    const mid = out[0].mix(out[1], 0.5);
    out[2] = if (ink_dark.contrast(mid) >= ink_light.contrast(mid) or ink_dark.contrast(mid) >= 4) ink_dark else ink_light;
    out[3] = acc.mix(Rgba.white, 0.62);
    return out;
}

pub fn colorOf(c: Colors, r: Role) Rgba {
    return c[@intFromEnum(r)];
}

// --- Visuais prontos ------------------------------------------------------------

pub const Preset = struct { id: []const u8, pt: []const u8, en: []const u8, look: Look };

fn withPalette(comptime id: []const u8, l: Look) Look {
    var out = l;
    out.usePalette(paletteIndex(id));
    return out;
}
fn withColors(hex: [5]u32, l: Look) Look {
    var out = l;
    out.paint = .custom;
    out.palette = no_palette;
    out.colors = hexColors(hex);
    return out;
}

pub const presets = [_]Preset{
    .{ .id = "hacker", .pt = "Hacker", .en = "Hacker", .look = withPalette("matrix", .{ .eyes = .binary, .mouth = .smirk, .hat = .beanie }) },
    .{ .id = "bruxo", .pt = "Bruxo", .en = "Wizard", .look = withPalette("meia-noite", .{ .eyes = .stars, .mouth = .smile, .hat = .wizard, .acc = bits(&.{.scarf}) }) },
    .{ .id = "realeza", .pt = "Realeza", .en = "Royalty", .look = withPalette("uva", .{ .eyes = .sleepy, .mouth = .smirk, .hat = .crown, .acc = bits(&.{ .monocle, .bowtie }) }) },
    .{ .id = "pirata", .pt = "Pirata", .en = "Pirate", .look = withPalette("lava", .{ .eyes = .dots, .mouth = .fang, .hat = .pirate, .acc = bits(&.{ .eyepatch, .earring }) }) },
    .{ .id = "chef", .pt = "Chef", .en = "Chef", .look = withPalette("por-do-sol", .{ .eyes = .happy, .mouth = .tongue, .hat = .chef, .acc = bits(&.{ .mustache, .blush }) }) },
    .{ .id = "astronauta", .pt = "Astronauta", .en = "Astronaut", .look = withPalette("oceano", .{ .eyes = .big, .mouth = .o, .hat = .helmet }) },
    .{ .id = "nerd", .pt = "Nerd", .en = "Nerd", .look = withPalette("menta", .{ .eyes = .dots, .mouth = .bunny, .acc = bits(&.{ .glasses, .freckles }) }) },
    .{ .id = "gatinho", .pt = "Gatinho", .en = "Kitty", .look = withPalette("morango", .{ .eyes = .cat, .mouth = .cat, .acc = bits(&.{.blush}) }) },
    .{ .id = "vampiro", .pt = "Vampiro", .en = "Vampire", .look = withColors(.{ 0xEDE7F6, 0xB8AECF, 0x2A0E1F, 0xE5394E, 0xE5394E }, .{ .eyes = .sleepy, .mouth = .vampire, .acc = bits(&.{.bowtie}) }) },
    .{ .id = "caubói", .pt = "Caubói", .en = "Cowboy", .look = withPalette("caramelo", .{ .eyes = .dots, .mouth = .smirk, .hat = .cowboy, .acc = bits(&.{.bandana}) }) },
    .{ .id = "fofura", .pt = "Fofura", .en = "Cutie", .look = withPalette("algodao-doce", .{ .eyes = .happy, .mouth = .uwu, .hat = .bow, .acc = bits(&.{.blush}) }) },
    .{ .id = "diabinho", .pt = "Diabinho", .en = "Little devil", .look = withPalette("lava", .{ .eyes = .wink, .mouth = .fang, .hat = .horns }) },
    .{ .id = "robo", .pt = "Robô", .en = "Robot", .look = withPalette("grafite", .{ .eyes = .visor, .mouth = .grin, .hat = .antenna, .ears = .none }) },
    .{ .id = "anjinho", .pt = "Anjinho", .en = "Little angel", .look = withPalette("neve", .{ .eyes = .lashes, .mouth = .smile, .hat = .halo, .acc = bits(&.{.blush}) }) },
    .{ .id = "viking", .pt = "Viking", .en = "Viking", .look = withPalette("floresta", .{ .eyes = .ovals, .mouth = .grin, .hat = .viking, .acc = bits(&.{.mustache}) }) },
    .{ .id = "jardineiro", .pt = "Jardim", .en = "Garden", .look = withPalette("limao", .{ .eyes = .ovals, .mouth = .whistle, .hat = .sprout, .ears = .round, .acc = bits(&.{.freckles}) }) },
};

/// O visual pronto igual a `l`, se houver (para marcar o cartão).
pub fn presetOf(l: *const Look) ?usize {
    for (presets, 0..) |p, i| if (p.look.eql(l)) return i;
    return null;
}

// --- Sorteio ----------------------------------------------------------------------

/// Um visual sorteado que combina: uma paleta pronta (as cores já conversam), peças
/// sorteadas, chapéu na maior parte das vezes e no máximo dois acessórios, um de cada
/// grupo. Nunca os chapéus das datas nem as peças "do arquivo".
pub fn random(seed: u64) Look {
    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();
    var l: Look = .{};
    l.eyes = @enumFromInt(r.uintLessThan(u8, @intFromEnum(Eyes.custom)));
    l.mouth = @enumFromInt(r.uintLessThan(u8, @intFromEnum(Mouth.custom)));
    l.hat = if (r.uintLessThan(u8, 10) < 3) .none else @enumFromInt(1 + r.uintLessThan(u8, @intFromEnum(Hat.santa) - 1));
    l.ears = if (r.uintLessThan(u8, 10) < 6) .pointy else @enumFromInt(r.uintLessThan(u8, ears_info.len));
    // Com o visor, os olhos já são um acessório: só o pescoço e as bochechas.
    const n = r.uintLessThan(u8, 3);
    var tries: u8 = 0;
    while (@popCount(l.acc) < n and tries < 8) : (tries += 1) {
        const a: Acc = @enumFromInt(r.uintLessThan(u8, acc_info.len));
        if (bit(a) & eyewear != 0 and (l.eyes == .visor or l.eyes == .cyclops) and a != .glasses) continue;
        if (bit(a) & eyewear != 0 and l.acc & eyewear != 0) continue;
        if (bit(a) & neckwear != 0 and l.acc & neckwear != 0) continue;
        l.acc |= bit(a);
    }
    l.usePalette(r.uintLessThan(u8, palettes.len));
    return l;
}

// --- Texto curto do settings.kdl ----------------------------------------------------

/// O visual em uma linha (`mascot_look` no settings.kdl), só com o que não é o padrão:
///
///     eyes=stars mouth=cat hat=wizard acc=scarf,blush pal=meia-noite
///
/// Quem não conhece uma chave ou um valor (uma versão mais velha, ou mais nova) ignora.
pub fn writeCompact(l: *const Look, buf: []u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    compactTo(l, &w) catch return w.buffered();
    return w.buffered();
}

fn compactTo(l: *const Look, w: *std.Io.Writer) !void {
    var first = true;
    const sep = struct {
        fn f(wr: *std.Io.Writer, fst: *bool) !void {
            if (!fst.*) try wr.writeByte(' ');
            fst.* = false;
        }
    }.f;
    if (l.eyes != .prompt) {
        try sep(w, &first);
        try w.print("eyes={s}", .{eyes_info[@intFromEnum(l.eyes)].id});
    }
    if (l.mouth != .smile) {
        try sep(w, &first);
        try w.print("mouth={s}", .{mouth_info[@intFromEnum(l.mouth)].id});
    }
    if (l.hat != .none) {
        try sep(w, &first);
        try w.print("hat={s}", .{hat_info[@intFromEnum(l.hat)].id});
    }
    if (l.ears != .pointy) {
        try sep(w, &first);
        try w.print("ears={s}", .{ears_info[@intFromEnum(l.ears)].id});
    }
    if (l.acc & all_acc != 0) {
        try sep(w, &first);
        try w.writeAll("acc=");
        var n: usize = 0;
        for (acc_info, 0..) |a, i| if (l.acc & (@as(u16, 1) << @intCast(i)) != 0) {
            if (n > 0) try w.writeByte(',');
            try w.writeAll(a.id);
            n += 1;
        };
    }
    switch (l.paint) {
        .brand => {},
        .theme => {
            try sep(w, &first);
            try w.writeAll("paint=theme");
        },
        .custom => {
            try sep(w, &first);
            if (l.palette < palettes.len and colorsEql(l.colors, paletteColors(l.palette))) {
                try w.print("pal={s}", .{palettes[l.palette].id});
            } else {
                try w.writeAll("colors=");
                for (l.colors, 0..) |c, i| {
                    if (i > 0) try w.writeByte('/');
                    var hb: [10]u8 = undefined;
                    try w.writeAll(hexText(&hb, c));
                }
            }
        },
    }
    if (l.draw_from.len > 0) {
        try sep(w, &first);
        try w.writeAll("draw=");
        // Espaço, "%" e "=" num nome de arquivo viram %20, %25 e %3D.
        for (l.draw_from.slice()) |ch| switch (ch) {
            ' ' => try w.writeAll("%20"),
            '%' => try w.writeAll("%25"),
            '=' => try w.writeAll("%3D"),
            else => if (ch >= 0x20) try w.writeByte(ch),
        };
    }
}

fn colorsEql(a: Colors, b: Colors) bool {
    for (a, b) |x, y| if (x.col(1) != y.col(1)) return false;
    return true;
}

/// "#RRGGBB" (ou "#RRGGBBAA" com transparência).
pub fn hexText(buf: []u8, c: Rgba) []const u8 {
    const q = struct {
        fn f(x: f32) u8 {
            return @intFromFloat(std.math.clamp(x, 0, 1) * 255.0 + 0.5);
        }
    }.f;
    if (q(c.a) == 255) return std.fmt.bufPrint(buf, "#{X:0>2}{X:0>2}{X:0>2}", .{ q(c.r), q(c.g), q(c.b) }) catch "#000000";
    return std.fmt.bufPrint(buf, "#{X:0>2}{X:0>2}{X:0>2}{X:0>2}", .{ q(c.r), q(c.g), q(c.b), q(c.a) }) catch "#000000";
}

/// "#RRGGBB", "#RGB", "#RRGGBBAA" (com ou sem o "#").
pub fn parseColor(s: []const u8) ?Rgba {
    const t = std.mem.trim(u8, s, " \t");
    const h = if (std.mem.startsWith(u8, t, "#")) t[1..] else t;
    if (h.len != 3 and h.len != 4 and h.len != 6 and h.len != 8) return null;
    return color.parseHex(h) catch null;
}

fn find(comptime E: type, table: []const Info, s: []const u8) ?E {
    for (table, 0..) |x, i| if (std.mem.eql(u8, x.id, s)) return @enumFromInt(i);
    return null;
}
pub fn eyesFrom(s: []const u8) ?Eyes {
    return find(Eyes, &eyes_info, s);
}
pub fn mouthFrom(s: []const u8) ?Mouth {
    return find(Mouth, &mouth_info, s);
}
pub fn hatFrom(s: []const u8) ?Hat {
    return find(Hat, &hat_info, s);
}
pub fn earsFrom(s: []const u8) ?Ears {
    return find(Ears, &ears_info, s);
}
pub fn accFrom(s: []const u8) ?Acc {
    return find(Acc, &acc_info, s);
}
pub fn paletteFrom(s: []const u8) ?u8 {
    for (palettes, 0..) |p, i| if (std.mem.eql(u8, p.id, s)) return @intCast(i);
    return null;
}

/// O contrário de `writeCompact`. Lê o que conhece; o resto fica no padrão.
pub fn parseCompact(text: []const u8) Look {
    var l: Look = .{};
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n");
    while (it.next()) |tok| {
        const eq = std.mem.indexOfScalar(u8, tok, '=') orelse continue;
        const k = tok[0..eq];
        const v = tok[eq + 1 ..];
        if (std.mem.eql(u8, k, "eyes")) {
            if (eyesFrom(v)) |e| l.eyes = e;
        } else if (std.mem.eql(u8, k, "mouth")) {
            if (mouthFrom(v)) |m| l.mouth = m;
        } else if (std.mem.eql(u8, k, "hat")) {
            if (hatFrom(v)) |h| l.hat = h;
        } else if (std.mem.eql(u8, k, "ears")) {
            if (earsFrom(v)) |e| l.ears = e;
        } else if (std.mem.eql(u8, k, "acc")) {
            var acc_it = std.mem.tokenizeScalar(u8, v, ',');
            while (acc_it.next()) |a| if (accFrom(a)) |x| toggleOn(&l, x);
        } else if (std.mem.eql(u8, k, "paint")) {
            if (std.mem.eql(u8, v, "theme")) l.paint = .theme;
        } else if (std.mem.eql(u8, k, "pal")) {
            if (paletteFrom(v)) |i| l.usePalette(i);
        } else if (std.mem.eql(u8, k, "colors")) {
            var cs: Colors = brand_colors;
            var ci = std.mem.tokenizeScalar(u8, v, '/');
            var n: usize = 0;
            var ok = true;
            while (ci.next()) |hx| : (n += 1) {
                if (n >= 5) break;
                cs[n] = parseColor(hx) orelse {
                    ok = false;
                    break;
                };
            }
            if (ok and n == 5) {
                l.paint = .custom;
                l.palette = no_palette;
                l.colors = cs;
            }
        } else if (std.mem.eql(u8, k, "draw")) {
            var nb: [Name.max_name]u8 = undefined;
            var n: usize = 0;
            var i: usize = 0;
            while (i < v.len and n < nb.len) {
                if (v[i] == '%' and i + 3 <= v.len) {
                    if (std.fmt.parseInt(u8, v[i + 1 .. i + 3], 16)) |b| {
                        nb[n] = b;
                        n += 1;
                        i += 3;
                        continue;
                    } else |_| {}
                }
                nb[n] = v[i];
                n += 1;
                i += 1;
            }
            l.draw_from.set(nb[0..n]);
        }
    }
    // Olhos e boca "do arquivo" só com o arquivo dos desenhos.
    if (l.draw_from.len == 0) {
        if (l.eyes == .custom) l.eyes = .prompt;
        if (l.mouth == .custom) l.mouth = .smile;
    }
    return l;
}

/// Liga sem desligar (ler um texto não alterna).
fn toggleOn(l: *Look, a: Acc) void {
    if (!l.has(a)) l.toggle(a);
}

// --- Expressões ---------------------------------------------------------------------

/// O que cada cara pede dos olhos e da boca, em números: cada estilo desenha a partir
/// deles (assim toda combinação de olhos e boca tem todas as expressões).
pub const Expr = struct {
    /// Olhos: 1 abertos, 0 fechados.
    open: f32 = 1,
    /// Olhos fechados em arco: + feliz ("^"), - triste ("u"), 0 um risco.
    arc: f32 = 0,
    /// "> <" apertados.
    squeeze: bool = false,
    /// Susto: olhos maiores (0..1).
    wide: f32 = 0,
    /// Sobrancelhas: -1 bravas ("\ /"), +1 tristes ("/ \"), 0 nenhuma.
    brow: f32 = 0,
    tear: bool = false,
    spiral: bool = false,
    /// Boca: -1 para baixo .. 1 sorriso (passa um pouco de 1 no sorriso grande).
    curve: f32 = 1,
    /// Abertura da boca (0 fechada, 1 rindo de boca toda aberta).
    gape: f32 = 0,
    /// Aberta redonda ("o") em vez de em "D".
    round: bool = false,
    /// Tremida (preocupado, tonto).
    wobble: f32 = 0,
};

pub fn exprOf(f: Face) Expr {
    return switch (f) {
        .prompt => .{},
        .sleep => .{ .open = 0, .curve = 0, .gape = 0.22, .round = true },
        .happy => .{ .open = 0, .arc = 1, .curve = 1.3 },
        .worried => .{ .squeeze = true, .brow = 1, .curve = 0, .wobble = 1 },
        .startled => .{ .wide = 1, .curve = 0, .gape = 0.42, .round = true },
        .angry => .{ .open = 0.8, .brow = -1, .curve = -1 },
        .sad => .{ .open = 0.85, .brow = 1, .tear = true, .curve = -0.8 },
        .dizzy => .{ .spiral = true, .curve = 0, .wobble = 1.2 },
        .laugh => .{ .open = 0, .arc = 1, .curve = 1.3, .gape = 1 },
    };
}

// --- Desenhos próprios (arquivos) ----------------------------------------------------

/// Onde uma forma entra: nos olhos e na boca (andam com o rosto), na frente de tudo
/// ou atrás do corpo (andam com o corpo).
pub const Layer = enum(u2) { eyes, mouth, front, back };
pub const ShapeKind = enum(u3) { circle, ellipse, rect, line, polyline, polygon };

/// Uma cor de forma: uma das cinco do mascote (segue a paleta) ou fixa.
pub const Ink = union(enum) {
    none,
    role: Role,
    rgba: Rgba,
};

pub const max_shapes = 256;
pub const max_points = 4096;
/// Pontos de uma forma (um caminho com curvas vira pontos).
pub const max_shape_points = 256;
pub const max_file_bytes = 64 * 1024;
/// Coordenadas e espessuras fora disso são apertadas (o desenho tem ~150 de largura).
const coord_limit: f32 = 400;
const width_limit: f32 = 40;

pub const Shape = struct {
    kind: ShapeKind,
    layer: Layer,
    /// Bits de `When` em que vale; 0 = o bloco padrão.
    when: u16 = 0,
    fill: Ink = .none,
    stroke: Ink = .none,
    width: f32 = 0,
    opacity: f32 = 1,
    /// circle: cx cy r; ellipse: cx cy rx ry giro(graus); rect: x y w h raio; line: x1 y1 x2 y2.
    v: [5]f32 = @splat(0),
    /// polyline e polygon: os pontos em `Drawing.points`.
    first: u16 = 0,
    count: u16 = 0,
};

pub const Drawing = struct {
    shapes: [max_shapes]Shape = undefined,
    n_shapes: u16 = 0,
    points: [max_points][2]f32 = undefined,
    n_points: u16 = 0,
    /// Por camada: as expressões que têm formas próprias, e se há formas no padrão.
    variants: [4]u16 = @splat(0),
    defaults: [4]bool = @splat(false),

    pub fn hasLayer(dw: *const Drawing, layer: Layer) bool {
        const i = @intFromEnum(layer);
        return dw.defaults[i] or dw.variants[i] != 0;
    }
    pub fn hasVariant(dw: *const Drawing, layer: Layer, w: When) bool {
        return dw.variants[@intFromEnum(layer)] & (@as(u16, 1) << @intFromEnum(w)) != 0;
    }
    /// Uma forma entra no quadro com a expressão `w`? As da expressão, se a camada tem
    /// formas para ela; senão, as do padrão.
    pub fn shows(dw: *const Drawing, s: *const Shape, w: When) bool {
        if (dw.hasVariant(s.layer, w)) return s.when & (@as(u16, 1) << @intFromEnum(w)) != 0;
        return s.when == 0;
    }
    pub fn pointsOf(dw: *const Drawing, s: *const Shape) []const [2]f32 {
        return dw.points[s.first .. s.first + s.count];
    }
    pub fn shapesSlice(dw: *const Drawing) []const Shape {
        return dw.shapes[0..dw.n_shapes];
    }
};

/// O que não deu num arquivo de mascote (mostrado como arquivo:linha:coluna).
pub const Issue = enum {
    syntax,
    too_big,
    unknown_node,
    unknown_part,
    bad_color,
    bad_number,
    too_many_shapes,
    too_many_points,
    bad_points,
    bad_path,
    unknown_when,
    nested_when,
    unknown_layer,
    not_kdl_text,
};
pub const issue_info = [_]struct { pt: []const u8, en: []const u8 }{
    .{ .pt = "erro de sintaxe do KDL", .en = "KDL syntax error" },
    .{ .pt = "arquivo maior que 64 KB", .en = "file larger than 64 KB" },
    .{ .pt = "nó desconhecido", .en = "unknown node" },
    .{ .pt = "peça desconhecida", .en = "unknown part" },
    .{ .pt = "cor inválida (use #RRGGBB, ink, body-top, body-bottom, tufts, accent, white, black ou none)", .en = "invalid color (use #RRGGBB, ink, body-top, body-bottom, tufts, accent, white, black or none)" },
    .{ .pt = "número faltando ou inválido", .en = "missing or invalid number" },
    .{ .pt = "formas demais (no máximo 256)", .en = "too many shapes (at most 256)" },
    .{ .pt = "pontos demais (no máximo 4096 no arquivo e 256 por forma)", .en = "too many points (at most 4096 in the file and 256 per shape)" },
    .{ .pt = "lista de pontos inválida (pares de números: \"x y x y …\")", .en = "invalid point list (pairs of numbers: \"x y x y …\")" },
    .{ .pt = "caminho inválido (comandos M L H V Q C Z)", .en = "invalid path (commands M L H V Q C Z)" },
    .{ .pt = "expressão desconhecida", .en = "unknown expression" },
    .{ .pt = "when dentro de when", .en = "when inside when" },
    .{ .pt = "camada desconhecida (front ou back)", .en = "unknown layer (front or back)" },
    .{ .pt = "não é um arquivo de texto UTF-8", .en = "not a UTF-8 text file" },
};

pub const Problem = struct {
    line: u32 = 0,
    col: u32 = 0,
    issue: Issue = .syntax,
};

/// O que um arquivo de mascote tem.
pub const File = struct {
    look: Look = .{},
    title: []const u8 = "",
    author: []const u8 = "",
    license: []const u8 = "",
    description: []const u8 = "",
    /// Os desenhos próprios (null: só peças prontas). Alocado com o `gpa` de `parseFile`.
    drawing: ?*Drawing = null,
};

const when_ids = [_][]const u8{ "normal", "sleep", "happy", "worried", "startled", "angry", "sad", "dizzy", "laugh", "error", "eat" };
pub fn whenId(w: When) []const u8 {
    return when_ids[@intFromEnum(w)];
}
fn whenFrom(s: []const u8) ?When {
    if (std.mem.eql(u8, s, "prompt")) return .normal;
    for (when_ids, 0..) |x, i| if (std.mem.eql(u8, x, s)) return @enumFromInt(i);
    return null;
}

const Parser = struct {
    dw: ?*Drawing = null,
    gpa: std.mem.Allocator,
    problem: *Problem,

    fn fail(p: *Parser, n: *const kdl.Node, issue: Issue) error{Bad} {
        p.problem.* = .{ .line = n.line, .col = @max(n.col, 1), .issue = issue };
        return error.Bad;
    }

    fn drawing(p: *Parser) !*Drawing {
        if (p.dw) |d| return d;
        const d = p.gpa.create(Drawing) catch return error.OutOfMemory;
        d.* = .{};
        p.dw = d;
        return d;
    }
};

/// Lê um arquivo de mascote. Erro: null, e `problem` diz onde e o quê. `gpa` aloca os
/// desenhos (quem chama solta `File.drawing`); `arena` é só para a leitura.
pub fn parseFile(gpa: std.mem.Allocator, arena: std.mem.Allocator, src: []const u8, problem: *Problem) ?File {
    problem.* = .{};
    if (src.len > max_file_bytes) {
        problem.* = .{ .line = 1, .col = 1, .issue = .too_big };
        return null;
    }
    if (!std.unicode.utf8ValidateSlice(src)) {
        problem.* = .{ .line = 1, .col = 1, .issue = .not_kdl_text };
        return null;
    }
    var diag: kdl.Diagnostic = .{};
    const nodes = kdl.parse(arena, src, &diag) catch {
        problem.* = .{ .line = @max(diag.line, 1), .col = @max(diag.column, 1), .issue = .syntax };
        return null;
    };
    var p: Parser = .{ .gpa = gpa, .problem = problem };
    var file: File = .{};
    readNodes(&p, nodes, &file) catch {
        if (p.dw) |d| gpa.destroy(d);
        return null;
    };
    file.drawing = p.dw;
    if (p.dw) |d| {
        file.look.drawing = d;
        if (d.hasLayer(.eyes)) file.look.eyes = .custom;
        if (d.hasLayer(.mouth)) file.look.mouth = .custom;
    }
    return file;
}

fn readNodes(p: *Parser, nodes: []const kdl.Node, file: *File) !void {
    for (nodes) |*n| {
        if (std.mem.eql(u8, n.name, "mascot")) {
            if (n.arg(0)) |a| if (a.asString()) |s| {
                file.title = s;
            };
            file.author = n.str("author") orelse "";
            file.license = n.str("license") orelse "";
            file.description = n.str("description") orelse "";
        } else if (std.mem.eql(u8, n.name, "look")) {
            try readLook(p, n, &file.look);
        } else if (std.mem.eql(u8, n.name, "colors")) {
            try readColors(p, n, &file.look);
        } else if (std.mem.eql(u8, n.name, "eyes")) {
            try readBlock(p, n, .eyes, 0);
        } else if (std.mem.eql(u8, n.name, "mouth")) {
            try readBlock(p, n, .mouth, 0);
        } else if (std.mem.eql(u8, n.name, "layer")) {
            const which = (n.arg(0) orelse return p.fail(n, .unknown_layer)).asString() orelse return p.fail(n, .unknown_layer);
            const layer: Layer = if (std.mem.eql(u8, which, "front")) .front else if (std.mem.eql(u8, which, "back")) .back else return p.fail(n, .unknown_layer);
            try readBlock(p, n, layer, 0);
        } else return p.fail(n, .unknown_node);
    }
}

fn readLook(p: *Parser, n: *const kdl.Node, l: *Look) !void {
    for (n.props) |pr| {
        const v = pr.value.asString() orelse return p.fail(n, .unknown_part);
        if (std.mem.eql(u8, pr.key, "eyes")) {
            const e = eyesFrom(v) orelse return p.fail(n, .unknown_part);
            if (e == .custom) return p.fail(n, .unknown_part);
            l.eyes = e;
        } else if (std.mem.eql(u8, pr.key, "mouth")) {
            const m = mouthFrom(v) orelse return p.fail(n, .unknown_part);
            if (m == .custom) return p.fail(n, .unknown_part);
            l.mouth = m;
        } else if (std.mem.eql(u8, pr.key, "hat")) {
            l.hat = hatFrom(v) orelse return p.fail(n, .unknown_part);
        } else if (std.mem.eql(u8, pr.key, "ears")) {
            l.ears = earsFrom(v) orelse return p.fail(n, .unknown_part);
        } else if (std.mem.eql(u8, pr.key, "accessories")) {
            var it = std.mem.tokenizeAny(u8, v, " ,");
            while (it.next()) |a| toggleOn(l, accFrom(a) orelse return p.fail(n, .unknown_part));
        } else return p.fail(n, .unknown_part);
    }
}

fn readColors(p: *Parser, n: *const kdl.Node, l: *Look) !void {
    if (n.flag("theme")) |t| if (t) {
        l.paint = .theme;
        return;
    };
    var cs = brand_colors;
    var pal: u8 = no_palette;
    if (n.str("palette")) |id| {
        pal = paletteFrom(id) orelse return p.fail(n, .unknown_part);
        cs = paletteColors(pal);
    }
    var own = false;
    for (n.props) |pr| {
        if (std.mem.eql(u8, pr.key, "palette") or std.mem.eql(u8, pr.key, "theme")) continue;
        const r = find(Role, &role_info, pr.key) orelse return p.fail(n, .unknown_part);
        const s = pr.value.asString() orelse return p.fail(n, .bad_color);
        cs[@intFromEnum(r)] = parseColor(s) orelse return p.fail(n, .bad_color);
        own = true;
    }
    l.paint = .custom;
    l.colors = cs;
    l.palette = if (own) no_palette else pal;
}

fn readBlock(p: *Parser, n: *const kdl.Node, layer: Layer, when: u16) !void {
    for (n.children) |*ch| {
        if (std.mem.eql(u8, ch.name, "when")) {
            if (when != 0) return p.fail(ch, .nested_when);
            var mask: u16 = 0;
            for (ch.args) |a| {
                const s = a.asString() orelse return p.fail(ch, .unknown_when);
                mask |= @as(u16, 1) << @intFromEnum(whenFrom(s) orelse return p.fail(ch, .unknown_when));
            }
            if (mask == 0) return p.fail(ch, .unknown_when);
            try readBlock(p, ch, layer, mask);
            continue;
        }
        try readShape(p, ch, layer, when);
    }
}

fn num(p: *Parser, n: *const kdl.Node, key: []const u8, default: ?f32) !f32 {
    const v = n.prop(key) orelse {
        if (default) |dv| return dv;
        return p.fail(n, .bad_number);
    };
    const x = v.asNumber() orelse return p.fail(n, .bad_number);
    if (!std.math.isFinite(x)) return p.fail(n, .bad_number);
    return @floatCast(std.math.clamp(x, -coord_limit, coord_limit));
}

fn inkOf(p: *Parser, n: *const kdl.Node, key: []const u8) !?Ink {
    const v = n.prop(key) orelse return null;
    const s = v.asString() orelse return p.fail(n, .bad_color);
    return inkFrom(s) orelse return p.fail(n, .bad_color);
}

pub fn inkFrom(s: []const u8) ?Ink {
    if (std.mem.eql(u8, s, "none")) return .none;
    if (std.mem.eql(u8, s, "white")) return .{ .rgba = Rgba.white };
    if (std.mem.eql(u8, s, "black")) return .{ .rgba = Rgba.black };
    if (find(Role, &role_info, s)) |r| return .{ .role = r };
    if (std.mem.startsWith(u8, s, "#")) if (parseColor(s)) |c| return .{ .rgba = c };
    return null;
}

fn readShape(p: *Parser, n: *const kdl.Node, layer: Layer, when: u16) !void {
    const dw = try p.drawing();
    var s: Shape = .{ .kind = .circle, .layer = layer, .when = when };
    const fill = try inkOf(p, n, "fill");
    const stroke = try inkOf(p, n, "stroke");
    s.width = std.math.clamp(try num(p, n, "width", 3), 0, width_limit);
    s.opacity = std.math.clamp(try num(p, n, "opacity", 1), 0, 1);
    // Fechadas pintam por dentro e abertas riscam, se o arquivo não disser.
    var closed = true;
    if (std.mem.eql(u8, n.name, "circle")) {
        s.kind = .circle;
        s.v = .{ try num(p, n, "cx", null), try num(p, n, "cy", null), @max(try num(p, n, "r", null), 0), 0, 0 };
    } else if (std.mem.eql(u8, n.name, "ellipse")) {
        s.kind = .ellipse;
        s.v = .{ try num(p, n, "cx", null), try num(p, n, "cy", null), @max(try num(p, n, "rx", null), 0), @max(try num(p, n, "ry", null), 0), try num(p, n, "rotate", 0) };
    } else if (std.mem.eql(u8, n.name, "rect")) {
        s.kind = .rect;
        s.v = .{ try num(p, n, "x", null), try num(p, n, "y", null), @max(try num(p, n, "w", null), 0), @max(try num(p, n, "h", null), 0), @max(try num(p, n, "r", 0), 0) };
    } else if (std.mem.eql(u8, n.name, "line")) {
        s.kind = .line;
        s.v = .{ try num(p, n, "x1", null), try num(p, n, "y1", null), try num(p, n, "x2", null), try num(p, n, "y2", null), 0 };
        closed = false;
    } else if (std.mem.eql(u8, n.name, "polyline") or std.mem.eql(u8, n.name, "polygon")) {
        closed = std.mem.eql(u8, n.name, "polygon");
        s.kind = if (closed) .polygon else .polyline;
        const text = n.str("points") orelse return p.fail(n, .bad_points);
        try readPoints(p, n, dw, text, &s);
    } else if (std.mem.eql(u8, n.name, "path")) {
        const text = n.str("d") orelse return p.fail(n, .bad_path);
        return readPath(p, n, dw, text, s, fill, stroke);
    } else return p.fail(n, .unknown_node);
    applyInks(&s, fill, stroke, closed);
    try addShape(p, n, dw, s);
}

fn applyInks(s: *Shape, fill: ?Ink, stroke: ?Ink, closed: bool) void {
    if (fill == null and stroke == null) {
        if (closed) s.fill = .{ .role = .ink } else s.stroke = .{ .role = .ink };
    } else {
        s.fill = fill orelse .none;
        s.stroke = stroke orelse .none;
    }
    // Uma linha não tem dentro.
    if (s.kind == .line or s.kind == .polyline) {
        if (s.stroke == .none and s.fill != .none) s.stroke = s.fill;
        s.fill = .none;
    }
}

fn addShape(p: *Parser, n: *const kdl.Node, dw: *Drawing, s: Shape) !void {
    if (dw.n_shapes >= max_shapes) return p.fail(n, .too_many_shapes);
    dw.shapes[dw.n_shapes] = s;
    dw.n_shapes += 1;
    const li = @intFromEnum(s.layer);
    if (s.when == 0) dw.defaults[li] = true else dw.variants[li] |= s.when;
}

fn pushPoint(p: *Parser, n: *const kdl.Node, dw: *Drawing, s: *Shape, x: f32, y: f32) !void {
    if (!std.math.isFinite(x) or !std.math.isFinite(y)) return p.fail(n, .bad_number);
    if (dw.n_points >= max_points or s.count >= max_shape_points) return p.fail(n, .too_many_points);
    dw.points[dw.n_points] = .{ std.math.clamp(x, -coord_limit, coord_limit), std.math.clamp(y, -coord_limit, coord_limit) };
    dw.n_points += 1;
    s.count += 1;
}

fn readPoints(p: *Parser, n: *const kdl.Node, dw: *Drawing, text: []const u8, s: *Shape) !void {
    s.first = dw.n_points;
    s.count = 0;
    var it = std.mem.tokenizeAny(u8, text, " ,\t\r\n");
    var pend: ?f32 = null;
    while (it.next()) |tok| {
        const v = std.fmt.parseFloat(f32, tok) catch return p.fail(n, .bad_points);
        if (pend) |x| {
            try pushPoint(p, n, dw, s, x, v);
            pend = null;
        } else pend = v;
    }
    if (pend != null or s.count < 2) return p.fail(n, .bad_points);
}

/// Um caminho no estilo do SVG (M L H V Q C Z, maiúsculas absolutas e minúsculas
/// relativas) vira uma polilinha por trecho; as curvas viram pontos.
fn readPath(p: *Parser, n: *const kdl.Node, dw: *Drawing, text: []const u8, base: Shape, fill: ?Ink, stroke: ?Ink) !void {
    var i: usize = 0;
    var cmd: u8 = 0;
    var cur: [2]f32 = .{ 0, 0 };
    var start: [2]f32 = .{ 0, 0 };
    var s: ?Shape = null;
    var any = false;
    const steps: usize = 10;
    while (true) {
        while (i < text.len and (text[i] == ' ' or text[i] == ',' or text[i] == '\t' or text[i] == '\n' or text[i] == '\r')) i += 1;
        if (i >= text.len) break;
        const ch = text[i];
        if (std.ascii.isAlphabetic(ch)) {
            cmd = ch;
            i += 1;
            if (cmd == 'Z' or cmd == 'z') {
                if (s) |*sh| {
                    if (sh.count >= 2) {
                        sh.kind = .polygon;
                        var out = sh.*;
                        applyInks(&out, fill, stroke, true);
                        try addShape(p, n, dw, out);
                        any = true;
                    }
                }
                s = null;
                cur = start;
                continue;
            }
            if (std.mem.indexOfScalar(u8, "MmLlHhVvQqCc", cmd) == null) return p.fail(n, .bad_path);
            continue;
        }
        if (cmd == 0) return p.fail(n, .bad_path);
        const rel = std.ascii.isLower(cmd);
        const ox: f32 = if (rel) cur[0] else 0;
        const oy: f32 = if (rel) cur[1] else 0;
        switch (std.ascii.toUpper(cmd)) {
            'M' => {
                const x = try pathNum(p, n, text, &i);
                const y = try pathNum(p, n, text, &i);
                if (s) |*sh| if (sh.count >= 2) {
                    var out = sh.*;
                    applyInks(&out, fill, stroke, false);
                    try addShape(p, n, dw, out);
                    any = true;
                };
                s = base;
                s.?.kind = .polyline;
                s.?.first = dw.n_points;
                s.?.count = 0;
                cur = .{ ox + x, oy + y };
                start = cur;
                try pushPoint(p, n, dw, &s.?, cur[0], cur[1]);
                // Pares seguidos depois do M são linhas.
                cmd = if (rel) 'l' else 'L';
            },
            'L' => {
                const x = try pathNum(p, n, text, &i);
                const y = try pathNum(p, n, text, &i);
                cur = .{ ox + x, oy + y };
                try pushPoint(p, n, dw, try open(p, n, &s), cur[0], cur[1]);
            },
            'H' => {
                const x = try pathNum(p, n, text, &i);
                cur = .{ ox + x, cur[1] };
                try pushPoint(p, n, dw, try open(p, n, &s), cur[0], cur[1]);
            },
            'V' => {
                const y = try pathNum(p, n, text, &i);
                cur = .{ cur[0], oy + y };
                try pushPoint(p, n, dw, try open(p, n, &s), cur[0], cur[1]);
            },
            'Q' => {
                const x1 = ox + try pathNum(p, n, text, &i);
                const y1 = oy + try pathNum(p, n, text, &i);
                const x2 = ox + try pathNum(p, n, text, &i);
                const y2 = oy + try pathNum(p, n, text, &i);
                const sh = try open(p, n, &s);
                for (1..steps + 1) |k| {
                    const t = @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(steps));
                    const u = 1 - t;
                    try pushPoint(p, n, dw, sh, u * u * cur[0] + 2 * u * t * x1 + t * t * x2, u * u * cur[1] + 2 * u * t * y1 + t * t * y2);
                }
                cur = .{ x2, y2 };
            },
            'C' => {
                const x1 = ox + try pathNum(p, n, text, &i);
                const y1 = oy + try pathNum(p, n, text, &i);
                const x2 = ox + try pathNum(p, n, text, &i);
                const y2 = oy + try pathNum(p, n, text, &i);
                const x3 = ox + try pathNum(p, n, text, &i);
                const y3 = oy + try pathNum(p, n, text, &i);
                const sh = try open(p, n, &s);
                for (1..steps + 1) |k| {
                    const t = @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(steps));
                    const u = 1 - t;
                    try pushPoint(p, n, dw, sh, u * u * u * cur[0] + 3 * u * u * t * x1 + 3 * u * t * t * x2 + t * t * t * x3, u * u * u * cur[1] + 3 * u * u * t * y1 + 3 * u * t * t * y2 + t * t * t * y3);
                }
                cur = .{ x3, y3 };
            },
            else => return p.fail(n, .bad_path),
        }
    }
    if (s) |*sh| if (sh.count >= 2) {
        var out = sh.*;
        applyInks(&out, fill, stroke, false);
        try addShape(p, n, dw, out);
        any = true;
    };
    if (!any) return p.fail(n, .bad_path);
}

fn open(p: *Parser, n: *const kdl.Node, s: *?Shape) !*Shape {
    if (s.*) |*sh| return sh;
    return p.fail(n, .bad_path);
}

fn pathNum(p: *Parser, n: *const kdl.Node, text: []const u8, i: *usize) !f32 {
    while (i.* < text.len and (text[i.*] == ' ' or text[i.*] == ',' or text[i.*] == '\t' or text[i.*] == '\n' or text[i.*] == '\r')) i.* += 1;
    const st = i.*;
    if (i.* < text.len and (text[i.*] == '-' or text[i.*] == '+')) i.* += 1;
    var dot = false;
    while (i.* < text.len) : (i.* += 1) {
        const ch = text[i.*];
        if (ch >= '0' and ch <= '9') continue;
        if (ch == '.' and !dot) {
            dot = true;
            continue;
        }
        break;
    }
    if (i.* == st) return p.fail(n, .bad_path);
    const v = std.fmt.parseFloat(f32, text[st..i.*]) catch return p.fail(n, .bad_path);
    if (!std.math.isFinite(v)) return p.fail(n, .bad_path);
    return v;
}

// --- Escrever um arquivo -------------------------------------------------------------

pub const Meta = struct {
    title: []const u8 = "",
    author: []const u8 = "",
    license: []const u8 = "CC0-1.0",
};

/// O arquivo de um visual ("Salvar como arquivo"): peças, cores e, se houver, os
/// desenhos próprios. Ler de volta dá o mesmo visual (os testes conferem).
pub fn writeFile(l: *const Look, meta: Meta, out: *std.ArrayList(u8), gpa: std.mem.Allocator) !void {
    var w: std.Io.Writer.Allocating = .fromArrayList(gpa, out);
    defer out.* = w.toArrayList();
    const o = &w.writer;
    try o.writeAll("// A larperCord mascot (Settings → Mascot → Customize → Save as file).\n");
    try o.writeAll("// Edit it and save: the app reloads it right away. Guide:\n");
    try o.writeAll("// https://rshacudevidro.github.io/larperCord/guide/mascots.html\n");
    try o.writeAll("mascot ");
    try kdlString(o, meta.title);
    if (meta.author.len > 0) {
        try o.writeAll(" author=");
        try kdlString(o, meta.author);
    }
    if (meta.license.len > 0) {
        try o.writeAll(" license=");
        try kdlString(o, meta.license);
    }
    try o.writeAll("\n\n");
    try o.print("look eyes=\"{s}\" mouth=\"{s}\" hat=\"{s}\" ears=\"{s}\"", .{
        eyes_info[@intFromEnum(if (l.eyes == .custom) Eyes.prompt else l.eyes)].id,
        mouth_info[@intFromEnum(if (l.mouth == .custom) Mouth.smile else l.mouth)].id,
        hat_info[@intFromEnum(l.hat)].id,
        ears_info[@intFromEnum(l.ears)].id,
    });
    if (l.acc & all_acc != 0) {
        try o.writeAll(" accessories=\"");
        var n: usize = 0;
        for (acc_info, 0..) |a, i| if (l.acc & (@as(u16, 1) << @intCast(i)) != 0) {
            if (n > 0) try o.writeByte(' ');
            try o.writeAll(a.id);
            n += 1;
        };
        try o.writeByte('"');
    }
    try o.writeByte('\n');
    switch (l.paint) {
        .brand => try o.writeAll("// No `colors`: the default purple (the corner mascot follows the theme accent).\n"),
        .theme => try o.writeAll("colors theme=#true\n"),
        .custom => if (l.palette < palettes.len and colorsEql(l.colors, paletteColors(l.palette))) {
            try o.print("colors palette=\"{s}\"\n", .{palettes[l.palette].id});
        } else {
            try o.writeAll("colors");
            for (l.colors, 0..) |c, i| {
                var hb: [10]u8 = undefined;
                try o.print(" {s}=\"{s}\"", .{ role_info[i].id, hexText(&hb, c) });
            }
            try o.writeByte('\n');
        },
    }
    if (l.drawing) |dw| try writeDrawing(o, dw);
}

fn kdlString(o: *std.Io.Writer, s: []const u8) !void {
    try o.writeByte('"');
    for (s) |ch| switch (ch) {
        '"' => try o.writeAll("\\\""),
        '\\' => try o.writeAll("\\\\"),
        '\n' => try o.writeAll("\\n"),
        else => if (ch >= 0x20) try o.writeByte(ch),
    };
    try o.writeByte('"');
}

fn numText(buf: []u8, x: f32) []const u8 {
    const r = @round(x * 100) / 100;
    var s = std.fmt.bufPrint(buf, "{d:.2}", .{r}) catch return "0";
    if (std.mem.indexOfScalar(u8, s, '.') != null) {
        while (s.len > 0 and s[s.len - 1] == '0') s = s[0 .. s.len - 1];
        if (s.len > 0 and s[s.len - 1] == '.') s = s[0 .. s.len - 1];
    }
    if (std.mem.eql(u8, s, "-0")) return "0";
    return s;
}

fn inkText(buf: []u8, k: Ink) []const u8 {
    return switch (k) {
        .none => "none",
        .role => |r| role_info[@intFromEnum(r)].id,
        .rgba => |c| hexText(buf, c),
    };
}

fn writeDrawing(o: *std.Io.Writer, dw: *const Drawing) !void {
    const layers = [_]Layer{ .eyes, .mouth, .front, .back };
    for (layers) |layer| {
        if (!dw.hasLayer(layer)) continue;
        switch (layer) {
            .eyes => try o.writeAll("\neyes {\n"),
            .mouth => try o.writeAll("\nmouth {\n"),
            .front => try o.writeAll("\nlayer \"front\" {\n"),
            .back => try o.writeAll("\nlayer \"back\" {\n"),
        }
        // O padrão primeiro, depois um `when` por conjunto de expressões.
        for (dw.shapesSlice()) |*s| if (s.layer == layer and s.when == 0) try writeShape(o, dw, s, "    ");
        for (dw.shapesSlice(), 0..) |*s, i| {
            if (s.layer != layer or s.when == 0 or seenWhen(dw, layer, s.when, i)) continue;
            try o.writeAll("    when");
            for (0..when_ids.len) |b| if (s.when & (@as(u16, 1) << @intCast(b)) != 0) try o.print(" \"{s}\"", .{when_ids[b]});
            try o.writeAll(" {\n");
            for (dw.shapesSlice()[i..]) |*t| if (t.layer == layer and t.when == s.when) try writeShape(o, dw, t, "        ");
            try o.writeAll("    }\n");
        }
        try o.writeAll("}\n");
    }
}

/// Já saiu um `when` com exatamente estas expressões antes da forma `i`?
fn seenWhen(dw: *const Drawing, layer: Layer, when: u16, i: usize) bool {
    for (dw.shapesSlice()[0..i]) |*s| if (s.layer == layer and s.when == when) return true;
    return false;
}

fn writeShape(o: *std.Io.Writer, dw: *const Drawing, s: *const Shape, indent: []const u8) !void {
    var b: [5][24]u8 = undefined;
    try o.writeAll(indent);
    switch (s.kind) {
        .circle => try o.print("circle cx={s} cy={s} r={s}", .{ numText(&b[0], s.v[0]), numText(&b[1], s.v[1]), numText(&b[2], s.v[2]) }),
        .ellipse => {
            try o.print("ellipse cx={s} cy={s} rx={s} ry={s}", .{ numText(&b[0], s.v[0]), numText(&b[1], s.v[1]), numText(&b[2], s.v[2]), numText(&b[3], s.v[3]) });
            if (s.v[4] != 0) try o.print(" rotate={s}", .{numText(&b[4], s.v[4])});
        },
        .rect => {
            try o.print("rect x={s} y={s} w={s} h={s}", .{ numText(&b[0], s.v[0]), numText(&b[1], s.v[1]), numText(&b[2], s.v[2]), numText(&b[3], s.v[3]) });
            if (s.v[4] != 0) try o.print(" r={s}", .{numText(&b[4], s.v[4])});
        },
        .line => try o.print("line x1={s} y1={s} x2={s} y2={s}", .{ numText(&b[0], s.v[0]), numText(&b[1], s.v[1]), numText(&b[2], s.v[2]), numText(&b[3], s.v[3]) }),
        .polyline, .polygon => {
            try o.writeAll(if (s.kind == .polygon) "polygon points=\"" else "polyline points=\"");
            for (dw.pointsOf(s), 0..) |pt, i| {
                if (i > 0) try o.writeByte(' ');
                try o.print("{s} {s}", .{ numText(&b[0], pt[0]), numText(&b[1], pt[1]) });
            }
            try o.writeByte('"');
        },
    }
    var cb: [12]u8 = undefined;
    try o.print(" fill=\"{s}\"", .{inkText(&cb, s.fill)});
    try o.print(" stroke=\"{s}\"", .{inkText(&cb, s.stroke)});
    if (s.stroke != .none) try o.print(" width={s}", .{numText(&b[0], s.width)});
    if (s.opacity < 1) try o.print(" opacity={s}", .{numText(&b[0], s.opacity)});
    try o.writeByte('\n');
}

// --- Testes -----------------------------------------------------------------------------

const testing = std.testing;

test "as tabelas têm um nome por peça e os nomes não se repetem" {
    try testing.expectEqual(@typeInfo(Eyes).@"enum".field_names.len, eyes_info.len);
    try testing.expectEqual(@typeInfo(Mouth).@"enum".field_names.len, mouth_info.len);
    try testing.expectEqual(@typeInfo(Hat).@"enum".field_names.len, hat_info.len);
    try testing.expectEqual(@typeInfo(Acc).@"enum".field_names.len, acc_info.len);
    try testing.expectEqual(@typeInfo(Ears).@"enum".field_names.len, ears_info.len);
    // O que o pedido exigia: pelo menos 10 olhos, 14 bocas, 12 chapéus além dos das
    // datas, 8 acessórios, 10 paletas e 6 visuais prontos.
    try testing.expect(eyes_info.len - 1 >= 10);
    try testing.expect(mouth_info.len - 1 >= 14);
    try testing.expect(hat_info.len - 4 >= 12);
    try testing.expect(acc_info.len >= 8);
    try testing.expect(palettes.len >= 10);
    try testing.expect(presets.len >= 6);
    inline for (.{ &eyes_info, &mouth_info, &hat_info, &acc_info, &ears_info }) |t| {
        for (t, 0..) |a, i| for (t[i + 1 ..]) |b| try testing.expect(!std.mem.eql(u8, a.id, b.id));
    }
    for (presets, 0..) |a, i| for (presets[i + 1 ..]) |b| {
        try testing.expect(!std.mem.eql(u8, a.id, b.id));
        try testing.expect(!a.look.eql(&b.look));
    };
}

test "o traço do rosto de cada paleta tem contraste com o corpo" {
    for (palettes) |p| {
        const c = hexColors(p.hex);
        const mid = c[0].mix(c[1], 0.5);
        if (c[2].contrast(mid) < 3) {
            std.debug.print("paleta {s}: contraste {d:.2}\n", .{ p.id, c[2].contrast(mid) });
            return error.LowContrast;
        }
    }
    // Com as cores do tema: o traço vira claro numa cor de destaque escura.
    const dark = themeColors(Rgba.hex(0x1E2A5A));
    try testing.expect(dark[2].contrast(dark[0].mix(dark[1], 0.5)) >= 3);
    const light = themeColors(Rgba.hex(0xF0B232));
    try testing.expect(light[2].contrast(light[0].mix(light[1], 0.5)) >= 3);
}

test "o visual padrão é o de sempre e vira um texto vazio" {
    const l: Look = .{};
    try testing.expect(l.isDefault());
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("", writeCompact(&l, &buf));
    try testing.expect(parseCompact("").isDefault());
    // As cores da marca no canto seguem o tema; nos outros lugares, o roxo.
    const pet = l.colorsFor(Rgba.hex(0x5865F2), true);
    try testing.expect(pet[0].col(1) != brand_colors[0].col(1));
    try testing.expectEqual(brand_colors[2].col(1), pet[2].col(1));
    try testing.expectEqual(brand_colors[0].col(1), l.colorsFor(Rgba.hex(0x5865F2), false)[0].col(1));
}

test "texto curto: escrever e ler dá o mesmo visual (prontos, sorteados e cores próprias)" {
    var buf: [256]u8 = undefined;
    for (presets) |p| {
        const t = writeCompact(&p.look, &buf);
        try testing.expect(t.len < 255);
        try testing.expect(parseCompact(t).eql(&p.look));
    }
    var seed: u64 = 1;
    while (seed < 200) : (seed += 1) {
        const l = random(seed);
        const t = writeCompact(&l, &buf);
        try testing.expect(parseCompact(t).eql(&l));
    }
    var own: Look = .{ .eyes = .cyclops, .mouth = .whistle, .hat = .propeller, .ears = .floppy };
    own.acc = bits(&.{ .shades, .blush, .freckles, .bandaid, .mustache, .scarf, .earring });
    own.paint = .custom;
    own.colors = hexColors(.{ 0x112233, 0x445566, 0xFFEEDD, 0x778899, 0xAABBCC });
    own.colors[4].a = 0.5;
    own.draw_from.set("meu mascote=100%");
    const t = writeCompact(&own, &buf);
    try testing.expect(t.len < 255);
    const back = parseCompact(t);
    try testing.expect(back.eql(&own));
    try testing.expectEqualStrings("meu mascote=100%", back.draw_from.slice());
    // Seguir o tema.
    const th: Look = .{ .paint = .theme };
    try testing.expect(parseCompact(writeCompact(&th, &buf)).eql(&th));
}

test "texto curto estranho não quebra: chaves e valores desconhecidos ficam no padrão" {
    const l = parseCompact("eyes=nada mouth= hat=crown acc=glasses,shades,xyz colors=#12/#zz pal=inexistente draw=%G0x % =x ===");
    try testing.expectEqual(Eyes.prompt, l.eyes);
    try testing.expectEqual(Mouth.smile, l.mouth);
    try testing.expectEqual(Hat.crown, l.hat);
    // Dois do mesmo grupo: fica o último.
    try testing.expect(l.has(.shades) and !l.has(.glasses));
    try testing.expectEqual(Paint.brand, l.paint);
    // Peças "do arquivo" só entram com o arquivo dos desenhos.
    try testing.expectEqual(Eyes.prompt, parseCompact("eyes=custom").eyes);
    const drawn = parseCompact("eyes=custom mouth=custom draw=bruxinho");
    try testing.expectEqual(Eyes.custom, drawn.eyes);
    try testing.expectEqual(Mouth.custom, drawn.mouth);
    var long: [600]u8 = undefined;
    @memset(&long, 'a');
    @memcpy(long[0..5], "draw=");
    try testing.expect(parseCompact(&long).draw_from.len <= Name.max_name);
}

test "acessórios do mesmo grupo se excluem" {
    var l: Look = .{};
    l.toggle(.glasses);
    l.toggle(.monocle);
    try testing.expect(!l.has(.glasses) and l.has(.monocle));
    l.toggle(.scarf);
    l.toggle(.bowtie);
    l.toggle(.blush);
    try testing.expect(!l.has(.scarf) and l.has(.bowtie) and l.has(.blush) and l.has(.monocle));
    l.toggle(.blush);
    try testing.expect(!l.has(.blush));
}

test "o sorteio respeita os grupos e nunca tira peça do arquivo nem chapéu de data" {
    var seed: u64 = 0;
    var hats: u32 = 0;
    while (seed < 500) : (seed += 1) {
        const l = random(seed);
        try testing.expect(l.eyes != .custom and l.mouth != .custom);
        try testing.expect(@intFromEnum(l.hat) < @intFromEnum(Hat.santa));
        try testing.expect(@popCount(l.acc & eyewear) <= 1 and @popCount(l.acc & neckwear) <= 1);
        try testing.expect(@popCount(l.acc) <= 2);
        try testing.expect(l.paint == .custom and l.palette < palettes.len);
        if (l.hat != .none) hats += 1;
    }
    try testing.expect(hats > 250);
}

const sample =
    \\// Um mascote de exemplo.
    \\mascot "Bruxinho" author="Fulana" license="CC0-1.0"
    \\look eyes="stars" mouth="cat" hat="wizard" ears="round" accessories="scarf blush"
    \\colors palette="meia-noite" accent="#FF00AA"
    \\eyes {
    \\    circle cx=40 cy=50 r=5
    \\    circle cx=84 cy=55 r=5 fill="#FFFFFF80" stroke="ink" width=1.5
    \\    when "happy" "laugh" {
    \\        polyline points="32 54 40 46 48 54"
    \\        polyline points="76,58 84,50 92,58" stroke="accent" width=4
    \\    }
    \\    when "sleep" { line x1=32 y1=52 x2=47 y2=52 }
    \\}
    \\mouth {
    \\    path d="M52 69 Q63.5 78 76 68" stroke="ink" width=2.6
    \\    when "eat" { ellipse cx=63.5 cy=72 rx=6 ry=7 rotate=10 }
    \\}
    \\layer "back" { rect x=-5 y=60 w=20 h=30 r=4 fill="tufts" opacity=0.5 }
    \\layer "front" {
    \\    path d="m 50 -10 l 10 -10 l 10 10 z" fill="accent"
    \\    path d="M0 0 C 10 10, 20 10, 30 0" stroke="white"
    \\}
;

test "arquivo de mascote: peças, cores, desenhos por expressão e o padrão de reserva" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var pr: Problem = .{};
    const f = parseFile(testing.allocator, arena.allocator(), sample, &pr) orelse {
        std.debug.print("{d}:{d} {s}\n", .{ pr.line, pr.col, @tagName(pr.issue) });
        return error.Parse;
    };
    defer if (f.drawing) |d| testing.allocator.destroy(d);
    try testing.expectEqualStrings("Bruxinho", f.title);
    try testing.expectEqualStrings("Fulana", f.author);
    try testing.expectEqual(Eyes.custom, f.look.eyes);
    try testing.expectEqual(Mouth.custom, f.look.mouth);
    try testing.expectEqual(Hat.wizard, f.look.hat);
    try testing.expectEqual(Ears.round, f.look.ears);
    try testing.expect(f.look.has(.scarf) and f.look.has(.blush));
    // Uma cor trocada em cima da paleta: cores próprias.
    try testing.expectEqual(Paint.custom, f.look.paint);
    try testing.expectEqual(no_palette, f.look.palette);
    try testing.expectEqual(Rgba.hex(0xFF00AA).col(1), f.look.colors[4].col(1));
    const dw = f.drawing.?;
    try testing.expect(dw.hasVariant(.eyes, .happy) and dw.hasVariant(.eyes, .laugh) and dw.hasVariant(.eyes, .sleep));
    try testing.expect(!dw.hasVariant(.eyes, .angry));
    var happy: usize = 0;
    var angry: usize = 0;
    for (dw.shapesSlice()) |*s| if (s.layer == .eyes) {
        if (dw.shows(s, .happy)) happy += 1;
        if (dw.shows(s, .angry)) angry += 1;
    };
    // Feliz: os dois arcos; bravo (sem bloco próprio): os dois círculos do padrão.
    try testing.expectEqual(@as(usize, 2), happy);
    try testing.expectEqual(@as(usize, 2), angry);
    // Polilinha sem cor risca com o traço; a do caminho com Q vira pontos.
    for (dw.shapesSlice()) |*s| if (s.kind == .polyline) try testing.expect(s.stroke != .none and s.fill == .none);
    try testing.expect(dw.hasLayer(.front) and dw.hasLayer(.back));
}

test "arquivo de mascote: escrever e ler de novo dá o mesmo visual e os mesmos desenhos" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var pr: Problem = .{};
    const a = parseFile(testing.allocator, arena.allocator(), sample, &pr).?;
    defer testing.allocator.destroy(a.drawing.?);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try writeFile(&a.look, .{ .title = a.title, .author = a.author }, &out, testing.allocator);
    const b = parseFile(testing.allocator, arena.allocator(), out.items, &pr) orelse {
        std.debug.print("{s}\n{d}:{d} {s}\n", .{ out.items, pr.line, pr.col, @tagName(pr.issue) });
        return error.Parse;
    };
    defer testing.allocator.destroy(b.drawing.?);
    try testing.expectEqualStrings(a.title, b.title);
    try testing.expect(a.look.eql(&b.look));
    const da = a.drawing.?;
    const db = b.drawing.?;
    try testing.expectEqual(da.n_shapes, db.n_shapes);
    try testing.expectEqual(da.variants, db.variants);
    try testing.expectEqual(da.defaults, db.defaults);
    // As formas saem agrupadas por camada e expressão: confere cada uma pela sua par.
    for (da.shapesSlice()) |*s| {
        var found = false;
        for (db.shapesSlice()) |*t| {
            if (sameShape(da, s, db, t)) {
                found = true;
                break;
            }
        }
        try testing.expect(found);
    }
    // E os visuais prontos, sem desenhos, também.
    for (presets) |p| {
        out.clearRetainingCapacity();
        try writeFile(&p.look, .{ .title = p.en }, &out, testing.allocator);
        const c = parseFile(testing.allocator, arena.allocator(), out.items, &pr).?;
        try testing.expect(c.drawing == null);
        try testing.expect(c.look.eql(&p.look));
    }
    const th: Look = .{ .paint = .theme, .hat = .santa };
    out.clearRetainingCapacity();
    try writeFile(&th, .{ .title = "x\"y\\z" }, &out, testing.allocator);
    const c = parseFile(testing.allocator, arena.allocator(), out.items, &pr).?;
    try testing.expect(c.look.eql(&th));
    try testing.expectEqualStrings("x\"y\\z", c.title);
}

fn sameShape(da: *const Drawing, s: *const Shape, db: *const Drawing, t: *const Shape) bool {
    if (s.kind != t.kind or s.layer != t.layer or s.when != t.when or s.count != t.count) return false;
    if (std.meta.activeTag(s.fill) != std.meta.activeTag(t.fill) or std.meta.activeTag(s.stroke) != std.meta.activeTag(t.stroke)) return false;
    if (@abs(s.width - t.width) > 0.01 and s.stroke != .none) return false;
    if (@abs(s.opacity - t.opacity) > 0.01) return false;
    for (s.v, t.v) |x, y| if (@abs(x - y) > 0.006) return false;
    for (da.pointsOf(s), db.pointsOf(t)) |p, q| if (@abs(p[0] - q[0]) > 0.006 or @abs(p[1] - q[1]) > 0.006) return false;
    return true;
}

test "arquivos ruins dizem a linha, a coluna e o porquê, sem quebrar" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const cases = [_]struct { src: []const u8, issue: Issue, line: u32 }{
        .{ .src = "look eyes=\"stars\"\nlook mouth=\"nope\"\n", .issue = .unknown_part, .line = 2 },
        .{ .src = "look eyes=\"custom\"\n", .issue = .unknown_part, .line = 1 },
        .{ .src = "colors ink=\"#12345\"\n", .issue = .bad_color, .line = 1 },
        .{ .src = "colors palette=\"nope\"\n", .issue = .unknown_part, .line = 1 },
        .{ .src = "eyes {\n  circle cx=1 cy=2\n}\n", .issue = .bad_number, .line = 2 },
        .{ .src = "eyes {\n  cirle cx=1 cy=2 r=3\n}\n", .issue = .unknown_node, .line = 2 },
        .{ .src = "eyes {\n  circle cx=1 cy=2 r=3 fill=\"roxo\"\n}\n", .issue = .bad_color, .line = 2 },
        .{ .src = "eyes {\n  polyline points=\"1 2 3\"\n}\n", .issue = .bad_points, .line = 2 },
        .{ .src = "eyes {\n  polyline points=\"1 2\"\n}\n", .issue = .bad_points, .line = 2 },
        .{ .src = "mouth {\n  path d=\"M 1 2 X 3 4\"\n}\n", .issue = .bad_path, .line = 2 },
        .{ .src = "mouth {\n  path d=\"L 1 2\"\n}\n", .issue = .bad_path, .line = 2 },
        .{ .src = "mouth {\n  path d=\"M 1 2 Q 3\"\n}\n", .issue = .bad_path, .line = 2 },
        .{ .src = "mouth {\n  when \"grumpy\" { circle cx=1 cy=1 r=1 }\n}\n", .issue = .unknown_when, .line = 2 },
        .{ .src = "mouth {\n  when \"sad\" { when \"happy\" { circle cx=1 cy=1 r=1 } }\n}\n", .issue = .nested_when, .line = 2 },
        .{ .src = "layer \"middle\" { }\n", .issue = .unknown_layer, .line = 1 },
        .{ .src = "script \"rm -rf\"\n", .issue = .unknown_node, .line = 1 },
        .{ .src = "eyes { circle cx=1 cy=2 r=3 \n", .issue = .syntax, .line = 2 },
        .{ .src = "look eyes=\"stars\" \"solto\n", .issue = .syntax, .line = 2 },
        .{ .src = "\xff\xfe l\x00o\x00o\x00k\x00", .issue = .not_kdl_text, .line = 1 },
    };
    for (cases) |cs| {
        var pr: Problem = .{};
        if (parseFile(testing.allocator, arena.allocator(), cs.src, &pr)) |f| {
            if (f.drawing) |d| testing.allocator.destroy(d);
            std.debug.print("deveria falhar: {s}\n", .{cs.src});
            return error.ShouldFail;
        }
        if (pr.issue != cs.issue or pr.line != cs.line or pr.col == 0) {
            std.debug.print("{s}\n → {d}:{d} {s}\n", .{ cs.src, pr.line, pr.col, @tagName(pr.issue) });
            return error.WrongProblem;
        }
    }
    // A coluna aponta o nó.
    var pr: Problem = .{};
    _ = parseFile(testing.allocator, arena.allocator(), "eyes {\n    circle cx=1 cy=2 fill=\"x\" r=1\n}\n", &pr);
    try testing.expectEqual(@as(u32, 5), pr.col);
}

test "limites: arquivo grande, formas e pontos demais, números absurdos" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var pr: Problem = .{};
    const big = try testing.allocator.alloc(u8, max_file_bytes + 1);
    defer testing.allocator.free(big);
    @memset(big, ' ');
    try testing.expect(parseFile(testing.allocator, arena.allocator(), big, &pr) == null);
    try testing.expectEqual(Issue.too_big, pr.issue);

    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(testing.allocator);
    try src.appendSlice(testing.allocator, "layer \"front\" {\n");
    for (0..max_shapes + 1) |_| try src.appendSlice(testing.allocator, "circle cx=1 cy=1 r=1\n");
    try src.appendSlice(testing.allocator, "}\n");
    try testing.expect(parseFile(testing.allocator, arena.allocator(), src.items, &pr) == null);
    try testing.expectEqual(Issue.too_many_shapes, pr.issue);

    src.clearRetainingCapacity();
    try src.appendSlice(testing.allocator, "eyes { polyline points=\"");
    for (0..max_shape_points + 1) |_| try src.appendSlice(testing.allocator, "1 2 ");
    try src.appendSlice(testing.allocator, "\" }\n");
    try testing.expect(parseFile(testing.allocator, arena.allocator(), src.items, &pr) == null);
    try testing.expectEqual(Issue.too_many_points, pr.issue);

    // Números enormes são apertados; NaN e infinito não entram.
    const f = parseFile(testing.allocator, arena.allocator(), "eyes { circle cx=1e30 cy=-1e30 r=5 width=999 }\n", &pr).?;
    defer testing.allocator.destroy(f.drawing.?);
    const s = f.drawing.?.shapes[0];
    try testing.expect(s.v[0] <= coord_limit and s.v[1] >= -coord_limit and s.width <= width_limit);
    try testing.expect(parseFile(testing.allocator, arena.allocator(), "eyes { polyline points=\"1 nan 3 4\" }\n", &pr) == null);
    try testing.expect(parseFile(testing.allocator, arena.allocator(), "eyes { polyline points=\"1 inf 3 4\" }\n", &pr) == null);
    // Um arquivo só com comentário é válido (o mascote padrão).
    const empty = parseFile(testing.allocator, arena.allocator(), "// nada\n", &pr).?;
    try testing.expect(empty.look.isDefault() and empty.drawing == null);
}

test "toda cara tem os números das expressões, e a de sempre é a neutra" {
    const n = exprOf(.prompt);
    try testing.expectEqual(@as(f32, 1), n.open);
    try testing.expectEqual(@as(f32, 0), n.gape);
    try testing.expect(exprOf(.laugh).gape > 0.9 and exprOf(.laugh).open == 0);
    try testing.expect(exprOf(.angry).brow < 0 and exprOf(.sad).brow > 0 and exprOf(.sad).tear);
    try testing.expect(exprOf(.dizzy).spiral and exprOf(.worried).squeeze);
    for (0..9) |i| try testing.expectEqual(i, @intFromEnum(whenOf(@enumFromInt(i))));
}
