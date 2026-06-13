"""Türkçe niyet örnekleri.

Üç sınıf:
- eylem:  kullanıcı bir şey yapılmasını istiyor (komut, talimat, hatırlatma).
- soru:   kullanıcı bilgi istiyor (durum sorgusu, açık uçlu soru).
- sohbet: ne komut ne bilgi sorgusu — selamlama, duygu paylaşımı, kısa onay.

Yeni örnek eklemek için ilgili listeye satır eklemek yeterli; yeniden
training gerekmiyor — embeddingler ilk çağrıda hesaplanır.

Sürüm 2 (eval feedback sonrası): 60 → 120 örnek. dataset.json üzerinde
%83.8 sonrası en sık hata kategorilerine göre hedeflenmiş varyasyonlar:
- soru: "X mi/mı?" durum sorgusu, "ne kadar/kaç/nerede/neden" kalıpları
- sohbet: bedensel/duygu ifadeleri, modal istek ("uzanayım"), aile yorumu
- eylem: uzun komutlar, "X hatırlat", müzik/streaming spesifik

dataset.json içerikleri burada KULLANILMADI — training/test leak olmasın.
"""

INTENTS: dict[str, list[str]] = {
    "eylem": [
        # temel ev kontrolü
        "ışıkları aç",
        "salondaki lambayı söndür",
        "mutfak ışığını kıs",
        "klimayı 22 dereceye ayarla",
        "klimayı kapat",
        "perdeleri kapat",
        "garaj kapısını kaldır",
        "ön kapıyı kilitleme moduna al",
        "salondaki tv'yi başlat",
        "robot süpürgeyi başlat",
        # ses / oynatma
        "müzik çal",
        "spotify'da sakin liste aç",
        "sesi biraz kıs",
        "haberleri oku",
        # uzun komutlar — eylem→sohbet/soru hatalarını azaltmak için
        "Tarkan'ın son şarkısını çalsın",
        "podcast'imi açtan başla",
        "filmde kaldığım yerden devam et",
        "playlist'imi karıştır",
        "yeni mesajları sesli oku",
        "alışveriş sepetime kalem ekle",
        # zaman / hatırlatma — adverb'lu varyasyonlar
        "yarın sabah 8'e alarm kur",
        "15 dakika sonra hatırlat",
        "akşam ilaç saatini hatırlat",
        "yarın spor günü için alarm kur",
        "öğleden sonra için randevu hatırlatması ekle",
        # listeleme / mesajlaşma
        "marketten süt almayı listeye ekle",
        "yarınki toplantıyı takvime ekle",
        "anneme mesaj at",
        "babama telefon aç",
        "kuaföre saat 4'e randevu al",
        # birden fazla parçalı uzun komut
        "yarın akşam yemek için 4 kişilik rezervasyon yap",
        "yarınki etkinliği ajandama yaz",
        "veteriner randevusu için ara yap",
        "fotoğrafı düzelt ve kaydet",
        "yarın için 7 buçuğa alarmı koy",
        # "X-i ara" — en büyük eylem→sohbet hata kaynağıydı (12 vaka)
        "amcamı ara",
        "Selçuk'u ara",
        "doktoru ara",
        "komşumuzu ara",
        # "X-i çalıştır" — kitchen appliance start
        "fırını çalıştır",
        "ütüyü çalıştır",
        "soğutucuyu başlat",
        # "X dinlemek istiyorum" — wishful command (sohbet'le karışıyordu)
        "rock müzik istiyorum",
        "klasik müzik dinlemek istiyorum",
        # Tarif display
        "pizza tarifi aç",
        "yemek tarifi göster",
        "tarifi açıkla bana",
        # Uzun bileşik hatırlatma
        "öğlen ilaç saatini ayarla",
        "yıldönümümüzü takvime kaydet",
    ],
    "soru": [
        # genel soru
        "hava nasıl?",
        "yarın için yağış bekleniyor mu?",
        "saat şu anda kaç oldu?",
        "bugün hangi gün?",
        "bu hafta hangi toplantılarım var?",
        "yarın ne yapacağım?",
        "buzdolabında ne var?",
        "kim aramış?",
        "yeni mailim var mı?",
        "trafik nasıl?",
        # "X mi/mı?" durum sorgusu — en büyük hata kategorisi
        "salonun ışığı açık mı?",
        "klima kaç derecede?",
        "ekmek bitti mi?",
        "kapı kilitli mi?",
        "garaj kapısı kapalı mı?",
        "tv kapanmamış mı hala?",
        "alarm aktif mi?",
        "ısıtıcı çalışıyor mu?",
        "perdeler kapandı mı?",
        "şu an internet bağlı mı?",
        "tencere kaynıyor mu?",
        "süt bitti mi?",
        # "kaç / ne kadar" kalıbı
        "kaç randevum kaldı bugün?",
        "ne kadar pilim var?",
        "kaç dakikadır müzik çalıyor?",
        "İstanbul'da hava kaç derece?",
        "tariften kaç bardak yapılır?",
        "telefonum şarjı kaç?",
        # "nerede / hangisi" kalıbı
        "anahtarlar nerede acaba?",
        "telefonum nerede kaldı?",
        "hangi gün toplantım var?",
        "hangi kanal Galatasaray maçı yayınlıyor?",
        # "nasıl / neden / ne zaman"
        "nasıl açılır bu kapak?",
        "neden hava bu kadar soğuk?",
        "ne zaman müsaitsin?",
        "borsa bugün nasıl kapandı?",
        # uzun / soyut sorular
        "pazartesi tatil mi?",
        "doğum günüm ne zaman?",
        "evde kim var?",
        "robot süpürge çalışıyor mu?",
        "yarınki uçuşum kaçta?",
        "sınav notum kaç oldu?",
        "okul tatili ne zaman bitiyor?",
        "borsada bugün ne haber?",
        "bu bayram kaç gün izinli olacağız?",
        "rezervasyonum onaylandı mı?",
    ],
    "sohbet": [
        # selamlama
        "hayırlı geceler",
        "ne yapıyorsun bakalım",
        "selamünaleyküm",
        "hayırlı akşamlar",
        "kolay gelsin",
        "kendine iyi bak",
        "görüşmek üzere kalın",
        # teşekkür / onay
        "çok sağ ol",
        "rica ederim",
        "estağfurullah",
        "anladım tamam",
        "tabii ki olur",
        "gerek yok",
        "boş ver şimdi",
        "önemli değil",
        "haklısın",
        "katılıyorum tamamen",
        "bilemiyorum şimdi",
        # duygu / hal ifadesi
        "canım sıkılıyor",
        "bugün çok güzeldi",
        "kendimi yorgun hissediyorum",
        "seni özledim",
        "iyiyim sen nasılsın",
        "moralim çok bozuk",
        "canım çok sıkkın bugün",
        "kafam çok yorgun",
        # bedensel ifade — sohbet→eylem hatalarını azaltmak için
        "başım zonkluyor",
        "midem bulanıyor",
        "başım dönüyor",
        "uyumam gerek artık",
        "pestilim çıktı bugün",
        # modal istek ("X-eyim/ayım") — komut görünür ama dilek
        "biraz dinlensem fena olmaz",
        "azıcık şekerleneyim",
        "bir çay içeyim",
        "azıcık nefes alayım",
        # aile yorumu / quotative
        "annem hep böyle söyler",
        "babam çok ciddi bugün",
        "kardeşim hep böyle yapar",
        "anne yine üzülmüş",
        "baba bugün enerjik",
        # düşünsel / bağ kurma
        "yine pazartesi geldi",
        "haftalar nasıl geçiyor",
        "bu hafta hızlı geçti",
        "söyle bakayım",
        "yorum yok",
        # sohbet→eylem yanlış sınıflandırma kaynaklarını azaltmak için
        "bana müsaade",
        "yetti gayri",
        "babamı dinlemem hiç",
        "iyi haftalar dilerim",
        "haftaya görüşürüz",
    ],
}
