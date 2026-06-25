// Swift'e C API'leri açan köprü başlığı.
// Vendor edilmiş speexdsp (yazılım AEC) — macOS 26'da donanım VPIO bozuk olduğu
// için echo canceller'ı kendimiz çalıştırıyoruz. iOS'ta VPIO çalıştığından bu
// yol dormant kalır ama kod iki projede de derlenir.
#include "speex/speex_echo.h"
#include "speex/speex_preprocess.h"
