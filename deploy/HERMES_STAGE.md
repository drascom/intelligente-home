# Hermes Agent — oracle-stage kurulumu

Hermes Agent (NousResearch) `oracle-stage` (132.145.24.135) üstüne, mevcut
brain(:8800) + LiveKit(:7880) servislerine **DOKUNMADAN** yeni servis olarak kuruldu.
Sonraki adımda buraya kendi ses eklentimiz (`mate_voice` Hermes platform adapter
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
  - Şu an "no messaging platforms enabled" (beklenen — `mate_voice` plugin sonra bağlanacak).
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
- ✅ **KARAR (b):** harici OpenAI-uyumlu `/v1` proxy **GEREKMİYOR**. `mate_voice` plugin
  Hermes İÇİNDE çalışıp `handle_message` ile beyni doğrudan çağıracak → gateway yeterli.
  Port **8810** serbest bırakıldı (ileride gerekirse). İş TAMAM.

---

## mate_voice plugin deploy (2026-06-27)

`mate-brain/hermes-plugins/mate_voice/` → Hermes platform adapter. Brain'in
`voice/livekit_agent.py` mantığı (STT/wake-gate/turn/barge-in/speaker-ID/TTS)
Hermes `BasePlatformAdapter`'ına taşındı. Voice modülleri (tts/services/
turn_detector/speaker/hallucination) plugin içine **vendor** edildi; `brain.*`
bağımlılığı yok, config env'den (`voice/config.py` shim).

