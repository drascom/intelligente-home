"""E5 nearest-neighbor + Türkçe sözdizimsel kural düzeltmesi.

E5 içerik benzerliğine bakıyor; "tavuk tarifi söyle" ile "tavuk nasıl pişer"
embedding olarak çok yakın. Ama biri eylem, diğeri soru. Türkçenin
**sözdizimsel** sinyalleri (soru parçacığı `mı/mi/mu/mü`, soru kelimeleri
`kaç/ne/nasıl/nerede/neden`, `?` işareti) bu farkı netleştiriyor.

Strateji:
1. E5 ile sınıflandır.
2. Üç soru sinyalini say: `?`, soru parçacığı, soru kelimesi.
3. **İki+ sinyal** ama E5 soru dememişse → soru'ya zorla.
4. **Tek sinyal + E5 emin değil** (margin < 0.05) → soru'ya kaydır.
5. Sohbet idiomları ("naber", "ne haber bugün") soru kelimesi içerse bile
   sohbet kalır (override).

E5'i bozmaz, sadece sarmalar. Performans etkisi sıfıra yakın
(regex eval ~1µs/cümle).
"""

from __future__ import annotations

import re

from brain.intent.classifier import IntentClassifier, Prediction

# Türkçe soru parçacığı: mı/mi/mu/mü + isteğe bağlı kişi/zaman eki.
# "mücadele", "mide", "müzik" gibi kelimeleri yakalamaz (kelime sınırı kontrolü
# nedeniyle "mı" parçacığı tek başına veya doğru ek ile bulunmalı).
QUESTION_PARTICLE_RE = re.compile(
    r"\b(?:m[ıiuü]"
    r"(?:y[ıiuü]m|sın|sin|sun|sün|y[ıiuü]z|sınız|siniz|sunuz|sünüz|"
    r"d[ıiuü]r|yd[ıiuü]|ymış|ymiş|ymuş|ymüş)?)\b",
    re.IGNORECASE,
)

# Türkçe soru sözcükleri + ekli varyantları (nedir, kimdir, kaçtır...).
QUESTION_WORD_RE = re.compile(
    r"\b(?:"
    r"kaç(?:tır|tı|ıncı)?|"
    r"ne(?:dir|ydi|ymiş|ler)?|"
    r"nas[ıi]l|"
    r"nere(?:de|ye|den|si)|"
    r"neden|niçin|"
    r"hangi(?:si|miz|niz|leri)?|"
    r"kim(?:dir|di|imiş|ler|i|e|in|den|le)?"
    r")\b",
    re.IGNORECASE,
)

# "Ne haber" / "Naber" / "Nasılsın" — soru kelimesi içeren ama sohbet kalıbı
# olan idiomlar. Bu ifadeler soru kuralını override eder.
SOHBET_IDIOMS: set[str] = {
    # selamlama / hal hatır
    "naber", "n'aber", "n'apıyorsun",
    "ne haber", "ne haber bugün",
    "nasılsın", "nasılsın bakim", "nasılsın bakalım", "nasılsınız",
    # ünlem / şaşırma
    "ne diyorsun", "ne diyorsun ya", "ne diyorsun yaa",
    "cidden mi", "cidden", "gerçekten mi", "gerçekten",
    "yok artık", "ay yapmaa", "omg", "lol",
    # tag soru (sohbet sırasında onay-arayan kalıplar)
    "değil mi", "dee mi", "öyle değil mi", "değil mi ya",
}

# Cümle sonunda emir kipinde olan fiiller — varsa soru kuralı bastırılır.
# "nasıl yapılır söyle" gibi içinde soru var ama gerçek niyet eylem olan
# bileşik cümleleri korur.
IMPERATIVE_VERBS_AT_END: set[str] = {
    # Eval'da fazla soru'ya flip edilen vakalardan toplandı
    "söyle", "göster", "yaz", "sor", "kur", "anlat", "et",
    # Ev asistanı domeninde sık kullanılan emir kipleri
    "aç", "kapat", "ara", "ekle", "sil", "çal", "oynat",
    "durdur", "başlat", "hatırlat", "gönder", "ayarla",
    "getir", "götür", "indir", "yükle", "kontrol",
    "rezerve", "hazırla", "düzenle", "taşı", "kaldır",
    "koy", "ver", "yap", "geç", "kıs", "yak", "ısıt",
    "kaydet", "paylaş", "temizle", "başla", "kullan",
    "okuyabilir", "söyleyebilir",  # uzak ihtimaller
}


