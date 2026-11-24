//! O que passa entre a interface e a thread dos plugins. As duas só conversam
//! por estas duas filas (e pelos poucos valores atômicos de `Shared`): `Ev` vai
//! para a thread dos plugins, `Cmd` volta. Quem recebe é dono do que veio.
const std = @import("std");
const lsp_core = @import("../core/lsp.zig");
const deco = @import("deco.zig");
const panel = @import("panel.zig");
const rewrite = @import("rewrite.zig");
const loc = @import("loc.zig");
const http_policy = @import("http_policy.zig");

/// Onde a pessoa está (canal e servidor abertos). Textos emprestados.
pub const Where = struct {
    channel: u64 = 0,
    channel_name: []const u8 = "",
    guild: u64 = 0,
    guild_name: []const u8 = "",
};

/// Um arquivo anexado (só com `larper.messages({files=true})`).
pub const FileRef = struct { name: []const u8, url: []const u8, size: u32 = 0 };

/// Uma mensagem como o plugin vê (nunca o que foi apagado, nem o texto de antes
/// de uma edição). Textos emprestados, ou de `OwnedMsg`.
pub const Message = struct {
    id: u64 = 0,
    content: []const u8,
    author: u64,
    author_name: []const u8,
    channel: u64,
    channel_name: []const u8,
    guild: u64 = 0,
    guild_name: []const u8 = "",
    mine: bool = false,
    /// A pessoa ignora quem escreveu (core/filtros.zig).
    ignored: bool = false,
    /// Segundos desde 1970 (0 = não veio).
    timestamp: i64 = 0,
    attachments: u16 = 0,
    files: []const FileRef = &.{},
    /// A que mensagem esta responde (0 = nenhuma).
    reply_to: u64 = 0,
    /// Fala com a pessoa: menção, cargo dela, @everyone. Só em larper.messages.
    mentions_me: bool = false,
};

/// Tem algum destes pedaços, sem ligar para maiúsculas? (`contains` de larper.on e larper.messages.)
pub fn hasAny(text: []const u8, needles: []const []u8) bool {
    for (needles) |n| {
        if (std.ascii.findIgnoreCase(text, n) != null) return true;
    }
    return false;
}

pub fn freeNeedles(gpa: std.mem.Allocator, list: [][]u8) void {
    for (list) |n| gpa.free(n);
    gpa.free(list);
}

/// Texto de mensagem que uma cópia guarda, no máximo.
const max_content = 4000;

/// Cópia de uma mensagem para a outra thread (os textos ficam juntos em `buf`).
pub const OwnedMsg = struct {
    msg: Message,
    buf: []u8,

    pub fn dup(gpa: std.mem.Allocator, m: *const Message) ?*OwnedMsg {
        var keep = @min(m.content.len, max_content);
        while (keep > 0 and keep < m.content.len and (m.content[keep] & 0xC0) == 0x80) keep -= 1;
        const content = m.content[0..keep];
        var total = content.len + m.author_name.len + m.channel_name.len + m.guild_name.len;
        for (m.files) |f| total += f.name.len + f.url.len;
        const own = gpa.create(OwnedMsg) catch return null;
        const buf = gpa.alloc(u8, total) catch {
            gpa.destroy(own);
            return null;
        };
        const files = gpa.alloc(FileRef, m.files.len) catch {
            gpa.free(buf);
            gpa.destroy(own);
            return null;
        };
        var at: usize = 0;
        const put = struct {
            fn f(b: []u8, n: *usize, s: []const u8) []const u8 {
                const out = b[n.*..][0..s.len];
                @memcpy(out, s);
                n.* += s.len;
                return out;
            }
        }.f;
        own.* = .{ .msg = m.*, .buf = buf };
        own.msg.content = put(buf, &at, content);
        own.msg.author_name = put(buf, &at, m.author_name);
        own.msg.channel_name = put(buf, &at, m.channel_name);
        own.msg.guild_name = put(buf, &at, m.guild_name);
        for (m.files, files) |f, *to| {
            to.* = .{ .name = put(buf, &at, f.name), .url = put(buf, &at, f.url), .size = f.size };
        }
        own.msg.files = files;
        return own;
    }

    pub fn free(o: *OwnedMsg, gpa: std.mem.Allocator) void {
        gpa.free(o.msg.files);
        gpa.free(o.buf);
        gpa.destroy(o);
    }
};

/// Um arquivo lido da pasta.
pub const Source = struct { name: []const u8, src: []const u8 };

