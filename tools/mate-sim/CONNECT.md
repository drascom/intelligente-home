# mate-sim bağlantı parametreleri

> Bu dosyayı normalde A worker'ı yazar; yoksa mate-mac ayarlarından çıkarıldı.

## LiveKit
- **URL:** `wss://mate-livekit.drascom.uk` (Traefik → oracle-stage :7880).
  Doğrudan IP alternatifi: `ws://132.145.24.135:7880`.
- **Oda (TEST):** `mate-demo` (mate-mac ile aynı oda; brain agent buraya katılır).
- **Identity:** `sim-client` (mac-client ile çakışmasın diye farklı).

## Token nasıl alınır
Token devkey-imzalı; **publish + canUpdateOwnMetadata** şart (attribute yayını için).
Üç yol (biri yeterli):

1. **Mevcut token (en hızlı):** `mate-mac/VoiceAgent/Secrets.swift` içindeki
   `livekitToken` (gitignored, repoda DEĞİL). Identity `mac-client`, oda `mate-demo`,
   ~30 gün geçerli, publish+metadata var. Sim'e `MATE_LK_TOKEN` ile ver.

2. **Taze mint (stage'de):**
   ```
   ssh oracle-stage 'lk token create \
     --api-key devkey --api-secret <LIVEKIT_API_SECRET /etc/livekit/livekit.yaml> \
     --join --room mate-demo --identity sim-client \
     --allow-update-metadata --valid-for 24h'
   ```

3. **Brain endpoint:** `POST {brainURL}/api/livekit-token` + `Authorization: Bearer
   <device/brain token>` → JSON `participantToken`. (mate-mac MateTokenSource.swift.)

## Sim'e geçirme
```
export MATE_LK_URL=wss://mate-livekit.drascom.uk
export MATE_LK_ROOM=mate-demo
export MATE_LK_IDENTITY=sim-client
export MATE_LK_TOKEN='<token>'        # veya tools/mate-sim/token.txt (gitignored)
```

## Brain attribute'ları (zorunlu — sunucu wake-gate)
`candan.awake=1` OLMAZSA brain sesi/transkripti yok sayar. Sim bunları otomatik set eder:
`candan.awake=1, stt_engine=whisper, voice=nese, language=tr, candan.barge_in=1`.

## Transkript protokolü
text-stream topic `lk.transcription`; `candan.role` attribute = user/assistant
(yoksa gönderen kimliğine düşer). `lk.transcription_final` = bool.
