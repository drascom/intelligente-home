# Türkçe "candan" wake word modeli (openWakeWord)

`candan.tflite` — Pi satellite'lerde openWakeWord (pyopen-wakeword) için özel
wake word modeli. Input `[1,16,96]` f32 → output `[1,1]` skor (openWakeWord
standart mimarisi). 2026-06-13'te GPU VPS'te (RTX 3090) eğitildi.

## Pi'ye kurulum (deploy)

```sh
scp candan.tflite candan@<pi>:/tmp/
ssh candan@<pi> 'sudo cp /tmp/candan.tflite /opt/candan/wakeword/'
# wyoming-openwakeword servisine: --custom-model-dir /opt/candan/wakeword [--threshold 0.3]
# wyoming-satellite servisine:    --wake-word-name candan
sudo systemctl daemon-reload && sudo systemctl restart wyoming-openwakeword wyoming-satellite
```
Doğrulama: `journalctl -u wyoming-openwakeword` → "Found custom model candan",
"Loaded models: ['candan']". Tespit testi `--debug --debug-probability` →
"Detected candan at N". **salon**'da canlı doğrulandı (enjeksiyon → brain wake).

## Eğitim reçetesi (GPU VPS, hibrit pozitifler)

Ortam: Ubuntu + NVIDIA, **Python 3.10** (uv ile; eski sabit deps gerekli),
`/root/oww_train/`. İki venv: `tv` (eğitim: torch 2.1.2+cu121 + openWakeWord +
pinned deps; piper için espeak-ng + deep-phonemizer) ve `cv` (onnx→tflite:
tensorflow-cpu 2.8.1 + onnx_tf 1.10.0 + tensorflow_probability 0.16.0).

Pozitifler = **hibrit**: piper-sample-generator (dscripka fork, en-us-libritts-high,
10k klip, İngilizce-aksanlı çeşitlilik) **+ vox VoxCPM2 ile üretilen ~5400 native
Türkçe "candan"** (`vox/` 4 ses × tonlama × pitch/tempo augment). Negatifler:
openWakeWord ACAV100M features (17G) + MIT RIR + fma/fsd50k background +
phoneme-örtüşen adversarial (custom_negative: canım, candaş, vatandaş…).

Akış (`run_train.sh`): `train.py --generate_clips` → vox kliplerini
positive_train/test'e enjekte (90/10) → `--augment_clips` → `--train_model`
(50k step) → `candan.onnx` → `cv` env `convert.py` ile `candan.tflite`.

Config: `candan.yaml` (target_phrase: candan, model_name: candan, layer_size 32,
steps 50000). **Notlar:** eğitimi `tmux` yerine foreground/normal kabukta çalıştır
(tmux server eski ortam yakalayıp espeak/dp import'unu bozuyordu); feature
modelleri (`melspectrogram/embedding .onnx`) openwakeword `resources/models/`'a
kopyalanmalı; tv env'e `onnx` paketi lazım (export için).

## İyileştirme fikirleri
- FP/hour ~3.6 çıktı (hedef 0.2) → daha fazla native vox pozitif, daha fazla
  adversarial, veya inference threshold'u yükselt (şu an 0.3).
- Daha doğal tetikleme için vox pozitif sayısını artır / gerçek insan kayıtları ekle.
