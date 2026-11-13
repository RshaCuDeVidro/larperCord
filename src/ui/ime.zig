//! Texto em conversão do IME (japonês, chinês, coreano...) na caixa de texto.
//!
//! O SDL manda o que está sendo convertido em `SDL_EVENT_TEXT_EDITING` e o texto
//! já decidido em `SDL_EVENT_TEXT_INPUT`. O ImGui só conhece o segundo: o backend
//! do SDL3 ignora o primeiro e o ImGui não desenha texto de composição. Aqui o
//! texto em conversão entra no buffer ativo do ImGui pela mesma porta do
//! `inputCallback` (ui/comp_messages.zig), sem passar para `st.input`: assim ele
//! aparece, ocupa o lugar certo e acompanha a quebra de linha, e some quando a
//! conversão termina (o texto decidido chega logo depois pelo caminho normal).
//!
//! O sublinhado é desenhado por `larper_input_underline` (ui/font_metrics.cpp),
//! que usa as mesmas posições do texto que o ImGui acabou de calcular.
const std = @import("std");
const c = @import("c");

/// O SDL manda o texto em UTF-8; uma conversão maior que isto é cortada.
const max_preedit = 256;

extern fn larper_input_underline(start: c_int, len: c_int, col: c_uint, thickness: f32) void;

/// A caixa de texto do chat estava com o foco no último quadro. O IME só vale
/// para ela (os outros campos do ImGui continuam sem composição por enquanto).
pub var composer_active = false;

var applied = false; // o texto em conversão está no buffer do ImGui
var applied_start: usize = 0;
var applied_len: usize = 0;
var applied_text: [max_preedit]u8 = undefined;

var pending = false; // chegou um texto em conversão novo
var pending_text: [max_preedit]u8 = undefined;
var pending_len: usize = 0;

var committing = false; // o texto foi decidido: tira o em conversão do buffer

/// Lê o evento do SDL. Chamar antes de `cImGui_ImplSDL3_ProcessEvent`: o texto
/// decidido continua indo para o ImGui por lá.
pub fn onSdlEvent(e: *const c.SDL_Event) void {
    if (e.type == c.SDL_EVENT_TEXT_EDITING) {
        if (!composer_active) return;
        const p = e.edit.text;
        if (p == null) return;
        const s = std.mem.span(@as([*:0]const u8, @ptrCast(p)));
        const n = utf8Fit(s, max_preedit);
        @memcpy(pending_text[0..n], s[0..n]);
        pending_len = n;
        pending = true;
        return;
    }
    if (e.type == c.SDL_EVENT_TEXT_INPUT) {
        // O texto decidido vem depois do último `TEXT_EDITING`. Qualquer
        // conversão que ainda estava esperando era ele: não volta como nova.
        if (applied or pending) {
            committing = true;
            pending = false;
            pending_len = 0;
        }
    }
}

/// Aplica a conversão no buffer do ImGui, de dentro do `inputCallback`.
pub fn applyCallback(data: [*c]c.ImGuiInputTextCallbackData) void {
    if (committing) {
        committing = false;
        removeApplied(data);
    }

    if (!pending) return;
    pending = false;

    // O texto em conversão novo toma o lugar do anterior. Sem anterior, entra
    // onde estava o cursor quando a conversão começou.
    const had = applied;
    if (had) removeApplied(data);

    if (pending_len > 0) {
        const text_len: usize = @intCast(@max(data.*.BufTextLen, 0));
        var at = if (had) applied_start else blk: {
            const cur: usize = @intCast(@max(data.*.CursorPos, 0));
            break :blk @min(cur, text_len);
        };
        if (at > text_len) at = text_len;

        const ptr: [*c]const u8 = pending_text[0..].ptr;
        const end: [*c]const u8 = pending_text[pending_len..].ptr;
        c.ImGuiInputTextCallbackData_InsertChars(data, @intCast(at), ptr, end);
        // O cursor fica depois do texto em conversão, e não dentro dele: o
        // ImGui encaixa o texto decidido (o `TEXT_INPUT` que vem logo depois)
        // exatamente nessa posição, antes de este callback rodar. Com o cursor
        // dentro, tirar a conversão do buffer levaria o texto decidido junto.
        const cur = at + pending_len;
        data.*.CursorPos = @intCast(cur);
        data.*.SelectionStart = @intCast(cur);
        data.*.SelectionEnd = @intCast(cur);

        @memcpy(applied_text[0..pending_len], pending_text[0..pending_len]);
        applied = true;
        applied_start = at;
        applied_len = pending_len;
    }
}

