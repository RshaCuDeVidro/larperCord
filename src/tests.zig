//! Testes das partes que não dependem de janela nem de GPU.
const std = @import("std");
const builtin_themes = @import("builtin_themes");
const theme = @import("theme/theme.zig");
const layout = @import("theme/layout.zig");
const schema = @import("theme/schema.zig");
const repo_paths = @import("repo_paths");

test {
    _ = @import("net/retry.zig");
    _ = @import("inspect/captura.zig");
    _ = @import("inspect/registros.zig");
    _ = @import("inspect/descreve.zig");
    _ = @import("inspect/curl_insp.zig");
    _ = @import("inspect/kit.zig");
    _ = @import("inspect/json_view.zig");
    _ = @import("inspect/doca.zig");
    _ = @import("inspect/aba_gateway.zig");
    _ = @import("inspect/aba_rede.zig");
    _ = @import("inspect/aba_elementos.zig");
    _ = @import("core/resample.zig");
    _ = @import("core/plain_letters.zig");
    _ = @import("core/gif_favorites.zig");
    _ = @import("core/pastas.zig");
    _ = @import("core/gif_clipe.zig");
    _ = @import("core/gif_quadros.zig");
    _ = @import("core/entrada.zig");
    _ = @import("platform/debug_log.zig");
    _ = @import("platform/ffmpeg_busca.zig");
    _ = @import("core/types.zig");
    _ = @import("core/ritmo.zig");
    _ = @import("core/mem_use.zig");
    _ = @import("core/mem_partes.zig");
    _ = @import("platform/mem_mapa.zig");
    _ = @import("core/image_uri.zig");
    _ = @import("core/version.zig");
    _ = @import("core/atualizacao.zig");
    _ = @import("core/sort.zig");
    _ = @import("core/dm_order.zig");
    _ = @import("core/markdown.zig");
    _ = @import("core/changelog.zig");
    _ = @import("core/store.zig");
    _ = @import("core/moderacao.zig");
    _ = @import("core/filtros.zig");
    _ = @import("core/jogos.zig");
    _ = @import("platform/processos.zig");
    _ = @import("core/volumes.zig");
    _ = @import("core/leitura.zig");
    _ = @import("core/links.zig");
    _ = @import("core/voz.zig");
    _ = @import("core/sons.zig");
    _ = @import("core/aviso.zig");
    _ = @import("core/som_arquivo.zig");
    _ = @import("core/janela.zig");
    _ = @import("core/ctl.zig");
    _ = @import("core/flutuante.zig");
    _ = @import("core/bandeja.zig");
    _ = @import("core/notificacao.zig");
    _ = @import("core/ruido.zig");
    _ = @import("core/nivel.zig");
    _ = @import("core/lsp.zig");
    _ = @import("ui/rascunhos.zig");
    _ = @import("core/inbox.zig");
    _ = @import("core/saved.zig");
    _ = @import("core/lembretes.zig");
    _ = @import("core/conjuntos.zig");
    _ = @import("core/mentions.zig");
    _ = @import("core/mencao.zig");
    _ = @import("ui/destaque.zig");
    _ = @import("ui/emoji_data.zig");
    _ = @import("core/cache_format.zig");
    _ = @import("core/state_format.zig");
    _ = @import("core/state_snapshot.zig");
    _ = @import("core/media_flags.zig");
    _ = @import("core/media_refresh.zig");
    _ = @import("core/ogg_opus.zig");
    _ = @import("core/ogg_escrita.zig");
    _ = @import("core/gravacao.zig");
    _ = @import("core/audio_formato.zig");
    _ = @import("core/audio_onda.zig");
    _ = @import("core/audio_bandas.zig");
    _ = @import("core/audio_pcm.zig");
    _ = @import("core/stickers.zig");
    _ = @import("core/reply_preview.zig");
    _ = @import("core/exportar.zig");
    _ = @import("core/salvar.zig");
    _ = @import("core/png_escrita.zig");
    _ = @import("core/metadados.zig");
    _ = @import("core/imagem_edicao.zig");
    _ = @import("platform/pastas.zig");
    _ = @import("core/search_query.zig");
    _ = @import("core/busca_indice.zig");
    _ = @import("core/accounts.zig");
    _ = @import("core/limites.zig");
    _ = @import("core/debounce.zig");
    _ = @import("net/gw_budget.zig");
    _ = @import("net/member_ask.zig");
    _ = @import("net/member_search.zig");
    _ = @import("core/voice_timer.zig");
    _ = @import("net/voice_info_json.zig");
    _ = @import("net/voz_movido.zig");
    _ = @import("net/saida_servidor.zig");
    _ = @import("net/registro_rede.zig");
    _ = @import("net/tls_ja4.zig");
    _ = @import("core/embutido.zig");
    _ = @import("core/aviso_versao.zig");
    _ = @import("net/limits_json.zig");
    _ = @import("core/conta.zig");
    _ = @import("theme/kdl.zig");
    _ = @import("theme/color.zig");
    _ = @import("theme/parts.zig");
    _ = @import("theme/theme.zig");
    _ = @import("theme/fx.zig");
    _ = @import("theme/schema.zig");
    _ = @import("theme/heranca.zig");
    _ = @import("theme/bases.zig");
    _ = @import("theme/lsp_tema.zig");
    _ = @import("theme/path.zig");
    _ = @import("ui/procgen.zig");
    _ = @import("ui/wallpaper_fit.zig");
    _ = @import("theme/custom.zig");
    _ = @import("theme/layout.zig");
    _ = @import("ui/anim.zig");
    _ = @import("ui/mascote_contas.zig");
    _ = @import("ui/mascote_visual.zig");
    _ = @import("ui/mascote_reacoes.zig");
    _ = @import("ui/carimbo.zig");
    _ = @import("ui/fuzzy.zig");
    _ = @import("ui/i18n.zig");
    _ = @import("ui/horario.zig");
    _ = @import("core/i18n_cabecalho.zig");
    _ = @import("ui/atalhos.zig");
    _ = @import("ui/ime.zig");
    _ = @import("core/combinacao.zig");
    _ = @import("ui/syntax.zig");
    _ = @import("ui/bidi.zig");
    _ = @import("ui/tint.zig");
    _ = @import("ui/call_layout.zig");
    _ = @import("core/event.zig");
    _ = @import("ui/rich_plan.zig");
    _ = @import("ui/font_blocks.zig");
    _ = @import("ui/font_names.zig");
    _ = @import("ui/settings_state.zig");
    _ = @import("ui/guild_color.zig");
    _ = @import("ui/device_pick.zig");
    _ = @import("net/jsonx.zig");
    _ = @import("core/interaction.zig");
    _ = @import("net/web_client.zig");
    _ = @import("net/read_state_json.zig");
    _ = @import("net/media_url.zig");
    _ = @import("net/proxy.zig");
    _ = @import("net/enderecos.zig");
    _ = @import("net/challenge.zig");
    _ = @import("net/settings_proto.zig");
    _ = @import("net/status_proto.zig");
    _ = @import("net/conta_json.zig");
    _ = @import("net/thread_json.zig");
    _ = @import("net/envio_json.zig");
    _ = @import("core/envio.zig");
    _ = @import("core/polls.zig");
    _ = @import("net/social.zig");
    _ = @import("core/thread_edit.zig");
    _ = @import("net/user_json.zig");
    _ = @import("net/face_json.zig");
    _ = @import("net/call_json.zig");
    _ = @import("net/rpc_proto.zig");
    _ = @import("ui/apng.zig");
    _ = @import("plugins/engine.zig");
    _ = @import("plugins/manifest.zig");
    _ = @import("plugins/deco.zig");
    _ = @import("plugins/panel.zig");
    _ = @import("plugins/rewrite.zig");
    _ = @import("plugins/json.zig");
    _ = @import("plugins/loc.zig");
    _ = @import("plugins/http_policy.zig");
    _ = @import("plugins/wire.zig");
}

