# Modeller (gitignore'lu)

Büyük ONNX dosyaları repoya commit edilmez (`.gitignore`: `mate-brain/models/*.onnx`),
release'ten indirilir.

## Speaker-ID — 3D-Speaker CAM++ (192-dim, ~27 MB)

```bash
curl -fSL -o models/campplus.onnx \
  https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx
```

`brain.env` / `.env`:
```
SPEAKER_ID_ENABLED=true
SPEAKER_MODEL_PATH=models/campplus.onnx
```

Bağımlılık: `sherpa-onnx`, `soundfile` (brain `requirements.txt`'te).
