//! O esquema dos temas: os nós, as propriedades e os valores que o app entende, num
//! lugar só. A checagem do carregamento (avisos e erros com linha e coluna), o
//! `--theme-check`, o `--theme-lsp`, o JSON do site (docs/assets/site/theme-schema.json,
//! `zig build theme-schema`) e o teste que varre src/theme e src/ui leem daqui.
//!
//! Para pôr outra tabela (as partes de `parts.zig`, por exemplo): um `NodeSpec` a mais em
//! `top` (o bloco, com `children = .{ .named = &.{"part"} }`) e um em `child_specs` (o
//! filho, com `parent = "parts"`, o `args` com os nomes e as `props` dele). O JSON, a
//! checagem, o LSP e o criador do site passam a conhecer sem mais nada.
const std = @import("std");
const kdl = @import("kdl.zig");
const theme = @import("theme.zig");
const fx = @import("fx.zig");
const parts = @import("parts.zig");
const tpath = @import("path.zig");
const jsonx = @import("../net/jsonx.zig");

/// A versão mais nova do formato que este app entende (`theme-api N`). Sem o nó, 1:
/// o que o app não conhece vira aviso. Com 2, vira erro.
pub const api_supported: u8 = 2;

/// Versão do formato do JSON (muda quando um campo muda de sentido).
pub const json_format: u8 = 1;

pub const Kind = enum {
    number,
    boolean,
    string,
    /// Um dos `values`.
    @"enum",
    /// Palavras separadas por espaço, cada uma um dos `values`.
    words,
    /// Expressão de cor (`"alpha(@accent, 0.4)"`) ou nome de token.
    color,
    /// Duas ou três cores separadas por espaço (degradês).
    colors,
    /// Nome de um token de cor.
    token,
    /// Nome de um estilo de `styles`.
    style,
    /// Nome de uma opção de `options` (`when=`, `unless=`).
    option,
    /// `mono`, `ui` ou o nome de uma família instalada.
    font,
};

pub const Default = union(enum) { none, num: f64, flag: bool, text: []const u8 };

pub const Prop = struct {
    key: []const u8,
    kind: Kind,
    desc: []const u8,
    pt: []const u8 = "",
    values: []const []const u8 = &.{},
    /// Faixa que o app aceita (fora dela, ele limita).
    min: ?f64 = null,
    max: ?f64 = null,
    /// Régua sugerida para editores: mínimo, máximo e passo (não limita nada).
    range: ?[3]f64 = null,
    default: Default = .none,
    /// Aceita `"$opção"` / `"$!opção"` no lugar do valor.
    option_ref: bool = false,
    /// Ajuste rápido no criador de temas do site.
    tweak: bool = false,
};

/// Grupos de propriedades que vários nós têm.
pub const Set = enum {
    /// `mode=`, `when=`, `unless=` nos nós do topo.
    condition,
    /// Todo nó do layout (contêiner ou componente).
    node,
    /// Contêineres (`row`, `column`, `stack`).
    container,
    /// Componentes.
    component,
    /// Gradiente, padrão, grão, bordas por lado… (fx.zig), em nós e estilos.
    box,
};

pub const Role = enum { top, container, component, child };

pub const Children = union(enum) {
    none,
    /// Um nó só, a raiz do layout (contêiner ou componente).
    layout_root,
    /// Contêineres e componentes.
    layout,
    /// Só estes nomes.
    named: []const []const u8,
    /// Nomes de tokens de cor, cada um com uma cor (`colors`).
    tokens,
    /// Qualquer nome (`vars`).
    free,
};

pub const ArgKind = enum { string, number, color, any };

pub const Args = struct {
    kind: ArgKind,
    min: u8 = 1,
    max: u8 = 1,
    desc: []const u8,
};

pub const NodeSpec = struct {
    name: []const u8,
    role: Role,
    desc: []const u8,
    pt: []const u8 = "",
    props: []const Prop = &.{},
    sets: []const Set = &.{},
    args: ?Args = null,
    children: Children = .none,
    /// Para os filhos: o bloco onde eles ficam (`styles` para `style`).
    parent: []const u8 = "",
    /// Guarda as cores das propriedades em fx.zig (`shape`, `rule`, fundos procedurais).
    paints: bool = false,
};

/// Prefixos de propriedade com um token de cor depois: `c-text="#fff"`.
pub const Pattern = struct { prefix: []const u8, desc: []const u8 };

pub const patterns = [_]Pattern{
    .{ .prefix = "c-", .desc = "Overrides a color token on this node and its children: c-text=\"#fff\"." },
    .{ .prefix = "cl-", .desc = "Like c-, only in light mode." },
    .{ .prefix = "cd-", .desc = "Like c-, only in dark mode." },
};

/// Miniaturas das Configurações (`theme … preview=`). manager.zig usa este enum.
pub const Preview = enum { classic, glass, terminal, bubbles, zen, mirror, office, desktop };

// --- Construtores das tabelas --------------------------------------------------

const Opts = struct {
    min: ?f64 = null,
    max: ?f64 = null,
    range: ?[3]f64 = null,
    def: Default = .none,
    tweak: bool = false,
    option_ref: bool = false,
    pt: []const u8 = "",
};

fn num(key: []const u8, desc: []const u8, o: Opts) Prop {
    return .{ .key = key, .kind = .number, .desc = desc, .pt = o.pt, .min = o.min, .max = o.max, .range = o.range, .default = o.def, .tweak = o.tweak };
}

/// Booleano lido com `d.pflag` (aceita `"$opção"`).
fn flag(key: []const u8, desc: []const u8, o: Opts) Prop {
    return .{ .key = key, .kind = .boolean, .desc = desc, .pt = o.pt, .default = o.def, .tweak = o.tweak, .option_ref = true };
}

/// Booleano lido com `n.flag` (só `#true`/`#false`).
fn plainFlag(key: []const u8, desc: []const u8, o: Opts) Prop {
    return .{ .key = key, .kind = .boolean, .desc = desc, .pt = o.pt, .default = o.def, .tweak = o.tweak };
}

fn pick(key: []const u8, values: []const []const u8, desc: []const u8, o: Opts) Prop {
    return .{ .key = key, .kind = .@"enum", .values = values, .desc = desc, .pt = o.pt, .default = o.def, .tweak = o.tweak };
}

fn of(kind: Kind, key: []const u8, desc: []const u8, o: Opts) Prop {
    return .{ .key = key, .kind = kind, .desc = desc, .pt = o.pt, .default = o.def, .tweak = o.tweak, .option_ref = o.option_ref };
}

fn fieldNames(comptime E: type) []const []const u8 {
    const names = comptime blk: {
        const fields = @typeInfo(E).@"enum".field_names;
        var out: [fields.len][]const u8 = undefined;
        for (fields, 0..) |f, i| out[i] = f;
        break :blk out;
    };
    return &names;
}

const align3 = &[_][]const u8{ "left", "center", "right" };
const weights = fieldNames(fx.Weight);

// --- Tokens --------------------------------------------------------------------

pub const token_count = @typeInfo(theme.Token).@"enum".field_names.len;

/// O nome de cada token como o tema escreve (`accent-text`), tirado do enum.
pub const token_names: [token_count][]const u8 = blk: {
    var out: [token_count][]const u8 = undefined;
    for (@typeInfo(theme.Token).@"enum".field_names, 0..) |f, i| {
        var name: [f.len]u8 = undefined;
        for (f, 0..) |ch, k| name[k] = if (ch == '_') '-' else ch;
        const final = name;
        out[i] = &final;
    }
    break :blk out;
};

/// Uma descrição para cada token (falta uma: não compila).
pub const token_desc = std.EnumArray(theme.Token, []const u8).init(.{
    .bg = "Window background, behind the chat.",
    .rail = "Background of the server bar.",
    .sidebar = "Background of the channel list and the member list.",
    .surface = "Background of the chat and of cards.",
    .elevated = "Raised surfaces: inputs, popups, hovered cards.",
    .overlay = "Menus and dialogs.",
    .text = "Main text.",
    .muted = "Secondary text (channel names, times). The app raises its contrast when it's too low.",
    .faint = "Tertiary text and hints. The app raises its contrast when it's too low.",
    .accent = "The highlight color: selection, buttons, focus.",
    .accent_text = "Text drawn on top of accent.",
    .border = "Lines and borders.",
    .hover = "Background under the mouse.",
    .selected = "Background of the selected item.",
    .online = "Online status, and the ring around who is speaking.",
    .idle = "Idle status (and the mention highlight in some layouts).",
    .dnd = "Do-not-disturb status.",
    .danger = "Destructive actions and errors.",
    .mention = "Mention highlight.",
    .link = "Links.",
    .code_bg = "Background of code blocks.",
    .bubble_self = "Your chat bubbles (messages variant=bubbles).",
    .bubble_self_text = "Text in your chat bubbles.",
    .bubble_other = "Other people's chat bubbles.",
    .shadow = "Shadow color.",
});

pub fn isToken(name: []const u8) bool {
    for (token_names) |t| if (std.mem.eql(u8, t, name)) return true;
    return false;
}

// --- Grupos --------------------------------------------------------------------

pub const condition_props = [_]Prop{
    pick("mode", &.{ "dark", "light" }, "The node only applies in this mode.", .{}),
    of(.option, "when", "The node only applies when this theme option is on (modo-claro and modo-escuro also work).", .{}),
    of(.option, "unless", "The node only applies when this theme option is off.", .{}),
};