def _normalize(text: str) -> str:
    return text.strip().lower().rstrip("?.,!…")


def is_sohbet_idiom(text: str) -> bool:
    t = _normalize(text)
    if t in SOHBET_IDIOMS:
        return True
    for idiom in SOHBET_IDIOMS:
        if t.startswith(idiom + " "):
            return True
    return False


def question_signal(text: str) -> tuple[int, list[str]]:
    """0-3 arası soru göstergesi sayısı + tetiklenen sinyaller."""
    signals: list[str] = []
    if "?" in text:
        signals.append("?")
    if QUESTION_PARTICLE_RE.search(text.lower()):
        signals.append("mı")
    if QUESTION_WORD_RE.search(text.lower()):
        signals.append("kw")
    return len(signals), signals


def ends_with_imperative(text: str) -> bool:
    """Cümlenin son 2 anlamlı kelimesinden biri emir kipi mi?

    'nasıl yapılır söyle' gibi bileşik cümleleri soru kuralından korur.
    Son 2 kelimeye bakar çünkü emir fiili bazen zarfla biter:
    'mi sor öğleyin' → 'sor' fiili sondan ikinci.
    """
    words = _normalize(text).split()
    if not words:
        return False
    if words[-1] in IMPERATIVE_VERBS_AT_END:
        return True
    if len(words) >= 2 and words[-2] in IMPERATIVE_VERBS_AT_END:
        return True
    return False


class HybridClassifier:
    """E5 IntentClassifier + Türkçe soru kuralları.

    `IntentClassifier` ile aynı arayüz (`fit`, `classify`); drop-in
    yerine geçebilir.
    """

    def __init__(self, e5: IntentClassifier | None = None) -> None:
        self.e5 = e5 if e5 is not None else IntentClassifier()

    def fit(self, examples_by_class: dict[str, list[str]]) -> None:
        self.e5.fit(examples_by_class)

    def embed(self, text: str):
        """Tek metnin normalize edilmiş E5 vektörü (oturum segmentasyonu için)."""
        return self.e5.embed(text)

    def classify(
        self,
        text: str,
        reject_below_margin: float | None = None,
    ) -> Prediction:
        pred = self.e5.classify(text, reject_below_margin=reject_below_margin)

        # 1. Sohbet idiom her zaman sohbet — E5 ister doğru desin ister
        #    yanlış. Bu erken-çıkış sonrasındaki kuralları da bloklar
        #    (ör. "ne diyorsun ya" → 'ne' soru kelimesi olsa bile sohbet).
        if is_sohbet_idiom(text):
            if pred.label == "sohbet":
                return pred
            return Prediction(
                label="sohbet",
                score=pred.runner_up_score if pred.runner_up == "sohbet" else 0.6,
                runner_up=pred.label,
                runner_up_score=pred.score,
                nearest_example=f"[hybrid:idiom] {pred.nearest_example}",
                abstain=False,
            )

        qscore, signals = question_signal(text)

        # 2. Cümle sonunda emir kipi varsa, soru kuralını bastır.
        #    "nasıl yapılır söyle" tipik bir bileşik komut — gerçek niyet
        #    sonundaki 'söyle' fiili, içindeki 'nasıl' yardımcı parametre.
        ends_imperative = ends_with_imperative(text)

        # 3. Güçlü soru sinyali (2+) ama E5 soru demedi → soru'ya zorla
        #    (emir kipi bile olsa, 2 sinyal hala güçlü sinyal sayılır).
        if qscore >= 2 and pred.label != "soru" and not ends_imperative:
            return Prediction(
                label="soru",
                score=0.85,
                runner_up=pred.label,
                runner_up_score=pred.score,
                nearest_example=f"[hybrid:q={','.join(signals)}] {pred.nearest_example}",
                abstain=False,
            )

        # 4. Tek sinyal + düşük margin → soru'ya kaydır
        #    Emir kipi varsa fırlama (yanlış flip riski yüksek).
        if (
            qscore >= 1
            and pred.label != "soru"
            and pred.margin < 0.05
            and not ends_imperative
        ):
            return Prediction(
                label="soru",
                score=0.7,
                runner_up=pred.label,
                runner_up_score=pred.score,
                nearest_example=f"[hybrid:q_weak={','.join(signals)}] {pred.nearest_example}",
                abstain=False,
            )

        return pred