// Exportar uma conversa não pede nada ao Discord (a conta de quem usa já foi
// desativada uma vez por "atividade suspeita"): nem o trabalho (net/exportar.zig)
// nem a tela (ui/exportar.zig) conhecem o gateway ou a API, e a parte da exportação
// nem chama o download (só o "Salvar", pelo clique, baixa um arquivo da CDN). O QA
// (qa_exportar.zig) conta os comandos e os downloads com o app rodando.
test "exportar não tem como pedir nada ao Discord" {
    const trabalho = @embedFile("net/exportar.zig");
    const tela = @embedFile("ui/exportar.zig");
    // Montados aos pedaços: senão casariam com este arquivo.
    const banned = [_][]const u8{ "discord" ++ ".zig\")", "fake_" ++ "gateway.zig\")", "app" ++ ".zig\")", "web_" ++ "client.zig\")", "Authori" ++ "zation:", "Comm" ++ "and" };
    for ([_][]const u8{ trabalho, tela }) |src| for (banned) |b| try std.testing.expect(std.mem.indexOf(u8, src, b) == null);
    const from = std.mem.indexOf(u8, trabalho, "// --- " ++ "Exportar") orelse return error.SemExportar;
    const to = std.mem.indexOf(u8, trabalho, "// --- " ++ "Salvar") orelse return error.SemSalvar;
    try std.testing.expect(from < to);
    for ([_][]const u8{ "download" ++ "(", "downloadTo" ++ "(", "tenorVideo" ++ "(", "images." ++ "fetch", "fetch_" ++ "hook", "cu" ++ "rl" }) |w|
        try std.testing.expect(std.mem.indexOf(u8, trabalho[from..to], w) == null);
    // A tela só pede ao app o seletor de arquivo.
    var it = std.mem.splitSequence(u8, tela, "ctx.act" ++ "(");
    _ = it.next();
    while (it.next()) |rest| try std.testing.expect(std.mem.startsWith(u8, rest, ".save_dialog)"));
}

