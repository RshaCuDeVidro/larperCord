// Só o que o player de áudio usa (src/core/audio_pcm.zig): MP3 e WAV (e AIFF, que o
// dr_wav também lê) decodificados da memória, em float, sem stdio. O resto (FLAC,
// Vorbis, AAC…) vai pelo FFmpeg do sistema.
#define DR_MP3_IMPLEMENTATION
#define DR_MP3_NO_STDIO
#define DR_WAV_IMPLEMENTATION
#define DR_WAV_NO_STDIO
#define DR_WAV_NO_WCHAR
#include "dr_mp3.h"
#include "dr_wav.h"

// --- larperCord: alças opacas para o Zig ------------------------------------
// As structs do dr_libs ficam aqui dentro: o Zig só vê um ponteiro e funções com
// tipos simples. `data` precisa durar até o close (nada é copiado).

typedef struct larper_mp3 { drmp3 d; } larper_mp3;

larper_mp3 *larper_mp3_open(const void *data, size_t len, unsigned *channels, unsigned *rate)
{
   larper_mp3 *m = (larper_mp3 *) DRMP3_MALLOC(sizeof(larper_mp3));
   if (!m) return 0;
   if (!drmp3_init_memory(&m->d, data, len, NULL)) {
      DRMP3_FREE(m);
      return 0;
   }
   *channels = m->d.channels;
   *rate = m->d.sampleRate;
   return m;
}

// Quadros de áudio no arquivo (pelo cabeçalho Xing/Info ou contando os quadros do
// MP3 sem decodificar).
unsigned long long larper_mp3_frames(larper_mp3 *m)
{
   return drmp3_get_pcm_frame_count(&m->d);
}

unsigned long long larper_mp3_read(larper_mp3 *m, unsigned long long frames, float *out)
{
   return drmp3_read_pcm_frames_f32(&m->d, frames, out);
}

int larper_mp3_seek(larper_mp3 *m, unsigned long long frame)
{
   return drmp3_seek_to_pcm_frame(&m->d, frame) ? 1 : 0;
}

void larper_mp3_close(larper_mp3 *m)
{
   drmp3_uninit(&m->d);
   DRMP3_FREE(m);
}

typedef struct larper_wav { drwav d; } larper_wav;

larper_wav *larper_wav_open(const void *data, size_t len, unsigned *channels, unsigned *rate)
{
   larper_wav *w = (larper_wav *) DRWAV_MALLOC(sizeof(larper_wav));
   if (!w) return 0;
   if (!drwav_init_memory(&w->d, data, len, NULL)) {
      DRWAV_FREE(w);
      return 0;
   }
   *channels = w->d.channels;
   *rate = w->d.sampleRate;
   return w;
}

unsigned long long larper_wav_frames(larper_wav *w)
{
   return w->d.totalPCMFrameCount;
}

unsigned long long larper_wav_read(larper_wav *w, unsigned long long frames, float *out)
{
   return drwav_read_pcm_frames_f32(&w->d, frames, out);
}

int larper_wav_seek(larper_wav *w, unsigned long long frame)
{
   return drwav_seek_to_pcm_frame(&w->d, frame) ? 1 : 0;
}

void larper_wav_close(larper_wav *w)
{
   drwav_uninit(&w->d);
   DRWAV_FREE(w);
}
