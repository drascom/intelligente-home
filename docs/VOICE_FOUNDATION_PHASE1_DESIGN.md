# Faz 1 tasarımı — sunucu speaker-ID + enrollment

*Tarih: 2026-06-16. `VOICE_FOUNDATION_PLAN.md` Faz 1'in somut tasarımı. Kod
konvansiyonları mevcut brain'den alındı (aiosqlite + raw SQL SCHEMA, `Database`
sınıfı, `APIRouter(prefix="/api")`, `Depends(admin_only)`, monitor bus).*

**Faz 0 kararı (verildi):** model = **3D-Speaker CAM++**
`3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx` (28 MB, **dim=192**,
16kHz). Eşleşme sherpa-onnx **`SpeakerEmbeddingManager`** ile (`add(name,[emb])`
ortalar; `search(emb,thr)` eşik altı → `""`=unknown). Eşik 0.6 (ayar 0.5–0.65) +
marj kuralı. Tasarım yine dim/model_id parametrik tutuluyor (model değişebilir).

## Hedef
Sunucuda, sherpa-onnx ile **tek bir embedding modeli** kullanarak:
1. 3 kişiyi **enrollment** ile kaydet (kişi başına birkaç kısa örnek).
2. Çalışma anında her wake-gated utterance'tan embedding çıkar → **kim** olduğunu
   bul → turn'e `speaker` ekle (emit + sakla). *(Kişiye-göre oturum = Faz 3.)*

## Tasarım ilkeleri / kararlar
- **Embedding'ler BLOB olarak** saklanır (float32 little-endian, ~dim×4 bayt) —
  JSON yok, kompakt.
- **Kişi başına çok örnek** sakla (`speaker_samples`) — DB kaynak. Eşleşme/ortalama
  sherpa-onnx `SpeakerEmbeddingManager`'a bırakılır (`add` ortalar). `speakers.centroid`
  sütunu **opsiyonel cache** (her örneği yüklemeden hızlı referans); manager onsuz da
  örneklerden yeniden hesaplar.
