# mate-sim — başsız mate-mac simülatörü

stage LiveKit odasına bağlanan, TEST ses dosyası yayınlayan ve geri dönen
transkript + TTS sesini yakalayan headless istemci. Uçtan uca ses hattını
(mic→STT→Hermes→cevap→TTS) GUI olmadan test eder.

## Kurulum
```
cd tools/mate-sim
python3 -m venv .venv && . .venv/bin/activate
pip install -r requirements.txt
```

## Çalıştırma
```
# token'ı CONNECT.md'deki bir yoldan al, env'e koy
export MATE_LK_TOKEN='<token>'
python sim.py                 # tam tur: yayınla + cevap bekle (30s)
python sim.py --connect-only  # yalnız bağlantı + publish doğrula
python sim.py --text "Candan, saat kaç?" --wait 40
```

## Çıktı
- Konsol + `last-run.log`: adım adım PASS/FAIL (connected/published/transcript/tts).
- `reply.wav`: agent'tan gelen TTS sesi (geldi ise).
- `prompt.wav`: yayınlanan test cümlesi (yoksa `make_wav.sh` ile otomatik üretilir).

Bağlantı/oda/token detayı: **CONNECT.md**.
Not: `*.wav`, `*.log`, `token.txt`, `.venv/` gitignore'da.
