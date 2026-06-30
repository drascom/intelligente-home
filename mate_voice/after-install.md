# Mate Voice — kurulum sonrası

Mate Voice, Hermes'e LiveKit üzerinden **canlı sesli asistan** ekler: konuş, dinlesin, sesli yanıt versin.

## Nereye bağlanır
- **LiveKit:** `LIVEKIT_URL` (örn. `wss://mate-livekit.drascom.uk`) · **Oda:** `MATE_LIVEKIT_ROOM` (varsayılan `mate-hermes-test`)

## Girilen değerler (`~/.hermes/.env`)
- `LIVEKIT_URL` · `LIVEKIT_API_KEY` · `LIVEKIT_API_SECRET` — LiveKit bağlantısı
- `STT_HOST`/`STT_PORT` (whisper) · `VOX_HOST`/`VOX_PORT` (TTS) — ses servisleri
- `MATE_VOICE_CLIENT_KEY` — istemcinin `X-Mate-Key`'i (boş bırakılırsa ilk başlatmada otomatik üretilir)

## Son adım
1. Gateway'i yeniden başlat:
   ```
   hermes gateway restart
   ```
2. İlk başlatmada konsolda **CLIENT_KEY ve QR kodu** çıkar (key otomatik üretildiyse). Bu değeri
   **client (mate-mac) ayarlarındaki `X-Mate-Key` / Client Key** alanına gir.
3. Bağlantı doğrulaması — `~/.hermes/logs/gateway.log` içinde:
   `✓ mate_voice connected` ve `Gateway running with 1 platform(s)`.
