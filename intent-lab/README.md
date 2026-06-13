# intent-lab

Mate Obsidian için **niyet sınıflandırma** sandbox'ı. Üç sınıf:
- **eylem** — komut, istek ("ışıkları aç", "10 dk sonra hatırlat")
- **soru** — bilgi sorgusu ("hava nasıl?", "klima kaç derecede?")
- **sohbet** — selamlama, duygu, kısa onay ("merhaba", "yoruldum", "tamam")

Yaklaşım: **multilingual-e5-small + cosine similarity** (nearest neighbor).
`intents.py`'deki örnekler embedding'e çevrilir; yeni cümle gelince her sınıfın
en yakın örneği bulunur, kazanan en yüksek skorlu sınıftır. `margin` (top −
runner-up) güven göstergesidir; düşükse `abstain=True` işaretlenir.

Daha önce **yeniguno BERT** (kırık İngilizce tokenizer, %63), **Qwen2.5-0.5B**
(0.5B instruction-following yetersiz, %50), **mDeBERTa zero-shot** (NLI
hipotez ambiguity, %43) denendi; üçü de E5'in %90'ını yenemedi. Bilinçli
olarak çıkarıldılar.

`mate-obsidian/` ve `mate-core/` kodlarına dokunmaz — kardeş klasör olarak
yaşar, hazır olduğunda module olarak import edilir.

## Sentetik dataset

`dataset.json` — 3 persona × 300 cümle = **900 utterance**:

| Persona | Profil | eylem | soru | sohbet |
|---|---|---|---|---|
| **baba** | Çalışan, haber/spor/araba odaklı, hafif resmi | 130 | 110 | 60 |
| **anne** | Çalışan, mutfak/aile/program odaklı, sıcak dil | 130 | 110 | 60 |
| **kiz** | 14 yaş ergen, müzik/oyun/sosyal medya, slang | 130 | 110 | 60 |

Mate'in gerçek voice logları henüz yok; bu set "üç kişilik aile bir voice
asistanı kullansa neler söyler?" sorusunu sentetik olarak modelliyor.

## Kurulum + çalıştırma

```bash
./run.sh                                  # tüm 900 cümle üzerinde eval
./run.sh "salondaki ışığı aç"             # tek cümle CLI

# Filtrelenmiş eval
python tests/eval.py --persona kiz        # sadece kız persona
python tests/eval.py --intent sohbet      # sadece sohbet sınıfı
python tests/eval.py --persona anne --intent eylem
python tests/eval.py --errors             # sadece yanlış sınıflandırmaları
```

İlk seferde `.venv` kurulur ve E5 modeli HuggingFace'ten çekilir (~470MB,
`~/.cache/huggingface/` altına gider).

## Dosyalar

| dosya              | iş                                                  |
| ------------------ | --------------------------------------------------- |
| `intents.py`       | E5 training örnekleri (sınıf başına ~20 cümle)      |
| `classifier.py`    | `IntentClassifier` — E5 + cosine similarity          |
| `dataset.json`     | 900 utterance (3 persona × 300), eval set            |
| `cli.py`           | `python cli.py "metin"` tek cümle test               |
| `tests/eval.py`    | dataset.json üzerinde detaylı eval + persona/intent kırılımı |
| `requirements.txt` | sentence-transformers, numpy                         |
| `run.sh`           | venv + deps + eval/cli kısayolu                      |

## Eval çıktısı (örnek)

```
GENEL DOĞRULUK: 810/900 = 90.0%  (abstain: 78)

PERSONA BAZINDA:
  anne : 273/300 = 91.0%
  baba : 280/300 = 93.3%
  kiz  : 257/300 = 85.7%

INTENT BAZINDA:
  eylem : 365/390 = 93.6%
  soru  : 305/330 = 92.4%
  sohbet: 140/180 = 77.8%

CONFUSION MATRIX (satır=gerçek, sütun=tahmin):
           eylem      soru    sohbet
  eylem      365        18         7
  soru        15       305        10
  sohbet      30        10       140
```

## Mate Obsidian'a entegrasyon yolu

```python
from intent_lab.classifier import IntentClassifier
from intent_lab.intents import INTENTS

clf = IntentClassifier()
clf.fit(INTENTS)

pred = clf.classify(user_utterance, reject_below_margin=0.03)
if pred.abstain:
    # Belirsiz — kullanıcıya geri sor: "Bunu nasıl yapayım, bilgi mi istiyorsun?"
    ...
elif pred.label == "sohbet":
    # Pi'siz template cevap (token tasarrufu)
    ...
elif pred.label == "soru":
    # Pi'ye query mode'da gönder
    ...
else:  # eylem
    # task vault'a Pending/ altında yaz
    ...
```

## Geliştirme notları

- E5 simetrik benzerlik için iki tarafta da `query: ` öneki ister
  (`classifier.py` içinde yapılıyor).
- `intents.py` E5'in indeksleyeceği training set — değişirse model
  performansı değişir. `dataset.json` ise hold-out (eval-only).
- Margin eşiği (`REJECT_BELOW = 0.03`) eval sonuçlarındaki abstain
  oranıyla ayarlanabilir. Düşük → daha çok belirsiz; yüksek → daha az
  belirsiz ama daha çok hatalı yüksek-güven kararı.
- Yeni intent eklemek için: `intents.py`'a anahtar ekle (örn. `"vazgec"`),
  10-20 Türkçe örnek yaz. Yeniden eğitim gerekmez.
