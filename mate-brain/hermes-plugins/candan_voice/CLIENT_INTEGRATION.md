# candan_voice — İstemci Entegrasyon Sözleşmesi

Bir istemci (mate-mac veya başka) Hermes `candan_voice` plugin'in LiveKit odasına
**brain'den bağımsız** bağlanır. LiveKit API secret SUNUCUDA kalır; istemci
paylaşılan-anahtarlı token endpoint'ten room-scoped bir join token alır.

## 1. Token endpoint (plugin'e gömülü)

Plugin gateway içinde küçük bir HTTP sunucu çalıştırır (env ile yapılandırılır).

| | |
|---|---|
| Token | `GET /candan/token?identity=<client-id>&room=<opsiyonel>` |
| Header | `X-Candan-Key: <CANDAN_VOICE_CLIENT_KEY>` |
| Health | `GET /candan/health` |

**Yanıt (200):**
```json
{
  "url": "wss://mate-livekit.drascom.uk",
  "room": "mate-hermes-test",
  "token": "<jwt>",
  "identity": "<client-id>"
}
```
- `room` verilmezse plugin'in kendi odası döner.
- Token grant'ları: `roomJoin + canPublish + canSubscribe + canUpdateOwnMetadata`,
  TTL `CANDAN_VOICE_CLIENT_TOKEN_TTL` (varsayılan 3600s). Identity = istemci `kind=agent` DEĞİL.

**Hatalar:** `401` (anahtar yanlış/eksik), `400` (identity yok), `500` (mint hatası).
Anahtar (`CANDAN_VOICE_CLIENT_KEY`) boşsa endpoint HİÇ açılmaz (token üretimi kapalı).

**Örnek:**
```bash
curl -s -H "X-Candan-Key: $CANDAN_VOICE_CLIENT_KEY" \
  "http://<host>:8830/candan/token?identity=mac-client"
```

## 2. Bağlantı + akış

1. Token endpoint'ten `{url, room, token}` al.
2. `url` + `token` ile LiveKit odasına bağlan (identity = istediğin client-id).
3. **Yayınla (publish):**
   - **mic audio track** (LiveKit mic source). Plugin track'i 16 kHz mono'ya kendi indirir.
   - **participant attribute'ları** (`set_attributes`):
     - `candan.awake` = `"1"` (uyanık) / `"0"` (uyku — wake-gate söz/transkripti yok sayar)
     - `stt_engine` = `"whisper"` (veya `"nemotron"`)
     - `voice` = TTS sesi (ör. `"nese"`)
     - `language` = `"tr"` / `"en"`
     - `candan.barge_in` = `"1"` (açık) / `"0"` (kapalı)
4. **Tüket (subscribe):**
   - **agent TTS audio track** (identity `assistant`, 48 kHz mono) → çal.
   - **`lk.transcription` text-stream**: her satır bir transkript; attribute `candan.role`
     = `user` | `assistant` (yoksa gönderen kimliğine düş), `lk.transcription_final` = bool.
   - **`candan.speaker`** text-stream (JSON `{name, speakerId, guest}`) — aktif konuşmacı (varsa göster).
   - **`candan.debug`** text-stream — opsiyonel canlı debug satırı (turn/gecikme).
   - **`candan.cue`** text-stream — proaktif bildirim öncesi kısa işaret (ör. `reminder`).

## 3. Audio formatları
- Yayınlanan mic: LiveKit mic source (herhangi sr; plugin 16k mono'ya indirir).
- Tüketilen TTS: 48 kHz mono s16.

## 4. Env (sunucu tarafı, `~/.hermes/.env`)
| Env | Açıklama |
|---|---|
| `CANDAN_VOICE_CLIENT_KEY` | İstemcilerin `X-Candan-Key` ile gönderdiği paylaşılan anahtar (zorunlu; boş=endpoint kapalı) |
| `CANDAN_VOICE_TOKEN_PORT` | Endpoint portu (varsayılan 8830) |
| `CANDAN_VOICE_TOKEN_BIND` | Bind adresi (varsayılan 0.0.0.0) |
| `CANDAN_PUBLIC_LIVEKIT_URL` | İstemciye dönen public LiveKit wss URL (yoksa `LIVEKIT_URL`) |
| `CANDAN_VOICE_CLIENT_TOKEN_TTL` | İstemci token TTL (sn, varsayılan 3600) |

## 5. Yayınlama notu (public erişim)
Endpoint `0.0.0.0:8830`'a bind olur. İnternete açmak için bir reverse-proxy
(Traefik/Caddy) ile TLS'li bir host'a yönlendir (LiveKit'in `wss://mate-livekit.drascom.uk`
gibi). Aksi halde aynı ağdan / SSH tüneli ile erişilir:
`ssh -L 8830:localhost:8830 oracle-stage` → `http://localhost:8830/candan/token`.

## 6. "Başkası kendi Hermes'ine nasıl bağlar"
1. `candan_voice` plugin'i `~/.hermes/plugins/`'e koy, `plugins.enabled`'a ekle.
2. `.env`'e LiveKit + STT/TTS host'ları + `CANDAN_VOICE_CLIENT_KEY` yaz.
3. Gateway'i başlat → ajan odaya bağlanır, token endpoint açılır.
4. İstemci endpoint'ten token alıp yukarıdaki sözleşmeyle bağlanır. Brain'e gerek yok.