pub const node_props = [_]Prop{
    num("width", "Fixed width (in a row: the size along the row).", .{ .min = -20000, .max = 20000, .range = .{ 40, 520, 1 } }),
    num("height", "Fixed height (in a column: the size along the column).", .{ .min = -20000, .max = 20000, .range = .{ 16, 240, 1 } }),
    num("flex", "Weight in the space left over by the fixed sizes.", .{ .min = -20000, .max = 20000, .range = .{ 0, 10, 0.5 }, .def = .{ .num = 1 } }),
    num("max-width", "Limits the width and centers the node.", .{ .min = -20000, .max = 20000, .range = .{ 320, 1600, 10 } }),
    num("hide-below", "Hides the node when the window is narrower than this.", .{ .min = -20000, .max = 20000, .range = .{ 400, 1600, 10 } }),
    num("hide-below-height", "Hides the node when the window is shorter than this.", .{ .min = -20000, .max = 20000, .range = .{ 300, 1200, 10 } }),
    num("only-below-height", "Shows the node only when the window is shorter than this.", .{ .min = -20000, .max = 20000, .range = .{ 300, 1200, 10 } }),
    plainFlag("show", "#false hides the node.", .{ .def = .{ .flag = true } }),
    of(.option, "when", "Shows the node only when this theme option is on (modo-claro and modo-escuro also work).", .{}),
    of(.option, "unless", "Shows the node only when this theme option is off.", .{}),
    of(.style, "style", "A named style from styles, drawn behind the node.", .{}),
    of(.color, "bg", "Background: a token name or a color expression.", .{}),
    num("radius", "Corner radius of bg and of the primitives on this node.", .{ .range = .{ 0, 32, 1 }, .def = .{ .num = 0 } }),
    of(.color, "border", "Full border around the node.", .{}),
};

pub const container_props = [_]Prop{
    num("gap", "Space between the children.", .{ .min = -20000, .max = 20000, .range = .{ 0, 40, 1 }, .def = .{ .num = 0 } }),
    num("padding", "Inner space on every side.", .{ .min = -20000, .max = 20000, .range = .{ 0, 64, 1 }, .def = .{ .num = 0 } }),
    num("padding-x", "Inner space on the left and right (instead of padding).", .{ .min = -20000, .max = 20000, .range = .{ 0, 64, 1 } }),
    num("padding-y", "Inner space at the top and bottom (instead of padding).", .{ .min = -20000, .max = 20000, .range = .{ 0, 64, 1 } }),
};

pub const component_props = [_]Prop{
    num("inset-x", "Inner margin of the component, left and right.", .{ .min = -20000, .max = 20000, .range = .{ 0, 48, 1 }, .def = .{ .num = 0 } }),
    num("inset-y", "Inner margin of the component, top and bottom.", .{ .min = -20000, .max = 20000, .range = .{ 0, 48, 1 }, .def = .{ .num = 0 } }),
    of(.font, "font", "The component's font: mono, ui or any installed family.", .{}),
    flag("autohide", "The component fades out until the mouse gets close.", .{ .def = .{ .flag = false } }),
};

pub const box_props = [_]Prop{
    of(.colors, "gradient", "Gradient of 2 or 3 colors separated by spaces.", .{}),
    num("gradient-angle", "Gradient angle in degrees: 0 left to right, 90 top to bottom.", .{ .range = .{ 0, 360, 1 }, .def = .{ .num = 90 } }),
    pick("pattern", fieldNames(fx.PatternKind), "Repeating pattern; needs pattern-color.", .{}),
    of(.color, "pattern-color", "Color of the pattern.", .{}),
    num("pattern-size", "Distance between repeats of the pattern.", .{ .min = 2, .max = 128, .range = .{ 4, 64, 1 }, .def = .{ .num = 16 } }),
    num("pattern-width", "Stroke thickness (or dot radius) of the pattern.", .{ .min = 0.5, .max = 32, .range = .{ 0.5, 8, 0.5 }, .def = .{ .num = 1 } }),
    of(.color, "grain", "Fine noise tinted by this color.", .{}),
    of(.color, "vignette", "Darkens (or tints) the edges.", .{}),
    num("vignette-size", "Where the vignette starts: 0 at the center, 1 only in the corners.", .{ .min = 0, .max = 0.95, .range = .{ 0, 0.95, 0.05 }, .def = .{ .num = 0.55 } }),
    of(.color, "inner-shadow", "Inward shadow.", .{}),
    num("inner-shadow-size", "Size of the inward shadow.", .{ .range = .{ 0, 48, 1 }, .def = .{ .num = 14 } }),
    of(.color, "drop-shadow", "Soft hollow shadow: it doesn't darken what's under a translucent panel.", .{}),
    num("drop-shadow-size", "Size of the drop shadow.", .{ .min = 1, .range = .{ 1, 80, 1 }, .def = .{ .num = 32 } }),
    num("drop-shadow-y", "Vertical offset of the drop shadow.", .{ .range = .{ -40, 40, 1 }, .def = .{ .num = 10 } }),
    of(.color, "hover-bg", "Background drawn on top when the mouse is over it, with a transition.", .{}),
    of(.colors, "border-gradient", "Gradient border of 2 or 3 colors.", .{}),
    num("border-gradient-angle", "Angle of the gradient border, in degrees.", .{ .range = .{ 0, 360, 1 }, .def = .{ .num = 90 } }),
    num("border-width", "Border thickness.", .{ .range = .{ 0, 8, 0.5 }, .def = .{ .num = 1 } }),
    of(.color, "border-top", "Border on the top side only.", .{}),
    of(.color, "border-right", "Border on the right side only.", .{}),
    of(.color, "border-bottom", "Border on the bottom side only.", .{}),
    of(.color, "border-left", "Border on the left side only.", .{}),
    num("border-top-width", "Thickness of the top border (default: border-width, or 1).", .{ .range = .{ 0, 8, 0.5 } }),
    num("border-right-width", "Thickness of the right border (default: border-width, or 1).", .{ .range = .{ 0, 8, 0.5 } }),
    num("border-bottom-width", "Thickness of the bottom border (default: border-width, or 1).", .{ .range = .{ 0, 8, 0.5 } }),
    num("border-left-width", "Thickness of the left border (default: border-width, or 1).", .{ .range = .{ 0, 8, 0.5 } }),
    pick("corners", fieldNames(fx.Corners), "Which corners the fill rounds.", .{ .def = .{ .text = "all" } }),
};

pub fn setProps(s: Set) []const Prop {
    return switch (s) {
        .condition => &condition_props,
        .node => &node_props,
        .container => &container_props,
        .component => &component_props,
        .box => &box_props,
    };
}

// --- Nós do topo -----------------------------------------------------------------

const cond = &[_]Set{.condition};
const layout_sets = &[_]Set{ .node, .component, .box };

pub const top = [_]NodeSpec{
    .{
        .name = "theme",
        .role = .top,
        .desc = "Metadata: the name and what shows in Settings.",
        .pt = "Metadados: o nome e o que aparece nas Configurações.",
        .args = .{ .kind = .string, .desc = "The theme's name." },
        .sets = cond,
        .props = &.{
            of(.string, "description", "Description in Portuguese (shown in Settings).", .{}),
            of(.string, "description-en", "Description in English.", .{}),
            of(.string, "author", "Who made the theme.", .{}),
            of(.string, "license", "SPDX license identifier (the community gallery asks for one; the app ignores it).", .{}),
            pick("preview", fieldNames(Preview), "Which thumbnail Settings draws for the theme.", .{ .def = .{ .text = "classic" } }),
        },
    },
    .{
        .name = "theme-api",
        .role = .top,
        .desc = "Version of the theme format. 2 = strict: unknown components, properties and values are errors. Without it, 1: they're warnings.",
        .pt = "Versão do formato do tema. 2 = estrito: componentes, propriedades e valores desconhecidos são erros. Sem ele, 1: são avisos.",
        .args = .{ .kind = .number, .desc = "1 or 2." },
    },
    .{
        .name = "extends",
        .role = .top,
        .desc = "Starts from another theme (built-in or in your themes folder) and changes only what differs.",
        .pt = "Parte de outro tema (embutido ou da sua pasta de temas) e muda só o que for diferente.",
        .args = .{ .kind = .string, .desc = "Name of the base theme, like \"classico\"." },
    },
    .{
        .name = "palette",
        .role = .top,
        .desc = "The 16 base colors (wal:0 … wal:15): \"wal\" for pywal's, or up to 16 hex colors.",
        .pt = "As 16 cores base (wal:0 … wal:15): \"wal\" para as do pywal, ou até 16 cores hex.",
        .args = .{ .kind = .string, .min = 1, .max = 16, .desc = "\"wal\", or hex colors." },
        .sets = cond,
    },
    .{
        .name = "colors",
        .role = .top,
        .desc = "Overrides color tokens: one child per token, with a color expression.",
        .pt = "Sobrescreve tokens de cor: um filho por token, com uma expressão de cor.",
        .sets = cond,
        .children = .tokens,
    },
    .{
        .name = "roles",
        .role = .top,
        .desc = "Up to 8 role colors (usernames, server icons).",
        .pt = "Até 8 cores de cargo (nomes, ícones de servidor).",
        .args = .{ .kind = .color, .min = 1, .max = 8, .desc = "Color expressions." },
        .sets = cond,
    },
    .{
        .name = "fonts",
        .role = .top,
        .desc = "Font families and the base size.",
        .pt = "Famílias de fonte e o tamanho base.",
        .sets = cond,
        .props = &.{
            of(.string, "ui", "Interface font family.", .{ .def = .{ .text = "Inter" } }),
            of(.string, "mono", "Monospace font family (code, mono).", .{ .def = .{ .text = "JetBrains Mono" } }),
            num("size", "Base text size.", .{ .min = 6, .max = 72, .range = .{ 10, 24, 0.5 }, .def = .{ .num = 16 } }),
        },
    },
    .{
        .name = "metrics",
        .role = .top,
        .desc = "Default rounding of rows and buttons.",
        .pt = "Arredondamento padrão de linhas e botões.",
        .sets = cond,
        .props = &.{num("radius", "Default corner radius.", .{ .min = 0, .max = 64, .range = .{ 0, 24, 1 }, .def = .{ .num = 6 } })},
    },
    .{
        .name = "window",
        .role = .top,
        .desc = "Window settings.",
        .pt = "Ajustes da janela.",
        .sets = cond,
        .props = &.{plainFlag("transparent", "Transparent window background (the compositor can blur what's behind it on Linux).", .{ .def = .{ .flag = false } })},
    },
    .{
        .name = "styles",
        .role = .top,
        .desc = "Named styles to use with style=name.",
        .pt = "Estilos nomeados para usar com style=nome.",
        .sets = cond,
        .children = .{ .named = &.{"style"} },
    },
    .{
        .name = "options",
        .role = .top,
        .desc = "On/off switches the theme offers in Settings → Appearance.",
        .pt = "Chaves liga/desliga que o tema oferece em Configurações → Aparência.",
        .children = .{ .named = &.{"option"} },
    },
    .{
        .name = "vars",
        .role = .top,
        .desc = "Variables: one child per variable (a number, a string or a color expression), used as $name in values. A theme that extends this one can change them.",
        .pt = "Variáveis: um filho por variável (número, texto ou expressão de cor), usadas como $nome nos valores. Um tema que estende este pode trocá-las.",
        .props = &.{pick("mode", &.{ "dark", "light" }, "The variables only apply in this mode.", .{})},
        .children = .free,
    },
    .{
        .name = "layout",
        .role = .top,
        .desc = "The interface tree, with a single root (row, column, stack or a component).",
        .pt = "A árvore da interface, com uma raiz só (row, column, stack ou um componente).",
        .sets = cond,
        .children = .layout_root,
    },
    .{
        .name = "parts",
        .role = .top,
        .desc = "Pieces inside the components (message rows, channel rows, member rows, the message box), each with its own look per state: hover, selected, unread, mention, speaking, muted, offline, self. One part child per rule.",
        .pt = "Partes de dentro dos componentes (linhas de mensagem, de canal, de membro, a caixa de texto), cada uma com o visual de cada estado: hover, selected, unread, mention, speaking, muted, offline, self. Um filho part por regra.",
        .sets = cond,
        .children = .{ .named = &.{"part"} },
    },
};

