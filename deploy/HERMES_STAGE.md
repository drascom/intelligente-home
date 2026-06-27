# Hermes Agent — oracle-stage kurulumu

Hermes Agent (NousResearch) `oracle-stage` (132.145.24.135) üstüne, mevcut
brain(:8800) + LiveKit(:7880) servislerine **DOKUNMADAN** yeni servis olarak kuruldu.
Sonraki adımda buraya kendi ses eklentimiz (`candan_voice` Hermes platform adapter
plugin) bağlanacak; gateway o yüzden ayakta tutuluyor.

## Erişim
- SSH: `ssh oracle-stage` (alias, `~/.ssh/config` → user `ubuntu`, key `…/oracle/stage/stage.key`).
- Host: aarch64 (ARM), Ubuntu, Python 3.12 sistem / 3.11 hermes venv. **Docker yok** → venv + systemd.
- Kullanıcı: `ubuntu` (sudo passwordless).

## Kurulum
- Sürüm: **Hermes Agent v0.17.0**. Resmi installer (`install.sh --non-interactive --skip-setup`), uv tabanlı.
- Kod: `/home/ubuntu/.hermes/hermes-agent`  ·  CLI: `/home/ubuntu/.local/bin/hermes`
- Config (non-secret): `/home/ubuntu/.hermes/config.yaml`
- **Secrets**: `/home/ubuntu/.hermes/.env`  ·  OAuth: `/home/ubuntu/.hermes/auth.json`
  → Key/token DEĞERLERİ burada; repoya/log'a YAZILMAZ.

## LLM backend
- Provider: **`openai-codex`** (ChatGPT/Codex **OAuth** — kullanıcı interaktif login etti).
- Model: `gpt-5.5`  ·  base_url: `https://chatgpt.com/backend-api/codex`
- Raw OpenAI API key YOK; kimlik OAuth (`auth.json`). `pi`'nin `/root/.pi/agent/auth.json`'undan AYRI.
- Round-trip doğrulandı: `hermes chat -Q -q "…"` → Codex gerçek cevap döndü.

