// Quanto cada biblioteca grande tem alocado agora (Configurações → Desempenho e o --stats):
// o SDL, o Dear ImGui, o FreeType, o curl e o OpenSSL alocam por estas funções, que chamam o
// mesmo malloc de sempre e só somam o tamanho de cada bloco (malloc_usable_size, _msize no
// Windows). As funções de cada biblioteca são entregues a ela no começo do main, antes de
// ela alocar qualquer coisa (src/platform/mem_contas.zig).
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <malloc.h>

#if defined(LARPER_MIMALLOC)
// Com o mimalloc (zig build -Dmimalloc=true) o tamanho vem dele: no Windows o _msize da DLL
// do C não conhece os blocos do mimalloc.
#include "mimalloc.h"
#define USABLE(p) mi_usable_size(p)
#elif defined(_WIN32)
#define USABLE(p) _msize(p)
#else
#define USABLE(p) malloc_usable_size(p)
#endif

enum { C_SDL, C_IMGUI, C_FREETYPE, C_CURL, C_OPENSSL, C_N };
static long long contas[C_N];

long long larper_mem_conta(int i) {
    if (i < 0 || i >= C_N) return 0;
    return __atomic_load_n(&contas[i], __ATOMIC_RELAXED);
}

static void soma(int i, long long n) {
    __atomic_add_fetch(&contas[i], n, __ATOMIC_RELAXED);
}

static void *c_malloc(int i, size_t n) {
    void *p = malloc(n);
    if (p) soma(i, (long long)USABLE(p));
    return p;
}

static void *c_calloc(int i, size_t a, size_t b) {
    void *p = calloc(a, b);
    if (p) soma(i, (long long)USABLE(p));
    return p;
}

static void c_free(int i, void *p) {
    if (!p) return;
    soma(i, -(long long)USABLE(p));
    free(p);
}

static void *c_realloc(int i, void *p, size_t n) {
    if (n == 0 && p) {
        c_free(i, p);
        return NULL;
    }
    long long old = p ? (long long)USABLE(p) : 0;
    void *q = realloc(p, n);
    if (q) soma(i, (long long)USABLE(q) - old);
    return q;
}

static char *c_strdup(int i, const char *s) {
    size_t n = strlen(s) + 1;
    char *p = c_malloc(i, n);
    if (p) memcpy(p, s, n);
    return p;
}

// SDL (SDL_SetMemoryFunctions).
void *larper_sdl_malloc(size_t n) { return c_malloc(C_SDL, n); }
void *larper_sdl_calloc(size_t a, size_t b) { return c_calloc(C_SDL, a, b); }
void *larper_sdl_realloc(void *p, size_t n) { return c_realloc(C_SDL, p, n); }
void larper_sdl_free(void *p) { c_free(C_SDL, p); }

// Dear ImGui (ImGui_SetAllocatorFunctions) e o FreeType dele (ImGuiFreeType::SetAllocatorFunctions).
void *larper_imgui_alloc(size_t n, void *ud) { (void)ud; return c_malloc(C_IMGUI, n); }
void larper_imgui_free(void *p, void *ud) { (void)ud; c_free(C_IMGUI, p); }
void *larper_freetype_alloc(size_t n, void *ud) { (void)ud; return c_malloc(C_FREETYPE, n); }
void larper_freetype_free(void *p, void *ud) { (void)ud; c_free(C_FREETYPE, p); }

// curl (curl_global_init_mem).
void *larper_curl_malloc(size_t n) { return c_malloc(C_CURL, n); }
void larper_curl_free(void *p) { c_free(C_CURL, p); }
void *larper_curl_realloc(void *p, size_t n) { return c_realloc(C_CURL, p, n); }
char *larper_curl_strdup(const char *s) { return c_strdup(C_CURL, s); }
void *larper_curl_calloc(size_t a, size_t b) { return c_calloc(C_CURL, a, b); }

// OpenSSL (CRYPTO_set_mem_functions): o arquivo e a linha de quem pediu não interessam.
void *larper_ssl_malloc(size_t n, const char *f, int l) { (void)f; (void)l; return c_malloc(C_OPENSSL, n); }
void *larper_ssl_realloc(void *p, size_t n, const char *f, int l) { (void)f; (void)l; return c_realloc(C_OPENSSL, p, n); }
void larper_ssl_free(void *p, const char *f, int l) { (void)f; (void)l; c_free(C_OPENSSL, p); }
