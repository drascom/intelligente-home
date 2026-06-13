# Prior work: `intent-lab/` and `mate-ios/`

Two earlier attempts imported into the repo 2026-06-12. Both are healthy and
reusable — analysis and conversion plans below.

---

## 1. `intent-lab/` — Turkish intent classifier (sandbox)

### What it is

3-class intent classifier for assistant utterances: **eylem** (command),
**soru** (question), **sohbet** (chitchat). Built for the previous "Mate
Obsidian" project; self-contained, ~350 lines + data.

- **Approach:** `intfloat/multilingual-e5-small` embeddings + nearest-neighbor
  cosine over ~20 examples/class (`classifier.py`, `intents.py`), wrapped by a
  Turkish syntax rule layer (`hybrid.py`): question particle `mı/mi/mu/mü`,
  question words, `?`, sentence-final imperative-verb suppression, chitchat
  idiom overrides ("naber", "değil mi", ...).
- **Eval:** `dataset.json` — 900 synthetic utterances, 3 family personas
  (baba/anne/kiz). **90.0% accuracy** overall; weakest class is sohbet (77.8%).
  Eval harness with persona/intent breakdowns in `tests/eval.py`.
- **Already-ruled-out alternatives** (documented in README — don't re-try):
  yeniguno BERT (63%), Qwen2.5-0.5B (50%), mDeBERTa zero-shot (43%).
- **Deps:** just `sentence-transformers` + `numpy`. Model is ~470MB, CPU is fine.
- **Status: complete and working** as a lab. No infra coupling; only flat
  imports (`from classifier import ...`) need packaging fixes.

### How we'll use it: fast-path pre-router in the brain

Every satellite utterance currently goes through the full vLLM tool loop —
multi-second latency even for "merhaba". Plan:

1. New module `brain/router/intent.py` wrapping `HybridClassifier`; model
   loaded once in app lifespan. Classify the transcript **before**
   `Agent.respond`:
   - high-confidence **sohbet** → single LLM call with no tools (or template
     reply) → big latency/token win on the voice path;
   - **soru / eylem / abstain** → full tool-loop agent (today's behavior);
   - later: high-confidence **eylem** matching a simple device grammar
     ("salonun ışığını aç") → direct HA `call_service`, no LLM at all —
     instant lights.
2. Log every classification + final route to SQLite so margins
   (`REJECT_BELOW=0.03`, weak-signal 0.05) can be tuned on *real* voice logs —
   the synthetic dataset stays as the regression eval.
3. Taxonomy growth (timer/reminder, media, follow-up...) = add 10–20 Turkish
   examples per class in `intents.py`; no retraining needed.

**Keep verbatim:** `dataset.json` (gold eval set), the Turkish regexes and
imperative-verb list in `hybrid.py` (also useful as end-of-utterance hints for
voice endpointing), `tests/eval.py`.

**Port cost:** small — package imports, lifespan loading, config. Half a day.

---

## 2. `mate-ios/` — native iOS voice client

### What it is

SwiftUI iOS app (~3,000 LoC, 13 files) implementing a complete on-device
voice pipeline. Status: **voice pipeline works; the LLM was never wired in** —
that's exactly the half the brain now provides.

- **Pipeline:** SFSpeech wake word (`WakeWordDetector.swift`) → adaptive VAD
  with noise-floor calibration (`AudioRecorder.swift`) → **on-device STT**
  (WhisperKit, Apple fallback; `OnDeviceSpeech.swift`) → text to server →
  streamed TTS audio back with **barge-in** (echo baseline + hysteresis,
  `AudioPlayer.swift` / `AudioPipeline.swift`).
- **Protocol** ("Realtime Bridge Protocol v0", `RealtimeBridgeClient.swift`):
  WebSocket, auth via `?token=` query param (same scheme as brain's `/api/ws`).
  - client → server (JSON): `{type:"speak", id, text, voice?}`,
    `{type:"cancel", id}`, `{type:"ping"}`
  - server → client: `{type:"audio_start", id, sample_rate, channels}` →
    raw **pcm_f32le** binary frames → `{type:"audio_end", id}`; plus
    `error`/`pong`. Keepalive ping every 10s, auto-reconnect, reachability
    callback for the UI banner.
- **Known gaps:** assistant reply text never shown in chat feed (TODOs at
  `ConversationManager.swift:868,911` — "when LLM is added"); push
  notifications stubbed; LiveSTT disabled (VPIO conflict).
- **Coupling:** only a default URL (`wss://mate.drascom.uk/ws`), user-editable
  in Settings. Nothing else to untangle.

### How we'll use it

**Fastest path to a phone client:** make the brain speak Bridge v0. Add
`/api/voice` WebSocket to the brain that:

1. accepts the existing `speak` message but treats `text` as the **user
   utterance** → intent fast-path / agent → reply;
2. sends the reply **text** back as a new JSON message (`{type:"reply", id,
   text}` — fills their chat-feed TODO), then
3. streams Piper TTS as `audio_start` + binary + `audio_end` (Piper emits
   int16 PCM; convert to float32 server-side), honouring `cancel` for
   barge-in.

With that, mate-ios becomes a working brain client with a URL change and one
small client patch (handle `reply`). Day-one phone voice without waiting for
Flutter.

**Architecture insight to adopt:** mate-ios sends *text* up (on-device STT),
while SYSTEM_PLAN's app section assumed *audio* up (server Whisper). Support
**both modes on the same WS** — text-up (low bandwidth, snappy, keeps GPU
free) and audio-up (better quality, cheap phones, satellites already do it).

**Flutter decision (when `mobile/` starts):** mate-ios is native Swift — no
direct port. Use it as (A) the production iOS client for now, and (B) the
**reference spec** for the Flutter app: VAD calibration algorithm, barge-in
echo-baseline logic, Whisper hallucination filtering, reconnect/reachability
UX. Worst case it remains the iOS app and Flutter only ever targets Android.

---

## Suggested sequencing

1. **Brain: Bridge v0 endpoint** (`/api/voice`) — unlocks mate-ios as a client. Small.
2. **Brain: intent fast-path** (`brain/router/intent.py`) — voice latency win. Small.
3. mate-ios: point at brain, add `reply` handling + chat feed lines (their TODO).
4. Later: direct-command grammar for instant device control; Flutter app using
   mate-ios as spec.