## Servisler
- **Gateway** (mesajlaşma/eklenti host'u): systemd **system** servisi
  `hermes-gateway.service` → `enabled` (boot'ta gelir), `active running`, `run-as-user=ubuntu`.
  - Durum: `sudo hermes gateway status --system` / `systemctl status hermes-gateway`
  - Log: `journalctl -u hermes-gateway -f`
  - Şu an "no messaging platforms enabled" (beklenen — `candan_voice` plugin sonra bağlanacak).
- **Proxy** (OpenAI-uyumlu `/v1` HTTP server) — `hermes proxy start [--port 8810]`.
  - Boş port **8810** ayrıldı (kullanılan: 22/53/111/7880/7881/8800 ile çakışmaz).
  - ⚠ **KISIT:** `hermes proxy` upstream'i yalnız **`nous`** veya **`xai`** OAuth destekler;
    **`openai-codex` desteklenmez.** Codex backend'iyle proxy /v1 endpoint'i sunamaz →
    bu yüzden proxy BAŞLATILMADI (yarım/bozuk servis bırakmamak için).
  - Harici OpenAI-uyumlu endpoint gerekirse: ayrıca Nous Portal **veya** xAI OAuth login
    (`hermes proxy providers`), sonra `hermes proxy start --provider nous --host 0.0.0.0 --port 8810`.

## Port haritası (stage)
| Port | Servis |
|------|--------|
| 7880/7881 | LiveKit (mevcut, dokunulmadı) |
| 8800 | brain (mevcut, dokunulmadı) |
| 8810 | Hermes proxy için AYRILDI (Codex kısıtı nedeniyle henüz başlatılmadı) |
| —    | Hermes gateway: ağ portu açmaz (mesajlaşma/eklenti dispatcher) |

## Doğrulama özeti
- ✅ LLM round-trip (Codex via Hermes) OK.
- ✅ Gateway `active running` + boot-enabled.
- ✅ **KARAR (b):** harici OpenAI-uyumlu `/v1` proxy **GEREKMİYOR**. `candan_voice` plugin
  Hermes İÇİNDE çalışıp `handle_message` ile beyni doğrudan çağıracak → gateway yeterli.
  Port **8810** serbest bırakıldı (ileride gerekirse). İş TAMAM.

---

## candan_voice plugin deploy (2026-06-27)

`mate-brain/hermes-plugins/candan_voice/` → Hermes platform adapter. Brain'in
`voice/livekit_agent.py` mantığı (STT/wake-gate/turn/barge-in/speaker-ID/TTS)
Hermes `BasePlatformAdapter`'ına taşındı. Voice modülleri (tts/services/
turn_detector/speaker/hallucination) plugin içine **vendor** edildi; `brain.*`
bağımlılığı yok, config env'den (`voice/config.py` shim).

### Kurulum yeri + etkinleştirme
- **Plugin dizini:** `/home/ubuntu/.hermes/plugins/candan_voice/` (user plugin).
- **Etkinleştirme (KRİTİK — user platform plugin'leri OPT-IN):**
  `~/.hermes/config.yaml` → `plugins:\n  enabled:\n    - candan_voice`.
  (Allow-list anahtarı = manifest `name:` alanı; bu yüzden plugin.yaml
  `name: candan_voice` — dizin/platform adı ile aynı tutuldu.)
- **Env (`~/.hermes/.env`, `# >>> candan_voice >>>` bloğu):** LIVEKIT_URL=
  ws://127.0.0.1:7880, LIVEKIT_API_KEY/SECRET (brain.env'den), CANDAN_LIVEKIT_ROOM=
  **mate-hermes-test** (brain'in mate-demo'su AYRI), STT_HOST=192.168.0.25:10300,
  STT_LANGUAGE=tr, VOX_HOST=192.168.0.25:8808, **TURN_DETECTOR_ENABLED=false**,
  **SPEAKER_ID_ENABLED=false** (ilk bağlantı sade), CANDAN_VOICE_ALLOW_ALL_USERS=true.

### Deps (Hermes venv: `/home/ubuntu/.hermes/hermes-agent/venv`)
- Kurulan: `livekit livekit-api wyoming` (websockets zaten vardı). Bunlar ilk
  bağlantı için yeterli.
- **Açılınca gerekecek (henüz KURULMADI):** `numpy onnxruntime transformers
  huggingface_hub sherpa_onnx` → smart-turn EOU + speaker-ID için. Kodda her ikisi
  de try/except + fail-open: deps yoksa turn-detector saf-sessizliğe, speaker-ID
  guest'e düşer (crash yok).

### Doğrulama (yapıldı)
- ✅ `discover_plugins()` → candan_voice **registered**, `is_connected=True`.
- ✅ Gateway restart sonrası adapter LiveKit'e bağlandı: `RoomService.
  list_participants("mate-hermes-test")` → `[('assistant', kind=4=AGENT)]`.
- ✅ Servis stabil (`NRestarts=0`), traceback yok. Disconnect reason=1 =
  CLIENT_INITIATED (yalnız restart/SIGTERM'de — temiz kapanış).
- ⏳ Uçtan uca tur (sim → STT → beyin → TTS) = **B worker** (`tools/mate-sim`,
  oda `mate-hermes-test`, hazır token `tools/mate-sim/token.txt`).

### BLOCKER / Faz 2 notları
- **Per-user Hermes hafıza scope:** speaker-ID identify kodu bağlı ama Hermes
  tarafında brain-DB yok → enrolled embedding yok → herkes guest (oda-kapsamı).
  Tanınan-kullanıcı→kişisel Hermes hafıza + oto-enrollment kalıcılığı = Faz 2.
- **Streaming TTS:** `send()` tam metni alır; cümle-cümle TTS istenirse kendi
  segmentasyonumuz veya Hermes streaming-reply hook'u gerekir (şimdilik tek atış).
- **Reconnect:** connect() True döner, Hermes yeniden bağlama kadansını yönetir;
  oda kopuşunda otomatik yeniden-bağlanma sertleştirmesi Faz 2.