pub const Keybind = struct {
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
    super: bool = false,
    key: i32 = 0,
    /// Posição da função em registry.larper.keys.
    slot: u32 = 0,
    label_buf: [40]u8 = undefined,
    label_len: u8 = 0,

    pub fn label(k: *const Keybind) []const u8 {
        return k.label_buf[0..k.label_len];
    }
};

/// Servidor de linguagem proposto com larper.lsp. Só uma proposta: quem decide
/// rodar é a pessoa, em Configurações (ui/settings_lsp.zig).
pub const LspServer = struct { lang: lsp_core.Short, cmd: lsp_core.Command };

pub const MenuKind = enum(u8) { message, user };

/// Uma escolha da segunda lista de uma entrada de menu.
pub const MenuChoice = struct { value: []u8, label: loc.Text = .{} };

/// Entrada num menu de botão direito.
pub const MenuEntry = struct {
    kind: MenuKind,
    /// Posição da função em registry.larper.menus.
    slot: u32,
    /// O rótulo em cada idioma que o plugin deu: a interface escolhe ao desenhar.
    label: loc.Text = .{},
    /// Com alguma: clicar abre a segunda lista, e a escolha vai para a função.
    choices: []MenuChoice = &.{},
    /// Também um botão na barra da mensagem, com este emoji ("" = só no menu).
    toolbar: []u8 = &.{},

    pub fn free(m: *const MenuEntry, gpa: std.mem.Allocator) void {
        m.label.free(gpa);
        gpa.free(m.toolbar);
        for (m.choices) |ch| {
            gpa.free(ch.value);
            ch.label.free(gpa);
        }
        gpa.free(m.choices);
    }

    pub fn dup(m: *const MenuEntry, gpa: std.mem.Allocator) !MenuEntry {
        var out: MenuEntry = .{ .kind = m.kind, .slot = m.slot };
        errdefer out.free(gpa);
        out.label = try m.label.dup(gpa);
        out.toolbar = try gpa.dupe(u8, m.toolbar);
        out.choices = try gpa.alloc(MenuChoice, m.choices.len);
        for (out.choices) |*ch| ch.* = .{ .value = &.{} };
        for (m.choices, out.choices) |ch, *to| {
            to.value = try gpa.dupe(u8, ch.value);
            to.label = try ch.label.dup(gpa);
        }
        return out;
    }
};

/// Uma sugestão de `larper.completions`: fica toda na interface, para a busca
/// andar a cada tecla sem chamar o plugin.
pub const Completion = struct { name: []u8, text: []u8, hint: []u8 };

pub const CompletionSet = struct {
    trigger: u8,
    items: []Completion,

    pub fn free(s: *CompletionSet, gpa: std.mem.Allocator) void {
        for (s.items) |it| {
            gpa.free(it.name);
            gpa.free(it.text);
            gpa.free(it.hint);
        }
        gpa.free(s.items);
        gpa.destroy(s);
    }
};

/// O que o plugin registrou até agora (comandos, atalhos…). A interface assume.
pub const Reg = struct {
    commands: [][]u8 = &.{},
    keys: []Keybind = &.{},
    lsp: []LspServer = &.{},
    menus: []MenuEntry = &.{},
    n_message: u16 = 0,
    n_ready: u16 = 0,
    n_delete: u16 = 0,
    n_channel: u16 = 0,
    n_lang: u16 = 0,
    n_edit: u16 = 0,
    n_dismiss: u16 = 0,

    pub fn free(r: *Reg, gpa: std.mem.Allocator) void {
        for (r.commands) |s| gpa.free(s);
        gpa.free(r.commands);
        gpa.free(r.keys);
        gpa.free(r.lsp);
        for (r.menus) |*m| m.free(gpa);
        gpa.free(r.menus);
        gpa.destroy(r);
    }
};

// --- HTTP --------------------------------------------------------------------

pub const HttpError = enum(u8) {
    none,
    /// O host não foi aprovado em Configurações → Plugins.
    not_approved,
    /// Passou do limite de pedidos por minuto (ou de pedidos ao mesmo tempo).
    rate_limited,
    /// A resposta passou do tamanho máximo.
    too_big,
    network,
    /// Redirecionou para um host não aprovado, para fora do HTTPS ou vezes demais.
    redirect,
};

pub const Method = http_policy.Method;