/// Componentes e propriedades que o app entende: os do esquema (theme/schema.zig).
fn checkNames(t: *const theme.Theme) !void {
    if (t.warnings.len == 0) return;
    for (t.warnings) |w| std.debug.print("linha {d}:{d}: {s}\n", .{ w.line, w.col, w.message });
    return error.ForaDoEsquema;
}

test "todos os temas embutidos carregam e montam o layout" {
    for (builtin_themes.list) |b| {
        var d: theme.Diagnostic = .{};
        var t = theme.load(std.testing.allocator, b.source, null, &d) catch |err| {
            std.debug.print("tema {s}: linha {d}: {s}\n", .{ b.name, d.line, d.message });
            return err;
        };
        defer t.deinit();
        checkNames(&t) catch |err| {
            std.debug.print("tema {s}\n", .{b.name});
            return err;
        };
        var out: std.ArrayList(layout.Placed) = .empty;
        defer out.deinit(std.testing.allocator);
        try layout.solve(std.testing.allocator, t.layout.?, .{ .x = 0, .y = 0, .w = 1280, .h = 800 }, 1280, &out);
        try std.testing.expect(out.items.len > 3);
        for (out.items) |p| try std.testing.expect(p.rect.w >= 0 and p.rect.h >= 0);
    }
}

