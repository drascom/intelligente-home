# Mate Voice — kurulumdan sonra

Bu plugin, LiveKit üzerinden **canlı sesli** bir Mate arayüzü ekler (wake-word
gate, smart-turn EOU, barge-in, speaker-ID/enrollment, canlı transkript; STT=whisper,
TTS=vox ağ servisleri). Bağlantı + token sözleşmesi: `CLIENT_INTEGRATION.md`.

## 1. Etkinleştir
`~/.hermes/config.yaml`:
```yaml
plugins:
  enabled:
    - mate_voice
```

## 2. Ortam değişkenleri (`~/.hermes/.env`)
`hermes plugins install` sırasında `requires_env` zaten soruldu. Eksikse:
- **Zorunlu:** `LIVEKIT_URL`, `LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET`, `STT_HOST`/`STT_PORT`,
  `VOX_HOST`/`VOX_PORT`, `MATE_VOICE_CLIENT_KEY` (istemcilerin `X-Mate-Key`'i; boş bırakılırsa ilk başlatmada otomatik üretilip konsolda metin + QR kod olarak gösterilir — o değeri client'a girin).
- **Opsiyonel:** `MATE_PUBLIC_LIVEKIT_URL`, `MATE_LIVEKIT_ROOM` (vars. `mate-hermes-test`),
  `MATE_VOICE_TOKEN_PORT` (8830), `TURN_DETECTOR_ENABLED`, `SPEAKER_ID_ENABLED`,
  `SPEAKER_MODEL_PATH` (campplus.onnx; speaker-ID açıksa).

## 3. Python bağımlılıkları — OTOMATİK
Hermes plugin installer Python deps KURMAZ. Bu plugin **kendi kurar**: gateway
ilk başladığında, ETKİN özelliklerin (turn-detector / speaker-ID) eksik paketlerini
(`onnxruntime`, `transformers`, `huggingface_hub`, `sherpa-onnx`, `numpy`) gateway
venv'ine `pip install` eder (fail-open; bkz. `voice/_deps.py`). İlk başlangıç bu
yüzden biraz uzun sürebilir.

- Kapatmak: `MATE_VOICE_AUTO_INSTALL_DEPS=0`.
- Elle kurmak: `<hermes-venv>/bin/python -m pip install -r requirements.txt`.
- Eğer Hermes ajanı bunu senin yerine kuracaksa: `requirements.txt`'i kur ve
  yukarıdaki env'leri ayarla, sonra gateway'i yeniden başlat.

## 4. Başlat / doğrula
```
sudo systemctl restart hermes-gateway
curl -s http://localhost:8830/mate/health     # {"status":"ok",...}
```
Loglar: `mate_voice: oda hazır`, `… token endpoint AÇIK`, (speaker açıksa) `… enrolled speaker yüklendi`.

## 5. Onboarding (sihirbaz)
Açık demo token: `GET /mate/demo-token` (key'siz, kısa ömürlü, onboarding odası).
İstemci sıfır-konfig bununla bağlanıp sesli tanışma + enrollment yapar.
