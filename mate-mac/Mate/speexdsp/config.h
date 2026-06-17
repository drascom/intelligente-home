/* Mate için minimal speexdsp yapılandırması (autotools configure yerine elle).
   Sadece echo canceller (mdf) + preprocess derlenir; kayan nokta + KISS FFT.
   C dosyaları bunu yalnız HAVE_CONFIG_H tanımlıyken include eder (build ayarı). */
#ifndef MATE_SPEEXDSP_CONFIG_H
#define MATE_SPEEXDSP_CONFIG_H

#define FLOATING_POINT   /* sabit nokta değil — float DSP */
#define USE_KISS_FFT     /* smallft yerine KISS FFT (kiss_fft.c/kiss_fftr.c) */
#define EXPORT           /* sembol görünürlük niteliği gerekmez (aynı target) */
#define VAR_ARRAYS       /* C99 değişken-uzunluklu diziler (clang destekler) */

#endif