test "destaque de menção aparece em todos os temas embutidos, no escuro e no claro" {
    const destaque = @import("ui/destaque.zig");
    for (builtin_themes.list) |b| for ([_]theme.Mode{ .dark, .light }) |mode| {
        var t = try theme.loadWith(std.testing.allocator, b.source, .{ .mode = mode }, null);
        defer t.deinit();
        const fundos = [_]theme.Rgba{ t.c(.bg), t.c(.surface) };
        // `idle` no estilo do Discord e nas bolhas; `mention` no estilo terminal.
        for ([_]theme.Token{ .idle, .mention }) |tok| {
            const c = destaque.cores(t.c(tok), &fundos);
            for (fundos) |f| {
                const opaco: theme.Rgba = .{ .r = f.r, .g = f.g, .b = f.b };
                const ct = c.faixa.contrast(opaco);
                const dif = destaque.maiorCanal(destaque.composto(c, f), opaco);
                if (ct < destaque.contraste_faixa or dif < 0.05) {
                    std.debug.print("tema {s} ({t}), cor {t}: contraste {d:.2}, fundo muda {d:.3}\n", .{ b.name, mode, tok, ct, dif });
                    return error.DestaqueInvisivel;
                }
            }
        }
    };
}

// O esquema em JSON (o site e os editores leem) acompanha as tabelas de theme/schema.zig.
test "docs/assets/site/theme-schema.json está em dia com o esquema" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try schema.writeJson(std.testing.allocator, &out);
    if (!std.mem.eql(u8, out.items, @embedFile("theme_schema_json"))) {
        std.debug.print("docs/assets/site/theme-schema.json está velho: rode `zig build theme-schema` (ou `larpercord --theme-schema > docs/assets/site/theme-schema.json`)\n", .{});
        return error.EsquemaVelho;
    }
}

// Toda propriedade que o código lê de um nó do tema está no esquema: assim ele não fica
// para trás em silêncio. Varre src/theme e src/ui atrás de leituras com a chave escrita
// (`n.str("chave")`, `d.pnum(n, "chave", …)`, `nodeColor(ctx, n, "chave", …)`) e das
// listas de chaves (`const side_keys = …`, `const text_keys = …`).
test "toda propriedade lida em src/theme e src/ui está no esquema" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    // Arquivos que leem outros KDL com os mesmos nós: o do mascote, o settings.kdl e os
    // arquivos de tradução (o cabeçalho `language … code= english=`).
    const fora = [_][]const u8{ "mascote_visual.zig", "settings_state.zig", "guild_color.zig", "i18n.zig" };
    var faltam: usize = 0;
    var lidas: usize = 0;
    for ([_][]const u8{ "theme", "ui" }) |sub| {
        const path = try std.fs.path.join(gpa, &.{ repo_paths.src, sub });
        defer gpa.free(path);
        var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
        defer dir.close(io);
        var it = dir.iterate();
        files: while (try it.next(io)) |e| {
            if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".zig")) continue;
            for (fora) |f| if (std.mem.eql(u8, f, e.name)) continue :files;
            const src = try dir.readFileAlloc(io, e.name, gpa, .limited(4 << 20));
            defer gpa.free(src);
            var keys: [512][]const u8 = undefined;
            for (propReads(src, &keys)) |k| {
                lidas += 1;
                if (schema.knowsKey(k)) continue;
                std.debug.print("src/{s}/{s}: a propriedade '{s}' não está em src/theme/schema.zig\n", .{ sub, e.name, k });
                faltam += 1;
            }
        }
    }
    try std.testing.expect(lidas > 100);
    try std.testing.expectEqual(@as(usize, 0), faltam);
}