// --- Filhos dos blocos -------------------------------------------------------------

pub const child_specs = [_]NodeSpec{
    .{
        .name = "style",
        .role = .child,
        .parent = "styles",
        .desc = "A named style.",
        .pt = "Um estilo nomeado.",
        .args = .{ .kind = .string, .desc = "The style's name." },
        .sets = &.{.box},
        .props = &.{
            of(.color, "bg", "Background color.", .{}),
            num("radius", "Corner radius.", .{ .range = .{ 0, 32, 1 }, .def = .{ .num = 0 } }),
            of(.color, "border", "Border color.", .{}),
            num("shadow", "Shadow size (0 = none).", .{ .range = .{ 0, 48, 1 }, .def = .{ .num = 0 } }),
            of(.color, "glow", "Border color when the mouse is over it.", .{}),
            flag("sheen", "Glass reflection at the top of the card.", .{ .def = .{ .flag = false } }),
        },
    },
    .{
        .name = "option",
        .role = .child,
        .parent = "options",
        .desc = "An on/off switch in Settings → Appearance.",
        .pt = "Uma chave liga/desliga em Configurações → Aparência.",
        .args = .{ .kind = .string, .desc = "The option's name (used as when=name and $name)." },
        .props = &.{
            of(.string, "label", "Label in Portuguese.", .{}),
            of(.string, "label-en", "Label in English.", .{}),
            of(.string, "description", "Description in Portuguese.", .{}),
            of(.string, "description-en", "Description in English.", .{}),
            plainFlag("default", "Starts on or off.", .{ .def = .{ .flag = true } }),
        },
    },
    .{
        .name = "span",
        .role = .child,
        .parent = "label",
        .desc = "A piece of the label's line, with its own color, weight, size or font.",
        .pt = "Um pedaço da linha do label, com cor, peso, tamanho ou fonte próprios.",
        .args = .{ .kind = .string, .min = 0, .desc = "The text." },
        .props = &.{
            of(.string, "text", "The text (instead of the argument).", .{}),
            of(.string, "en", "English version of the text.", .{}),
            of(.string, "text-en", "English version of the text.", .{}),
            of(.font, "font", "Font (inherits from the label).", .{}),
            pick("weight", weights, "Weight (inherits from the label).", .{}),
            num("size", "Size (inherits from the label).", .{ .range = .{ 8, 48, 1 } }),
            of(.color, "color", "Color (inherits from the label).", .{}),
            num("tracking", "Extra space between letters (inherits from the label).", .{ .range = .{ -2, 16, 0.5 } }),
        },
    },
    .{
        .name = "part",
        .role = .child,
        .parent = "parts",
        .desc = "How a part looks, in all its states or only in some (\"message:hover\", \"channel.item:selected:hover\"). Each part takes only some of the properties: the list is in themes/README.md (Parts and states).",
        .pt = "Como uma parte fica, em todos os estados ou só em alguns (\"message:hover\", \"channel.item:selected:hover\"). Cada parte aceita só algumas das propriedades: a lista está em themes/README.md (Partes e estados).",
        .args = .{ .kind = .string, .desc = part_selector_desc },
        .props = &part_props,
    },
};

/// O nome do `part`: a parte e os estados, separados por `:` (de parts.zig).
const part_selector_desc = blk: {
    @setEvalBranchQuota(100_000);
    var out: []const u8 = "The part, then its states separated by colons. Parts: ";
    for (parts.partes, 0..) |p, i| out = std.fmt.comptimePrint("{s}{s}{s}", .{ out, if (i > 0) ", " else "", p.name });
    out = std.fmt.comptimePrint("{s}. States: ", .{out});
    for (parts.estados, 0..) |st, i| out = std.fmt.comptimePrint("{s}{s}{s}", .{ out, if (i > 0) ", " else "", st.name });
    break :blk std.fmt.comptimePrint("{s}.", .{out});
};

/// As propriedades de `part`, com o tipo e a faixa da tabela `props` de parts.zig.
const part_props = blk: {
    @setEvalBranchQuota(100_000);
    var out: [parts.props.len]Prop = undefined;
    for (parts.props, 0..) |p, i| {
        const desc = std.fmt.comptimePrint("{c}{s}.", .{ std.ascii.toUpper(p.desc[0]), p.desc[1..] });
        out[i] = switch (p.kind) {
            .color => of(.color, p.name, desc, .{}),
            .number => num(p.name, desc, .{ .min = p.min, .max = p.max }),
            .weight => pick(p.name, weights, desc, .{}),
        };
    }
    break :blk out;
};

// --- Layout ------------------------------------------------------------------------

pub const containers = [_]NodeSpec{
    .{ .name = "row", .role = .container, .desc = "Children side by side.", .pt = "Filhos lado a lado.", .sets = &.{ .node, .container, .box }, .children = .layout },
    .{ .name = "column", .role = .container, .desc = "Children one under the other.", .pt = "Filhos um embaixo do outro.", .sets = &.{ .node, .container, .box }, .children = .layout },
    .{ .name = "stack", .role = .container, .desc = "Children on top of each other (the first one is drawn first).", .pt = "Filhos um por cima do outro (o primeiro é desenhado antes).", .sets = &.{ .node, .container, .box }, .children = .layout },
};

const motion_props = [_]Prop{
    num("seed", "A different drawing.", .{ .range = .{ 1, 999, 1 }, .def = .{ .num = 7 }, .tweak = true }),
    flag("motion", "Moves slowly (stops with Reduce motion, minimized or out of focus). Best as \"$option\".", .{ .def = .{ .flag = false }, .tweak = true }),
    num("motion-fps", "Frames per second of the motion.", .{ .min = 1, .max = 15, .range = .{ 1, 15, 1 }, .def = .{ .num = 10 } }),
};

fn color1(desc: []const u8) Prop {
    return of(.color, "color", desc, .{});
}
fn color2(desc: []const u8) Prop {
    return of(.color, "color2", desc, .{});
}
fn color3(desc: []const u8) Prop {
    return of(.color, "color3", desc, .{});
}