pub const HttpReq = struct {
    gpa: std.mem.Allocator,
    run: u32,
    id: u32,
    method: Method = .GET,
    /// O gesto que pediu: a resposta ainda pode pôr texto na caixa.
    token: u32 = 0,
    url: [:0]u8,
    body: []u8,
    /// Só os cabeçalhos da lista permitida, prontos ("Nome: valor").
    headers: [][:0]u8,
    /// Os hosts aprovados (nomes ou curingas): um redirecionamento só segue para eles.
    allow: [][]u8 = &.{},
    /// Os aprovados que podem receber credenciais: indo para outro, elas ficam para trás.
    creds: [][]u8 = &.{},
    /// A linha do registro de rede, já com o método, o host e o caminho.
    log: NetEntry = .{},
    /// Chamar quando acabar, de qualquer thread (assume a resposta).
    done_ctx: *anyopaque,
    done: *const fn (ctx: *anyopaque, res: *HttpRes) void,

    pub fn free(r: *HttpReq) void {
        const gpa = r.gpa;
        gpa.free(r.url);
        gpa.free(r.body);
        for (r.headers) |h| gpa.free(h);
        gpa.free(r.headers);
        for (r.allow) |h| gpa.free(h);
        gpa.free(r.allow);
        for (r.creds) |h| gpa.free(h);
        gpa.free(r.creds);
        gpa.destroy(r);
    }
};

pub const HttpRes = struct {
    run: u32,
    id: u32,
    status: u16 = 0,
    body: []u8 = &.{},
    /// Os cabeçalhos da resposta que o plugin pode ler ("nome\x00valor\x00…", nomes em
    /// minúsculas; http_policy.responseHeader).
    headers: []u8 = &.{},
    err: HttpError = .none,
    /// Nem chegou a sair (recusado aqui mesmo).
    refused: bool = false,
    token: u32 = 0,
    /// Quanto levou, do começo ao fim (com os redirecionamentos).
    ms: u32 = 0,
    /// A linha do registro de rede que veio com o pedido.
    log: NetEntry = .{},
};

/// Uma linha do registro de rede de um plugin (Configurações → Plugins): o que saiu,
/// para onde e o que voltou. Nunca o valor de um cabeçalho, o corpo ou a busca da URL.
pub const NetEntry = struct {
    method: Method = .GET,
    status: u16 = 0,
    err: HttpError = .none,
    bytes: u32 = 0,
    ms: u32 = 0,
    /// Segundos desde 1970.
    time: i64 = 0,
    host_buf: [64]u8 = undefined,
    host_len: u8 = 0,
    path_buf: [96]u8 = undefined,
    path_len: u8 = 0,

    pub fn host(e: *const NetEntry) []const u8 {
        return e.host_buf[0..e.host_len];
    }

    pub fn path(e: *const NetEntry) []const u8 {
        return e.path_buf[0..e.path_len];
    }

    /// Host e caminho de uma URL https:// já conferida, sem a busca (`?…`).
    pub fn setUrl(e: *NetEntry, url: []const u8) void {
        const after = if (std.ascii.startsWithIgnoreCase(url, "https://")) url[8..] else url;
        const cut = std.mem.indexOfAny(u8, after, "/?#") orelse after.len;
        e.host_len = put(&e.host_buf, after[0..cut]);
        const rest = after[cut..];
        const path_end = std.mem.indexOfAny(u8, rest, "?#") orelse rest.len;
        e.path_len = put(&e.path_buf, if (path_end == 0) "/" else rest[0..path_end]);
    }

    fn put(buf: []u8, s: []const u8) u8 {
        var n = @min(s.len, buf.len);
        while (n > 0 and n < s.len and (s[n] & 0xC0) == 0x80) n -= 1;
        @memcpy(buf[0..n], s[0..n]);
        return @intCast(n);
    }
};

// --- Ações na conta -----------------------------------------------------------------

/// O que um plugin pede para fazer numa mensagem, sempre direto de um gesto. A
/// interface confere de novo (a mensagem existe, é sua, há permissão) e faz pelo
/// mesmo caminho dos botões do app. Apagar e anexar pedem confirmação na tela.
pub const Action = union(enum) {
    /// `emoji`: o emoji em texto ou um personalizado ("nome:id").
    react: struct { id: u64, emoji: []u8 },
    edit: struct { id: u64, text: []u8 },
    delete: struct { id: u64 },
    pin: struct { id: u64, add: bool },
    thread: struct { id: u64, name: []u8 },
    /// Abre o seletor de arquivos do app para a caixa deste canal (0 = o aberto).
    attach: struct { channel: u64 },

    pub fn free(a: *const Action, gpa: std.mem.Allocator) void {
        switch (a.*) {
            .react => |x| gpa.free(x.emoji),
            .edit => |x| gpa.free(x.text),
            .thread => |x| gpa.free(x.name),
            .delete, .pin, .attach => {},
        }
    }
};

