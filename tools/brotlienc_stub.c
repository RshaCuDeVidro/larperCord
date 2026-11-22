/* Codificador brotli vazio para o OpenSSL do binário portátil (tools/linux_deps.sh).
 * O OpenSSL com brotli cita o codificador e o decodificador, mas o app só descomprime: o
 * certificado comprimido que o servidor manda (o Chrome pede em brotli) e as respostas
 * do curl. Comprimir é coisa de servidor. O codificador de verdade são ~570 KB. */
#include <brotli/encode.h>

BrotliEncoderState *BrotliEncoderCreateInstance(brotli_alloc_func alloc_func, brotli_free_func free_func,
                                                void *opaque) {
    (void)alloc_func, (void)free_func, (void)opaque;
    return NULL;
}

void BrotliEncoderDestroyInstance(BrotliEncoderState *state) { (void)state; }

BROTLI_BOOL BrotliEncoderCompressStream(BrotliEncoderState *state, BrotliEncoderOperation op, size_t *available_in,
                                        const uint8_t **next_in, size_t *available_out, uint8_t **next_out,
                                        size_t *total_out) {
    (void)state, (void)op, (void)available_in, (void)next_in, (void)available_out, (void)next_out, (void)total_out;
    return BROTLI_FALSE;
}

BROTLI_BOOL BrotliEncoderHasMoreOutput(BrotliEncoderState *state) {
    (void)state;
    return BROTLI_FALSE;
}

BROTLI_BOOL BrotliEncoderCompress(int quality, int lgwin, BrotliEncoderMode mode, size_t input_size,
                                  const uint8_t *input_buffer, size_t *encoded_size, uint8_t *encoded_buffer) {
    (void)quality, (void)lgwin, (void)mode, (void)input_size, (void)input_buffer, (void)encoded_size, (void)encoded_buffer;
    return BROTLI_FALSE;
}