pub const components = [_]NodeSpec{
    .{
        .name = "guild-bar",
        .role = .component,
        .desc = "The server bar.",
        .pt = "A barra de servidores.",
        .sets = layout_sets,
        .props = &.{
            pick("variant", &.{ "bar", "dock", "list" }, "Bar, macOS-style dock or list with names.", .{ .def = .{ .text = "bar" }, .tweak = true }),
            pick("icon-style", fieldNames(enum { fill, soft, outline }), "How the server icons are filled.", .{ .def = .{ .text = "fill" }, .tweak = true }),
            pick("orientation", &.{ "vertical", "horizontal" }, "Direction (default: by the node's shape).", .{ .tweak = true }),
            pick("shape", &.{ "circle", "squircle", "square", "text" }, "Shape of the icons; text = tabs with the names.", .{ .def = .{ .text = "circle" }, .tweak = true }),
            num("size", "Icon size (default 48; 36 horizontal, 40 dock, 26 list).", .{ .range = .{ 16, 80, 1 }, .def = .{ .num = 48 }, .tweak = true }),
            flag("labels", "Names under the icons (horizontal bar).", .{ .def = .{ .flag = false }, .tweak = true }),
            flag("home", "The home (DMs) button.", .{ .def = .{ .flag = true }, .tweak = true }),
            flag("indicators", "Unread and selection marks.", .{ .def = .{ .flag = true }, .tweak = true }),
            num("font-size", "Text size of shape=text tabs.", .{ .range = .{ 10, 24, 0.5 } }),
        },
    },
    .{
        .name = "channel-list",
        .role = .component,
        .desc = "The server's channels (or the DM list).",
        .pt = "Os canais do servidor (ou a lista de DMs).",
        .sets = layout_sets,
        .props = &.{
            pick("variant", &.{ "discord", "tree", "pills" }, "Look of the list.", .{ .def = .{ .text = "discord" }, .tweak = true }),
            flag("header", "Server name at the top.", .{ .def = .{ .flag = true }, .tweak = true }),
            flag("banner", "Colored banner with the server name (variant=discord).", .{ .def = .{ .flag = false }, .tweak = true }),
        },
    },
    .{
        .name = "user-panel",
        .role = .component,
        .desc = "Your name, status, mute/deafen and the settings button.",
        .pt = "Seu nome, status, mudo/surdo e o botão de configurações.",
        .sets = layout_sets,
        .props = &.{pick("variant", &.{ "discord", "tty" }, "Look of the panel.", .{ .def = .{ .text = "discord" }, .tweak = true })},
    },
    .{
        .name = "header",
        .role = .component,
        .desc = "Channel name, topic and buttons above the chat.",
        .pt = "Nome do canal, tópico e botões em cima da conversa.",
        .sets = layout_sets,
        .props = &.{
            pick("variant", &.{ "discord", "minimal", "tty" }, "Look of the header.", .{ .def = .{ .text = "discord" }, .tweak = true }),
            flag("divider", "Line under the header.", .{ .def = .{ .flag = true }, .tweak = true }),
        },
    },
    .{
        .name = "tabs",
        .role = .component,
        .desc = "Open conversations as tabs.",
        .pt = "Conversas abertas em abas.",
        .sets = layout_sets,
        .props = &.{pick("variant", &.{ "pills", "underline", "tty" }, "Look of the tabs.", .{ .def = .{ .text = "pills" }, .tweak = true })},
    },
    .{
        .name = "messages",
        .role = .component,
        .desc = "The conversation (and the call screen when a voice channel is open).",
        .pt = "A conversa (e a tela da call quando um canal de voz está aberto).",
        .sets = layout_sets,
        .props = &.{
            pick("variant", &.{ "cozy", "irc", "bubbles" }, "Layout of the messages.", .{ .def = .{ .text = "cozy" }, .tweak = true }),
            pick("avatar", &.{ "circle", "squircle", "square", "none" }, "Shape of the photos.", .{ .def = .{ .text = "circle" }, .tweak = true }),
            num("avatar-size", "Photo size (default 40; 30 with bubbles).", .{ .range = .{ 16, 72, 1 }, .def = .{ .num = 40 }, .tweak = true }),
            num("spacing", "Space between groups of messages.", .{ .range = .{ 0, 48, 1 }, .def = .{ .num = 16 }, .tweak = true }),
            num("font-size", "Text size (default: the fonts size).", .{ .range = .{ 10, 24, 0.5 }, .tweak = true }),
            flag("ruled", "Ruled paper.", .{ .def = .{ .flag = false }, .tweak = true }),
            flag("margin-line", "Red margin line.", .{ .def = .{ .flag = false }, .tweak = true }),
            flag("ticks", "\"Delivered ✓✓\" under your messages.", .{ .def = .{ .flag = false }, .tweak = true }),
            flag("typing-bubble", "Typing bubble (variant=bubbles).", .{ .def = .{ .flag = false }, .tweak = true }),
            of(.style, "call-style", "Named style for each tile of the call screen.", .{}),
            num("call-tint", "How much of each person's photo color goes into the call tile.", .{ .min = 0, .max = 1, .range = .{ 0, 1, 0.01 }, .def = .{ .num = 0.22 } }),
        },
    },
    .{
        .name = "composer",
        .role = .component,
        .desc = "The text box.",
        .pt = "A caixa de texto.",
        .sets = layout_sets,
        .props = &.{
            pick("variant", &.{ "box", "pill", "prompt" }, "Look of the box.", .{ .def = .{ .text = "box" }, .tweak = true }),
            flag("typing", "\"x is typing…\" above the box.", .{ .def = .{ .flag = true }, .tweak = true }),
        },
    },
    .{
        .name = "member-list",
        .role = .component,
        .desc = "Members of the server (or the profile in a DM).",
        .pt = "Membros do servidor (ou o perfil numa DM).",
        .sets = layout_sets,
        .props = &.{pick("variant", &.{ "discord", "tty" }, "Look of the list.", .{ .def = .{ .text = "discord" }, .tweak = true })},
    },
    .{
        .name = "status-bar",
        .role = .component,
        .desc = "A status line: connection, ping, memory, voice, theme, keys, clock.",
        .pt = "Uma linha de status: conexão, ping, memória, voz, tema, atalhos, relógio.",
        .sets = layout_sets,
        .props = &.{
            pick("variant", &.{ "pills", "tty", "plain" }, "Look of the bar.", .{ .def = .{ .text = "pills" }, .tweak = true }),
            .{
                .key = "items",
                .kind = .words,
                .values = &.{ "conn", "ping", "ram", "frame", "voice", "theme", "keys", "clock", "me", "mic", "deaf", "spacer" },
                .desc = "What the bar shows, in order; after spacer it goes to the right. me, mic and deaf: your status and the mute/deafen buttons.",
                .default = .{ .text = "conn ping ram voice spacer theme keys clock" },
                .tweak = true,
            },
        },
    },
    .{
        .name = "label",
        .role = .component,
        .desc = "A line of text, with display typography (tracking, spans, shadow, outline, gradient).",
        .pt = "Uma linha de texto, com tipografia de display (tracking, spans, sombra, contorno, degradê).",
        .sets = layout_sets,
        .children = .{ .named = &.{"span"} },
        .props = &.{
            of(.string, "text", "The text.", .{}),
            of(.string, "text-en", "English version of the text.", .{}),
            num("size", "Text size.", .{ .range = .{ 8, 48, 1 }, .def = .{ .num = 14 } }),
            pick("weight", weights, "Weight.", .{ .def = .{ .text = "semibold" } }),
            of(.color, "color", "Text color: a token name or a color expression.", .{ .def = .{ .text = "muted" } }),
            pick("align", align3, "Alignment.", .{ .def = .{ .text = "left" } }),
            num("tracking", "Extra space between letters, in pixels (can be negative).", .{ .range = .{ -2, 16, 0.5 }, .def = .{ .num = 0 } }),
            num("span-gap", "Space between spans.", .{ .range = .{ 0, 32, 1 }, .def = .{ .num = 0 } }),
            of(.color, "shadow", "Text shadow; with shadow-blur it becomes a soft halo.", .{}),
            num("shadow-x", "Horizontal offset of the shadow.", .{ .range = .{ -8, 8, 0.5 }, .def = .{ .num = 0 } }),
            num("shadow-y", "Vertical offset of the shadow (default 1, or 0 with shadow-blur).", .{ .range = .{ -8, 8, 0.5 }, .def = .{ .num = 1 } }),
            num("shadow-blur", "Blur of the shadow.", .{ .range = .{ 0, 12, 0.5 }, .def = .{ .num = 0 } }),
            of(.color, "outline", "Text outline.", .{}),
            num("outline-width", "Outline thickness.", .{ .range = .{ 0.5, 6, 0.5 }, .def = .{ .num = 1 } }),
            of(.colors, "text-gradient", "Gradient on the text, 2 or 3 colors.", .{}),
            num("text-gradient-angle", "Angle of the text gradient (default: horizontal).", .{ .range = .{ 0, 360, 1 }, .def = .{ .num = 0 } }),
        },
    },
    .{
        .name = "logo",
        .role = .component,
        .desc = "The app logo, in ASCII or as a wordmark.",
        .pt = "O logo do app, em ASCII ou como texto.",
        .sets = layout_sets,
        .props = &.{
            pick("variant", &.{ "wordmark", "ascii" }, "ASCII art or text.", .{ .def = .{ .text = "wordmark" }, .tweak = true }),
            num("size", "Text size (default 17; 13 in ASCII).", .{ .range = .{ 8, 40, 1 }, .def = .{ .num = 17 }, .tweak = true }),
        },
    },
    .{ .name = "topbar", .role = .component, .desc = "Top bar: back/forward between tabs, search and help.", .pt = "Barra de cima: voltar/avançar entre abas, busca e ajuda.", .sets = layout_sets },
    .{
        .name = "crt",
        .role = .component,
        .desc = "Scanlines and vignette on top of everything (use it in a stack).",
        .pt = "Linhas de varredura e vinheta por cima de tudo (use num stack).",
        .sets = layout_sets,
        .props = &.{
            num("spacing", "Distance between the scanlines.", .{ .min = 1, .range = .{ 1, 10, 1 }, .def = .{ .num = 3 }, .tweak = true }),
            num("strength", "How dark the scanlines are.", .{ .range = .{ 0, 0.4, 0.01 }, .def = .{ .num = 0.08 }, .tweak = true }),
        },
    },
    .{
        .name = "shape",
        .role = .component,
        .desc = "A drawn shape: circle, ring, arc, rounded rectangle, line or an SVG path.",
        .pt = "Uma forma desenhada: círculo, anel, arco, retângulo arredondado, linha ou um caminho do SVG.",
        .sets = layout_sets,
        .paints = true,
        .props = &.{
            pick("kind", &.{ "circle", "ring", "arc", "rounded", "line", "path" }, "Which shape.", .{ .def = .{ .text = "circle" } }),
            color1("Stroke color."),
            num("thickness", "Stroke thickness.", .{ .range = .{ 0.5, 8, 0.5 }, .def = .{ .num = 1.5 } }),
            num("size", "Diameter (default: the node's shorter side); on line, the length; on path, the side of the square the viewbox fits in (default: the whole node).", .{ .range = .{ 2, 120, 1 } }),
            of(.color, "fill", "Fill of ring, rounded and path.", .{}),
            num("start", "Start of the arc, in degrees.", .{ .range = .{ -360, 360, 1 }, .def = .{ .num = -90 } }),
            num("sweep", "Opening of the arc, in degrees.", .{ .range = .{ 0, 360, 1 }, .def = .{ .num = 270 } }),
            of(.color, "dot", "A dot at the tip of the arc.", .{}),
            num("dot-size", "Size of the dot (default: thickness × 1.6).", .{ .range = .{ 1, 12, 0.5 } }),
            num("radius", "Corners of rounded.", .{ .range = .{ 0, 32, 1 }, .def = .{ .num = 6 } }),
            num("angle", "Tilt of the line, in degrees.", .{ .range = .{ -180, 180, 1 }, .def = .{ .num = 0 } }),
            pick("align", align3, "Position inside the node.", .{ .def = .{ .text = "center" } }),
            num("offset-x", "Horizontal offset inside the node.", .{ .range = .{ -40, 40, 1 }, .def = .{ .num = 0 } }),
            num("offset-y", "Vertical offset inside the node.", .{ .range = .{ -40, 40, 1 }, .def = .{ .num = 0 } }),
            of(.string, "d", "The path of kind=path: SVG path data (M L H V C S Q T A Z, up to 1024 commands), read when the theme loads.", .{}),
            of(.string, "viewbox", "\"x y w h\": the part of the path's coordinates that fits in the node, keeping the proportions (default: the path's own bounds).", .{}),
            pick("fill-rule", fieldNames(tpath.FillRule), "Which parts of a path that crosses itself or has holes get filled.", .{ .def = .{ .text = "nonzero" } }),
        },
    },
    .{
        .name = "rule",
        .role = .component,
        .desc = "A rule: plain, dashed, dotted, double, newspaper or ornamented.",
        .pt = "Uma régua: lisa, tracejada, pontilhada, dupla, de jornal ou com ornamento.",
        .sets = layout_sets,
        .paints = true,
        .props = &.{
            pick("kind", &.{ "solid", "dashed", "dotted", "double", "oxford" }, "Which rule.", .{ .def = .{ .text = "solid" } }),
            color1("Rule color."),
            num("thickness", "Thickness.", .{ .range = .{ 0.5, 8, 0.5 }, .def = .{ .num = 1 } }),
            num("dash", "Dash size (dashed).", .{ .range = .{ 1, 24, 1 }, .def = .{ .num = 6 } }),
            num("gap", "Gap between dashes (dashed).", .{ .range = .{ 1, 24, 1 }, .def = .{ .num = 4 } }),
            flag("vertical", "From top to bottom (give the node a width).", .{ .def = .{ .flag = false } }),
            flag("fade", "Fades out at both ends.", .{ .def = .{ .flag = false } }),
            pick("ornament", &.{ "none", "diamond", "dot", "ring", "star" }, "A shape in the middle of the rule.", .{ .def = .{ .text = "none" } }),
            of(.string, "ornament-text", "A character in the middle, instead of the shape (uses the node's font).", .{}),
            of(.color, "ornament-color", "Color of the ornament.", .{}),
            num("ornament-size", "Size of the ornament.", .{ .range = .{ 4, 32, 1 }, .def = .{ .num = 8 } }),
            num("ornament-gap", "Gap in the rule around the ornament.", .{ .range = .{ 0, 32, 1 } }),
        },
    },
    .{
        .name = "window-controls",
        .role = .component,
        .desc = "The three window buttons (close, minimize, maximize), which really work.",
        .pt = "Os três botões da janela (fechar, minimizar, maximizar), que funcionam de verdade.",
        .sets = layout_sets,
        .paints = true,
        .props = &.{
            num("size", "Button size.", .{ .range = .{ 6, 24, 1 }, .def = .{ .num = 12 }, .tweak = true }),
            num("gap", "Space between the buttons.", .{ .range = .{ 2, 24, 1 }, .def = .{ .num = 8 }, .tweak = true }),
            color1("Close button (default: danger)."),
            color2("Minimize button (default: idle)."),
            color3("Maximize button (default: online)."),
            pick("align", align3, "Position inside the node.", .{ .def = .{ .text = "left" }, .tweak = true }),
        },
    },
    .{
        .name = "starfield",
        .role = .component,
        .desc = "Procedural background: stars (first child of a stack).",
        .pt = "Fundo procedural: estrelas (primeiro filho de um stack).",
        .sets = layout_sets,
        .paints = true,
        .props = &([_]Prop{
            color1("Distant stars."),
            color2("Near stars."),
            num("density", "How many stars.", .{ .min = 0.1, .max = 6, .range = .{ 0.1, 6, 0.1 }, .def = .{ .num = 1 }, .tweak = true }),
        } ++ motion_props),
    },
    .{
        .name = "orbit",
        .role = .component,
        .desc = "Procedural background: orbits with moons.",
        .pt = "Fundo procedural: órbitas com luas.",
        .sets = layout_sets,
        .paints = true,
        .props = &([_]Prop{
            color1("The orbits."),
            color2("The moons."),
            num("center-x", "Horizontal center, as a fraction of the width.", .{ .min = -1, .max = 2, .range = .{ -1, 2, 0.01 }, .def = .{ .num = 0.7 }, .tweak = true }),
            num("center-y", "Vertical center, as a fraction of the height.", .{ .min = -1, .max = 2, .range = .{ -1, 2, 0.01 }, .def = .{ .num = 0.35 }, .tweak = true }),
            num("rings", "How many orbits.", .{ .min = 1, .max = 12, .range = .{ 1, 12, 1 }, .def = .{ .num = 6 }, .tweak = true }),
        } ++ motion_props),
    },
    .{
        .name = "radar",
        .role = .component,
        .desc = "Procedural background: radar rings and sweep.",
        .pt = "Fundo procedural: anéis e varredura de radar.",
        .sets = layout_sets,
        .paints = true,
        .props = &([_]Prop{
            color1("The rings."),
            color2("The sweep."),
            num("center-x", "Horizontal center, as a fraction of the width.", .{ .min = -1, .max = 2, .range = .{ -1, 2, 0.01 }, .def = .{ .num = 0.5 }, .tweak = true }),
            num("center-y", "Vertical center, as a fraction of the height.", .{ .min = -1, .max = 2, .range = .{ -1, 2, 0.01 }, .def = .{ .num = 0.5 }, .tweak = true }),
            num("rings", "How many rings.", .{ .min = 1, .max = 12, .range = .{ 1, 12, 1 }, .def = .{ .num = 5 }, .tweak = true }),
        } ++ motion_props),
    },
    .{
        .name = "topography",
        .role = .component,
        .desc = "Procedural background: contour lines (always still).",
        .pt = "Fundo procedural: curvas de nível (sempre paradas).",
        .sets = layout_sets,
        .paints = true,
        .props = &.{
            color1("The lines."),
            num("levels", "How many contour lines.", .{ .min = 4, .max = 40, .range = .{ 4, 40, 1 }, .def = .{ .num = 14 }, .tweak = true }),
            motion_props[0],
        },
    },
    .{
        .name = "aurora",
        .role = .component,
        .desc = "Procedural background: two curtains of light.",
        .pt = "Fundo procedural: duas cortinas de luz.",
        .sets = layout_sets,
        .paints = true,
        .props = &([_]Prop{ color1("First curtain."), color2("Second curtain.") } ++ motion_props),
    },
    .{
        .name = "dunes",
        .role = .component,
        .desc = "Procedural background: hills from back to front (the sky is the gradient of the node around it).",
        .pt = "Fundo procedural: morros do fundo para a frente (o céu é o gradiente do nó em volta).",
        .sets = layout_sets,
        .paints = true,
        .props = &([_]Prop{ color1("Hills at the back."), color2("Hills in the middle."), color3("Hills in front.") } ++ motion_props),
    },
    .{
        .name = "rain",
        .role = .component,
        .desc = "Procedural background: rain, the far drops slower than the near ones.",
        .pt = "Fundo procedural: chuva, as gotas de longe mais devagar que as de perto.",
        .sets = layout_sets,
        .paints = true,
        .props = &([_]Prop{
            color1("Far drops."),
            color2("Near drops."),
            num("density", "How many drops.", .{ .min = 0.1, .max = 6, .range = .{ 0.1, 6, 0.1 }, .def = .{ .num = 1 }, .tweak = true }),
            num("angle", "The wind's tilt, in degrees.", .{ .min = -45, .max = 45, .range = .{ -45, 45, 1 }, .def = .{ .num = 10 }, .tweak = true }),
        } ++ motion_props),
    },
    .{
        .name = "matrix",
        .role = .component,
        .desc = "Procedural background: falling columns of characters drawn by the app.",
        .pt = "Fundo procedural: colunas de caracteres caindo, desenhados pelo app.",
        .sets = layout_sets,
        .paints = true,
        .props = &([_]Prop{
            color1("The trails."),
            color2("The bright head of each column."),
            num("density", "How many columns.", .{ .min = 0.1, .max = 6, .range = .{ 0.1, 6, 0.1 }, .def = .{ .num = 1 }, .tweak = true }),
        } ++ motion_props),
    },
    .{
        .name = "waves",
        .role = .component,
        .desc = "Procedural background: waves stretched over the whole area.",
        .pt = "Fundo procedural: ondas esticadas na área inteira.",
        .sets = layout_sets,
        .paints = true,
        .props = &([_]Prop{
            color1("The waves."),
            color2("The crests."),
            num("lines", "How many waves.", .{ .min = 2, .max = 24, .range = .{ 2, 24, 1 }, .def = .{ .num = 9 }, .tweak = true }),
        } ++ motion_props),
    },
    .{
        .name = "particles",
        .role = .component,
        .desc = "Procedural background: fine dust and large blurred discs.",
        .pt = "Fundo procedural: poeira fina e discos grandes desfocados.",
        .sets = layout_sets,
        .paints = true,
        .props = &([_]Prop{
            color1("Fine dust."),
            color2("Large blurred discs."),
            num("density", "How many particles.", .{ .min = 0.1, .max = 6, .range = .{ 0.1, 6, 0.1 }, .def = .{ .num = 1 }, .tweak = true }),
        } ++ motion_props),
    },
    .{
        .name = "wallpaper",
        .role = .component,
        .desc = "The picture the user chose in Settings → Appearance (first child of a stack), or nothing. The theme can't choose the picture: src, path, url, file and image are errors.",
        .pt = "A imagem que quem usa escolheu em Configurações → Aparência (primeiro filho de um stack), ou nada. O tema não escolhe a imagem: src, path, url, file e image são erros.",
        .sets = layout_sets,
        .props = &.{
            pick("fit", &.{ "cover", "contain", "tile", "center" }, "cover fills and crops, contain shows the whole picture, tile repeats it, center puts it in the middle. The user's Fit wins, except on Theme.", .{ .def = .{ .text = "cover" }, .tweak = true }),
            num("dim", "How much it darkens toward bg; the user's Dim can only darken further.", .{ .min = 0, .max = 1, .range = .{ 0, 1, 0.05 }, .def = .{ .num = 0 }, .tweak = true }),
            num("blur", "Blur radius, in pixels (made once, never per frame).", .{ .min = 0, .max = 64, .range = .{ 0, 64, 1 }, .def = .{ .num = 0 }, .tweak = true }),
            num("opacity", "The picture's opacity.", .{ .min = 0, .max = 1, .range = .{ 0, 1, 0.05 }, .def = .{ .num = 1 }, .tweak = true }),
        },
    },
    .{ .name = "spacer", .role = .component, .desc = "Empty space.", .pt = "Espaço vazio.", .sets = layout_sets },
};

