# VoxCPM2 — Türkçe Sesli Kitap & Seslendirme Sistemi

Uzun metinleri (özellikle Türkçe kitapları) yapay zekâ ile sese dönüştüren sistem.
Mac'te (Apple Silicon / MPS) çalışır.

---

## 1. Sistem nasıl kuruldu?

- **Model:** [openbmb/VoxCPM2](https://huggingface.co/openbmb/VoxCPM2) — 2B parametreli,
  30 dil destekli (Türkçe dâhil), 48 kHz çıkışlı metin-konuşma modeli.
- **Ortam:** `.venv/` adlı bir Python sanal ortamı (Python 3.12).
- **Cihaz:** Apple GPU (**MPS**). CUDA gerektirmez ama Mac'te NVIDIA'ya göre
  yavaştır (yaklaşık **1.5 sn üretim / 1 sn ses**).
- **Model konumu:** `~/.cache/huggingface/hub/models--openbmb--VoxCPM2` (~4.6 GB, indirildi).

### Sıfırdan kurulum (gerekirse)

```bash
cd /Users/drascom/work/voxcpm2
python3 -m venv .venv
source .venv/bin/activate
pip install --upgrade pip
pip install voxcpm soundfile gradio
```

### Modeli indirme

Model ilk kullanımda otomatik iner. Bağlantı koparsa diye dayanıklı indirici:

```bash
bash _robust_dl.sh        # kaldığı yerden devam eder, kopmalara karşı yeniden dener
```

> **Not:** İnternet bağlantısı değişince HuggingFace'in "Xet" indiricisi takılıyor.
> Çözüm `_robust_dl.sh` içinde hazır: `HF_HUB_DISABLE_XET=1` + 30 sn zaman aşımı + otomatik yeniden deneme.

---

## 2. Klasördeki dosyalar

| Dosya | Görevi |
|---|---|
| `app.py` | **Gradio web arayüzü** (metin/dosya → ses, ses klonlama). En kolay kullanım. |
| `audiobook.py` | Komut satırından uzun metin → tek `.wav` sesli kitap. Otomatik cümle bölme. |
| `epub2txt.py` | EPUB → düz metin çıkarıcı (bölüm sırasına saygılı, harici bağımlılık yok). |
| `_smoketest.py` | Hızlı test: İngilizce + Türkçe birer örnek üretir. |
| `_robust_dl.sh` | Bağlantı kopmalarına dayanıklı model indirici. |
| `zaman_uzerine_full.txt` | "Zaman Üzerine" kitabının tam metni (örnek). |
| `zaman_sample.wav` | Üretilmiş Türkçe deneme sesi. |

---

## 3. Nasıl çalıştırılır?

Her komuttan önce ortamı aktifleştir:

```bash
cd /Users/drascom/work/voxcpm2
source .venv/bin/activate
```

### A) Web arayüzü (önerilen)

```bash
python app.py            # sadece bu bilgisayar:  http://localhost:7860
python app.py --share    # public link (profesör/uzaktan test için, ~1 hafta geçerli)
```

Arayüzde:
- Metni yapıştır **veya** `.txt` / `.epub` dosyası yükle
- İstersen 5–15 sn'lik referans ses yükleyip o sesi **klonla**
- Gelişmiş ayarlar: `cfg` (ifade), `timesteps` (kalite/hız), parça boyutu
- **🔊 Seslendir** → tüm sesi üretir, sonunda **indirilebilir tam dosya** verir
- **🔴 Canlı Seslendir (Stream)** → ses parçaları üretildikçe **anında çalmaya başlar**
  (tüm metnin bitmesini beklemez; otomatik oynatma açık)

> Public link sadece arayüzü paylaşır; işlem senin Mac'inde çalışır.
> Mac uyursa veya `app.py` kapanırsa link çalışmaz.

### B) Komut satırı — tek metin/bölüm

```bash
python audiobook.py zaman_sample.txt -o cikti.wav

# Ses klonlama ile:
python audiobook.py kitap.txt -o kitap.wav \
  --reference ses_ornegi.wav --ref-text "Kayıttaki cümlenin tam metni."
```

Ayarlar: `--cfg 2.0` `--timesteps 10` `--max-chars 300` `--gap-ms 300`

### C) EPUB'dan metin çıkarma

```bash
python epub2txt.py kitap.epub -o kitap.txt                 # tam metin
python epub2txt.py kitap.epub -o ornek.txt --max-chars 1300 # kısa örnek
```

---

## 4. Tam kitap seslendirme (önemli)

"Zaman Üzerine" ≈ **542.000 karakter** → tahmini **~10 saat ses**, **~16 saat render**.

Bu yüzden **bölüm bölüm** seslendirmek önerilir:
1. `epub2txt.py` ile metni çıkar.
2. Bölümlere ayır (her bölüm ayrı `.txt`).
3. Her bölümü `audiobook.py` ile ayrı `.wav` yap.
4. Aynı `--reference` ile tüm bölümlerde **aynı sesi** koru.

Bu sayede bir çökme tüm işi kaybettirmez ve ilerlemeyi takip edebilirsin.

---

## 5. Gerçek zamanlı (streaming) seslendirme

VoxCPM2, sesi parça parça üreten `generate_streaming()` metodunu destekler.
Tüm metnin bitmesini beklemeden ilk parça gelir gelmez oynatmaya başlar — **gecikme düşer**.

### Arayüzde
- **🔴 Canlı Seslendir (Stream)** butonu → "Canlı ses" oynatıcısında anında çalmaya başlar.

### Komut satırı / kendi kodunda

```python
from voxcpm import VoxCPM
model = VoxCPM.from_pretrained("openbmb/VoxCPM2", load_denoiser=False,
                               optimize=False, device="mps")

for chunk in model.generate_streaming(
    text="Bu, gerçek zamanlı seslendirme örneğidir.",
    cfg_value=2.0, inference_timesteps=10,
    # reference_wav_path="ses.wav",   # opsiyonel: ses klonlama
):
    # chunk = numpy ses parçası — oynat veya ağ üzerinden gönder
    ...
```

> **Mac sınırı:** Bu bilgisayarda üretim sesten biraz yavaş (RTF ~1.5).
> Streaming ilk sesin gelme gecikmesini azaltır ama uzun cümlelerde aralarda
> küçük takılmalar olabilir. Kesintisiz uzun dinleme için normal **🔊 Seslendir**
> + indir daha pürüzsüzdür. (NVIDIA GPU'da RTF ~0.3 ile sorunsuz canlı yayın olur.)

---

## 6. Sık karşılaşılan durumlar

- **İlk seslendirme yavaş:** Model belleğe yükleniyor (~15 sn). Sonrası hızlanır.
- **`bfloat16 -> float32` uyarısı:** Normal. MPS bfloat16 desteklemediği için otomatik dönüşüm.
- **`torch.compile disabled` uyarısı:** Normal. Optimizasyon yalnız CUDA'da; Mac'te kapalı.
- **İndirme takılırsa:** `bash _robust_dl.sh` çalıştır (kaldığı yerden devam eder).

---

## 7. Teknik özet

- Python 3.12 · PyTorch 2.12 · VoxCPM 2.0.3 · Gradio 6.14
- Cihaz: MPS (Apple GPU), dtype float32
- Çıkış: 48 kHz WAV
