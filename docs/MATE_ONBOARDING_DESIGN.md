# mate Onboarding Sihirbazı — Tasarım (S3/S4 + istemci)

Durum (2026-06-28 gece, otonom): **S1 (speaker DB) + S2 (/mate/demo-token) DONE+deployed+verified.**
Bu doküman kalan parçaların tasarımı — canlı test gerektirdiği için kör implement edilmedi.

Kararlar: açık `/mate/demo-token` · aynı agent demo odasına katılır · sunucu-tarafı embed · önce sunucu.
Bağlam: [[mate-onboarding-wizard-plan]] [[hermes-memory-model]] [[candan-voice-phase2-plan]]. Plugin-only.

## YAPILDI (bu gece)
- **S1** `mate_voice/voice/speaker_store.py` — plugin-local SQLite (`~/.hermes/mate_voice/speakers.db`),
  `create_speaker/add_speaker_sample/list_speakers/all_speaker_embeddings/delete_speaker`. Adapter
  `connect()`'te `_load_speakers()` ile `SpeakerID.reload()` (SPEAKER_ID açıkken; şu an dormant).
- **S2** `GET /mate/demo-token` — key'siz, 600s TTL, guest identity `onboard-<rnd>`, oda=`MATE_ONBOARDING_ROOM`
  (boşsa ana oda). Canlı 200 + onboarding:true doğrulandı.

## ÖN KOŞUL (S3 enrollment çalışması için) — ŞU AN EKSİK
Hermes gateway venv'inde **sherpa_onnx + numpy + onnxruntime YOK** (sadece brain venv'inde 1.13.3 var).
Speaker model `campplus.onnx` `/opt/intelligente-home/mate-brain/models/`'da VAR.
Yapılacak (dikkatli, gateway'i bozabilir → kullanıcı gözüyle):
- `~/.hermes/hermes-agent/venv/bin/pip install sherpa_onnx numpy onnxruntime` (sürüm çakışmasına dikkat).
- `.env`: `SPEAKER_ID_ENABLED=true`, `SPEAKER_MODEL_PATH=/opt/intelligente-home/mate-brain/models/campplus.onnx`,
  `SPEAKER_MODEL_ID=campplus_zh_en_advanced_v1` (veya model gerçek id'si).
- gateway restart → log "speaker-ID etkin" + "_load_speakers".
- Aynı şekilde turn-detector için `TURN_DETECTOR_ENABLED=true` + transformers/huggingface_hub/onnxruntime.

## S3 — Recognize-first enrollment + demo oda (iki katman)

**Katman A (ana oda, sim ile test edilebilir): recognize-first enrollment.**
Eski `mate-brain/brain/voice/livekit_agent.py`'taki `_begin_enrollment`/`_complete_enrollment`/
`_parse_name`/`_pending_enroll` akışını `adapter._handle_utterance` içine port et:
- `_identify(pcm)` zaten var → tanınırsa speaker_id, tanınmazsa:
  - `_pending_enroll is None` & utterance asistana hitap → istek beklet, TTS ile isim sor
    ("Seni tanımadım, adın ne?"). `_pending_enroll={text, emb}`.
  - sonraki utterance → `_parse_name` → `speaker_store.create_speaker(name)` +
    `add_speaker_sample(emb, dim, model_id, source="auto-enroll")` → `_load_speakers()` reload →
    bekletilen isteği tanınan kullanıcı olarak işle.
- **Verify:** enroll sonrası "Doğrulamak için tekrar 'merhaba' de" → yeni embed → `SpeakerID.identify`
  aynı kişiye düşüyor mu (cosine ≥ threshold). Düşmezse örneği geri al / tekrar dene.

**Katman B (demo oda — iki-oda): onboarding wrapper.**
Adapter şu an tek-oda (`self._room`, `_open_room`). Onboarding odasına da katılmak için:
- `MATE_ONBOARDING_ROOM`'u ana odadan AYRI yap (ör. `mate-onboarding`).
- Adapter'ı çoklu-oda yap: ana oda + onboarding oda için ayrı `rtc.Room` + consume/publish seti
  (mevcut tek-oda mantığını oda-başına bir "RoomSession" sınıfına çıkar; en temiz refactor).
  Alternatif (daha ucuz): onboarding için 2. bir hafif Room bağlantısı + sadece greet+enroll consume.
- Onboarding odasında guest katılınca: agent TTS ile karşılar ("Hoş geldin, tanışalım, adın ne?")
  → Katman A enrollment akışı → bitince istemciye sinyal (data topic `mate.onboarding` JSON
  `{status:"enrolled", speaker_id, name}`).
- Greet metnini Hermes brain mı üretsin yoksa sabit script mi: ŞİMDİLİK sabit script (deterministik,
  test kolay); sonra brain'e bağlanabilir.

## S4 — Per-user profil + kalıcı credential

Enroll başarı sonrası ([[hermes-memory-model]]):
- `config.yaml` → `multiplex_profiles: true`.
- Profil provizyonu: `~/.hermes/profiles/<speaker_id>/` (Hermes ilk kullanımda kendi oluşturur; gerekiyorsa mkdir).
- Adapter `_handle_utterance` → recognized speaker → `self.build_source(..., profile=<speaker_id>)`
  (DOĞRULA: `build_source`/`SessionSource` `profile` alanını geçiriyor mu; geçmiyorsa MessageEvent.source.profile set et).
  Böylece USER.md/MEMORY.md + konuşma geçmişi kullanıcıya izole.
- **Kalıcı credential (gerçek bağlantı, demo'dan sonra):** enroll bitince sunucu kullanıcıya özel bir
  credential üretir. Öneri: per-user `X-Mate-Key` yerine, `/mate/token`'a speaker_id'ye bağlı imzalı bir
  **device-pairing token** ver (uzun TTL veya yenilenebilir). İstemci Keychain'e yazar; sonraki açılışlarda
  onunla `/mate/token` çağırıp gerçek odaya bağlanır. (Paylaşılan tek key'in per-user olmaması sorununu çözer.)
  MVP: enroll sonrası uzun-TTL bir LiveKit token'ı + speaker_id'yi data topic ile gönder, Keychain'e yaz.

## İstemci — mate-mac sihirbaz UI (sonra; sadece build-verify, görsel test kullanıcı)
- Tetik: `SettingsStore.resolvedTokenEndpointURL` boş VEYA livekit boş → sihirbaz aç. App'e gömülü default
  endpoint `https://mate-token.drascom.uk` (Secrets/defaults).
- Adımlar: (1) Karşılama — `/mate/demo-token` ile demo odaya bağlan, agent sesli "hoş geldin". (2) İsim/ses —
  kullanıcı konuşur, sunucu embed+enroll. (3) Verify — tekrar konuş, eşleşme onayı. (4) Bağlanıyor —
  dönen credential Keychain'e, gerçek odaya `source.profile` ile bağlan.
- Mevcut: zaten Hermes-only, `MateTranscriptionReceiver`/`SpeakerReceiver` var; sihirbaz bunların üstüne
  çok-adımlı bir SwiftUI akışı.

## Test stratejisi
- S1/S2: curl + py self-test (yapıldı).
- S3 Katman A: `tools/mate-sim` ile WAV gönder → enroll log + speakers.db satırı + verify; deps kurulunca.
- S3 Katman B / istemci: kullanıcı canlı (mic + GUI).