// --- Consultas ---------------------------------------------------------------------

fn findIn(list: []const NodeSpec, name: []const u8) ?*const NodeSpec {
    for (list) |*s| if (std.mem.eql(u8, s.name, name)) return s;
    return null;
}

pub fn topSpec(name: []const u8) ?*const NodeSpec {
    return findIn(&top, name);
}

/// Contêiner ou componente.
pub fn layoutSpec(name: []const u8) ?*const NodeSpec {
    return findIn(&containers, name) orelse findIn(&components, name);
}

pub fn isContainer(name: []const u8) bool {
    return findIn(&containers, name) != null;
}

/// O filho `name` dentro do bloco `parent` (`style` em `styles`).
pub fn childSpec(parent: []const u8, name: []const u8) ?*const NodeSpec {
    for (&child_specs) |*s| if (std.mem.eql(u8, s.parent, parent) and std.mem.eql(u8, s.name, name)) return s;
    return null;
}

/// A propriedade `key` do nó: as dele e as dos grupos.
pub fn findProp(spec: *const NodeSpec, key: []const u8) ?*const Prop {
    for (spec.props) |*p| if (std.mem.eql(u8, p.key, key)) return p;
    for (spec.sets) |s| for (setProps(s)) |*p| if (std.mem.eql(u8, p.key, key)) return p;
    return null;
}

