// O que o larperCord pede ao mimalloc (só com zig build -Dmimalloc=true; ver
// src/platform/mem_tune.zig): devolver a memória livre ao sistema e os números do heap.
// Em C porque a estrutura das estatísticas é grande e muda de uma versão para outra.
#include <stddef.h>
#include "mimalloc.h"
#include "mimalloc-stats.h"

void larper_mi_trim(void) {
    mi_collect(true);
}

// Em uso (`allocated`), pedido ao sistema (`committed`) e quantos blocos ainda vivem.
int larper_mi_heap(size_t *used, size_t *committed) {
    static mi_stats_t st;
    mi_stats_header_init(&st);
    if (!mi_stats_get(&st)) return 0;
    *used = st.allocated.current > 0 ? (size_t)st.allocated.current : 0;
    *committed = st.committed.current > 0 ? (size_t)st.committed.current : 0;
    return 1;
}
