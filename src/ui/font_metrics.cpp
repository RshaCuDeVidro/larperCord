// As bindings em C do ImGui deixam ImFontBaked opaco (tem campos de bits), e a
// linha de base dos runs do `label` precisa do Ascent de cada fonte e tamanho.
#include "imgui.h"
#include "imgui_internal.h"

extern "C" float larper_font_ascent(ImFont* font, float size) {
    return font->GetFontBaked(size)->Ascent;
}

// Onde o ImGui quebra uma linha da caixa de texto com WordWrap (InputTextLineIndexBuild).
extern "C" const char* larper_input_wrap(ImFont* font, float size, const char* s, const char* end, float wrap) {
    return ImFontCalcWordWrapPositionEx(font, size, s, end, wrap, ImDrawTextFlags_WrapKeepBlanks);
}

// Põe uma fonte já mesclada na posição `pos` de `font`: para um mesmo caractere, vence a
// que vem primeiro. A ordem que vale é a da lista do atlas (ImFontAtlasBuildUpdatePointers).
extern "C" void larper_font_source_to(ImFont* font, const void* data, int font_no, int pos) {
    ImFontAtlas* atlas = font->OwnerAtlas;
    // Os dados de cada tamanho seguem a ordem das fontes: esses saem antes de mudar.
    ImFontAtlasFontDiscardBakes(atlas, font, 0);
    int to = -1, from = -1, seen = 0;
    for (int i = 0; i < atlas->Sources.Size; i++) {
        const ImFontConfig& src = atlas->Sources[i];
        if (src.DstFont != font) continue;
        if (seen == pos) to = i;
        if (src.FontData == data && (int)src.FontNo == font_no) from = i;
        seen++;
    }
    if (to < 0 || from <= to) return;
    ImFontConfig moved = atlas->Sources[from];
    memmove(&atlas->Sources[to + 1], &atlas->Sources[to], (size_t)(from - to) * sizeof(ImFontConfig));
    atlas->Sources[to] = moved;
    ImFontAtlasBuildUpdatePointers(atlas);
}

// Quantas entradas a tabela de caracteres dessa fonte+tamanho tem (o QA confere
// que um emoji não reserva a tabela até U+1F600).
extern "C" int larper_font_index_size(ImFont* font, float size) {
    return font->GetFontBaked(size)->IndexLookup.Size;
}

// O sublinhado do texto em conversão do IME (ui/ime.zig), nas posições que o
// ImGui acabou de calcular para o InputText ativo.
extern "C" void larper_input_underline(int start, int len, unsigned int col, float thickness) {
    ImGui::InputTextDrawUnderline(start, len, (ImU32)col, thickness);
}

// Põe a janela atual (entre Begin e End) na frente das outras sem pegar o foco do
// teclado: quem está digitando em outra janela continua digitando. As bindings em C
// não expõem a função interna.
extern "C" void larper_window_to_front(void) {
    ImGui::BringWindowToDisplayFront(ImGui::GetCurrentWindow());
}

// Uma fonte reserva de outra escrita (fonts.zig, marcada com `tag` no nome) ganhou mais um
// bloco do Unicode: passa a valer fora destas faixas. A mesma fonte no atlas, sem abrir outra
// face do FreeType. As letras já carregadas saem, como numa fonte nova mesclada (AddFont).
extern "C" void larper_font_source_exclude(ImFont* font, const void* data, int font_no, const char* tag, const ImWchar* ranges) {
    int size = 0;
    while (ranges[size] != 0) size++;
    IM_ASSERT((size & 1) == 0 && size <= 64);
    for (ImFontConfig* src : font->Sources) {
        if (src->FontData != data || (int)src->FontNo != font_no || strcmp(src->Name, tag) != 0) continue;
        ImFontAtlasFontDiscardBakes(font->OwnerAtlas, font, 0);
        IM_FREE((void*)src->GlyphExcludeRanges);
        src->GlyphExcludeRanges = (ImWchar*)ImMemdup(ranges, sizeof(ImWchar) * (size_t)(size + 1));
    }
}

// Alguma fonte de `font` desenha esta letra (sem cair no "?")? Respeita as faixas excluídas
// de cada fonte, ao contrário do IsGlyphInFont. Para o QA.
extern "C" bool larper_font_draws(ImFont* font, float size, unsigned int c) {
    return font->GetFontBaked(size)->FindGlyphNoFallback((ImWchar)c) != NULL;
}

// A caixa das letras de `s` desenhadas em (0, 0) no tamanho `size` (x0, y0, x1, y1 em
// `out`), com as mesmas contas do ImFont::RenderText. Cada fonte de emoji põe o desenho
// num lugar da linha (a do Windows fica mais larga e mais baixa que a do Linux): quem
// centraliza um emoji usa esta caixa, não a largura nem a altura da linha. Sem nenhuma
// letra visível, devolve false.
extern "C" bool larper_text_ink(ImFont* font, float size, const char* s, const char* e, float* out) {
    ImFontBaked* baked = font->GetFontBaked(size);
    if (baked == NULL || baked->Size <= 0.0f) return false;
    const float scale = size / baked->Size;
    float x = 0.0f;
    bool any = false;
    while (s < e) {
        unsigned int c = (unsigned char)*s;
        if (c < 0x80) s += 1;
        else s += ImTextCharFromUtf8(&c, s, e);
        if (c < 32) continue;
        const ImFontGlyph* g = baked->FindGlyph((ImWchar)c);
        if (g == NULL) continue;
        if (g->Visible) {
            const float x0 = x + g->X0 * scale, x1 = x + g->X1 * scale;
            const float y0 = g->Y0 * scale, y1 = g->Y1 * scale;
            if (!any) {
                out[0] = x0; out[1] = y0; out[2] = x1; out[3] = y1;
                any = true;
            } else {
                out[0] = ImMin(out[0], x0); out[1] = ImMin(out[1], y0);
                out[2] = ImMax(out[2], x1); out[3] = ImMax(out[3], y1);
            }
        }
        x += g->AdvanceX * scale;
    }
    return any;
}
