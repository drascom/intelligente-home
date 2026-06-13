# Brain v1

The brain service from `SYSTEM_PLAN.md` — Phase 2 scope:

- **HA mirror** (`ha/mirror.py`): live device registry over the HA WebSocket API,
  `state_changed` subscription, `call_service` control.
- **Conversation agent** (`router/agent.py`): tool-loop against vLLM with
  `list_entities` / `get_state` / `call_service` tools.
- **OpenAI-compatible endpoint** (`api/openai_compat.py`): `/v1/chat/completions`
  for HA's Assist pipeline (configure HA's OpenAI conversation integration with
  base URL `http://<server>:8800/v1` and the admin token as API key).
- **Client API** (`api/client_api.py`): REST + WebSocket for the Flutter app —
  chat, device list/state, per-device tokens, FCM token registration.
- **Registry + memory** (`db.py`): SQLite — clients and conversation history.
- **Voice plane** (`voice/`): the brain speaks Wyoming itself — it connects directly
  to each `wyoming-satellite` (Pi Zero 2 W, `SATELLITES` env) and to Whisper,
  and drives the whole wake→STT→agent→TTS loop. **HA is not in the voice path** —
  if HA is down, voice still works (the agent just loses device control and says so).
  Test the loop without hardware: `python -m brain.tests.test_voice_loop`.
- **TTS engines** (`voice/tts.py`): `TTS_ENGINE=vox` (default) streams from the
  VoxCPM2 server in `vox/` (Bridge v0 WS, f32le 48k, cloned voices via
  `vox/voices/*.wav`); `TTS_ENGINE=piper` uses Wyoming piper (s16le). Width
  conversion per consumer is automatic (satellites get s16, Bridge clients f32).
  Dev: start vox with `cd vox && .venv/bin/python server.py` (port 8808, MPS).

- **MQTT node management plane** (`nodes/manager.py`, SYSTEM_PLAN Layer 2):
  watches `nodes/+/status` (retained JSON + LWT) and `nodes/+/telemetry`,
  persists the fleet in the `nodes` table, publishes commands to
  `nodes/<id>/cmd`. Disabled when `MQTT_HOST` is empty. Dev broker: the
  standalone zigbee2mqtt box (192.168.0.90, user `brain`). API: `GET
  /api/nodes`, `POST /api/nodes/{id}/cmd` (admin). Node side: see
  `node-image/` (bootstrap.sh + Ansible + node-agent.py).
- **Announce flow** (`POST /api/announce`, admin): one call fans out to every
  connected satellite (spoken via TTS), every connected `/api/ws` client
  (`{"type":"announce"}` JSON) and registered phones via FCM push.
- **FCM push** (`notify/fcm.py`): HTTP v1 with a service-account file
  (`FCM_CREDENTIALS_PATH`); without credentials it runs dry (logs only).

Later phases (stubs ready): `agents/` sub-agents.

## Dev mode: this Mac as dev server (pi + Codex subscription)

`LLM_BACKEND=pi` in `.env` (already set) delegates agent turns to the
**project-local** pi (`node_modules/.bin/pi`, pinned 0.78.1 — not the global
one; only OAuth in `~/.pi/agent/auth.json` is shared) running
`openai-codex/gpt-5.5`. Pi gets the same HA tools via the extension
`brain/pi/ha-tools.ts`, which calls back into this brain's REST API. On the
real Linux server, `LLM_BACKEND=vllm` switches to the native tool loop; pi is
dev-only.

- run the server: `.venv/bin/python -m brain.main`
- chat with the house in a terminal: `./pi-brain` (interactive TUI,
  project-scoped sessions in `.pi/`)
- GUI test client: `mate-mac/` (SwiftUI, Bridge v0) — `cd mate-mac &&
  xcodegen && xcodebuild -scheme BrainClient build`

## Run locally

```bash
cd "candan assistant"
python3 -m venv .venv && .venv/bin/pip install -r brain/requirements.txt
cp deploy/.env.example .env   # fill in HA_TOKEN, BRAIN_ADMIN_TOKEN, LLM_*
.venv/bin/python -m brain.main
```

## Quick checks

```bash
curl -s localhost:8800/api/health -H "Authorization: Bearer $BRAIN_ADMIN_TOKEN"
curl -s localhost:8800/api/devices?domain=light -H "Authorization: Bearer $BRAIN_ADMIN_TOKEN"
curl -s localhost:8800/v1/chat/completions -H "Authorization: Bearer $BRAIN_ADMIN_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"Which lights are on?"}]}'
```

Issue a phone token: `POST /api/clients {"name": "ismet-iphone"}` with the admin token.
