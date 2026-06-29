# mate-sim bağlantı parametreleri — mate_voice (Hermes) HEDEFİ

> A worker (bu) yazdı. Hedef artık **Hermes gateway içindeki `mate_voice`
> platform adapter**'ı (brain LiveKit agent'ı DEĞİL). Adapter ayrı bir test
> odasına bağlanır → brain'in `mate-demo` odasını bozmaz.

## LiveKit
- **URL:** `wss://mate-livekit.drascom.uk` (Traefik → oracle-stage :7880).
  Doğrudan IP alternatifi: `ws://132.145.24.135:7880`.
- **Oda (TEST):** `mate-hermes-test`  ← mate_voice bu odaya `assistant`
  (kind=agent) olarak bağlı. (brain'in `mate-demo`'su AYRI; karıştırma.)
- **Identity:** `sim-client` (agent kimliği `assistant` ile çakışmaz).

## Token — TERCİH: plugin token endpoint
Plugin artık paylaşılan-anahtarlı bir token endpoint sunar (LiveKit secret sunucuda kalır).
Tam sözleşme: `mate_voice/CLIENT_INTEGRATION.md`.

- `GET /mate/token?identity=<id>&room=<ops>` + header `X-Mate-Key: <MATE_VOICE_CLIENT_KEY>`
  → `{url, room, token, identity}`. Health: `GET /mate/health`. Hata: 401/400.
- Endpoint stage'de `oracle-stage:8830` (henüz public değil → SSH tüneli ile eriş):
  ```
  ssh -fN -L 8830:localhost:8830 oracle-stage   # tünel aç
  KEY=$(ssh oracle-stage 'sed -n "s/^MATE_VOICE_CLIENT_KEY=//p" ~/.hermes/.env')
  RESP=$(curl -s -H "X-Mate-Key: $KEY" "http://localhost:8830/mate/token?identity=sim-client")
  export MATE_LK_URL=$(echo "$RESP" | python3 -c 'import sys,json;print(json.load(sys.stdin)["url"])')
  export MATE_LK_TOKEN=$(echo "$RESP" | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
  export MATE_LK_ROOM=mate-hermes-test
  python sim.py --text "Candan, üç kere üç kaç eder?" --wait 35
  ```
  (`--token-url` desteği eklenirse: `python sim.py --token-url http://localhost:8830/mate/token --key $KEY`.)
- **Fallback hazır token:** `tools/mate-sim/token.txt` (gitignored) — identity `sim-client`,
  oda `mate-hermes-test`, 7 gün. sim.py bunu otomatik okur.

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
2. sim `mate.awake=1` + `stt_engine/voice/language` attribute'larını yayınlar,
   sonra prompt.wav'ı 48k mono mic track olarak akıtır.
3. Adapter: STT (whisper @192.168.0.25:10300, dil=tr) → wake-gate geçer (awake=1)
   → `MessageEvent` → **Hermes beyni (Codex/gpt-5.5)** → cevap.
4. Cevap `send()` ile: **vox TTS** (@192.168.0.25:8808) → 48k ses track'i odaya
   publish + `lk.transcription` text-stream (`mate.role`=user/assistant).
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
text-stream topic `lk.transcription`; `mate.role` attribute = user/assistant;
`lk.transcription_final` = bool. (mate-mac alıcısı ile birebir aynı.)
