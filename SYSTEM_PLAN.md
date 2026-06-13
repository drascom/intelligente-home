# Home AI Server — Full System Plan

Device-by-device specification: technologies, software stacks, and communication paths.
Core principle: **The brain is the center of the system — a standalone service that owns
identity, memory, conversation, voice, and notifications. Home Assistant is one connector:
the smart-home tool, source of truth for *device state* only. House reflexes (dumb, fast
automations) stay in HA so the home works even when the brain is down; everything needing
language, memory, or judgment lives in the brain. Voice satellites connect to the brain
directly (Wyoming), so voice keeps working even when HA is down.**

---

## 1. Device Inventory

### 1.1 Linux GPU Server — "the brain box"

The only stateful machine in the system. Everything intelligent runs here.

| Component | Tech | Port | Notes |
|---|---|---|---|
| OS | Ubuntu Server 24.04 LTS | — | headless, SSH only |
| GPU runtime | NVIDIA driver + CUDA 12.x | — | shared by vLLM + Whisper |
| Container runtime | Docker + Compose (systemd-managed) | — | every service below is a container or systemd unit |
| LLM engine | vLLM (OpenAI-compatible) | 8000 | resident model; `--tool-call-parser` per model family |
| Lab engine | llama.cpp (`llama-server`) | 8081 | stopped by default; GGUF experiments only |
| STT | wyoming-faster-whisper (GPU) | 10300 | Wyoming protocol |
| TTS (primary) | **vox** — VoxCPM2 2B (GPU), 48kHz, cloned voices (`vox/`) | 8808 | OpenAI-style HTTP + Bridge v0 WS; brain's TTS for satellites + apps |
| TTS (fallback) | wyoming-piper | 10200 | CPU; Wyoming — used by HA's Assist pipeline (Voice PE path) |
| Wake word (server-side) | wyoming-openwakeword | 10400 | only for satellites without local wake word |
| MQTT broker | Mosquitto 2.x | 1883 | per-device credentials; HA discovery enabled |
| Home automation | Home Assistant (container) | 8123 | co-located here; owns Assist pipeline + device registry |
| **Brain service** | Python 3.12 · FastAPI + uvicorn · websockets · paho-mqtt · SQLite (registry + memory) · Pi Agent runtime for sub-agents | 8800 | exposes `/v1/chat/completions` (for HA) + REST/WebSocket client API (for apps) |
| Push gateway | firebase-admin (FCM) inside brain `notify/` | → HTTPS out | one FCM project covers Android + iOS/APNs |
| Fleet management | Ansible (runs on server, SSH out to Pi nodes) | 22 → nodes | provisioning + OS/software updates |
| Remote access | Tailscale, advertised as **subnet router** for the LAN | — | phones/Mac reach HA, brain, satellites through one tailnet node |

### 1.2 MacBook M4 — thin client

| Component | Tech |
|---|---|
| Voice/control | HA web UI + Assist in browser; brain web client later |
| Dev workstation | repo checkout, Flutter tooling, Ansible authoring |
| Migration note | current local llama.cpp "gemma server" + taskbar app retire once the Linux box is live |

### 1.3 Phones — iOS + Android (custom app)

| Component | Tech |
|---|---|
| App | Flutter 3.x (single codebase) |
| Voice | push-to-talk: mic capture → stream to brain over WebSocket → server-side Whisper; reply audio from Piper |
| Chat/UI | brain REST + WebSocket API (port 8800) |
| Push | Firebase Cloud Messaging (FCM → APNs for iOS) |
| Presence | HA Companion app installed alongside (free presence + day-one voice while Flutter app matures) |
| Connectivity | Tailscale app; same brain address on LAN and away |

### 1.4 Voice satellites — Raspberry Pi Zero 2 W (default per room)

> Must be **Zero 2 W**. Original Zero W (ARMv6 single-core) cannot run voice workloads.
> Primary satellite type: speaks Wyoming to the **brain directly** — no HA dependency,
> so voice survives HA restarts/outages.

| Component | Tech |
|---|---|
| OS | Raspberry Pi OS Lite 64-bit (Bookworm) |
| Satellite | wyoming-satellite (systemd service) |
| Wake word | wyoming-openwakeword running locally on the Zero 2 W |
| Mic | ReSpeaker 2-Mic HAT |
| Speaker | 3.5mm/I2S out → any amp/speaker |
| Connection | Wyoming protocol; **brain** connects to the satellite on TCP 10700 (`brain/voice/`) |
| Audio path | wake (local) → stream to brain → Whisper → agent → Piper → back to its own speaker |
| Provisioning/updates | common base image + Ansible profile `voice-satellite` |