- **`model_id` tutarlılık kilidi:** her embedding'in hangi modelden geldiği kişide
  saklanır. Model değişirse eski enrollment geçersiz (dim/model_id uyuşmaz) →
  eşleşmede reddet/işaretle. ("Her yerde aynı model" şartının DB'deki bekçisi.)
- **Privacy:** çalışma sesi ASLA saklanmaz; sadece embedding. Enrollment kısa
  klipleri (3 kişi × birkaç wav) **opsiyonel** olarak `speaker_enroll_dir`'de
  tutulur → model yükseltilirse yeniden-embed mümkün olsun (yoksa yeniden enroll).
- **Kapalı küme + eşik:** 3 kişi; en yüksek kosinüs `threshold`'un altındaysa
  → `unknown`. Eşik değeri Faz 0 araştırmasından gelir (config'te ayarlanabilir).
- Speaker-ID **turn'ü bloklamaz** — transcript sonrası paralel hesaplanır, sonuca
  iliştirilir (Faz 1 kapsamı: hesapla + emit + sakla).

## DB şeması (db.py `SCHEMA`'ya eklenecek)
```sql
CREATE TABLE IF NOT EXISTS speakers (
    id           INTEGER PRIMARY KEY,
    name         TEXT NOT NULL,
    user_id      INTEGER,            -- ileride users tablosuna bağlanır (çok-kullanıcı)
    centroid     BLOB,               -- normalize ortalama embedding (float32 bayt)
    dim          INTEGER,            -- embedding boyutu (sanity)
    model_id     TEXT,               -- embedding modeli kimliği (tutarlılık kilidi)
    sample_count INTEGER NOT NULL DEFAULT 0,
    enrolled_at  REAL NOT NULL,
    updated_at   REAL
);
CREATE TABLE IF NOT EXISTS speaker_samples (
    id          INTEGER PRIMARY KEY,
    speaker_id  INTEGER NOT NULL,    -- -> speakers.id (silinince temizlenir)
    embedding   BLOB NOT NULL,       -- float32 vektör baytları
    source      TEXT,                -- 'mac' | 'ios' | 'satellite:salon' ...
    created_at  REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_samples_speaker ON speaker_samples(speaker_id);
```

### db.py'ye eklenecek metodlar
- `create_speaker(name, user_id=None) -> dict`
- `add_speaker_sample(speaker_id, embedding: bytes, source, model_id, dim)` →
  örneği ekle, centroid'i yeniden hesapla, `sample_count`/`updated_at` güncelle.
- `list_speakers() -> [{id,name,sample_count,enrolled_at,...}]` (centroid'siz)
- `speaker_samples(speaker_id) -> [embedding bytes]`
- `delete_speaker(id)` / `delete_sample(sample_id)` (sonra centroid yeniden hesap)
- `all_centroids() -> [{id,name,centroid,dim,model_id}]` (başlangıçta SpeakerID'e yükle)

## `brain/voice/speaker.py` (yeni modül)
sherpa-onnx hazır API'sini sar — elle kosinüs/centroid YOK:
```python
class SpeakerID:
    def __init__(self, model_path, model_id, threshold=0.6, margin=0.05):
        # SpeakerEmbeddingExtractorConfig(model=..., num_threads=1, provider="cpu")
        # extractor = SpeakerEmbeddingExtractor(cfg)
        # manager   = SpeakerEmbeddingManager(extractor.dim)   # dim=192
    def embed(self, pcm_f32_16k_mono) -> np.ndarray
        # stream.accept_waveform(16000, samples); input_finished(); extractor.compute(stream)
    def identify(self, emb) -> tuple[str | None, float]
        # eşleştirme ELLE kosinüs (manager.search skor döndürmüyor → marj kuralı
        # için kendi hesabımız): centroid'lere kosinüs, en iyi < eşik VEYA top
        # 2.'yi <margin geçiyorsa unknown (far-field sağlamlık)
    def reload(self, speakers: list[dict]) -> None
        # manager.clear; her kişi için manager.add(name, [tüm örnek embedding'leri])
        #   → manager ortalar. model_id uyuşmayan kişiyi atla (tutarlılık kilidi).
```
- Başlangıçta DB'den tüm örnekleri çek → `reload`. Her enroll/silme sonrası `reload`
  (3 kişi, ucuz). DB **kaynak**, manager **bellek-içi indeks**.
- Ses formatı: utterance buffer s16le 16k mono → `f32 = int16/32768.0` (Apple f32le
  ise doğrudan). Model 16kHz mono bekler.

## Enrollment API (`brain/api/speaker_api.py`, admin)
Enrollment gecikme-duyarlı değil → **REST multipart wav upload** (runtime için WS;
enrollment için basit upload). Kişi ~5-10sn'lik birkaç klip yükler.

| Uç | Yetki | İş |
|---|---|---|
| `POST /api/speakers` `{name}` | admin | kişi oluştur → `{id}` |
| `POST /api/speakers/{id}/samples` (wav) | admin | wav → 16k mono → embed → sakla → centroid güncelle |
| `GET /api/speakers` | admin | liste (id, name, sample_count, enrolled_at) |
| `DELETE /api/speakers/{id}` | admin | kişiyi sil |
| `DELETE /api/speakers/{id}/samples/{sid}` | admin | tek örnek sil (eşik ayarı) |
| `POST /api/speakers/identify` (wav) | admin | DEBUG: wav → `{name, score}` (eşik ayarı) |

Enrollment iyi-pratik (Faz 0): kişi başına **5-10 kısa klip (~2-4sn)**, **gerçek
ReSpeaker'da/odada** (+ telefon/Mac'ten birkaç → tek çapraz-cihaz profil), çeşitli
cümle/mesafe, hafif oda gürültüsüyle. Manager embedding'leri ortalar. N örneğe uyumlu.

## Runtime hook (`brain/api/voice.py`)
Bugün `feed()` ile WhisperSession'a giden ham PCM'i (binary `message["bytes"]`)
**paralel bir buffer'a** da biriktir:
- `audio_start`: per-turn `bytearray()` + format kaydet.
- her binary chunk: WhisperSession'a feed + buffer'a append.
- `finish_stt` (transcript sonrası): SpeakerID açıksa ve buffer ≥ ~1sn ise →
  f32 16k mono'ya çevir → `embed` → `identify` → `speaker` (ad veya `unknown`)
  - `transcript` mesajına ekle: `{"type":"transcript", ..., "speaker": ...}`
  - monitor bus'a iliştir (utterance event payload'una `speaker`)
  - `messages` tablosuna yaz (aşağıdaki additive sütun).
- Turn'ü bloklamamak için identify, reply üretimiyle paralel koşar.

`messages` tablosuna additive: `speaker TEXT` (nullable) → sohbet akışında "kim".

## config.py eklentileri
```
speaker_id_enabled: bool = False
speaker_model_path: str = ""          # .../3dspeaker_..._campplus_sv_zh_en_..._advanced.onnx
speaker_model_id: str = "campplus_zh_en_advanced_v1"   # tutarlılık kilidi etiketi
speaker_threshold: float = 0.6        # ayar 0.5–0.65
speaker_margin: float = 0.05          # top, 2.'yi bu kadar geçmezse unknown
speaker_enroll_dir: str = ""          # opsiyonel wav saklama (model yükseltme için)
```

## Test (`brain/tests/test_speaker.py`)
- DB CRUD: create/add sample/centroid recompute/list/delete (gerçek model olmadan,
  sahte sabit vektörlerle).
- `identify`: aynı kişi → eşleşir, farklı → unknown, eşik sınırı.
- `model_id` uyuşmazlığı → reddedilir.
- voice.py: buffer biriktirme + transcript'e speaker iliştirme (fake STT/embedder).

## Açık noktalar
- **Model + dim + eşik + enrollment** → Faz 0'da KARARA bağlandı (CAM++, 192, 0.6,
  5-10 klip). Eşik/marj gerçek ReSpeaker kayıtlarıyla kalibre edilecek.
- Embedding **sunucuda** (tasarım böyle); Pi-üstü opsiyonel optimizasyon, sonra ölç.
- **Türkçe doğruluk** Faz 0'da test edilmedi (model dil-bağımsız) → enrollment +
  birkaç gerçek turla doğrula.
- sherpa-onnx Python paketi brain `.venv`'ine eklenecek; **sürüm pinle**.
