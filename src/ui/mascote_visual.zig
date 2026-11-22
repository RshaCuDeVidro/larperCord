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

/// Até onde vão a altura dos olhos e a da boca, em unidades do desenho (+ sobe): os
/// olhos sobem até a testa sem chegar no chapéu, e a boca aberta (comendo) desce até
/// perto dos pés sem sair do corpo.
pub const eye_height_range = [2]i8{ -4, 10 };
pub const mouth_height_range = [2]i8{ -4, 8 };

/// Os ajustes de Personalizar → Mais ajustes (e as duas alturas): números inteiros,
/// zero é o desenho de sempre. Ficam no texto curto do formato (`mascot_tweaks` no
/// settings.kdl) e no nó `look` dos arquivos, com o mesmo nome (`tweak_ids`).
pub const Tweak = enum(u4) { eye_height, mouth_height, eye_x, eye_spacing, eye_tilt, eye_size, mouth_x, mouth_size, ear_size, ear_tilt, roundness, body_width };
pub const tweak_ids = [_][]const u8{ "eye-height", "mouth-height", "eye-x", "eye-spacing", "eye-tilt", "eye-size", "mouth-x", "mouth-size", "ear-size", "ear-tilt", "roundness", "body-width" };
/// Os limites de cada um. Os olhos (par) andam 6 para cada lado e se afastam de 4 a 6
/// cada um; desalinhados, um sobe e o outro desce até 3; a boca anda 10 para cada lado.
/// Assim nada sai do rosto nem do corpo, em qualquer formato (os testes conferem).
pub const tweak_range = [_][2]i8{ eye_height_range, mouth_height_range, .{ -6, 6 }, .{ -4, 6 }, .{ -6, 6 }, .{ -4, 5 }, .{ -10, 10 }, .{ -3, 4 }, .{ -4, 4 }, .{ -4, 4 }, .{ -5, 4 }, .{ -4, 4 } };
/// A força das bochechas (o acessório "blush"): 3 é a de sempre.
pub const blush_range = [2]i8{ 1, 6 };
pub const blush_usual: i8 = 3;

/// O meio e as metades do corpo no desenho (o formato arredonda em volta daqui).
const body_cx: f32 = 63.57;
const body_cy: f32 = 48;
const body_rx: f32 = 63.6;
const body_ry: f32 = 48;

/// O contorno do corpo do Terminal (assets/mascote-terminal.svg), em curvas cúbicas
/// (os arcos do SVG convertidos): aqui para os testes conferirem que olhos e boca
/// nunca saem dele. ui/mascote_terminal.zig desenha a partir disto.
pub const body_start = [2]f32{ 107.70, 8.07 };
pub const body_curves = [_][6]f32{
    .{ 99.35, 4.25, 90.53, 1.53, 81.47, 0.00 },
    .{ 80.23, 2.22, 79.11, 4.50, 78.11, 6.83 },
    .{ 68.46, 5.38, 58.65, 5.38, 49.00, 6.83 },
    .{ 48.00, 4.50, 46.88, 2.22, 45.64, 0.00 },
    .{ 36.58, 1.55, 27.75, 4.27, 19.39, 8.09 },
    .{ 2.79, 32.65, -1.71, 56.60, 0.54, 80.21 },
    .{ 10.26, 87.39, 21.14, 92.86, 32.71, 96.36 },
    .{ 35.31, 92.86, 37.62, 89.14, 39.60, 85.25 },
    .{ 35.84, 83.85, 32.21, 82.11, 28.75, 80.07 },
    .{ 29.66, 79.41, 30.55, 78.73, 31.41, 78.07 },
    .{ 51.78, 87.65, 75.36, 87.65, 95.73, 78.07 },
    .{ 96.60, 78.78, 97.49, 79.46, 98.39, 80.07 },
    .{ 94.93, 82.12, 91.29, 83.85, 87.52, 85.26 },
    .{ 89.50, 89.15, 91.80, 92.86, 94.41, 96.36 },
    .{ 105.99, 92.87, 116.88, 87.41, 126.60, 80.22 },
    .{ 129.24, 52.84, 122.09, 29.11, 107.70, 8.07 },
};

/// Onde ficam os olhos e a boca do ">_" (o direito mais baixo: o rosto é inclinado).
pub const eye_l = [2]f32{ 40, 50 };
pub const eye_r = [2]f32{ 84, 55 };
pub const mouth_ctr = [2]f32{ 63.5, 70 };
/// O olho cresce em volta de um ponto um pouco abaixo do meio: maior, ele sobe para a
/// testa em vez de descer até a boca.
pub const eye_anchor_dy: f32 = 3;

/// O nome dele (Personalizar → Nome; `name` nos arquivos): até 24 letras, sem quebra
/// de linha, guardado num tamanho fixo (o visual é copiado inteiro).
pub const PetName = struct {
    len: u8 = 0,
    buf: [max_bytes]u8 = @splat(0),

    pub const max_chars = 24;
    const max_bytes = max_chars * 4;

    pub fn slice(n: *const PetName) []const u8 {
        return n.buf[0..n.len];
    }
    /// Sem os espaços das pontas, sem caracteres de controle e com no máximo 24 letras
    /// (nunca cortando uma no meio). UTF-8 inválido fica de fora.
    pub fn set(n: *PetName, s: []const u8) void {
        n.* = .{};
        const t = std.mem.trim(u8, s, " \t\r\n");
        if (!std.unicode.utf8ValidateSlice(t)) return;
        var chars: usize = 0;
        var i: usize = 0;
        while (i < t.len and chars < max_chars) {
            const k = std.unicode.utf8ByteSequenceLength(t[i]) catch return;
            if (i + k > t.len) break;
            if (!(k == 1 and (t[i] < 0x20 or t[i] == 0x7f))) {
                @memcpy(n.buf[n.len..][0..k], t[i..][0..k]);
                n.len += @intCast(k);
                chars += 1;
            }
            i += k;
        }
        // Um espaço que sobrou no fim (cortado depois dele) também sai.
        while (n.len > 0 and n.buf[n.len - 1] == ' ') {
            n.len -= 1;
            n.buf[n.len] = 0;
        }
    }
};