### 1.5 Voice satellites — Home Assistant Voice PE (optional; HA-bound)

Stock Voice PE firmware is ESPHome-locked to HA, so these route through HA's Assist
pipeline (HA still reaches the brain via `/v1/chat/completions`). Use only where the
ready-made puck form factor wins; accept that they go quiet if HA is down.

| Component | Tech |
|---|---|
| Firmware | stock ESPHome firmware |
| Wake word | microWakeWord, on-device |
| Connection | ESPHome native API → HA (TCP 6053), appears as `assist_satellite` entity |
| Audio path | wake → stream to HA → Whisper (server) → brain → Piper (server) → back to its own speaker |
| Updates | OTA via HA's ESPHome integration |

### 1.6 Sensor/actor nodes — Raspberry Pi Zero (any revision)

For nodes needing a camera, USB, or real compute. (Battery or single-sensor spots: prefer ESP32, §1.7.)

| Component | Tech |
|---|---|
| OS | Raspberry Pi OS Lite (Bookworm) |
| Node agent | Python 3.11 service: paho-mqtt, publishes **MQTT with HA auto-discovery** — entities appear in HA with zero config |
| Telemetry | state topics `home/<node>/<sensor>` + availability (LWT) `nodes/<node>/status` |
| Commands | subscribes `nodes/<node>/cmd` (relay toggles, config reload, restart, update trigger) |
| Camera (optional) | MediaMTX → RTSP into HA (Frigate on the server later if detection is wanted) |
| Provisioning/updates | same base image + Ansible profile `sensor-node` |

### 1.7 ESP32 micro-nodes

| Component | Tech |
|---|---|
| Firmware | ESPHome (YAML-defined) |
| Connection | ESPHome native API → HA, or MQTT for battery deep-sleep nodes |
| Updates | ESPHome OTA from HA |

### 1.8 Existing smart devices (lights, plugs, TV, …)

Integrated through standard HA integrations (Zigbee/Z-Wave/WiFi/cloud). Automatically visible
to the brain via the HA mirror — no extra work per device.

---

## 2. Communication Map

```
                            ┌────────────────── LINUX GPU SERVER ──────────────────┐
                            │                                                      │
 Pi Zero sat ◄─Wyoming:10700─── BRAIN:8800 ──Wyoming──► Whisper:10300              │
                            │      │  ▲  │                Piper:10200              │
 Voice PE ──ESPHome:6053──► │  Home Assistant:8123 ─┐     openWakeWord:10400       │
                            │      ▲   WS (mirror + │ /v1/chat (Voice PE           │
 ESP32 ───ESPHome/MQTT────► │      │   call_service)│  path only)                  │
 Pi sensor ──MQTT:1883────► │  Mosquitto:1883 ◄──MQTT──► BRAIN ──HTTP──► vLLM:8000 │
                            │      ▲                                               │
                            │      └── HA MQTT discovery                           │
                            └──────────────────────────────┬───────────────────────┘
                                                           │
 Flutter app ◄──REST/WS over Tailscale────────────────────►│
 Flutter app ◄──push── FCM/APNs ◄──HTTPS── brain notify ───┘
 HA Companion (presence) ──► HA:8123
```

| From | To | Protocol / Port | Purpose |
|---|---|---|---|
| Brain | Pi Zero satellite | Wyoming, TCP 10700 | wake events + audio in/out (HA not in path) |
| Brain | Whisper | Wyoming, 10300 | STT for satellites + app PTT |
| Brain | vox (VoxCPM2) | Bridge v0 WS, 8808 | primary TTS for satellites + apps (TTS_ENGINE=vox; piper fallback) |
| Voice PE | HA | ESPHome native API, 6053 | audio in/out, entity state (optional, HA-bound) |
| HA | Whisper / Piper / oWW | Wyoming, 10300/10200/10400 | STT / TTS / wake for Voice PE path only |
| HA | Brain | HTTP, 8800 `/v1/chat/completions` | conversation agent step (Voice PE / Companion path) |
| Brain | HA | WebSocket API, 8123 (long-lived token) | live state mirror + `call_service` device control |
| Brain | vLLM | HTTP, 8000 (OpenAI API) | all LLM inference (brain + sub-agents) |
| Pi/ESP32 nodes | Mosquitto | MQTT, 1883 (per-device creds, LWT) | telemetry, availability, discovery |
| Brain | Mosquitto | MQTT, 1883 | node health watch + `nodes/<id>/cmd` management |
| Flutter app | Brain | REST + WebSocket, 8800, via Tailscale | chat, PTT audio, tasks, history |
| Brain | FCM → APNs | HTTPS out | push notifications to closed apps |
| Brain (Ansible) | Pi nodes | SSH, 22 | provisioning, OS/software updates |
| HA | ESP32 / Voice PE | ESPHome OTA | firmware updates |
| Phones / Mac | LAN services | Tailscale (server = subnet router) | identical access on LAN and away |