fn removeApplied(data: [*c]c.ImGuiInputTextCallbackData) void {
    if (!applied) return;
    applied = false;
    const text_len: usize = @intCast(@max(data.*.BufTextLen, 0));
    if (applied_start > text_len) return;
    const n = @min(applied_len, text_len - applied_start);
    if (n > 0) c.ImGuiInputTextCallbackData_DeleteChars(data, @intCast(applied_start), @intCast(n));
    applied_len = 0;
}

/// Desenha o sublinhado do texto em conversão. Chamar com a caixa ainda ativa e
/// depois de `ImGui_InputTextMultiline`, antes de trocar a fonte.
pub fn underline(col: c_uint, thickness: f32) void {
    if (applied and applied_len > 0)
        larper_input_underline(@intCast(applied_start), @intCast(applied_len), col, thickness);
}

/// A conversão está no buffer do ImGui (e o cursor lógico está dentro dela).
pub fn isComposing() bool {
    return applied or pending or committing;
}

/// Esquece a conversão sem tocar em buffer nenhum. Usar quando a caixa deixou de
/// ser desenhada (outro painel por cima), para o estado não ficar preso.
pub fn forget() void {
    applied = false;
    applied_len = 0;
    pending = false;
    pending_len = 0;
    committing = false;
}

/// A caixa do chat foi desenhada no quadro anterior. O app zera `composer_active`
/// a cada quadro; este sinalizador só é zerado aqui.
var drawn = false;

/// Primeira coisa de `composer`: se a caixa não foi desenhada no quadro passado,
/// a conversão morreu com ela (outro painel por cima, outra tela).
pub fn beginComposer() void {
    if (!drawn) forget();
    drawn = false;
    composer_active = false;
}

/// A caixa foi desenhada neste quadro.
pub fn endComposer(active_now: bool) void {
    drawn = true;
    composer_active = active_now;
}

/// A caixa perdeu o foco com uma conversão aberta: o ImGui acabou de copiar o
/// buffer (com o texto em conversão) para `st.input`. Tira ele de lá.
pub fn dropFromBuffer(buf: []u8) void {
    if (!applied and !pending) return;
    pending = false;
    pending_len = 0;
    committing = false;
    if (!applied) return;

    const len = std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
    if (applied_start >= len) {
        applied = false;
        applied_len = 0;
        return;
    }
    const n = @min(applied_len, len - applied_start);
    if (n == 0) {
        applied = false;
        return;
    }
    // O ImGui só copia o buffer ativo para o st.input ao soltar a caixa. Se o
    // texto em conversão não estiver lá, não mexe em nada.
    if (!std.mem.eql(u8, buf[applied_start .. applied_start + n], applied_text[0..n])) {
        applied = false;
        applied_len = 0;
        return;
    }
    const end = len - n;
    std.mem.copyForwards(u8, buf[applied_start..end], buf[applied_start + n .. len]);
    @memset(buf[end .. end + n], 0);
    applied = false;
    applied_len = 0;
}

/// Maior prefixo de `s` que cabe em `cap` bytes sem cortar um caractere UTF-8.
fn utf8Fit(s: []const u8, cap: usize) usize {
    if (s.len <= cap) return s.len;
    var at = cap;
    while (at > 0 and (s[at] & 0xc0) == 0x80) at -= 1;
    return at;
}

test "utf8Fit não corta caractere" {
    const s = "変換中";
    try std.testing.expectEqual(@as(usize, 0), utf8Fit(s, 0));
    try std.testing.expectEqual(@as(usize, 3), utf8Fit(s, 3));
    try std.testing.expectEqual(@as(usize, 3), utf8Fit(s, 4));
    try std.testing.expectEqual(@as(usize, 9), utf8Fit(s, 100));
}
