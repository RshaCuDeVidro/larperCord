//! Configurações → Aparência → Canais de voz: o tempo da call ao lado de cada
//! canal de voz (ui/voice_timer.zig), o formato (um pronto ou um escrito pela
//! pessoa, core/voice_timer.zig) e a prévia, que muda enquanto se escreve.
const std = @import("std");
const c = @import("c");
const d = @import("draw.zig");
const qa = @import("qa.zig");
const icons = @import("icons.zig");
const i18n = @import("i18n.zig");
const dropdown = @import("dropdown.zig");
const vt = @import("../core/voice_timer.zig");
const S = @import("settings_state.zig");
const timer_ui = @import("voice_timer.zig");

const dd_key: usize = 0x7133_E200;
const base_id: usize = 0x7133_E300;

/// O texto da caixa do formato da pessoa (o ImGui escreve aqui).
var pat_buf: [256]u8 = @splat(0);
var pat_seen: S.Text = .{};

/// As amostras da prévia: menos de um minuto, a do exemplo (16:42:14) e mais de
/// dois dias.
const samples = [_]u64{ 42, 60134, 187234 };

/// O exemplo de cada pronto na lista (sempre 16:42:14, o mesmo do Discord).
const example_s: u64 = 60134;

fn presetName(i: usize) []const u8 {
    if (i >= vt.presets.len) return i18n.tr("Personalizado", "Custom");
    const p = vt.presets[i];
    return if (p.name_en.len > 0) i18n.tr(p.name, p.name_en) else p.name;
}

/// O exemplo de um pronto: o curto (abaixo de uma hora) e o longo, quando há os dois.
fn presetExample(buf: []u8, i: usize) []const u8 {
    const S2 = struct {
        var f: vt.Format = undefined;
    };
    S2.f = vt.resolve(@intCast(i), "");
    var a: [48]u8 = undefined;
    var b: [48]u8 = undefined;
    const long = S2.f.text(&b, example_s);
    if (S2.f.short == null) return std.fmt.bufPrint(buf, "{s}", .{long}) catch long;
    return std.fmt.bufPrint(buf, "{s} · {s}", .{ S2.f.text(&a, 2534), long }) catch long;
}