---

## 3. Brain Device Awareness & Control (the core requirement)

The brain maintains a **live device registry** and can act on every device. Three layers
(plus the voice plane, which is brain-native and described in §1.4 — HA appears below only
as the device connector; if it's down, chat and voice still run, only device tools degrade):

**Layer 1 — HA mirror (state plane).**
On startup the brain pulls HA's device, entity, and area registries over the HA WebSocket API,
then holds a `subscribe_events: state_changed` subscription. Result: an always-current in-memory
model (persisted to SQLite) of every device, its room, capabilities, and state — smart devices,
satellites, ESP32s, and Pi nodes alike, since they all surface in HA.
**Control:** brain issues `call_service` over the same socket (lights, climate, media,
`assist_satellite.announce` for spoken announcements in a chosen room).

**Layer 2 — MQTT management plane (node ops).**
The brain also subscribes directly to `nodes/+/status` (heartbeats, version, health via LWT) and
publishes to `nodes/<id>/cmd` for operations HA doesn't model: config push, service restart,
update trigger, log request. This is how the brain *manages* its own fleet rather than just
*using* it.

**Layer 3 — client registry (apps).**
Phones and the Mac authenticate to the brain API with per-device tokens; the brain tracks FCM
token, last-seen, and active WebSocket per client. Combined with HA presence, this lets the brain
route any outbound message to the right surface: room speaker if you're home, phone push if not.

**OS-level updates:** for changes beyond runtime commands (package upgrades, new node profiles),
the brain shells out to Ansible playbooks in `node-image/` targeting the node inventory. ESP32 and
Voice PE firmware updates go through HA's ESPHome OTA, which the brain can trigger via service call.

---

## 4. Security

- **Tailscale** is the only remote path; no ports exposed to the internet. Server advertises LAN routes (subnet router) so satellites/HA are reachable from phones without per-device installs.
- **Brain API:** per-client bearer tokens, issued once per device, revocable in the registry.
- **HA ↔ brain:** long-lived access token, scoped to one HA user (`brain`).
- **MQTT:** per-device username/password, ACL limiting each node to its own topic tree.
- **SSH/Ansible:** key-only auth from the server to nodes.

---

## 5. Rollout Phases

1. **Server foundation** — Ubuntu, drivers, Docker, Tailscale; vLLM + Whisper + Piper + Mosquitto + HA up; migrate llama.cpp/gemma duties off the Mac.
2. **Brain v1** — HA mirror + `call_service`, OpenAI-compatible endpoint wired in as HA's conversation agent, **Wyoming voice plane** (`brain/voice/`: satellite controller + direct Whisper/Piper clients). Voice works via HA Companion app immediately.
3. **First satellite** — one Pi Zero 2 W running wyoming-satellite, connected **directly to the brain**; proves the full wake→STT→agent→TTS loop with HA out of the path (test: stop the HA container, voice keeps answering).
4. **Flutter app v1** — auth, chat, PTT over WebSocket, FCM push.
5. **Node fleet** — base image + Ansible profiles; first sensor node and ESP32; brain MQTT management plane.
6. **Sub-agent buildout** — mail/bill summarizer, task organizer, presence-aware notify routing.

### Prior work to fold in (see `docs/PRIOR_WORK.md`)

- `intent-lab/` — working Turkish 3-class intent classifier (E5 embeddings + syntax
  rules, 90% on a 900-utterance eval set) → becomes the brain's **fast-path pre-router**
  (skip the tool-loop for chitchat; eventually direct device commands with no LLM).
- `mate-ios/` — working native iOS voice client (wake word, VAD, on-device Whisper STT,
  WebSocket TTS streaming with barge-in); its LLM half was never built — the brain is
  that half. Brain grows a Bridge-v0-compatible `/api/voice` WS endpoint and mate-ios
  becomes the day-one phone client; it also serves as the reference spec for the
  Flutter app.