/// As chaves de propriedade lidas de um nó em `src`: `R.str("k")` (e num, flag, prop),
/// `(R, "k"` e `, R, "k"` com R um nome de nó (n, ch, nd, node, sp, p.node), e as
/// strings das listas `…_keys = [`.
fn propReads(src: []const u8, out: [][]const u8) []const []const u8 {
    const nodes = [_][]const u8{ "n", "ch", "nd", "node", "sp", "p.node" };
    const methods = [_][]const u8{ ".str(\"", ".num(\"", ".flag(\"", ".prop(\"" };
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t");
        if (std.mem.startsWith(u8, line, "//")) continue;
        if (std.mem.indexOf(u8, line, "_keys = [") != null) {
            var rest = line;
            while (std.mem.indexOfScalar(u8, rest, '"')) |q| {
                const end = std.mem.indexOfScalarPos(u8, rest, q + 1, '"') orelse break;
                if (n < out.len and isKey(rest[q + 1 .. end])) {
                    out[n] = rest[q + 1 .. end];
                    n += 1;
                }
                rest = rest[end + 1 ..];
            }
            continue;
        }
        for (nodes) |r| {
            var i: usize = 0;
            while (std.mem.indexOfPos(u8, line, i, r)) |at| : (i = at + r.len) {
                // O nome inteiro: `n` não pode ser o fim de `fn` nem o começo de `nodes`.
                if (at > 0 and (std.ascii.isAlphanumeric(line[at - 1]) or line[at - 1] == '_' or line[at - 1] == '.')) continue;
                const after = line[at + r.len ..];
                const before = line[0..at];
                var key: ?[]const u8 = null;
                for (methods) |m| if (std.mem.startsWith(u8, after, m)) {
                    key = quoted(after[m.len - 1 ..]);
                };
                if (key == null and std.mem.startsWith(u8, after, ", \"") and
                    (std.mem.endsWith(u8, before, "(") or std.mem.endsWith(u8, before, ", ")))
                    key = quoted(after[2..]);
                if (key) |k| if (n < out.len and isKey(k)) {
                    out[n] = k;
                    n += 1;
                };
            }
        }
    }
    return out[0..n];
}

fn quoted(s: []const u8) ?[]const u8 {
    if (s.len < 2 or s[0] != '"') return null;
    const end = std.mem.indexOfScalarPos(u8, s, 1, '"') orelse return null;
    return s[1..end];
}

fn isKey(s: []const u8) bool {
    if (s.len == 0 or !std.ascii.isLower(s[0])) return false;
    for (s) |ch| if (!(std.ascii.isLower(ch) or std.ascii.isDigit(ch) or ch == '-')) return false;
    return true;
}

test "a varredura das propriedades acha as leituras e ignora o resto" {
    var keys: [16][]const u8 = undefined;
    const got = propReads(
        \\    const t = d.pstr(n, "text", "");
        \\    if (p.node.str("bg")) |bg| x(nodeColor(ctx, n, "color2", .idle));
        \\    // d.pnum(n, "comentario", 1)
        \\    const side_keys = [4][]const u8{ "border-top", "border-right" };
        \\    return cx.fail(n, "pattern: dots, lines");
        \\    fn(n, "nao") ; const x = run(xn, "outra");
    , &keys);
    // Na ordem dos nomes de nó procurados (n antes de p.node), não da posição na linha.
    const want = [_][]const u8{ "text", "color2", "bg", "border-top", "border-right", "nao" };
    try std.testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try std.testing.expectEqualStrings(w, g);
}

test "os dois CHANGELOGs têm as mesmas versões, com o mesmo tanto em cada seção" {
    const log = @import("core/changelog.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const en = try log.parse(arena.allocator(), @embedFile("changelog_en"));
    const pt = try log.parse(arena.allocator(), @embedFile("changelog_pt"));
    try std.testing.expect(en.len > 0);
    try std.testing.expectEqual(en.len, pt.len);
    for (en, pt) |a, b| {
        try std.testing.expectEqualStrings(a.name, b.name);
        try std.testing.expectEqual(a.sections.len, b.sections.len);
        for (a.sections, b.sections) |sa, sb| try std.testing.expectEqual(sa.items.len, sb.items.len);
    }
    // A página de novidades marca cada título como "changelog-section:<título>" para o QA,
    // numa chave de 56 bytes: um título maior some da varredura e o QA da página falha
    // quando a versão dele vira a instalada.
    for (pt) |v| for (v.sections) |sec| {
        try std.testing.expect("changelog-section:".len + sec.title.len <= 56);
    };
}