pub fn section(p: anytype) void {
    const ctx = p.ctx;
    const s = &ctx.st.settings;
    p.heading(i18n.tr("Canais de voz", "Voice channels"));
    p.toggle(i18n.tr("Tempo da call", "Call timer"), i18n.tr("Mostra há quanto tempo a call de cada canal de voz começou, ao lado do nome do canal, como no Discord.", "Shows how long each voice channel's call has been going, next to the channel name, like Discord."), &s.voice_timer);
    if (!s.voice_timer) return;

    // O formato: uma caixa que abre a lista dos prontos.
    p.line(.bold, 12, ctx.col(.muted), i18n.tr("FORMATO", "FORMAT"), 22);
    const cur: usize = @min(s.voice_timer_format, vt.custom_index);
    const box: d.Rect = .{ .x = p.x, .y = p.y, .w = @min(p.w, 440), .h = 40 };
    const open = dropdown.isOpen(dd_key);
    const hb = d.hit(ctx, base_id, box);
    qa.mark(box, "vt-format", .{});
    d.rect(p.dl, box, ctx.col(.rail).mix(ctx.col(.elevated), if (hb.hovered) 0.4 else 0.2), ctx.th.radius);
    d.border(p.dl, box, if (open) ctx.col(.accent) else if (hb.hovered) ctx.col(.accent).alpha(0.6) else ctx.col(.border), ctx.th.radius, 1);
    var eb: [96]u8 = undefined;
    const ex = if (cur == vt.custom_index) s.voice_timer_pattern.slice() else presetExample(&eb, cur);
    const ex_w = @min(d.width(ctx.mono.get(.regular), 13, ex), box.w * 0.45);
    _ = d.textClipped(p.dl, p.font(.medium), 15, box.x + 12, d.centerY(box, 15), ctx.col(.text), presetName(cur), box.w - ex_w - 56);
    _ = d.textClipped(p.dl, ctx.mono.get(.regular), 13, box.right() - 34 - ex_w, d.centerY(box, 13), ctx.col(.faint), ex, ex_w);
    icons.chevron(p.dl, box.right() - 18, box.y + box.h / 2, ctx.col(.muted).u(), if (open) 1 else 0);
    if (hb.clicked) dropdown.toggle(dd_key);
    p.y += box.h + 12;
    // Linhas de 30: a lista inteira cabe sem rolar (até 340, ui/dropdown.zig).
    if (dropdown.beginAt(ctx, dd_key, box, box.w, @as(f32, @floatFromInt(vt.custom_index + 1)) * 30, @as(f32, @floatFromInt(cur)) * 30)) |dd_c| {
        var dd = dd_c;
        defer dd.end();
        for (0..vt.custom_index + 1) |i| {
            const row = dd.row(30, i == cur);
            qa.mark(row.rect, "vt-preset:{d}", .{i});
            var rb: [96]u8 = undefined;
            const rex = if (i == vt.custom_index) s.voice_timer_pattern.slice() else presetExample(&rb, i);
            const rex_w = @min(d.width(ctx.mono.get(.regular), 13, rex), row.rect.w * 0.45);
            _ = d.textClipped(dd.dl, p.font(.medium), 14, row.rect.x + 10, d.centerY(row.rect, 14), ctx.col(.text), presetName(i), row.rect.w - rex_w - 30);
            _ = d.textClipped(dd.dl, ctx.mono.get(.regular), 13, row.rect.right() - 10 - rex_w, d.centerY(row.rect, 13), ctx.col(.faint), rex, rex_w);
            if (row.hit.clicked) {
                // Escrever o próprio começa do que estava escolhido.
                if (i == vt.custom_index and s.voice_timer_pattern.len == 0 and cur < vt.presets.len) s.voice_timer_pattern.set(vt.presets[cur].pattern);
                s.voice_timer_format = @intCast(i);
                dropdown.close();
            }
        }
    }

    if (cur == vt.custom_index) custom(p, s);

    // A prévia, com o formato de agora.
    p.line(.bold, 12, ctx.col(.muted), i18n.tr("PRÉVIA", "PREVIEW"), 22);
    const fmt = timer_ui.format(s);
    const mono = ctx.mono.get(.regular);
    const label_w = d.width(mono, 13, "187234 s  →  ");
    for (samples) |e| {
        var lb: [24]u8 = undefined;
        const lt = std.fmt.bufPrint(&lb, "{d} s  →", .{e}) catch "";
        // Encostadas à direita: as setas ficam numa coluna só.
        const lw = d.width(mono, 13, lt);
        d.text(p.dl, mono, 13, p.x + label_w - lw - d.width(mono, 13, "  "), p.y, ctx.col(.faint), lt);
        var vb: [320]u8 = undefined;
        const v = fmt.text(&vb, e);
        const vw = d.textClipped(p.dl, mono, 14, p.x + label_w, p.y - 1, timer_ui.color(ctx), v, p.w - label_w);
        p.markText(.{ .x = p.x, .y = p.y, .w = label_w + vw, .h = 18 });
        qa.mark(.{ .x = p.x + label_w, .y = p.y, .w = vw, .h = 18 }, "vt-preview:{d}", .{e});
        p.y += 24;
    }
    p.y += 8;
}

