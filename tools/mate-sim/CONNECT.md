# mate-sim bağlantı parametreleri — candan_voice (Hermes) HEDEFİ

> A worker (bu) yazdı. Hedef artık **Hermes gateway içindeki `candan_voice`
> platform adapter**'ı (brain LiveKit agent'ı DEĞİL). Adapter ayrı bir test
> odasına bağlanır → brain'in `mate-demo` odasını bozmaz.

## LiveKit
- **URL:** `wss://mate-livekit.drascom.uk` (Traefik → oracle-stage :7880).
  Doğrudan IP alternatifi: `ws://132.145.24.135:7880`.
- **Oda (TEST):** `mate-hermes-test`  ← candan_voice bu odaya `assistant`
  (kind=agent) olarak bağlı. (brain'in `mate-demo`'su AYRI; karıştırma.)
- **Identity:** `sim-client` (agent kimliği `assistant` ile çakışmaz).

## Token
- **Hazır token:** `tools/mate-sim/token.txt` (gitignored) — identity `sim-client`,
  oda `mate-hermes-test`, publish+subscribe+canUpdateOwnMetadata, **7 gün** geçerli.
  sim.py bunu otomatik okur. (Süresi dolarsa aşağıdan yeniden mint et.)
- **Taze mint (stage'de, secret'ı brain.env/.env'den okur):**
  ```
  ssh oracle-stage 'cd /home/ubuntu/.hermes/hermes-agent && venv/bin/python - <<PY
  import os; from datetime import timedelta; from livekit import api
  from gateway.run import load_hermes_dotenv; from pathlib import Path
  load_hermes_dotenv(hermes_home=Path("/home/ubuntu/.hermes"))
  at=(api.AccessToken(os.getenv("LIVEKIT_API_KEY"),os.getenv("LIVEKIT_API_SECRET"))
      .with_identity("sim-client").with_ttl(timedelta(days=7))
      .with_grants(api.VideoGrants(room_join=True,room="mate-hermes-test",
       can_publish=True,can_subscribe=True,can_update_own_metadata=True)))
  print(at.to_jwt())
  PY' > tools/mate-sim/token.txt
  ```

## Sim'e geçirme
```
export MATE_LK_URL=wss://mate-livekit.drascom.uk
export MATE_LK_ROOM=mate-hermes-test          # ← DEĞİŞTİ (mate-demo değil)
export MATE_LK_IDENTITY=sim-client
# token.txt varsa MATE_LK_TOKEN gerekmez
python sim.py --text "Candan, bugün hava nasıl?" --wait 30
```

## Davranış (beklenen)
1. sim bağlanır → odada `assistant` (agent) görünür. Görünmüyorsa adapter bağlı
   değil → A worker'a / gateway loglarına bak (`journalctl -u hermes-gateway`).
2. sim `candan.awake=1` + `stt_engine/voice/language` attribute'larını yayınlar,
   sonra prompt.wav'ı 48k mono mic track olarak akıtır.
3. Adapter: STT (whisper @192.168.0.25:10300, dil=tr) → wake-gate geçer (awake=1)
   → `MessageEvent` → **Hermes beyni (Codex/gpt-5.5)** → cevap.
4. Cevap `send()` ile: **vox TTS** (@192.168.0.25:8808) → 48k ses track'i odaya
   publish + `lk.transcription` text-stream (`candan.role`=user/assistant).
5. sim: assistant ses track'ini `reply.wav`'a yazar + transkriptleri loglar.
   PASS = connected+published (+ tam tur: transcript+tts).

## Mevcut deploy notları (A worker, 2026-06-27)
- **TURN_DETECTOR_ENABLED=false, SPEAKER_ID_ENABLED=false** (ilk bağlantı sade
  tutuldu; numpy/onnx/sherpa Hermes venv'ine henüz kurulmadı). Endpointing =
  saf-sessizlik (1.0s). Konuşmacı tanıma yok → herkes guest (oda-kapsamı session).
  Bunları açmak için: Hermes venv'ine `numpy onnxruntime transformers
  huggingface_hub sherpa_onnx` kur + env'de `true` yap + gateway restart.
- Wake kelimesi ("candan") gating'i AKTİF değil çünkü 0→1 awake geçişi yok
  (sim hep awake=1). İlk komut işlenir — istenen test davranışı.

## Transkript protokolü
text-stream topic `lk.transcription`; `candan.role` attribute = user/assistant;
`lk.transcription_final` = bool. (mate-mac alıcısı ile birebir aynı.)