/// `c-text` → `text` (só nos nós do layout).
pub fn patternToken(key: []const u8) ?[]const u8 {
    for (patterns) |pt| if (std.mem.startsWith(u8, key, pt.prefix)) return key[pt.prefix.len..];
    return null;
}

/// Algum nó do esquema lê a propriedade `key`? (Para o teste que varre o código.)
pub fn knowsKey(key: []const u8) bool {
    const lists = [_][]const NodeSpec{ &top, &child_specs, &containers, &components };
    for (lists) |list| for (list) |*s| if (findProp(s, key) != null) return true;
    return false;
}

/// O nó tem `c-…`? (Todo nó do layout.)
pub fn takesPatterns(spec: *const NodeSpec) bool {
    for (spec.sets) |s| if (s == .node) return true;
    return false;
}

/// Nome parecido (até duas letras de diferença) para sugerir num erro de digitação.
pub fn suggest(word: []const u8, candidates: []const []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_d: usize = 3;
    for (candidates) |cand| {
        const d = distance(word, cand);
        if (d < best_d and d < @max(word.len, 3) - 1) {
            best = cand;
            best_d = d;
        }
    }
    return best;
}

fn distance(a: []const u8, b: []const u8) usize {
    if (a.len > 40 or b.len > 40) return 99;
    var prev: [41]usize = undefined;
    var cur: [41]usize = undefined;
    for (0..b.len + 1) |j| prev[j] = j;
    for (a, 0..) |ca, i| {
        cur[0] = i + 1;
        for (b, 0..) |cb, j| {
            const sub = prev[j] + @intFromBool(ca != cb);
            cur[j + 1] = @min(sub, @min(prev[j + 1] + 1, cur[j] + 1));
        }
        @memcpy(prev[0 .. b.len + 1], cur[0 .. b.len + 1]);
    }
    return prev[b.len];
}

// --- Checagem ------------------------------------------------------------------------

pub const Severity = enum { warning, @"error" };

pub const Issue = struct {
    severity: Severity,
    /// Arquivo de onde veio (vazio = o próprio tema; senão, a base de `extends`).
    file: []const u8 = "",
    line: u32,
    col: u32,
    message: []const u8,
};

/// Recebe tudo o que a checagem acha (o --theme-check e o LSP mostram a lista inteira).
pub const Report = struct {
    gpa: std.mem.Allocator,
    items: std.ArrayList(Issue) = .empty,

    pub fn deinit(r: *Report) void {
        for (r.items.items) |it| {
            r.gpa.free(it.message);
            r.gpa.free(it.file);
        }
        r.items.deinit(r.gpa);
    }

    pub fn add(r: *Report, it: Issue) !void {
        const msg = try r.gpa.dupe(u8, it.message);
        errdefer r.gpa.free(msg);
        const file = try r.gpa.dupe(u8, it.file);
        errdefer r.gpa.free(file);
        for (r.items.items) |old| {
            if (old.line == it.line and old.col == it.col and old.severity == it.severity and std.mem.eql(u8, old.message, it.message) and std.mem.eql(u8, old.file, it.file)) {
                r.gpa.free(msg);
                r.gpa.free(file);
                return;
            }
        }
        try r.items.append(r.gpa, .{ .severity = it.severity, .file = file, .line = it.line, .col = it.col, .message = msg });
    }

    pub fn errors(r: *const Report) usize {
        var n: usize = 0;
        for (r.items.items) |it| n += @intFromBool(it.severity == .@"error");
        return n;
    }
};

/// Confere os nós do topo de um tema. Os nomes das opções e dos estilos vêm do tema
/// inteiro (com a base de `extends`); `strict` (theme-api 2) faz de tudo um erro.
pub const Checker = struct {
    a: std.mem.Allocator,
    out: *std.ArrayList(Issue),
    options: []const []const u8 = &.{},
    styles: []const []const u8 = &.{},
    strict: bool = false,
    file: []const u8 = "",

    fn issue(ck: *Checker, line: u32, col: u32, comptime fmt: []const u8, args: anytype) error{OutOfMemory}!void {
        const msg = try std.fmt.allocPrint(ck.a, fmt, args);
        try ck.out.append(ck.a, .{ .severity = if (ck.strict) .@"error" else .warning, .file = ck.file, .line = line, .col = col, .message = msg });
    }

    fn knownOption(ck: *const Checker, name: []const u8) bool {
        if (std.mem.eql(u8, name, "modo-claro") or std.mem.eql(u8, name, "modo-escuro")) return true;
        for (ck.options) |o| if (std.mem.eql(u8, o, name)) return true;
        return false;
    }

    fn knownStyle(ck: *const Checker, name: []const u8) bool {
        for (ck.styles) |s| if (std.mem.eql(u8, s, name)) return true;
        return false;
    }

    pub fn topNode(ck: *Checker, n: *const kdl.Node) error{OutOfMemory}!void {
        const spec = topSpec(n.name) orelse {
            var names: [top.len][]const u8 = undefined;
            for (top, 0..) |s, i| names[i] = s.name;
            if (suggest(n.name, &names)) |s|
                return ck.issue(n.line, n.col, "unknown top-level node '{s}' (did you mean '{s}'?)", .{ n.name, s });
            return ck.issue(n.line, n.col, "unknown top-level node '{s}'", .{n.name});
        };
        try ck.props(n, spec);
        switch (spec.children) {
            .named => |names| for (n.children) |*ch| {
                if (childSpec(n.name, ch.name)) |cs| {
                    try ck.props(ch, cs);
                    if (ch.children.len > 0) try ck.issue(ch.children[0].line, ch.children[0].col, "{s} doesn't take children", .{ch.name});
                } else try ck.issue(ch.line, ch.col, "only {s} nodes go inside {s}, not '{s}'", .{ names[0], n.name, ch.name });
            },
            .layout_root => for (n.children) |*ch| try ck.layoutNode(ch),
            .tokens, .free => for (n.children) |*ch| {
                if (ch.props.len > 0) try ck.issue(ch.props[0].line, ch.props[0].col, "'{s}' takes a single value, not properties", .{ch.name});
                if (ch.children.len > 0) try ck.issue(ch.children[0].line, ch.children[0].col, "'{s}' doesn't take children", .{ch.name});
            },
            .none, .layout => if (n.children.len > 0) try ck.issue(n.children[0].line, n.children[0].col, "{s} doesn't take children", .{n.name}),
        }
    }

    pub fn layoutNode(ck: *Checker, n: *const kdl.Node) error{OutOfMemory}!void {
        const spec = layoutSpec(n.name) orelse {
            var names: [containers.len + components.len][]const u8 = undefined;
            for (containers ++ components, 0..) |s, i| names[i] = s.name;
            if (suggest(n.name, &names)) |s|
                return ck.issue(n.line, n.col, "unknown component '{s}' (did you mean '{s}'?)", .{ n.name, s });
            return ck.issue(n.line, n.col, "unknown component '{s}'", .{n.name});
        };
        try ck.props(n, spec);
        switch (spec.children) {
            .layout => for (n.children) |*ch| try ck.layoutNode(ch),
            .named => |names| for (n.children) |*ch| {
                if (childSpec(n.name, ch.name)) |cs| {
                    try ck.props(ch, cs);
                } else try ck.issue(ch.line, ch.col, "only {s} goes inside {s}, not '{s}'", .{ names[0], n.name, ch.name });
            },
            else => if (n.children.len > 0) try ck.issue(n.children[0].line, n.children[0].col, "{s} doesn't take children", .{n.name}),
        }
    }

    fn props(ck: *Checker, n: *const kdl.Node, spec: *const NodeSpec) error{OutOfMemory}!void {
        for (n.props) |*p| {
            if (findProp(spec, p.key)) |ps| {
                try ck.value(n, p, ps);
                continue;
            }
            if (takesPatterns(spec)) if (patternToken(p.key)) |tok| {
                // Token desconhecido em `c-…` já é erro do carregamento.
                _ = tok;
                if (p.value != .string) try ck.issue(p.line, p.col, "'{s}' expects a color", .{p.key});
                continue;
            };
            var keys: [128][]const u8 = undefined;
            var k: usize = 0;
            for (spec.props) |q| if (k < keys.len) {
                keys[k] = q.key;
                k += 1;
            };
            for (spec.sets) |s| for (setProps(s)) |q| if (k < keys.len) {
                keys[k] = q.key;
                k += 1;
            };
            if (suggest(p.key, keys[0..k])) |s|
                try ck.issue(p.line, p.col, "unknown property '{s}' on {s} (did you mean '{s}'?)", .{ p.key, n.name, s })
            else
                try ck.issue(p.line, p.col, "unknown property '{s}' on {s}", .{ p.key, n.name });
        }
    }

    fn value(ck: *Checker, n: *const kdl.Node, p: *const kdl.Prop, ps: *const Prop) error{OutOfMemory}!void {
        _ = n;
        const v = p.value;
        // `$nome` que sobrou depois de trocar as variáveis (heranca.zig): uma opção, ou nada.
        if (v.asString()) |s| if (s.len > 1 and s[0] == '$' and ps.kind != .boolean) {
            const name = if (s[1] == '!') s[2..] else s[1..];
            if (ck.knownOption(name)) return ck.issue(p.line, p.col, "'{s}' doesn't take an option ({s})", .{ p.key, s });
            return ck.issue(p.line, p.col, "unknown variable or option '{s}'", .{s});
        };
        switch (ps.kind) {
            .number => {
                const x = v.asNumber() orelse return ck.issue(p.line, p.col, "'{s}' expects a number", .{p.key});
                const lo = ps.min orelse -std.math.inf(f64);
                const hi = ps.max orelse std.math.inf(f64);
                if (x < lo or x > hi) {
                    const to = std.math.clamp(x, lo, hi);
                    if (ps.min != null and ps.max != null)
                        return ck.issue(p.line, p.col, "'{s}'={d} is out of range ({d} to {d}): the app uses {d}", .{ p.key, x, lo, hi, to });
                    if (ps.min != null)
                        return ck.issue(p.line, p.col, "'{s}'={d} is below the minimum ({d}): the app uses {d}", .{ p.key, x, lo, to });
                    return ck.issue(p.line, p.col, "'{s}'={d} is above the maximum ({d}): the app uses {d}", .{ p.key, x, hi, to });
                }
            },
            .boolean => {
                if (v == .boolean or v == .number) return;
                if (v.asString()) |s| if (s.len > 1 and s[0] == '$') {
                    if (!ps.option_ref) return ck.issue(p.line, p.col, "'{s}' doesn't take an option ({s}): use #true or #false", .{ p.key, s });
                    const name = if (s[1] == '!') s[2..] else s[1..];
                    if (!ck.knownOption(name)) return ck.issue(p.line, p.col, "unknown option '{s}' in '{s}'", .{ name, p.key });
                    return;
                };
                return ck.issue(p.line, p.col, "'{s}' expects #true or #false", .{p.key});
            },
            .@"enum" => {
                const s = v.asString() orelse return ck.issue(p.line, p.col, "'{s}' expects one of: {f}", .{ p.key, List{ .items = ps.values } });
                for (ps.values) |ok| if (std.mem.eql(u8, ok, s)) return;
                return ck.issue(p.line, p.col, "'{s}' isn't a value of '{s}' (expected: {f})", .{ s, p.key, List{ .items = ps.values } });
            },
            .words => {
                const s = v.asString() orelse return ck.issue(p.line, p.col, "'{s}' expects a list of words", .{p.key});
                var it = std.mem.tokenizeScalar(u8, s, ' ');
                words: while (it.next()) |w| {
                    for (ps.values) |ok| if (std.mem.eql(u8, ok, w)) continue :words;
                    try ck.issue(p.line, p.col, "'{s}' isn't an item of '{s}' (expected: {f})", .{ w, p.key, List{ .items = ps.values } });
                }
            },
            .string, .font => if (v != .string) return ck.issue(p.line, p.col, "'{s}' expects a string", .{p.key}),
            .color, .colors => if (v != .string) return ck.issue(p.line, p.col, "'{s}' expects a color (a token name or an expression in quotes)", .{p.key}),
            .token => {
                const s = v.asString() orelse return ck.issue(p.line, p.col, "'{s}' expects a color token", .{p.key});
                if (!isToken(s)) return ck.issue(p.line, p.col, "unknown color token '{s}' in '{s}'", .{ s, p.key });
            },
            .style => {
                const s = v.asString() orelse return ck.issue(p.line, p.col, "'{s}' expects the name of a style", .{p.key});
                if (!ck.knownStyle(s)) return ck.issue(p.line, p.col, "style '{s}' isn't defined in styles", .{s});
            },
            .option => {
                const s = v.asString() orelse return ck.issue(p.line, p.col, "'{s}' expects the name of an option", .{p.key});
                if (!ck.knownOption(s)) return ck.issue(p.line, p.col, "unknown option '{s}' in '{s}'", .{ s, p.key });
            },
        }
    }
};