// --- O app oferece aos plugins ---------------------------------------------------

pub const Host = struct {
    ctx: *anyopaque,
    // Só na thread da interface:
    /// Aviso na interface. `desktop`: também uma notificação do sistema com a
    /// janela em foco (sem ele, só com a janela fora de foco).
    notify: *const fn (ctx: *anyopaque, plugin: []const u8, text: []const u8, desktop: bool) void,
    /// Manda uma mensagem (channel 0 = o canal aberto; com `reply_to`, o canal da
    /// mensagem respondida). false = canal ou mensagem não existe.
    send: *const fn (ctx: *anyopaque, channel: u64, text: []const u8, reply_to: u64) bool,
    /// Uma ação numa mensagem (ver `Action`). Devolve o motivo de não fazer (null =
    /// feito, ou esperando a confirmação da pessoa). `plugin` é o nome do arquivo.
    action: *const fn (ctx: *anyopaque, plugin: []const u8, title: []const u8, a: *const Action) ?[]const u8,
    where: *const fn (ctx: *anyopaque) Where,
    /// Lê a pasta de novo e chama `load` (botão Recarregar).
    rescan: *const fn (ctx: *anyopaque) void,
    /// Uma escolha mudou (ligado, host aprovado): salvar.
    save: *const fn (ctx: *anyopaque) void,
    /// Um plugin deu erro.
    failed: *const fn (ctx: *anyopaque, plugin: []const u8, msg: []const u8) void,
    /// Põe texto na caixa de mensagem.
    insert: *const fn (ctx: *anyopaque, text: []const u8) void,
    /// Abre o canal e vai até a mensagem.
    jump: *const fn (ctx: *anyopaque, channel: u64, id: u64) void,
    /// Copia para a área de transferência.
    copy: *const fn (ctx: *anyopaque, text: []const u8) void,
    /// Abre no navegador (o endereço já foi conferido).
    open_url: *const fn (ctx: *anyopaque, url: []const u8) void,
    /// Copia as mensagens carregadas do canal (0 = o aberto), da mais antiga para
    /// a mais nova; chama `add` para cada uma.
    messages: *const fn (ctx: *anyopaque, channel: u64, limit: u32, out: *MsgList) void,
    // Em qualquer thread:
    /// "x", "f5", "enter"… para o código da tecla (null = não conhece).
    key: *const fn (name: []const u8) ?i32,
    /// Acorda a interface: tem `Cmd` na fila.
    wake: *const fn (ctx: *anyopaque) void,
    /// Armazenamento do plugin: o arquivo inteiro (null = ainda não tem).
    read_data: *const fn (ctx: *anyopaque, gpa: std.mem.Allocator, account: u64, plugin: []const u8) ?[]u8,
    write_data: *const fn (ctx: *anyopaque, account: u64, plugin: []const u8, bytes: []const u8) bool,
    /// O arquivo estava ilegível: guarda a cópia em vez de sobrescrever.
    keep_broken_data: *const fn (ctx: *anyopaque, account: u64, plugin: []const u8) void,
    /// Começa um pedido (assume `req`; a resposta chega por `req.done`).
    http_start: *const fn (req: *HttpReq) bool,
    /// larper.secrets, no chaveiro do sistema, separado por plugin (`plugin` só tem
    /// letras, números, ".", "_" e "-"; `key` também). get: null = não tem.
    secret_get: *const fn (ctx: *anyopaque, gpa: std.mem.Allocator, plugin: []const u8, key: []const u8) ?[]u8,
    secret_set: *const fn (ctx: *anyopaque, plugin: []const u8, key: []const u8, value: []const u8) bool,
    secret_delete: *const fn (ctx: *anyopaque, plugin: []const u8, key: []const u8) void,
    /// Cancela o que estiver no ar e espera acabar (ao fechar).
    http_stop: *const fn () void,
};

