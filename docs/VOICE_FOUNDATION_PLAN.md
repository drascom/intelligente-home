# Ses altyapısı planı — birleşik yığın: sherpa-onnx

*Karar tarihi: 2026-06-16. Onaylayan: kullanıcı. Bu plan, asistanı tek-soru/tek-cevap
modelinden **wake-gated, kalıcı oturumlu ambient** modele taşırken alttaki **ses
altyapısını** oturtur. Entegrasyonlar (mail/takvim) bilerek ERTELENDİ — önce ses.*

## 0. Karar ve kapsam

**Birleşik ses yığını = `sherpa-onnx`** (k2-fsa / Next-gen Kaldi, Apache-2.0).
Aynı modelleri Apple/iOS, Android, Linux ve Raspberry Pi'da çalıştırır; VAD + STT +
TTS + **speaker-ID/diarization** kapsar. FluidAudio'ya karşı belirleyici üstünlük:
**her yerde tek speaker-embedding modeli** → enrollment ile kaydedilen ses-parmak-izi
tüm cihaz sınıflarında eşleşir. (FluidAudio'nun CoreML speaker modelinin Linux ikizi
yok → çapraz-cihaz tutarlılık testinde kaldı.) **FluidAudio artık opsiyonel, sadece
Apple ANE hızlandırıcısı** olarak rafta; hiç kullanılmayabilir.

**Bu turda DEĞİŞMEYENLER (çalışan şeye dokunma):**
- **TTS** = `vox`/VoxCPM2 (Türkçe) kalır. sherpa-onnx TTS'e geçmiyoruz.
- **Sunucu STT** = faster-whisper large-v3-turbo kalır; nemotron'a geçiş ancak
  gerçek ev sesiyle A/B testinden sonra (bkz. `STT_NEMOTRON_NOTES.md`).
- **Wake word** = "candan" (Apple: SFSpeech, Pi: openWakeWord). **Wake-gated** —
  hiçbir client sesi sürekli akıtmaz.

**Bu turda YENİ olan asıl iş = speaker-ID (voice-ID).** Kodda hiç yok. Önce
**sunucuda merkezi** yapılır (brain zaten hem Pi hem Apple yolundan utterance sesini
alıyor), tek sherpa-onnx embedding modeliyle — böylece ileride Apple/Android'de
on-device ID'ye geçilse bile vektörler tutarlı kalır.

## Cihaz sınıfına göre hedef mimari

```
KULLANICI → ASİSTAN (wake-gated, "candan")
  Apple client : wake(SFSpeech) → VAD → segment → sunucuya akıt
  Pi satellite : wake(openWakeWord) → VAD → segment → sunucuya akıt
  Android(ileri): sherpa-onnx (Flutter) wake/VAD → segment → sunucuya akıt
        ↓ (sunucu, Linux/Nvidia)
  STT (faster-whisper tr  |  ileride sherpa-onnx/nemotron)   → metin
  Speaker-ID (sherpa-onnx embedding + eşleştirme)            → KİM
        ↓
  Brain: turn + speaker → (ileride) triage / oturum / görev

GPU = sadece LLM.  CPU = STT + speaker-ID (wake-gated, sürekli değil → ucuz).
```

## Mevcut durum (kodda doğrulandı)

- Brain STT'ye **Wyoming** ile bağlanır: `mate-brain/brain/voice/services.py`
  → `WhisperSession` (`start`/`feed`/`finish`). STT motorunu değiştirmek =
  arkaya başka bir Wyoming servisi koymak. sherpa-onnx online-recognizer API'si
  (create stream / accept_waveform / finalize) bu modele birebir oturuyor.
- TTS: `brain/voice/tts.py` (`TTS_ENGINE=vox|piper`), vox/VoxCPM2.
- Speaker-ID / enrollment / embedding: **YOK** (grep boş döndü).
- Apple client'lar bugün sesi sunucuya gönderiyor (WhisperKit kaldırılmıştı) →
  merkezi speaker-ID bugün her iki yol için de çalışır.

---

## Aşamalı plan

### Faz 0 — Model seçimi ve doğrulama (KARAR VERİLDİ 2026-06-16)
**Model = 3D-Speaker CAM++** (multilingual ZH+EN "advanced"):
`3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx` — **28 MB, 192-dim,
16kHz**. İndirme: github.com/k2-fsa/sherpa-onnx releases → `speaker-recongition-models`.
- **Neden:** sherpa-onnx'in en hafif/hızlısı (RTF 0.013, ~2× ResNet34/ECAPA) ama
  doğrulukta üst grupla eşit (VoxCeleb %0.37 EER). 3 kişilik kapalı küme için fazlası.
- **Türkçe-güvenli:** embedding tınıyı modeller (dil-bağımsız); dile bağlı kıran
  katman yok. Türkçe'ye özel eval YOK → kendi kayıtlarımızla kalibre.