/// A caixa do formato da pessoa, o que cada campo quer dizer e os avisos.
fn custom(p: anytype, s: *S.Settings) void {
    const ctx = p.ctx;
    // O texto mudou por fora (arquivo, outro formato escolhido): a caixa acompanha.
    if (!std.mem.eql(u8, pat_seen.slice(), s.voice_timer_pattern.slice())) {
        pat_seen = s.voice_timer_pattern;
        @memset(&pat_buf, 0);
        @memcpy(pat_buf[0..pat_seen.len], pat_seen.slice());
    }
    const iw = @min(p.w, 440);
    const ir: d.Rect = .{ .x = p.x, .y = p.y, .w = iw, .h = 32 };
    const cp = vt.compile(s.voice_timer_pattern.slice());
    d.rect(p.dl, ir, ctx.col(.elevated), 6);
    d.border(p.dl, ir, if (cp.unknown > 0) ctx.col(.idle) else ctx.col(.border), 6, 1);
    c.ImGui_SetCursorScreenPos(d.v(p.x + 10, p.y + 3));
    c.ImGui_SetNextItemWidth(iw - 20);
    // Cada tecla já vale: a prévia e a lista de canais mudam enquanto se escreve.
    if (c.ImGui_InputTextWithHint("##vt-pattern", "{H}:{mm}:{ss}", &pat_buf, pat_buf.len, 0)) {
        s.voice_timer_pattern.set(std.mem.sliceTo(&pat_buf, 0));
        pat_seen = s.voice_timer_pattern;
    }
    qa.mark(ir, "vt-pattern", .{});
    p.y += ir.h + 10;

    // O que cada campo quer dizer.
    const fields = [_]struct { tok: []const u8, pt: []const u8, en: []const u8 }{
        .{ .tok = "{H}", .pt = "horas no total", .en = "total hours" },
        .{ .tok = "{h}", .pt = "horas do dia (0 a 23)", .en = "hours of the day (0 to 23)" },
        .{ .tok = "{d}", .pt = "dias", .en = "days" },
        .{ .tok = "{M}", .pt = "minutos no total", .en = "total minutes" },
        .{ .tok = "{m}", .pt = "minutos da hora (0 a 59)", .en = "minutes of the hour (0 to 59)" },
        .{ .tok = "{S}", .pt = "segundos no total", .en = "total seconds" },
        .{ .tok = "{s}", .pt = "segundos do minuto (0 a 59)", .en = "seconds of the minute (0 to 59)" },
    };
    const mono = ctx.mono.get(.regular);
    const tok_w = d.width(mono, 13, "{HH} ") + 8;
    for (fields) |f| {
        d.text(p.dl, mono, 13, p.x, p.y, timer_ui.color(ctx), f.tok);
        const w = d.textClipped(p.dl, p.font(.regular), 13.5, p.x + tok_w, p.y, ctx.col(.muted), i18n.tr(f.pt, f.en), p.w - tok_w);
        p.markText(.{ .x = p.x, .y = p.y, .w = tok_w + w, .h = 18 });
        p.y += 21;
    }
    p.y += 4;
    p.note(i18n.tr("Com a letra dobrada, sempre dois algarismos: 07 em vez de 7. O resto do texto aparece como você escreveu.", "Doubling the letter always gives two digits: 07 instead of 7. Everything else shows as you typed it."));
    if (cp.unknown > 0) {
        var wb: [160]u8 = undefined;
        const y0 = p.y;
        const tw = d.textClipped(p.dl, p.font(.medium), 13.5, p.x, p.y, ctx.col(.idle), i18n.fmt(&wb, "Não é um campo, aparece como texto: {s}", "Not a field, shown as text: {s}", .{cp.firstUnknown()}), p.w);
        p.markText(.{ .x = p.x, .y = y0, .w = tw, .h = 18 });
        qa.mark(.{ .x = p.x, .y = y0, .w = tw, .h = 18 }, "vt-unknown", .{});
        p.y += 24;
    } else if (cp.unit == .none and std.mem.trim(u8, s.voice_timer_pattern.slice(), " \t").len > 0) {
        const y0 = p.y;
        const tw = d.textClipped(p.dl, p.font(.medium), 13.5, p.x, p.y, ctx.col(.idle), i18n.tr("Sem nenhum campo, o texto nunca muda.", "Without any field, the text never changes."), p.w);
        p.markText(.{ .x = p.x, .y = y0, .w = tw, .h = 18 });
        p.y += 24;
    }
    p.y += 6;
}