/// Um visual inteiro.
pub const Look = struct {
    eyes: Eyes = .prompt,
    mouth: Mouth = .smile,
    /// A altura dos olhos e a da boca no rosto (+ sobe, - desce; 0 é o lugar de
    /// sempre). Os olhos nunca chegam mais perto da boca do que no desenho:
    /// `eye_height` >= `mouth_height` (mais a folga de `eyeMouthGap`, ver `fixHeights`).
    eye_height: i8 = 0,
    mouth_height: i8 = 0,
    /// Os olhos, juntos, para a esquerda (-) ou a direita (+); o espaço entre eles (+
    /// mais longe); um mais alto que o outro (+ o direito sobe e o esquerdo desce); o
    /// tamanho (+ maiores).
    eye_x: i8 = 0,
    eye_spacing: i8 = 0,
    eye_tilt: i8 = 0,
    eye_size: i8 = 0,
    /// A boca para os lados e o tamanho dela.
    mouth_x: i8 = 0,
    mouth_size: i8 = 0,
    /// O tamanho das orelhas (+ mais altas) e o ângulo (+ abertas para fora).
    ear_size: i8 = 0,
    ear_tilt: i8 = 0,
    /// O formato do corpo: mais redondo (+) ou mais quadrado (-), e mais gordinho (+)
    /// ou mais magrinho (-).
    roundness: i8 = 0,
    body_width: i8 = 0,
    /// A força das bochechas quando o acessório está ligado (1 a 6; 3 é a de sempre).
    blush: i8 = blush_usual,
    /// A cor só do olho direito (null: os dois iguais, como sempre).
    right_eye: ?Rgba = null,
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
    /// O nome dele. Não é parte do desenho: não conta em `eql` (um visual pronto
    /// continua ele mesmo com nome), e fica fora do texto curto (`mascot_name`).
    name: PetName = .{},

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

    pub fn tweak(l: *const Look, t: Tweak) i8 {
        return switch (t) {
            inline else => |x| @field(l, @tagName(x)),
        };
    }
    fn tweakPtr(l: *Look, t: Tweak) *i8 {
        return switch (t) {
            inline else => |x| &@field(l, @tagName(x)),
        };
    }

    /// Muda um ajuste (apertado nos limites). As alturas se empurram; os tamanhos e o
    /// desalinhado mudam a folga entre olhos e boca, e podem empurrar as alturas.
    pub fn setTweak(l: *Look, t: Tweak, v: i8) void {
        switch (t) {
            .eye_height => l.setEyeHeight(v),
            .mouth_height => l.setMouthHeight(v),
            else => {
                const r = tweak_range[@intFromEnum(t)];
                l.tweakPtr(t).* = std.math.clamp(v, r[0], r[1]);
                l.fixHeights();
            },
        }
    }

    /// As bochechas como o controle mostra: 0 desligadas, senão a força.
    pub fn blushLevel(l: *const Look) i8 {
        return if (l.has(.blush)) l.blush else 0;
    }
    /// 0 desliga o acessório; de 1 a 6 liga com essa força.
    pub fn setBlushLevel(l: *Look, v: i8) void {
        if (v <= 0) {
            l.acc &= ~bit(.blush);
            l.blush = blush_usual;
            return;
        }
        l.acc |= bit(.blush);
        l.blush = std.math.clamp(v, blush_range[0], blush_range[1]);
    }

    /// Tudo nos limites (um texto ou arquivo escrito à mão pode trazer qualquer número).
    pub fn fix(l: *Look) void {
        inline for (@typeInfo(Tweak).@"enum".field_names, 0..) |f, i| {
            if (i >= 2) @field(l, f) = std.math.clamp(@field(l, f), tweak_range[i][0], tweak_range[i][1]);
        }
        l.blush = std.math.clamp(l.blush, blush_range[0], blush_range[1]);
        l.fixHeights();
    }

    /// Quanto os olhos precisam ficar acima da boca além do desenho de sempre: olhos e
    /// boca maiores crescem um na direção do outro, e o olho mais baixo de um par
    /// desalinhado desce. Zero com os tamanhos de sempre.
    pub fn eyeMouthGap(l: *const Look) i8 {
        const e: i32 = @max(0, l.eye_size);
        const m: i32 = @max(0, l.mouth_size);
        const t: i32 = @intCast(@abs(l.eye_tilt));
        return @intCast(@divTrunc(e * 42 + m * 26 + 50, 100) + @divTrunc(t + 1, 2));
    }
    /// A boca maior não desce tanto: aberta (comendo), ela sairia por baixo do queixo.
    pub fn mouthLow(l: *const Look) i8 {
        return mouth_height_range[0] + @max(0, l.mouth_size - 2);
    }

    /// Põe as alturas nos limites, com os olhos nunca abaixo da boca mais a folga (os
    /// dois juntos demais: os olhos sobem até onde precisam).
    pub fn fixHeights(l: *Look) void {
        const gap = l.eyeMouthGap();
        const top = eye_height_range[1];
        l.eye_height = std.math.clamp(l.eye_height, eye_height_range[0], top);
        l.mouth_height = std.math.clamp(l.mouth_height, l.mouthLow(), mouth_height_range[1]);
        if (l.eye_height < l.mouth_height + gap) l.eye_height = @min(l.mouth_height + gap, top);
        if (l.eye_height < l.mouth_height + gap) l.mouth_height = l.eye_height - gap;
    }

    /// Muda a altura dos olhos; descendo até a boca, empurram a boca junto.
    pub fn setEyeHeight(l: *Look, h: i8) void {
        l.eye_height = std.math.clamp(h, eye_height_range[0], eye_height_range[1]);
        const gap = l.eyeMouthGap();
        if (l.mouth_height > l.eye_height - gap) l.mouth_height = @max(l.eye_height - gap, l.mouthLow());
        l.fixHeights();
    }

    /// Muda a altura da boca; subindo até os olhos, empurra os olhos junto.
    pub fn setMouthHeight(l: *Look, h: i8) void {
        l.mouth_height = std.math.clamp(h, mouth_height_range[0], mouth_height_range[1]);
        l.fixHeights();
    }

    /// Quanto os olhos e a boca andam no y do desenho (que cresce para baixo).
    pub fn eyeDy(l: *const Look) f32 {
        return -@as(f32, @floatFromInt(l.eye_height));
    }
    pub fn mouthDy(l: *const Look) f32 {
        return -@as(f32, @floatFromInt(l.mouth_height));
    }

    /// O formato do corpo é o de sempre?
    pub fn plainBody(l: *const Look) bool {
        return l.roundness == 0 and l.body_width == 0;
    }
    /// A largura do corpo (1 a de sempre).
    pub fn widthK(l: *const Look) f32 {
        return 1 + 0.04 * @as(f32, @floatFromInt(l.body_width));
    }

    /// O ponto (x, y) do desenho no corpo com o formato escolhido: mais redondo puxa os
    /// cantos para dentro, mais quadrado empurra para fora (um superelipse em volta do
    /// meio do corpo); a largura estica para os lados. Da cintura para baixo só os
    /// lados mudam: os pés continuam no chão. No formato de sempre, o mesmo ponto.
    pub fn bodyAp(l: *const Look, x: f32, y: f32) [2]f32 {
        if (l.plainBody()) return .{ x, y };
        var px = x;
        var py = y;
        if (l.roundness != 0) {
            const u = (x - body_cx) / body_rx;
            const w = (y - body_cy) / body_ry;
            const r = @sqrt(u * u + w * w);
            if (r > 1e-4) {
                // O expoente do superelipse: 2 é o desenho; menos, mais redondo.
                const n = std.math.pow(f32, 2, 1 - 0.125 * @as(f32, @floatFromInt(l.roundness)));
                const rho = std.math.pow(f32, std.math.pow(f32, @abs(u) / r, n) + std.math.pow(f32, @abs(w) / r, n), -1 / n);
                px = body_cx + (x - body_cx) * rho;
                if (w < 0) py = body_cy + (y - body_cy) * rho;
            }
        }
        if (l.body_width != 0) px = body_cx + (px - body_cx) * l.widthK();
        return .{ px, py };
    }
    /// Quanto o ponto (x, y) anda com o formato do corpo.
    pub fn bodyDelta(l: *const Look, x: f32, y: f32) [2]f32 {
        if (l.plainBody()) return .{ 0, 0 };
        const q = l.bodyAp(x, y);
        return .{ q[0] - x, q[1] - y };
    }

    /// O tamanho dos olhos e o da boca (1 o de sempre).
    pub fn eyeScale(l: *const Look) f32 {
        return 1 + 0.07 * @as(f32, @floatFromInt(l.eye_size));
    }
    pub fn mouthScale(l: *const Look) f32 {
        return 1 + 0.075 * @as(f32, @floatFromInt(l.mouth_size));
    }
    /// Quanto anda o olho com o meio em `ctr` (`side` -1 o esquerdo, 1 o direito, 0 o
    /// do ciclope e o visor): o par, o espaço entre eles, o desalinhado, a altura e o
    /// formato do corpo. Sem o tamanho (que cresce em volta do olho).
    pub fn eyeShift(l: *const Look, ctr: [2]f32, side: f32) [2]f32 {
        const x: f32 = @floatFromInt(l.eye_x);
        const sp: f32 = @floatFromInt(l.eye_spacing);
        const t: f32 = @floatFromInt(l.eye_tilt);
        const dx = x + side * sp;
        const dy = l.eyeDy() - side * t / 2;
        // O formato do corpo onde o olho foi parar (num corpo magrinho, o olho que foi
        // para o canto volta junto com a borda).
        const bd = l.bodyDelta(ctr[0] + dx, ctr[1] + dy);
        return .{ dx + bd[0], dy + bd[1] };
    }
    /// O meio do olho (`side` -1 ou 1) com tudo: onde o arrastar da prévia pega.
    pub fn eyeCenter(l: *const Look, side: f32) [2]f32 {
        const ctr = if (side < 0) eye_l else eye_r;
        const sh = l.eyeShift(ctr, side);
        const s = l.eyeScale();
        return .{ ctr[0] + sh[0], ctr[1] + eye_anchor_dy - eye_anchor_dy * s + sh[1] };
    }
    /// Quanto anda a boca: para os lados, a altura e o formato do corpo.
    pub fn mouthShift(l: *const Look) [2]f32 {
        const dx: f32 = @floatFromInt(l.mouth_x);
        const dy = l.mouthDy();
        const bd = l.bodyDelta(mouth_ctr[0] + dx, mouth_ctr[1] + dy);
        return .{ dx + bd[0], dy + bd[1] };
    }
    /// As orelhas: a escala (mais na altura que na largura, para a base continuar
    /// dentro da cabeça) e o giro (radianos; + abertas para fora).
    pub fn earScale(l: *const Look) [2]f32 {
        const s = 1 + 0.09 * @as(f32, @floatFromInt(l.ear_size));
        return .{ 1 + (s - 1) * 0.5, s };
    }
    pub fn earTurn(l: *const Look) f32 {
        return -0.08 * @as(f32, @floatFromInt(l.ear_tilt));
    }
    /// A força das bochechas (1 a de sempre).
    pub fn blushK(l: *const Look) f32 {
        return @as(f32, @floatFromInt(l.blush)) / @as(f32, @floatFromInt(blush_usual));
    }

    /// Mesmo visual (os desenhos contam pelo arquivo de onde vêm; o nome não conta).
    pub fn eql(a: *const Look, b: *const Look) bool {
        if (a.eyes != b.eyes or a.mouth != b.mouth or a.hat != b.hat or a.ears != b.ears or a.acc != b.acc or a.paint != b.paint) return false;
        inline for (@typeInfo(Tweak).@"enum".field_names) |f| if (@field(a, f) != @field(b, f)) return false;
        if (a.has(.blush) and a.blush != b.blush) return false;
        if ((a.right_eye == null) != (b.right_eye == null)) return false;
        if (a.right_eye) |x| if (x.col(1) != b.right_eye.?.col(1)) return false;
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

/// As posições, os tamanhos e o formato numa linha (`mascot_tweaks` no settings.kdl),
/// só o que não é o padrão:
///
///     eye-height=4 eye-spacing=-2 mouth-size=3 roundness=2 blush=5 right-eye=#29E6FF
///
/// Fica numa linha à parte do visual para as duas caberem no tamanho de cada texto do
/// settings.kdl. Cada pedaço entra inteiro ou fica de fora (nunca um número cortado).
pub fn writeTweaks(l: *const Look, buf: []u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    for (tweak_ids, 0..) |id, i| {
        const v = l.tweak(@enumFromInt(i));
        if (v != 0) piece(&w, "{s}={d}", .{ id, v });
    }
    if (l.has(.blush) and l.blush != blush_usual) piece(&w, "blush={d}", .{l.blush});
    if (l.right_eye) |re| {
        var hb: [10]u8 = undefined;
        piece(&w, "right-eye={s}", .{hexText(&hb, re)});
    }
    return w.buffered();
}

/// Um pedaço do texto curto (com o espaço antes), inteiro ou nada.
fn piece(w: *std.Io.Writer, comptime fmt: []const u8, args: anytype) void {
    var tb: [64]u8 = undefined;
    const t = std.fmt.bufPrint(&tb, fmt, args) catch return;
    const need = t.len + @intFromBool(w.end > 0);
    if (w.buffer.len - w.end < need) return;
    if (w.end > 0) w.writeByte(' ') catch return;
    w.writeAll(t) catch return;
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
    return parseLook(text, "");
}

/// O visual dos dois textos do settings.kdl: o das peças (`writeCompact`) e o do
/// formato (`writeTweaks`). Cada um aceita as chaves do outro (um texto de antes, com
/// as alturas junto das peças, continua valendo).
pub fn parseLook(look_text: []const u8, tweaks_text: []const u8) Look {
    var l: Look = .{};
    readCompact(&l, look_text);
    readCompact(&l, tweaks_text);
    // Olhos e boca "do arquivo" só com o arquivo dos desenhos.
    if (l.draw_from.len == 0) {
        if (l.eyes == .custom) l.eyes = .prompt;
        if (l.mouth == .custom) l.mouth = .smile;
    }
    l.fix();
    return l;
}

fn readCompact(l: *Look, text: []const u8) void {
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n");
    tokens: while (it.next()) |tok| {
        const eq = std.mem.indexOfScalar(u8, tok, '=') orelse continue;
        const k = tok[0..eq];
        const v = tok[eq + 1 ..];
        for (tweak_ids, 0..) |id, i| if (std.mem.eql(u8, k, id)) {
            if (heightFrom(v)) |h| l.tweakPtr(@enumFromInt(i)).* = h;
            continue :tokens;
        };
        if (std.mem.eql(u8, k, "eyes")) {
            if (eyesFrom(v)) |e| l.eyes = e;
        } else if (std.mem.eql(u8, k, "mouth")) {
            if (mouthFrom(v)) |m| l.mouth = m;
        } else if (std.mem.eql(u8, k, "blush")) {
            if (heightFrom(v)) |b| l.setBlushLevel(b);
        } else if (std.mem.eql(u8, k, "right-eye")) {
            if (parseColor(v)) |c| l.right_eye = c;
        } else if (std.mem.eql(u8, k, "hat")) {
            if (hatFrom(v)) |h| l.hat = h;
        } else if (std.mem.eql(u8, k, "ears")) {
            if (earsFrom(v)) |e| l.ears = e;
        } else if (std.mem.eql(u8, k, "acc")) {
            var acc_it = std.mem.tokenizeScalar(u8, v, ',');
            while (acc_it.next()) |a| if (accFrom(a)) |x| toggleOn(l, x);
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
}

/// Um número escrito no texto curto (inteiro; os limites ficam com `Look.fix`).
fn heightFrom(s: []const u8) ?i8 {
    const x = std.fmt.parseInt(i32, s, 10) catch return null;
    return @intCast(std.math.clamp(x, -100, 100));
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
    file.look.fix();
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
        } else if (std.mem.eql(u8, n.name, "name")) {
            // `name "Bitinho"`: o nome dele, que aparece ao parar o mouse em cima.
            const a = (n.arg(0) orelse return p.fail(n, .unknown_part)).asString() orelse return p.fail(n, .unknown_part);
            file.look.name.set(a);
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
        // As alturas, posições, tamanhos e o formato são números (inteiros; fora dos
        // limites, apertados), e a força das bochechas também (0 tira o acessório).
        const which: ?usize = for (tweak_ids, 0..) |id, i| {
            if (std.mem.eql(u8, pr.key, id)) break i;
        } else null;
        const blush = std.mem.eql(u8, pr.key, "blush");
        if (which != null or blush) {
            const x = pr.value.asNumber() orelse return p.fail(n, .bad_number);
            if (!std.math.isFinite(x)) return p.fail(n, .bad_number);
            const h: i8 = @intFromFloat(std.math.clamp(@round(x), -100, 100));
            if (which) |i| l.tweakPtr(@enumFromInt(i)).* = h else l.setBlushLevel(h);
            continue;
        }
        const v = pr.value.asString() orelse return p.fail(n, .unknown_part);
        if (std.mem.eql(u8, pr.key, "right-eye")) {
            // A cor só do olho direito; "none" deixa os dois iguais.
            l.right_eye = if (std.mem.eql(u8, v, "none")) null else parseColor(v) orelse return p.fail(n, .bad_color);
            continue;
        }
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
    try o.writeAll("\n");
    if (l.name.len > 0) {
        try o.writeAll("name ");
        try kdlString(o, l.name.slice());
        try o.writeByte('\n');
    }
    try o.writeAll("\n");
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
    for (tweak_ids, 0..) |id, i| {
        const v = l.tweak(@enumFromInt(i));
        if (v != 0) try o.print(" {s}={d}", .{ id, v });
    }
    if (l.has(.blush) and l.blush != blush_usual) try o.print(" blush={d}", .{l.blush});
    if (l.right_eye) |re| {
        var hb: [10]u8 = undefined;
        try o.print(" right-eye=\"{s}\"", .{hexText(&hb, re)});
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
    own.eye_height = 7;
    own.mouth_height = -3;
    const t = writeCompact(&own, &buf);
    try testing.expect(t.len < 255);
    var sbuf: [256]u8 = undefined;
    const back = parseLook(t, writeTweaks(&own, &sbuf));
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

test "altura dos olhos e da boca: o padrão não escreve nada, e o texto curto e o arquivo voltam iguais" {
    var buf: [256]u8 = undefined;
    // Na altura de sempre, nada muda no que fica salvo.
    const plain: Look = .{ .eyes = .stars };
    try testing.expectEqualStrings("eyes=stars", writeCompact(&plain, &buf));
    try testing.expectEqualStrings("", writeTweaks(&plain, &buf));
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try writeFile(&plain, .{ .title = "x" }, &out, testing.allocator);
    try testing.expect(std.mem.indexOf(u8, out.items, "height") == null);

    var l: Look = .{ .eyes = .cat, .mouth = .fang };
    l.setEyeHeight(6);
    l.setMouthHeight(-2);
    try testing.expectEqual(@as(i8, 6), l.eye_height);
    try testing.expectEqual(@as(i8, -2), l.mouth_height);
    try testing.expect(!l.eql(&.{ .eyes = .cat, .mouth = .fang }));
    // As alturas ficam no texto do formato, não no das peças.
    var pbuf: [256]u8 = undefined;
    const parts = writeCompact(&l, &pbuf);
    try testing.expect(std.mem.indexOf(u8, parts, "height") == null);
    const t = writeTweaks(&l, &buf);
    try testing.expectEqualStrings("eye-height=6 mouth-height=-2", t);
    try testing.expect(parseLook(parts, t).eql(&l));
    // Um texto de antes, com as alturas junto das peças, continua valendo.
    try testing.expectEqual(@as(i8, 6), parseCompact("eyes=cat eye-height=6").eye_height);

    // O arquivo ("Salvar como arquivo") escreve as duas chaves e lê de volta.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    out.clearRetainingCapacity();
    try writeFile(&l, .{ .title = "Alto" }, &out, testing.allocator);
    try testing.expect(std.mem.indexOf(u8, out.items, " eye-height=6 mouth-height=-2\n") != null);
    var pr: Problem = .{};
    const f = parseFile(testing.allocator, arena.allocator(), out.items, &pr) orelse {
        std.debug.print("{s}\n{d}:{d} {s}\n", .{ out.items, pr.line, pr.col, @tagName(pr.issue) });
        return error.Parse;
    };
    try testing.expect(f.look.eql(&l));

    // Escrito à mão: número quebrado arredonda, fora dos limites aperta.
    const g = parseFile(testing.allocator, arena.allocator(), "look eye-height=2.6 mouth-height=-1e9\n", &pr).?;
    try testing.expectEqual(@as(i8, 3), g.look.eye_height);
    try testing.expectEqual(mouth_height_range[0], g.look.mouth_height);
    // Uma altura que não é número é erro, com a linha.
    try testing.expect(parseFile(testing.allocator, arena.allocator(), "mascot \"x\"\nlook eye-height=\"alto\"\n", &pr) == null);
    try testing.expectEqual(Issue.bad_number, pr.issue);
    try testing.expectEqual(@as(u32, 2), pr.line);
    try testing.expect(parseFile(testing.allocator, arena.allocator(), "look mouth-height=#true\n", &pr) == null);
    try testing.expectEqual(Issue.bad_number, pr.issue);
}

test "altura: os limites, e os olhos e a boca se empurram sem nunca se cruzar" {
    var l: Look = .{};
    l.setEyeHeight(100);
    try testing.expectEqual(eye_height_range[1], l.eye_height);
    l.setMouthHeight(-100);
    try testing.expectEqual(mouth_height_range[0], l.mouth_height);
    // Os olhos descendo até a boca levam a boca junto.
    l = .{};
    l.setMouthHeight(2);
    try testing.expectEqual(@as(i8, 2), l.eye_height);
    l.setEyeHeight(-3);
    try testing.expectEqual(@as(i8, -3), l.eye_height);
    try testing.expectEqual(@as(i8, -3), l.mouth_height);
    l.setEyeHeight(eye_height_range[0]);
    try testing.expectEqual(l.eye_height, l.mouth_height);
    // A boca subindo até os olhos leva os olhos junto, até o alto da boca.
    l.setMouthHeight(100);
    try testing.expectEqual(mouth_height_range[1], l.mouth_height);
    try testing.expectEqual(mouth_height_range[1], l.eye_height);
    // Texto curto com os dois cruzados (escrito à mão, ou de uma versão estranha): os
    // olhos sobem até a boca; lixo fica no padrão.
    const crossed = parseCompact("eye-height=-4 mouth-height=5");
    try testing.expectEqual(@as(i8, 5), crossed.eye_height);
    try testing.expectEqual(@as(i8, 5), crossed.mouth_height);
    const junk = parseCompact("eye-height=x mouth-height= eye-height=99999999999");
    try testing.expectEqual(@as(i8, 0), junk.eye_height);
    try testing.expectEqual(@as(i8, 0), junk.mouth_height);
    try testing.expectEqual(eye_height_range[1], parseCompact("eye-height=40").eye_height);
    // Todo par dentro dos limites sai com os olhos na altura da boca ou acima.
    var e: i8 = -20;
    while (e <= 20) : (e += 1) {
        var m: i8 = -20;
        while (m <= 20) : (m += 1) {
            var a: Look = .{ .eye_height = e, .mouth_height = m };
            a.fixHeights();
            try testing.expect(a.eye_height >= a.mouth_height);
            try testing.expect(a.eye_height >= eye_height_range[0] and a.eye_height <= eye_height_range[1]);
            try testing.expect(a.mouth_height >= mouth_height_range[0] and a.mouth_height <= mouth_height_range[1]);
        }
    }
}

/// Um visual com todo ajuste fora do padrão (dentro dos limites).
fn tweaked() Look {
    var l: Look = .{ .eyes = .big, .mouth = .grin, .hat = .crown };
    l.eye_x = -3;
    l.eye_spacing = 4;
    l.eye_tilt = -2;
    l.eye_size = 2;
    l.mouth_x = 6;
    l.mouth_size = -2;
    l.ear_size = 3;
    l.ear_tilt = -4;
    l.roundness = 2;
    l.body_width = -3;
    l.eye_height = 5;
    l.mouth_height = 1;
    l.setBlushLevel(5);
    l.right_eye = Rgba.hex(0x29E6FF);
    l.fix();
    return l;
}

test "mais ajustes: o padrão não escreve nada, e o texto do formato e o arquivo voltam iguais" {
    var buf: [256]u8 = undefined;
    const plain: Look = .{};
    try testing.expectEqualStrings("", writeTweaks(&plain, &buf));
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try writeFile(&plain, .{ .title = "x" }, &out, testing.allocator);
    for (tweak_ids) |id| try testing.expect(std.mem.indexOf(u8, out.items, id) == null);
    for ([_][]const u8{ "blush", "right-eye", "\nname" }) |k| try testing.expect(std.mem.indexOf(u8, out.items, k) == null);
    // As bochechas de sempre (o acessório ligado) também não escrevem a força.
    var cheeks: Look = .{};
    cheeks.toggle(.blush);
    try testing.expectEqualStrings("", writeTweaks(&cheeks, &buf));

    var l = tweaked();
    l.name.set("Bitinho");
    try testing.expect(!l.isDefault());
    var pbuf: [256]u8 = undefined;
    const parts = writeCompact(&l, &pbuf);
    const shape = writeTweaks(&l, &buf);
    try testing.expectEqualStrings("eye-height=5 mouth-height=1 eye-x=-3 eye-spacing=4 eye-tilt=-2 eye-size=2 mouth-x=6 mouth-size=-2 ear-size=3 ear-tilt=-4 roundness=2 body-width=-3 blush=5 right-eye=#29E6FF", shape);
    // O nome não vai em nenhum dos dois textos (fica em `mascot_name`).
    try testing.expect(std.mem.indexOf(u8, parts, "Bitinho") == null and std.mem.indexOf(u8, shape, "Bitinho") == null);
    const back = parseLook(parts, shape);
    try testing.expect(back.eql(&l));
    try testing.expectEqual(@as(usize, 0), back.name.len);

    // O arquivo ("Salvar como arquivo") escreve tudo, e o nome num nó próprio.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    out.clearRetainingCapacity();
    try writeFile(&l, .{ .title = "Ajustado" }, &out, testing.allocator);
    try testing.expect(std.mem.indexOf(u8, out.items, "\nname \"Bitinho\"\n") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, " eye-x=-3 eye-spacing=4 eye-tilt=-2 eye-size=2 mouth-x=6 mouth-size=-2 ear-size=3 ear-tilt=-4 roundness=2 body-width=-3 blush=5 right-eye=\"#29E6FF\"\n") != null);
    var pr: Problem = .{};
    const f = parseFile(testing.allocator, arena.allocator(), out.items, &pr) orelse {
        std.debug.print("{s}\n{d}:{d} {s}\n", .{ out.items, pr.line, pr.col, @tagName(pr.issue) });
        return error.Parse;
    };
    try testing.expect(f.look.eql(&l));
    try testing.expectEqualStrings("Bitinho", f.look.name.slice());
    try testing.expectEqualStrings("Ajustado", f.title);

    // O nome não muda o visual: um pronto com nome continua sendo o pronto.
    var named = presets[3].look;
    named.name.set("Barba Ruiva");
    try testing.expectEqual(@as(?usize, 3), presetOf(&named));
}

test "nome: até 24 letras, sem controle nem espaço nas pontas, sem cortar uma letra" {
    var n: PetName = .{};
    n.set("  Bitinho \n");
    try testing.expectEqualStrings("Bitinho", n.slice());
    n.set("abcdefghijklmnopqrstuvwxyz0123");
    try testing.expectEqualStrings("abcdefghijklmnopqrstuvwx", n.slice());
    // Letras de mais de um byte contam como uma.
    n.set("ビットくんビットくんビットくんビットくんビットくんビ");
    try testing.expectEqual(@as(usize, PetName.max_chars * 3), n.len);
    try testing.expect(std.unicode.utf8ValidateSlice(n.slice()));
    n.set("Бит\x07ик\tон");
    try testing.expectEqualStrings("Битикон", n.slice());
    // Cortado logo depois de um espaço: o espaço sai.
    n.set("abcdefghijklmnopqrstuvw xyz");
    try testing.expectEqualStrings("abcdefghijklmnopqrstuvw", n.slice());
    n.set("\xff\xfeoi");
    try testing.expectEqual(@as(usize, 0), n.len);
    // No arquivo, com aspas e barra.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var l: Look = .{};
    l.name.set("Zé \"Bit\" \\o/");
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try writeFile(&l, .{ .title = "x" }, &out, testing.allocator);
    var pr: Problem = .{};
    const f = parseFile(testing.allocator, arena.allocator(), out.items, &pr).?;
    try testing.expectEqualStrings("Zé \"Bit\" \\o/", f.look.name.slice());
    try testing.expect(parseFile(testing.allocator, arena.allocator(), "mascot \"x\"\nname 5\n", &pr) == null);
    try testing.expectEqual(@as(u32, 2), pr.line);
}

test "mais ajustes: limites, números estranhos e as bochechas" {
    // Fora dos limites, apertado; lixo fica no padrão.
    const big = parseCompact("eye-x=99 eye-spacing=-99 eye-tilt=40 eye-size=40 mouth-x=-99 mouth-size=99 ear-size=-50 ear-tilt=50 roundness=-77 body-width=77");
    for ([_]Tweak{ .eye_x, .eye_spacing, .eye_tilt, .eye_size, .mouth_x, .mouth_size, .ear_size, .ear_tilt, .roundness, .body_width }, [_]u1{ 1, 0, 1, 1, 0, 1, 0, 1, 0, 1 }) |t, hi| {
        try testing.expectEqual(tweak_range[@intFromEnum(t)][hi], big.tweak(t));
    }
    const junk = parseCompact("eye-x=x eye-size= mouth-x=1.5 right-eye=#zz blush=nada roundness=99999999999");
    try testing.expect(junk.isDefault());
    var l: Look = .{};
    l.setTweak(.mouth_x, 100);
    try testing.expectEqual(@as(i8, 10), l.mouth_x);
    l.setTweak(.ear_tilt, -100);
    try testing.expectEqual(@as(i8, -4), l.ear_tilt);

    // Bochechas: 0 tira o acessório; o controle e o acessório são a mesma coisa.
    var b: Look = .{};
    try testing.expectEqual(@as(i8, 0), b.blushLevel());
    b.setBlushLevel(6);
    try testing.expect(b.has(.blush) and b.blushLevel() == 6);
    b.setBlushLevel(0);
    try testing.expect(!b.has(.blush) and b.isDefault());
    b.setBlushLevel(9);
    try testing.expectEqual(blush_range[1], b.blush);
    // Com o acessório desligado, a força guardada não muda o visual.
    var off: Look = .{ .blush = 5 };
    try testing.expect(off.isDefault());
    off.toggle(.blush);
    try testing.expect(!off.eql(&.{ .acc = bit(.blush) }));
    try testing.expect(parseCompact("acc=blush blush=0").isDefault());
    try testing.expectEqual(@as(i8, 4), parseLook("acc=scarf", "blush=4").blushLevel());

    // No arquivo: número quebrado arredonda, fora dos limites aperta, texto é erro com a
    // linha; a cor do olho direito tem de ser uma cor (ou "none").
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var pr: Problem = .{};
    const g = parseFile(testing.allocator, arena.allocator(), "look eye-size=2.6 mouth-x=-1e9 body-width=3 blush=2 right-eye=\"#fff\"\n", &pr).?;
    try testing.expectEqual(@as(i8, 3), g.look.eye_size);
    try testing.expectEqual(@as(i8, -10), g.look.mouth_x);
    try testing.expectEqual(@as(i8, 3), g.look.body_width);
    try testing.expectEqual(@as(i8, 2), g.look.blushLevel());
    try testing.expectEqual(Rgba.white.col(1), g.look.right_eye.?.col(1));
    try testing.expect(parseFile(testing.allocator, arena.allocator(), "look right-eye=\"none\" accessories=\"blush\" blush=0\n", &pr).?.look.isDefault());
    const bad = [_]struct { src: []const u8, issue: Issue }{
        .{ .src = "mascot \"x\"\nlook roundness=\"redondo\"\n", .issue = .bad_number },
        .{ .src = "mascot \"x\"\nlook ear-tilt=#true\n", .issue = .bad_number },
        .{ .src = "mascot \"x\"\nlook blush=\"forte\"\n", .issue = .bad_number },
        .{ .src = "mascot \"x\"\nlook right-eye=\"azul\"\n", .issue = .bad_color },
        .{ .src = "mascot \"x\"\nlook right-eye=3\n", .issue = .unknown_part },
    };
    for (bad) |cs| {
        try testing.expect(parseFile(testing.allocator, arena.allocator(), cs.src, &pr) == null);
        try testing.expectEqual(cs.issue, pr.issue);
        try testing.expectEqual(@as(u32, 2), pr.line);
    }
}

test "olhos e boca maiores ou desalinhados ganham folga, e nunca se cruzam" {
    // Nos tamanhos de sempre, folga zero: as alturas de antes continuam iguais.
    try testing.expectEqual(@as(i8, 0), (Look{}).eyeMouthGap());
    try testing.expectEqual(@as(i8, 3), (Look{ .eye_size = 5, .mouth_size = 4 }).eyeMouthGap());
    try testing.expectEqual(@as(i8, 3), (Look{ .eye_tilt = -6 }).eyeMouthGap());
    try testing.expectEqual(@as(i8, 1), (Look{ .eye_tilt = 1 }).eyeMouthGap());
    // Crescer os olhos com eles juntos da boca: os olhos sobem.
    var l: Look = .{};
    l.setTweak(.eye_size, 5);
    try testing.expectEqual(@as(i8, 2), l.eye_height);
    try testing.expectEqual(@as(i8, 0), l.mouth_height);
    // A boca grande lá embaixo sobe um pouco (aberta, sairia pelo queixo).
    l = .{};
    l.setEyeHeight(eye_height_range[0]);
    try testing.expectEqual(mouth_height_range[0], l.mouth_height);
    l.setTweak(.mouth_size, 4);
    try testing.expectEqual(@as(i8, -2), l.mouth_height);
    try testing.expect(l.eye_height >= l.mouth_height + l.eyeMouthGap());
    // Desalinhar com tudo junto: o olho de baixo fica onde estava, o outro sobe.
    l = .{};
    l.setTweak(.eye_tilt, 6);
    try testing.expectEqual(@as(i8, 3), l.eye_height);
    // Lá em cima, com a folga toda, a boca não sobe tanto.
    l = .{ .eye_size = 5, .mouth_size = 4, .eye_tilt = 6 };
    l.setMouthHeight(100);
    try testing.expectEqual(eye_height_range[1], l.eye_height);
    try testing.expectEqual(eye_height_range[1] - l.eyeMouthGap(), l.mouth_height);
    // Todo par de alturas, com todo tamanho e desalinhado: dentro dos limites e com a folga.
    var es: i8 = -4;
    while (es <= 5) : (es += 1) {
        var ms: i8 = -3;
        while (ms <= 4) : (ms += 1) {
            var t: i8 = -6;
            while (t <= 6) : (t += 3) {
                var e: i8 = -20;
                while (e <= 20) : (e += 3) {
                    var m: i8 = -20;
                    while (m <= 20) : (m += 3) {
                        var a: Look = .{ .eye_height = e, .mouth_height = m, .eye_size = es, .mouth_size = ms, .eye_tilt = t };
                        a.fix();
                        try testing.expect(a.eye_height >= a.mouth_height + a.eyeMouthGap());
                        try testing.expect(a.eye_height >= eye_height_range[0] and a.eye_height <= eye_height_range[1]);
                        try testing.expect(a.mouth_height >= a.mouthLow() and a.mouth_height <= mouth_height_range[1]);
                        var b = a;
                        b.setEyeHeight(e);
                        try testing.expect(b.eye_height >= b.mouth_height + b.eyeMouthGap() and b.mouth_height >= b.mouthLow());
                        b.setMouthHeight(m);
                        try testing.expect(b.eye_height >= b.mouth_height + b.eyeMouthGap() and b.eye_height <= eye_height_range[1]);
                    }
                }
            }
        }
    }
}

test "formato do corpo: o de sempre é o mesmo ponto, os pés ficam no chão e ele continua simétrico" {
    const plain: Look = .{};
    for ([_][2]f32{ .{ 12.5, -3 }, .{ 40, 50 }, .{ 100.25, 90 } }) |q| {
        const o = plain.bodyAp(q[0], q[1]);
        try testing.expectEqual(q[0], o[0]);
        try testing.expectEqual(q[1], o[1]);
        try testing.expectEqual([2]f32{ 0, 0 }, plain.bodyDelta(q[0], q[1]));
    }
    const corner = [2]f32{ 19.39, 8.09 };
    for ([_]i8{ -5, -2, 2, 4 }) |r| {
        for ([_]i8{ -4, 0, 4 }) |w| {
            const l: Look = .{ .roundness = r, .body_width = w };
            // Simétrico em volta do meio.
            for ([_][2]f32{ .{ 10, 20 }, .{ 30, 70 }, .{ 50, 5 }, .{ 2, 48 } }) |q| {
                const a = l.bodyAp(q[0], q[1]);
                const b = l.bodyAp(2 * body_cx - q[0], q[1]);
                try testing.expectApproxEqAbs(a[0] - body_cx, body_cx - b[0], 1e-3);
                try testing.expectApproxEqAbs(a[1], b[1], 1e-3);
            }
            // Os pés e tudo da cintura para baixo continuam na mesma altura.
            try testing.expectEqual(@as(f32, 96.36), l.bodyAp(32.71, 96.36)[1]);
            try testing.expectEqual(@as(f32, 85.25), l.bodyAp(39.6, 85.25)[1]);
            // O alto da cabeça, no meio, não sai do lugar.
            try testing.expectApproxEqAbs(@as(f32, 0), l.bodyAp(body_cx, 0)[1], 1e-4);
            // Redondo puxa o canto de cima para dentro; quadrado empurra para fora.
            const c = (Look{ .roundness = r }).bodyAp(corner[0], corner[1]);
            if (r > 0) try testing.expect(c[0] > corner[0] and c[1] > corner[1]) else try testing.expect(c[0] < corner[0] and c[1] < corner[1]);
        }
    }
    // A largura estica só para os lados.
    const wide = (Look{ .body_width = 4 }).bodyAp(0.54, 80.21);
    try testing.expect(wide[0] < 0.54 and wide[1] == 80.21);
}

/// O contorno do corpo com o formato de `l`, em pontos.
fn bodyOutline(l: *const Look, out: [][2]f32) usize {
    var n: usize = 0;
    var cur = body_start;
    for (body_curves) |q| {
        const p0 = l.bodyAp(cur[0], cur[1]);
        const p1 = l.bodyAp(q[0], q[1]);
        const p2 = l.bodyAp(q[2], q[3]);
        const p3 = l.bodyAp(q[4], q[5]);
        for (0..10) |si| {
            const t = @as(f32, @floatFromInt(si)) / 10.0;
            const u = 1 - t;
            out[n] = .{
                u * u * u * p0[0] + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t * t * t * p3[0],
                u * u * u * p0[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t * t * t * p3[1],
            };
            n += 1;
        }
        cur = .{ q[4], q[5] };
    }
    return n;
}

/// Dentro do contorno e a pelo menos `margin` da borda?
fn insideBy(poly: []const [2]f32, x: f32, y: f32, margin: f32) bool {
    var inside = false;
    var j = poly.len - 1;
    var near: f32 = std.math.inf(f32);
    for (poly, 0..) |a, i| {
        const b = poly[j];
        if ((a[1] > y) != (b[1] > y) and x < (b[0] - a[0]) * (y - a[1]) / (b[1] - a[1]) + a[0]) inside = !inside;
        const dx = b[0] - a[0];
        const dy = b[1] - a[1];
        const l2 = dx * dx + dy * dy;
        const t = if (l2 > 0) std.math.clamp(((x - a[0]) * dx + (y - a[1]) * dy) / l2, 0, 1) else 0;
        near = @min(near, std.math.hypot(x - (a[0] + dx * t), y - (a[1] + dy * t)));
        j = i;
    }
    return inside and near >= margin;
}

test "olhos e boca nunca saem do corpo nem encostam um no outro, em todo extremo" {
    // Cada ajuste no mínimo, no zero e no máximo, todos combinados (as alturas por
    // último, pelos controles, como no Personalizar).
    const T = [_]Tweak{ .eye_x, .eye_spacing, .eye_tilt, .eye_size, .mouth_x, .mouth_size, .roundness, .body_width };
    var poly: [body_curves.len * 10][2]f32 = undefined;
    var combos: usize = 0;
    var idx: [T.len + 2]u8 = @splat(0);
    outer: while (true) {
        var l: Look = .{};
        for (T, 0..) |t, i| {
            const r = tweak_range[@intFromEnum(t)];
            l.setTweak(t, switch (idx[i]) {
                0 => r[0],
                1 => 0,
                else => r[1],
            });
        }
        const hs = [3]i8{ -100, 0, 100 };
        l.setEyeHeight(hs[idx[T.len]]);
        l.setMouthHeight(hs[idx[T.len + 1]]);
        const n = bodyOutline(&l, &poly);
        const se = l.eyeScale();
        const sm = l.mouthScale();
        const ms = l.mouthShift();
        const mx = mouth_ctr[0] + ms[0];
        const my = mouth_ctr[1] + ms[1];
        // A boca: da ponta de um lado à do outro, do alto até aberta comendo.
        const half_w = 11.5 * sm;
        const top = my - 3.4 * sm;
        const open_r = 9 * sm;
        const diag = open_r * 0.7071;
        for ([_][2]f32{ .{ mx - half_w, top }, .{ mx + half_w, top }, .{ mx, my + open_r }, .{ mx - diag, my + diag }, .{ mx + diag, my + diag } }) |q| {
            if (!insideBy(poly[0..n], q[0], q[1], 0.5)) {
                std.debug.print("boca fora do corpo em ({d:.1}, {d:.1}) com {any}\n", .{ q[0], q[1], idx });
                return error.MouthOut;
            }
        }
        for ([_]f32{ -1, 1 }) |side| {
            // O maior olho de um par (o ">" do Terminal tem meia altura 9).
            const ec = l.eyeCenter(side);
            const r = 9 * se;
            if (!insideBy(poly[0..n], ec[0], ec[1], r + 2)) {
                std.debug.print("olho {d} fora do corpo em ({d:.1}, {d:.1}) r {d:.1} com {any}\n", .{ side, ec[0], ec[1], r, idx });
                return error.EyeOut;
            }
            // Em cima da boca, sempre com folga.
            if (@abs(ec[0] - mx) < r + half_w and ec[1] + r > top - 1) {
                std.debug.print("olho {d} encosta na boca: {d:.1} > {d:.1} com {any}\n", .{ side, ec[1] + r, top, idx });
                return error.EyeOnMouth;
            }
        }
        combos += 1;
        // A próxima combinação (contando em base 3).
        var k: usize = 0;
        while (k < idx.len) : (k += 1) {
            idx[k] += 1;
            if (idx[k] < 3) continue :outer;
            idx[k] = 0;
        }
        break;
    }
    try testing.expectEqual(@as(usize, 59049), combos);
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
