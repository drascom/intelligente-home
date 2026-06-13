# STT adayı: nvidia/nemotron-3.5-asr-streaming-0.6b

*Araştırma tarihi: 2026-06-13. Karar: **şimdilik faster-whisper large-v3-turbo'da
kal**; Linux GPU sunucusu kurulurken bu modelle gerçek ev kayıtları üzerinde A/B
testi yap.*

## Özet

Cache-aware FastConformer (24 katman) + RNNT decoder, 600M parametre, tek
checkpoint 40 dil. 4 Haziran 2026'da çıktı. Lisans: OpenMDW-1.1 (açık ağırlık,
ticari kullanım serbest). Girdi mono ses (bizim 16kHz s16le hattıyla uyumlu),
çıktı noktalama + büyük/küçük harfli metin.

**Türkçe (tr-TR) en iyi katmanda** ("transcription-ready", 19 dil) — model
kartından doğrulandı. Dil `target_lang` prompt'u ile seçiliyor; NVIDIA yanlış
etiketin kaliteyi sert düşürdüğünü söylüyor → **tr-TR hardcode et, auto
kullanma.**

## Whisper'a karşı durum

| | Nemotron 3.5 0.6B | faster-whisper large-v3-turbo (bizdeki) |
|---|---|---|
| Türkçe WER (FLEURS) | %11.17 (1.12s ayarı) | large-v3 ~%8-10 bandı (turbo biraz daha kötü) — yaklaşık |
| Gecikme | gerçek streaming, 80ms–1.12s ayarlanabilir; sustuğunda transkript hazır | segment bitince toplu çözüm (M4 CPU'da 7.2s ses → 2.2s) |
| Halüsinasyon | RNNT yapısal olarak çok az üretir | gürültüde uyduruyor (brain'de `looks_hallucinated` filtresi gerekti) |
| Partial transkript | bedava | yok |
| VRAM | ~1.5-2GB (fp16, tahmini) | turbo ~6GB |

- Resmi Whisper karşılaştırması yayınlanmamış; Türkçe rakamlar FLEURS (temiz
  okuma cümleleri) üzerinden. Bizim senaryo (kısa komut, uzak mikrofon, TV
  gürültüsü) farklı — fark kapanabilir, tersine de dönebilir. **Kendi
  kayıtlarımızla test şart.**
- Düşük gecikme ayarlarında (80–320ms) doğruluk düşüyor; Türkçe'ye özgü kayıp
  yayınlanmamış — düşük gecikmeye geçmeden kontrol et.
- Fine-tune birinci sınıf yol: NVIDIA blog'u kamu verisiyle ~%30 görece WER
  iyileşmesi gösteriyor, tek GPU yetiyor. Taban kalite yetmezse Türkçe Common
  Voice fine-tune gerçekçi bir rota.

## Nasıl çalıştırılır

- **Önerilen: sherpa-onnx** — maintainer master'da desteklendiğini doğruladı
  (HF discussion #1); topluluk ONNX export'u da var. Python binding'i Mac
  CPU'da (dev) ve Linux CPU/CUDA'da aynı kodla çalışır.
- Resmi yol NeMo 26.06 (Linux + NVIDIA GPU); Mac'te önerilmez. NIM konteyneri
  duyuruldu ama henüz yok; Riva entegrasyonu doğrulanmadı. HF transformers
  pipeline'ı YOK (NeMo/ONNX'e özel mimari).
- CoreML çevirisi mevcut (FluidInference) ama Türkçe "full-vocabulary"
  varyantına düşüyor ve 2s altı katmanlarda zayıf; Swift tarafı olduğu için
  bizim Python brain'e uygun değil — sadece "Apple donanımında çalışıyor"
  kanıtı olarak not.

## Entegrasyon planı (yapılacaksa)

sherpa-onnx online-recognizer API'si (create stream / accept_waveform /
partial / finalize) brain'deki `WhisperSession` modeline (start/feed/finish)
birebir oturuyor. Aynı Wyoming arayüzünün arkasına ikinci bir STT backend'i
olarak koy (`STT_ENGINE=whisper|nemotron` gibi), gerçek ev sesiyle A/B yap.
Tahmini iş: 1-2 gün.

## Riskler

- Türkçe doğruluk bugün muhtemelen whisper'ın gerisinde — bir numaralı
  kriterimiz buydu.
- Model çok yeni (~1 hafta); NVIDIA WER iyileştirmelerinin sürdüğünü söylüyor,
  checkpoint revizyonları beklenir. sherpa-onnx desteği master'da, etiketli
  sürümde olmayabilir.
- Türkçe code-switching / uzun ses davranışı hakkında veri yok (15s segment
  sınırımız için sorun değil).

## Kaynaklar

- Model kartı: https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b
- ONNX/sherpa-onnx tartışması: https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b/discussions/1
- Fine-tune blog'u: https://huggingface.co/blog/nvidia/fine-tuning-nemotron-35-asr
- CoreML çevirisi: https://huggingface.co/FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML
- İngilizce kardeş model: https://huggingface.co/nvidia/nemotron-speech-streaming-en-0.6b