/// Lista de valores para as mensagens: "a, b, c".
const List = struct {
    items: []const []const u8,
    pub fn format(l: List, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (l.items, 0..) |it, i| {
            if (i > 0) try w.writeAll(", ");
            try w.writeAll(it);
        }
    }
};

// --- JSON ------------------------------------------------------------------------------

/// O esquema em JSON (docs/assets/site/theme-schema.json, `larpercord --theme-schema`).
/// Sempre igual para as mesmas tabelas: o teste compara com o arquivo guardado.
pub fn writeJson(gpa: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
    var w: J = .{ .gpa = gpa, .out = out };
    try out.appendSlice(gpa, "{\n");
    try out.print(gpa, "  \"format\": {d},\n  \"theme-api\": {d},\n", .{ json_format, api_supported });
    try out.appendSlice(gpa, "  \"tokens\": [\n");
    for (token_names, 0..) |name, i| {
        try out.appendSlice(gpa, "    {\"name\": ");
        try w.str(name);
        try out.appendSlice(gpa, ", \"desc\": ");
        try w.str(token_desc.values[i]);
        try out.appendSlice(gpa, if (i + 1 < token_names.len) "},\n" else "}\n");
    }
    try out.appendSlice(gpa, "  ],\n  \"previews\": ");
    try w.strList(fieldNames(Preview));
    try out.appendSlice(gpa, ",\n  \"patterns\": [\n");
    for (patterns, 0..) |p, i| {
        try out.appendSlice(gpa, "    {\"prefix\": ");
        try w.str(p.prefix);
        try out.appendSlice(gpa, ", \"type\": \"color\", \"sets\": [\"node\"], \"desc\": ");
        try w.str(p.desc);
        try out.appendSlice(gpa, if (i + 1 < patterns.len) "},\n" else "}\n");
    }
    try out.appendSlice(gpa, "  ],\n  \"sets\": {\n");
    const sets = std.enums.values(Set);
    for (sets, 0..) |s, i| {
        try out.print(gpa, "    \"{t}\": [\n", .{s});
        try w.props(setProps(s), "      ");
        try out.appendSlice(gpa, if (i + 1 < sets.len) "    ],\n" else "    ]\n");
    }
    try out.appendSlice(gpa, "  },\n");
    const groups = [_]struct { []const u8, []const NodeSpec }{
        .{ "top", &top },
        .{ "children", &child_specs },
        .{ "containers", &containers },
        .{ "components", &components },
    };
    for (groups, 0..) |g, gi| {
        try out.print(gpa, "  \"{s}\": [\n", .{g[0]});
        for (g[1], 0..) |*spec, i| {
            try w.node(spec);
            try out.appendSlice(gpa, if (i + 1 < g[1].len) ",\n" else "\n");
        }
        try out.appendSlice(gpa, if (gi + 1 < groups.len) "  ],\n" else "  ]\n");
    }
    try out.appendSlice(gpa, "}\n");
}

const J = struct {
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),

    fn str(w: *J, s: []const u8) !void {
        try jsonx.writeString(w.out, w.gpa, s);
    }

    fn strList(w: *J, items: []const []const u8) !void {
        try w.out.append(w.gpa, '[');
        for (items, 0..) |it, i| {
            if (i > 0) try w.out.appendSlice(w.gpa, ", ");
            try w.str(it);
        }
        try w.out.append(w.gpa, ']');
    }

    fn props(w: *J, list: []const Prop, indent: []const u8) !void {
        for (list, 0..) |*p, i| {
            try w.out.appendSlice(w.gpa, indent);
            try w.prop(p);
            try w.out.appendSlice(w.gpa, if (i + 1 < list.len) ",\n" else "\n");
        }
    }

    fn prop(w: *J, p: *const Prop) !void {
        const gpa = w.gpa;
        try w.out.appendSlice(gpa, "{\"key\": ");
        try w.str(p.key);
        try w.out.print(gpa, ", \"type\": \"{t}\"", .{p.kind});
        if (p.values.len > 0) {
            try w.out.appendSlice(gpa, ", \"values\": ");
            try w.strList(p.values);
        }
        if (p.min) |x| try w.out.print(gpa, ", \"min\": {d}", .{x});
        if (p.max) |x| try w.out.print(gpa, ", \"max\": {d}", .{x});
        if (p.range) |r| try w.out.print(gpa, ", \"range\": [{d}, {d}, {d}]", .{ r[0], r[1], r[2] });
        switch (p.default) {
            .none => {},
            .num => |x| try w.out.print(gpa, ", \"default\": {d}", .{x}),
            .flag => |b| try w.out.print(gpa, ", \"default\": {s}", .{if (b) "true" else "false"}),
            .text => |s| {
                try w.out.appendSlice(gpa, ", \"default\": ");
                try w.str(s);
            },
        }
        if (p.option_ref) try w.out.appendSlice(gpa, ", \"option\": true");
        if (p.tweak) try w.out.appendSlice(gpa, ", \"tweak\": true");
        try w.out.appendSlice(gpa, ", \"desc\": ");
        try w.str(p.desc);
        if (p.pt.len > 0) {
            try w.out.appendSlice(gpa, ", \"pt\": ");
            try w.str(p.pt);
        }
        try w.out.append(gpa, '}');
    }

    fn node(w: *J, s: *const NodeSpec) !void {
        const gpa = w.gpa;
        try w.out.appendSlice(gpa, "    {\n      \"name\": ");
        try w.str(s.name);
        if (s.parent.len > 0) {
            try w.out.appendSlice(gpa, ",\n      \"parent\": ");
            try w.str(s.parent);
        }
        try w.out.appendSlice(gpa, ",\n      \"desc\": ");
        try w.str(s.desc);
        if (s.pt.len > 0) {
            try w.out.appendSlice(gpa, ",\n      \"pt\": ");
            try w.str(s.pt);
        }
        if (s.args) |a| {
            try w.out.print(gpa, ",\n      \"args\": {{\"type\": \"{t}\", \"min\": {d}, \"max\": {d}, \"desc\": ", .{ a.kind, a.min, a.max });
            try w.str(a.desc);
            try w.out.append(gpa, '}');
        }
        if (s.sets.len > 0) {
            try w.out.appendSlice(gpa, ",\n      \"sets\": [");
            for (s.sets, 0..) |set, i| try w.out.print(gpa, "{s}\"{t}\"", .{ if (i > 0) ", " else "", set });
            try w.out.append(gpa, ']');
        }
        switch (s.children) {
            .none => {},
            .named => |names| {
                try w.out.appendSlice(gpa, ",\n      \"children\": ");
                try w.strList(names);
            },
            else => try w.out.print(gpa, ",\n      \"children\": \"{s}\"", .{@tagName(s.children)}),
        }
        if (s.paints) try w.out.appendSlice(gpa, ",\n      \"paints\": true");
        if (s.props.len > 0) {
            try w.out.appendSlice(gpa, ",\n      \"props\": [\n");
            try w.props(s.props, "        ");
            try w.out.appendSlice(gpa, "      ]");
        }
        try w.out.appendSlice(gpa, "\n    }");
    }
};