### Kurulum yeri + etkinleştirme
- **Plugin dizini:** `/home/ubuntu/.hermes/plugins/mate_voice/` (user plugin).
- **Etkinleştirme (KRİTİK — user platform plugin'leri OPT-IN):**
  `~/.hermes/config.yaml` → `plugins:\n  enabled:\n    - mate_voice`.
  (Allow-list anahtarı = manifest `name:` alanı; bu yüzden plugin.yaml
  `name: mate_voice` — dizin/platform adı ile aynı tutuldu.)
- **Env (`~/.hermes/.env`, `# >>> mate_voice >>>` bloğu):** LIVEKIT_URL=
  ws://127.0.0.1:7880, LIVEKIT_API_KEY/SECRET (brain.env'den), MATE_LIVEKIT_ROOM=
  **mate-hermes-test** (brain'in mate-demo'su AYRI), STT_HOST=192.168.0.25:10300,
  STT_LANGUAGE=tr, VOX_HOST=192.168.0.25:8808, **TURN_DETECTOR_ENABLED=false**,
  **SPEAKER_ID_ENABLED=false** (ilk bağlantı sade), MATE_VOICE_ALLOW_ALL_USERS=true.

### Deps (Hermes venv: `/home/ubuntu/.hermes/hermes-agent/venv`)
- Kurulan: `livekit livekit-api wyoming` (websockets zaten vardı). Bunlar ilk
  bağlantı için yeterli.
- **Açılınca gerekecek (henüz KURULMADI):** `numpy onnxruntime transformers
  huggingface_hub sherpa_onnx` → smart-turn EOU + speaker-ID için. Kodda her ikisi
  de try/except + fail-open: deps yoksa turn-detector saf-sessizliğe, speaker-ID
  guest'e düşer (crash yok).

### Doğrulama (yapıldı)
- ✅ `discover_plugins()` → mate_voice **registered**, `is_connected=True`.
- ✅ Gateway restart sonrası adapter LiveKit'e bağlandı: `RoomService.
  list_participants("mate-hermes-test")` → `[('assistant', kind=4=AGENT)]`.
- ✅ Servis stabil (`NRestarts=0`), traceback yok. Disconnect reason=1 =
  CLIENT_INITIATED (yalnız restart/SIGTERM'de — temiz kapanış).
- ⏳ Uçtan uca tur (sim → STT → beyin → TTS) = **B worker** (`tools/mate-sim`,
  oda `mate-hermes-test`, hazır token `tools/mate-sim/token.txt`).

### Authz fix (2026-06-27, B testi blocker'ıydı)
- **Bulgu:** Hermes `gateway/authz_mixin.py` → `if not user_id: return False`,
  allow-all bayraklarından ÖNCE. Guest (user_id=None) mesajı **sessizce düşer**
  (brain hiç çalışmaz, log/hata yok). İlk B turu'nda STT doğru transcript verdi
  (`'Candan, 2 artı 2 kaç eder?'`) ama cevap üretilmedi — kök neden buydu.
- **Çözüm:** adapter guest'e `user_id="voice:<participant_identity>"` verir
  (cihaz-kapsamlı; None DEĞİL) → authz guard'ı geçer, `MATE_VOICE_ALLOW_ALL_USERS=true`
  ile yetkilenir. Speaker-ID açılınca (Faz 2) tanınan kişi override eder.

### Token endpoint (2026-06-27, A2)
- Plugin'e gömülü aiohttp sunucu: `GET /mate/token` (`X-Mate-Key` ile room-scoped
  join token mint) + `GET /mate/health`. LiveKit secret sunucuda kalır.
- env (`~/.hermes/.env` mate bloğu): `MATE_VOICE_CLIENT_KEY` (openssl rand),
  `MATE_VOICE_TOKEN_PORT=8830`, `MATE_PUBLIC_LIVEKIT_URL=wss://mate-livekit.drascom.uk`.
- Bind `0.0.0.0:8830` (henüz public DEĞİL → SSH tüneli ile eriş; public için Traefik route).
- Doğrulandı: health/200, token/200 (geçerli jwt), yanlış-key/401, identity-yok/400;
  endpoint token'ı ile sim e2e PASS (`[assistant] "3 kere 3, 9 eder."` + reply.wav).
  Sözleşme: `hermes-plugins/mate_voice/CLIENT_INTEGRATION.md`.

### Faz 2 notları
- **Per-user Hermes hafıza scope:** speaker-ID identify kodu bağlı ama Hermes
  tarafında brain-DB yok → enrolled embedding yok → herkes guest (cihaz-kapsamı).
  Tanınan-kullanıcı→kişisel Hermes hafıza + oto-enrollment kalıcılığı = Faz 2.
- **Streaming TTS:** `send()` tam metni alır; cümle-cümle TTS istenirse kendi
  segmentasyonumuz veya Hermes streaming-reply hook'u gerekir (şimdilik tek atış).
- **Reconnect + empty_timeout (YAPILDI 2026-06-27):** adapter `_ensure_room`
  ile odayı `empty_timeout=86400` (24h) ile önceden oluşturur → boş oda KAPANMAZ
  (eski reason-10 ROOM_CLOSED düşüşü biter). Ek backstop: `_reconnect_loop`
  beklenmedik kopuşta backoff ile yeniden bağlanır. Doğrulandı: restart sonrası
  ajan 100sn+ boş odada KALICI bağlı (`list_participants → assistant`), churn yok.

## candan → mate cutover (stage'de YAPILACAK — kod tarafı bitti)

Repo'da plugin/protokol `candan_*` → `mate_*` olarak yeniden adlandırıldı
(dizin `candan_voice/` → `mate_voice/`, route `/candan/*` → `/mate/*`, header
`X-Candan-Key` → `X-Mate-Key`, topic/attr `candan.*` → `mate.*`, env `CANDAN_*`
→ `MATE_*`). Wake word "candan" KORUNDU. Stage'de eşleşmeyi sağlamak için
(SSH ile CANLI değişikliği orkestratör/kullanıcı yapar — burada SADECE not):

1. `~/.hermes/.env`: tüm `CANDAN_VOICE_*` / `CANDAN_*` anahtarlarını `MATE_*`'e
   çevir (değerler AYNI kalır). Etkilenenler: `CANDAN_VOICE_CLIENT_KEY`,
   `CANDAN_VOICE_TOKEN_PORT`, `CANDAN_VOICE_TOKEN_BIND`, `CANDAN_VOICE_CLIENT_TOKEN_TTL`,
   `CANDAN_LIVEKIT_ROOM`, `CANDAN_PUBLIC_LIVEKIT_URL`, `CANDAN_HOME_CHANNEL`,
   `CANDAN_VOICE_ALLOW_ALL_USERS`.
2. `~/.hermes/config.yaml`: `plugins.enabled` listesinde `candan_voice` → `mate_voice`.
3. Plugin dizini: `~/.hermes/plugins/candan_voice` → `mate_voice` (rename) — ya da
   deploy script kopyalıyorsa eski `candan_voice` dizinini SİL (artık `mate_voice` kopyalanır).
4. Gateway restart.
5. Doğrula: `curl -s https://mate-token.drascom.uk/mate/health` → `200 {status:ok,...}`
   (eski `/candan/health` artık 404). İstemci (mate-mac) Settings'te token endpoint
   public URL + Client key zaten aynı; sadece route/header isimleri yeni build ile uyumlu.