/// A cópia de mensagens que `Host.messages` preenche.
pub const MsgList = struct {
    gpa: std.mem.Allocator,
    items: std.ArrayList(*OwnedMsg) = .empty,
    channel: u64 = 0,
    /// Copiar também a lista de anexos (só quem pede paga por ela).
    files: bool = false,
    /// Só as que têm um destes pedaços (vazio = todas).
    needles: [][]u8 = &.{},
    /// Até onde a pessoa já tinha lido este canal (0 = nada novo, ou não se sabe).
    last_read: u64 = 0,

    pub fn wants(l: *const MsgList, text: []const u8) bool {
        return l.needles.len == 0 or hasAny(text, l.needles);
    }

    pub fn add(l: *MsgList, m: *const Message) void {
        if (!l.wants(m.content)) return;
        const own = OwnedMsg.dup(l.gpa, m) orelse return;
        l.items.append(l.gpa, own) catch own.free(l.gpa);
    }

    pub fn free(l: *MsgList) void {
        const gpa = l.gpa;
        for (l.items.items) |o| o.free(gpa);
        l.items.deinit(gpa);
        freeNeedles(gpa, l.needles);
        gpa.destroy(l);
    }
};

// --- Interface -> plugins --------------------------------------------------------

pub const StartArgs = struct {
    run: u32,
    slot: u16,
    account: u64,
    name: []u8,
    src: []u8,
    /// Hosts que a pessoa já aprovou para este plugin.
    approved: [][]u8,
    fire_ready: bool,
    budget: u32,
};

/// O que a pessoa fez em algo do plugin. Só `token` diferente de 0 libera o que
/// pede um gesto (larper.send, larper.insert, larper.jump, abrir o painel).
pub const Gesture = union(enum) {
    command: struct { name: []u8, args: []u8 },
    key: u32,
    /// `value`: a escolha da segunda lista, se tem.
    menu_message: struct { slot: u32, msg: *OwnedMsg, value: ?[]u8 = null },
    menu_user: struct { slot: u32, id: u64, name: []u8, value: ?[]u8 = null },
    /// `toggled`: o estado novo de um interruptor (no lugar de `value`).
    panel: struct { handle: u32, value: ?[]u8, toggled: ?bool = null },
};

pub const Ev = union(enum) {
    start: *StartArgs,
    stop: u32,
    ready,
    message: *OwnedMsg,
    edit: *OwnedMsg,
    delete: struct { channel: u64, id: u64 },
    /// A pessoa fechou a nota deste plugin nesta mensagem (o × dela).
    dismiss: struct { run: u32, id: u64 },
    channel,
    lang,
    /// O painel do plugin abriu ou fechou na tela.
    panel_state: struct { run: u32, open: bool },
    gesture: struct { run: u32, token: u32, what: Gesture },
    messages: struct { run: u32, req: u32, list: *MsgList },
    http: *HttpRes,
    hosts: struct { run: u32, approved: [][]u8 },
};

// --- Plugins -> interface --------------------------------------------------------

pub const CmdWhat = union(enum) {
    reg: *Reg,
    /// Erro. `stopped`: o plugin parou.
    failed: struct { msg: []u8, stopped: bool },
    notify: struct { text: []u8, desktop: bool },
    send: struct { channel: u64, text: []u8, token: u32, reply_to: u64 = 0 },
    action: struct { what: Action, token: u32 },
    /// Mais uma linha do registro de rede do plugin.
    net_log: NetEntry,
    insert: struct { text: []u8, token: u32 },
    jump: struct { channel: u64, id: u64, token: u32 },
    copy: struct { text: []u8, token: u32 },
    open_url: struct { url: []u8, token: u32 },
    panel_tree: *panel.Tree,
    settings_tree: *panel.Tree,
    completions: *CompletionSet,
    rewrite: []rewrite.Rule,
    panel_show: struct { open: bool, token: u32 },
    deco_set: struct { id: u64, badge: []u8, note: []u8, label: []u8, collapse: bool, danger: bool = false },
    deco_remove: u64,
    deco_rules: []deco.Rule,
    want_messages: struct { req: u32, channel: u64, limit: u32, files: bool = false, needles: [][]u8 = &.{} },
};

pub const Cmd = struct { run: u32, what: CmdWhat };

test "registro de rede: host e caminho, nunca a busca" {
    var e: NetEntry = .{};
    e.setUrl("https://api.exemplo.com/v1/itens?token=segredo#x");
    try std.testing.expectEqualStrings("api.exemplo.com", e.host());
    try std.testing.expectEqualStrings("/v1/itens", e.path());
    e.setUrl("https://api.exemplo.com?q=1");
    try std.testing.expectEqualStrings("/", e.path());
}
