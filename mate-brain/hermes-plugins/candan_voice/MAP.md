# MAP: `livekit_agent.py` → `CandanVoiceAdapter`

Mapping the standalone `mate-brain/brain/voice/livekit_agent.py::LiveKitAgent`
onto the Hermes `BasePlatformAdapter` contract. **STATUS: IMPLEMENTED** — the
adapter is real (not a scaffold). Voice modules are vendored under `voice/`
(env-config shim, no `brain.*` deps). Deployed + connects to LiveKit on stage
(room `mate-hermes-test`); see `deploy/HERMES_STAGE.md`. Phase-2 items below.

## Core architecture shift

Standalone `LiveKitAgent._process_turn` does **respond + transcript + TTS in one
method**. Hermes splits inbound from outbound:

- `BasePlatformAdapter.handle_message(event) -> None` spawns a background task,
  calls the registered `_message_handler` (= Hermes brain), then calls
  `self.send(chat_id, reply)`.
- So the **brain reply comes back out-of-band**: inbound builds the event,
  `send()` does TTS. The LLM/session/memory tail of `_process_turn` is **deleted**
  (Hermes owns it).

## Method mapping

| `livekit_agent.py`                                   | Adapter method                | Notes |
|------------------------------------------------------|-------------------------------|-------|
| `run()` (reconnect-forever loop)                     | — (dropped)                   | Hermes calls `connect(is_reconnect=True)` on drop; no self-loop. |
| `_mint_token()`                                      | inside `connect()`            | server JWT, identity `assistant`, kind=agent. |
| `_session()` (room connect + publish + handlers)     | `connect()`                   | rtc.Room, publish AudioSource→`_source`/`_pub_track_sid`, register room events. |
| `_session` finally / `run()` cleanup                 | `disconnect()`                | cancel consume/poll/tts tasks, abort STT, `room.disconnect()`. |
| `_consume_loop()` / `_consume_track()`               | task started in `connect()`   | RMS endpointing + smart-turn EOU + barge-in; per-utterance WhisperSession. |
| `_is_silence()`, `_identify()`                       | helpers (port as-is)          | speaker-ID embed/identify. |
| `_handle_utterance()`                                | `_on_utterance_final()` (stub)| wake-gate + hallucination filter + enrollment; ends in `handle_message()`. |
| `_process_turn()` — scope/session part               | `build_source()` in `_on_utterance_final` | speaker-ID → `user_id` → session scope. |
| `_process_turn()` — `agent.respond` / db / segmenter | — (deleted)                   | Hermes brain + Hermes memory replace it. |
| `_process_turn()` — TTS + transcript tail            | `send()`                      | runs out-of-band when brain reply returns. |
| `_speak()` + `_capture_s16le()` + `_to_mono()`       | `send()`                      | `synthesize_stream`→`to_s16le`→48kHz frames; `_tts_task` for barge-in. |
| `_publish_transcripts()` / `_publish_text()`         | inside `send()`               | `lk.transcription` topic; mate-mac receiver unchanged. |
| `_publish_speaker()`                                 | inside `_on_utterance_final`  | `candan.speaker` topic (active-user UI). |
| `_set_agent_state()` / `_debug()` / `_send_cue()`    | helpers (port as-is)          | `lk.agent.state` + debug/cue topics. |
| `_attrs()` / `participant_attributes_changed`        | `connect()` event + `_attr_cache` | per-client stt_engine/voice/language + `candan.awake`/`barge_in`. |
| `_begin_enrollment()` / `_complete_enrollment()` / `_parse_name()` | port into inbound path | recognize-first auto-enroll. |
| `_poll_deliveries()` / `_deliver_due()`              | `_poll_task` in `connect()`   | proactive reminders → could move to Hermes cron + `standalone_sender_fn`. |
| `conversation_id`                                    | `get_chat_info()` / room scope| `livekit-{room}` ≈ guest scope. |

## Contract signatures (verified against Hermes `gateway/platforms/base.py`)

- `async connect(self, *, is_reconnect: bool = False) -> bool`
- `async disconnect(self) -> None`
- `async send(self, chat_id, content, reply_to=None, metadata=None) -> SendResult`
- `async send_typing(self, chat_id, metadata=None) -> None`
- `async send_image(self, chat_id, image_url, caption=None, reply_to=None, metadata=None) -> SendResult`
- `async get_chat_info(self, chat_id) -> Dict[str, Any]`
- `self.build_source(chat_id, chat_name, chat_type, user_id, user_name, thread_id, ...) -> SessionSource`
- `await self.handle_message(MessageEvent(text=, message_type=, source=))` — returns None; reply arrives via `send()`.
- `register(ctx)` → `ctx.register_platform(name=, label=, adapter_factory=, check_fn=, validate_config=, is_connected=, required_env=, env_enablement_fn=, cron_deliver_env_var=, platform_hint=, ...)`
- `Platform("candan_voice")` works without core enum edits (dynamic `_missing_` pseudo-member).

## Open questions / decisions

1. **Streaming TTS vs single string.** `send()` receives the *full* brain reply
   (handle_message resolves to one text). Sentence-by-sentence TTS (lower
   latency) needs either our own sentence segmentation inside `send()`, or
   Hermes' streaming-reply consumer hook. Decide before porting `_speak`.
2. **Speaker-ID → session-key scope.** speaker-ID maps to `source.user_id` →
   Hermes `build_session_key`. Confirm Hermes per-user memory keys on `user_id`
   the way we want (recognized → persistent user model; guest → anonymous /
   room scope). Enrollment ("what's your name?") may map to Hermes'
   `send_clarify` interactive hook instead of our hand-rolled 2-turn flow.
3. **Barge-in to the brain (`interrupt_session_activity`).** Today barge-in only
   cancels the in-flight TTS (`_tts_task.cancel()` + `clear_queue()`). Hermes
   exposes `interrupt_session_activity` (see LINE adapter) to also cancel the
   brain's in-flight generation when the user starts speaking. Optional upgrade.
4. **Proactive deliveries.** Keep `_poll_deliveries` inside the adapter (Phase 1)
   or move to Hermes cron + `standalone_sender_fn` + `cron_deliver_env_var`
   (already wired in `register()`). Phase decision.
5. **STT/TTS deps location.** whisper + vox + livekit Python deps must be in the
   Hermes gateway environment (they run inside the adapter, not as services).