- **Yedek:** WeSpeaker ResNet34 (`wespeaker_en_voxceleb_resnet34_LM.onnx`, 26.5 MB,
  256-dim) — farklı mimari, far-field sağlama için. Sunucu-üstü en iyi: ERes2NetV2
  (71 MB, Pi'a koyma).
- **Elendi:** NeMo TitaNet (sherpa ONNX skor-uyuşmazlık bug'ı #2883 + 101 MB).
- **sherpa-onnx API teyitli:** `SpeakerEmbeddingExtractor` + `SpeakerEmbeddingManager`
  (`add(name,[emb])` ortalar; `search(emb,threshold)` eşik altı → `""` = unknown).
- **Eşik:** varsayılan 0.6, ayar 0.5–0.65 + **marj kuralı** (top 2.'yi ≥0.05 geçmeli).
- **Enrollment:** kişi başı 5–10 klip ~2–4sn, gerçek ReSpeaker'da + telefon/Mac'ten
  birkaç; embedding'ler ortalanır.
- **Pi:** tahmini ~0.3–0.6sn/utterance (ölçülmedi) → **varsayılan sunucuda**, Pi
  opsiyonel. RAM (512MB) asıl risk, `num_threads=1`.
- Açık: sherpa-onnx **sürümünü pinle**; VAD modeli (Silero) opsiyonel ortak.

### Faz 1 — Sunucu: speaker-ID servisi + enrollment (asıl yeni yetenek)
- Brain'e sherpa-onnx (Python binding) ekle → `brain/voice/speaker.py`:
  `embed(wav_segment) -> vector`, `identify(vector) -> (speaker|unknown, score)`
  (kosinüs benzerliği + eşik; kapalı küme 3 kişi).
- **DB**: `speakers` tablosu (id, name, user_id?, embedding(ler), created_at).
- **Enrollment API**: `POST /api/speakers/enroll` (name + ses → embedding kaydet),
  `GET /api/speakers`, `DELETE /api/speakers/{id}`.
- **Turn'e bağla**: STT ile paralel, utterance sesinden embedding çıkar →
  `identify` → turn'e `speaker` ekle. Monitor bus'a `speaker` event'i + konuşmaya
  yaz (dashboard zaten event şemasında `client_id`/`conversation_id` taşıyor).
- Test: 3 kişilik örnek seslerle enroll + tanıma doğruluğu / eşik ayarı.

### Faz 2 — Client'larda enrollment UX
- mate-mac + mate-ios'a basit **enrollment ekranı**: kişi ~30-60sn konuşur →
  `/api/speakers/enroll`'a gönder. (Sync kuralı: HER İKİ uygulamaya da uygula.)
- Opsiyonel: bir Pi satellite üzerinden sesli enrollment akışı.

### Faz 3 — Kişi-bazlı oturum yönlendirme ("kim" bilgisini kullan)
- Tanınan speaker → kullanıcı/oturum eşle. Mevcut çok-kullanıcı yol haritasına
  bağla (`users` tablosu + `clients.user_id`). Konuşma context'i kullanıcıya göre
  ayrışsın. (Görev kuyruğu/triage sonraki epic — bu plan ses tabanında durur.)

### Faz 4 — (Opsiyonel / paralel) STT birleştirme + on-device offload
- sherpa-onnx (nemotron tr) bir **Wyoming STT servisi** olarak sarılsın →
  `STT_ENGINE=whisper|nemotron`, gerçek ev sesiyle A/B (notlardaki plan). Daha
  iyiyse sunucu STT geçişi → VRAM kazancı (whisper-turbo ~6GB → nemotron ~2GB).
- Apple client'lar: opsiyonel **on-device sherpa-onnx STT** (sunucuyu boşalt).
- Android (gelecek Flutter): baştan sherpa-onnx.
- Pi: ince kalır; opsiyonel sherpa-onnx VAD ile daha temiz segment.

### STT sonrası düzeltme katmanı — "Handy" tarzı (araştırıldı 2026-06-16)
- Kullanıcı MacBook'ta **Handy** (github.com/cjpais/Handy, Tauri/Rust, MIT)
  kullanıyor: STT'den sonra cümleyi **LLM ile düzeltip** yazıyor; çok beğeniliyor.
- **Yöntem (kaynak koddan doğrulandı):** kurallar/fine-tune değil — OpenAI-uyumlu
  `/chat/completions`'a **sabit bir sistem prompt'u + ham transkript** gönderip
  dönen temiz metni kullanıyor. Prompt dil-bağımsız ("orijinal dili koru" kuralı).
  Yerel (Ollama `localhost:11434`) veya bulut, ayarlanabilir; temp 0.
- **Bize uyarlama:** OpenAI-uyumlu LLM backend'imiz zaten var → düzeltme = tek chat
  çağrısı. Önemli kısayol: transkript bizde zaten triage/agent LLM'ine gidiyor →
  - **sohbet/komut turları:** ayrı düzeltme YOK, düzeltmeyi **triage prompt'una
    katla** (ekstra gecikme/maliyet yok).
  - **dikte/not görevleri + ekranda transkript gösterimi:** ayrı temizleme geçişi
    değerli (Türkçe sabit prompt, temp 0).
- **Model önerisi (yerel TR, 3090):** Qwen2.5-7B-Instruct, reasoning kapalı.
- **Güvenlik:** çıktı uzunluğu girdiden çok saparsa reddet (uydurma metne karşı).
- Bu katman ses tabanının değil **triage/görev epic'inin** parçası — burada sadece
  karar olarak not edildi.

---

## Riskler / açık noktalar
- **Türkçe STT**: nemotron bugün whisper'ın gerisinde olabilir → A/B kapısı şart.
- **Speaker-ID doğruluğu**: uzak mikrofon + TV gürültüsünde zorlanabilir; 3 kişilik
  kapalı küme + eşik ayarı yardımcı. Far-field test gerekli.
- **Tek model şartı**: enrollment ve çalışma her yerde AYNI embedding modelini
  kullanmalı → tek model dosyası, sürüm kilidi.
- **sherpa-onnx sürüm pinleme** (nemotron desteği master'da olabilir).
- TTS/VAD bilerek kapsam dışı — gereksiz değişiklik yapma.