// --- Testes ------------------------------------------------------------------------------

const testing = std.testing;

test "tokens saem do enum, com descrição" {
    try testing.expectEqual(token_count, token_names.len);
    try testing.expectEqualStrings("accent-text", token_names[@intFromEnum(theme.Token.accent_text)]);
    try testing.expect(isToken("bubble-self-text"));
    try testing.expect(!isToken("bubble_self_text"));
    for (token_desc.values) |d| try testing.expect(d.len > 0);
}

test "nomes únicos e propriedades sem repetir dentro de cada nó" {
    const lists = [_][]const NodeSpec{ &top, &child_specs, &containers, &components };
    for (lists) |list| for (list, 0..) |*s, i| {
        for (list[i + 1 ..]) |*o| try testing.expect(!std.mem.eql(u8, s.name, o.name) or !std.mem.eql(u8, s.parent, o.parent));
        // Uma propriedade do próprio nó pode detalhar a de um grupo (`radius` do `shape`:
        // findProp acha a do nó primeiro); repetida no nó ou entre os grupos, não.
        var keys: [160][]const u8 = undefined;
        for ([_]bool{ true, false }) |own| {
            var k: usize = 0;
            if (own) {
                for (s.props) |p| {
                    keys[k] = p.key;
                    k += 1;
                }
            } else for (s.sets) |set| for (setProps(set)) |p| {
                keys[k] = p.key;
                k += 1;
            };
            for (keys[0..k], 0..) |a, x| for (keys[x + 1 .. k]) |b| {
                if (std.mem.eql(u8, a, b)) {
                    std.debug.print("{s}: '{s}' repetida\n", .{ s.name, a });
                    return error.Repetida;
                }
            };
        }
        for (s.props) |p| {
            if (p.kind == .@"enum" or p.kind == .words) try testing.expect(p.values.len > 0);
            if (p.min != null and p.max != null) try testing.expect(p.min.? < p.max.?);
            if (p.range) |r| try testing.expect(r[0] < r[1] and r[2] > 0);
        }
    };
}

test "sugestão para erro de digitação" {
    try testing.expectEqualStrings("variant", suggest("varient", &.{ "size", "variant", "home" }).?);
    try testing.expect(suggest("xyz", &.{ "size", "variant" }) == null);
    try testing.expectEqualStrings("messages", suggest("mesages", &.{ "messages", "composer" }).?);
}

fn checkSrc(src: []const u8, strict: bool, out: *std.ArrayList(Issue), arena: std.mem.Allocator) !void {
    const nodes = try kdl.parse(arena, src, null);
    var ck: Checker = .{ .a = arena, .out = out, .options = &.{"brilho"}, .styles = &.{"card"}, .strict = strict };
    for (nodes) |*n| try ck.topNode(n);
}

test "checagem: componente, propriedade e valor desconhecidos, com linha e coluna" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.ArrayList(Issue) = .empty;
    try checkSrc(
        \\theme "x" preview=nada
        \\fonts size=200
        \\layout {
        \\    row gap=4 {
        \\        mesages flex=1
        \\        messages varient=cozy variant=listra style=card
        \\        composer typing="$brilho" style=outro
        \\        status-bar items="conn relogio clock" c-text="#fff"
        \\    }
        \\}
        \\nada-disso 1
    , false, &out, a);
    const want = [_]struct { line: u32, col: u32, has: []const u8 }{
        .{ .line = 1, .col = 11, .has = "'nada' isn't a value of 'preview'" },
        .{ .line = 2, .col = 7, .has = "'size'=200 is out of range (6 to 72): the app uses 72" },
        .{ .line = 5, .col = 9, .has = "unknown component 'mesages' (did you mean 'messages'?)" },
        .{ .line = 6, .col = 18, .has = "unknown property 'varient' on messages (did you mean 'variant'?)" },
        .{ .line = 6, .col = 31, .has = "'listra' isn't a value of 'variant' (expected: cozy, irc, bubbles)" },
        .{ .line = 7, .col = 35, .has = "style 'outro' isn't defined" },
        .{ .line = 8, .col = 20, .has = "'relogio' isn't an item of 'items'" },
        .{ .line = 11, .col = 1, .has = "unknown top-level node 'nada-disso'" },
    };
    try testing.expectEqual(want.len, out.items.len);
    for (want, out.items) |w, got| {
        if (got.line != w.line or got.col != w.col or std.mem.indexOf(u8, got.message, w.has) == null) {
            std.debug.print("esperava {d}:{d} '{s}', veio {d}:{d} '{s}'\n", .{ w.line, w.col, w.has, got.line, got.col, got.message });
            return error.Diferente;
        }
        try testing.expectEqual(Severity.warning, got.severity);
    }
}

test "checagem estrita vira erro; tema certo não tem nada" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.ArrayList(Issue) = .empty;
    try checkSrc("layout { messages tamanho=3 }", true, &out, a);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqual(Severity.@"error", out.items[0].severity);
    out.clearRetainingCapacity();
    try checkSrc(
        \\styles { style "card" bg="@surface" sheen="$!brilho" grain="alpha(@text, 0.05)" corners=left }
        \\options { option "brilho" label="Brilho" default=#false }
        \\layout { stack { starfield color=faint density=2 motion="$brilho"; column c-text="#fff" cl-muted="#000" { label text="x" { span "a" en="b" }; composer when=modo-claro } } }
    , true, &out, a);
    for (out.items) |it| std.debug.print("{d}:{d} {s}\n", .{ it.line, it.col, it.message });
    try testing.expectEqual(@as(usize, 0), out.items.len);
}

test "os componentes com cor são os de fx.zig, e as cores deles são as que fx.zig guarda" {
    for (components) |s| {
        if (s.paints != fx.painted.has(s.name)) {
            std.debug.print("{s}: paints={} no esquema, {} em fx.zig\n", .{ s.name, s.paints, fx.painted.has(s.name) });
            return error.Diferente;
        }
        if (!s.paints) continue;
        props: for (s.props) |p| {
            if (p.kind != .color) continue;
            for (fx.color_keys) |k| if (std.mem.eql(u8, k, p.key)) continue :props;
            std.debug.print("{s}.{s}: fx.zig não guarda esta cor\n", .{ s.name, p.key });
            return error.Diferente;
        }
    }
    for (fx.painted.keys()) |name| try testing.expect(layoutSpec(name) != null);
}

test "wallpaper: a imagem não é propriedade dele (o carregamento recusa)" {
    const wp = layoutSpec("wallpaper").?;
    for (fx.wallpaper_banned) |k| try testing.expect(findProp(wp, k) == null);
    try testing.expect(findProp(wp, "fit") != null and findProp(wp, "radius") != null);
}

test "parts: as partes, os estados e as propriedades de parts.zig" {
    try testing.expect(topSpec("parts") != null);
    const part = childSpec("parts", "part").?;
    try testing.expectEqual(parts.props.len, part.props.len);
    for (parts.partes) |p| try testing.expect(std.mem.indexOf(u8, part.args.?.desc, p.name) != null);
    for (parts.estados) |st| try testing.expect(std.mem.indexOf(u8, part.args.?.desc, st.name) != null);
    try testing.expectEqual(@as(?f64, 64), findProp(part, "radius").?.max);
    try testing.expectEqual(Kind.@"enum", findProp(part, "weight").?.kind);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.ArrayList(Issue) = .empty;
    try checkSrc(
        \\parts mode=dark {
        \\    part "message:hover" bg="@hover" radius=6 bar=accent
        \\    part "member.name:offline" color=muted weight=bold opacity=0.5
        \\}
        \\layout { stack { rain color=faint angle=-20 motion="$brilho"; wallpaper fit=tile dim=0.3; shape kind=path d="M0 0 L1 1" viewbox="0 0 1 1" fill-rule=evenodd } }
    , true, &out, a);
    for (out.items) |it| std.debug.print("{d}:{d} {s}\n", .{ it.line, it.col, it.message });
    try testing.expectEqual(@as(usize, 0), out.items.len);
    try checkSrc(
        \\parts {
        \\    part "message" tamanho=3 weight=pesado
        \\    estilo "x"
        \\}
    , false, &out, a);
    try testing.expectEqual(@as(usize, 3), out.items.len);
    try testing.expect(std.mem.indexOf(u8, out.items[0].message, "unknown property 'tamanho' on part") != null);
    try testing.expect(std.mem.indexOf(u8, out.items[1].message, "'pesado' isn't a value of 'weight'") != null);
    try testing.expect(std.mem.indexOf(u8, out.items[2].message, "only part nodes go inside parts") != null);
}

test "o JSON abre e tem os componentes" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try writeJson(testing.allocator, &out);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out.items, .{});
    defer parsed.deinit();
    const comps = parsed.value.object.get("components").?.array.items;
    try testing.expectEqual(components.len, comps.len);
    try testing.expectEqualStrings("guild-bar", comps[0].object.get("name").?.string);
    try testing.expectEqual(@as(usize, token_count), parsed.value.object.get("tokens").?.array.items.len);
}
