# Mate. — Apple Watch & CarPlay Uygulama Planı

> Durum: Planlama (henüz kod yazılmadı). Sonra ele alınacak.
> Hazırlanma tarihi: 2026-05-20

## Özet

Mevcut iOS uygulaması (SwiftUI, iOS 16+, tek hedef `uk.drascom.mate`) hem Apple
Watch hem de CarPlay'e taşınabilir. "Aynı uygulamayı kopyala" değil; her platform
için ayrı bir Xcode hedefi (target) eklenir. Çekirdek mantık (network + ses)
zaten UI'dan büyük ölçüde ayrık olduğu için zemin uygun. Asıl iş, paylaşılan
çekirdeği ayırmak ve `ConversationManager`'ı ayrıştırmak.

---

## Faz 0 — Ortak çekirdeği ayır (her iki platform için ön koşul)

Çekirdek mantık şu an iOS app hedefinin içinde; Watch/CarPlay paylaşamaz. Önce
local bir **`MateCore` Swift Package** oluşturulur.

**MateCore'a taşınacaklar (UI'dan bağımsız, hazır):**
- `APIClient.swift` — tüm network (STT/TTS/bridge), olduğu gibi
- `AudioPipeline.swift`, `AudioRecorder.swift`, `AudioPlayer.swift` — ses motoru
- `OnDeviceSpeech.swift`, `WakeWordDetector.swift`
- `Settings.swift`

**Kritik ayrıştırma — `ConversationManager` (809 satır):**
Cihaz-bağımsız mantık (VAD, durum geçişleri, barge-in, çok-turlu konuşma) ile
UI'a özel şeyler (Türkçe durum etiketleri, görsel state) karışık. İkiye böl:
- `ConversationEngine` → MateCore içinde, platform-bağımsız
- `ConversationViewModel` → her platformun kendi UI'ına özel ince katman

> En riskli / en çok zaman alan kısım budur. Watch ve CarPlay'in değeri buna bağlı.
>
> Çıktı: `MateCore` iOS hedefinde çalışıyor, davranış birebir aynı (regresyon yok).

---

## Faz A — Apple Watch (watchOS hedefi)

**Hedef cihaz:** Series 9+ (yerleşik mikrofon). Önerilen: watchOS 10+.

**Etkileşim modeli — push-to-talk (sürekli wake word DEĞİL):**
Sürekli "candan" dinleme Watch'ta pil/sistem kısıtları yüzünden pratik değil.
Akış: butona bas → konuş → STT → bridge `/chat` → TTS → çal.

**Ses:**
- Watch mikrofonundan kayıt → mevcut `APIClient` ile aynı sunuculara gider
  (network katmanı aynen çalışır).
- Çıkış: Watch hoparlörü veya AirPods. `RoutePickerView` watchOS'ta yok → sabit çıkış.
- Barge-in (TTS kesme) Watch'ta daha az güvenilir olabilir; ilk sürümde kapalı önerilir.

**UI:** Tek ekran — büyük "Konuş" butonu, dinleme/cevap durumu, son transcript.
Orb/equalizer animasyonları sadeleştirilir.

**Ayarlar:** İlk sürümde basit tut — sunucu adresleri Watch'a senkron/sabit.
Sonra `WatchConnectivity` ile iPhone'dan çekilebilir.

**Apple onayı:** Gerekmez. Hemen geliştirilebilir.

---

## Faz B — CarPlay (CarPlay hedefi/entitlement)

**Ön koşul — Apple entitlement başvurusu:**
CarPlay özel app'ler entitlement gerektirir. Communication/voice app olduğumuz için
`com.apple.developer.carplay-communication` (veya audio kategorisi) başvurusu lazım.
Apple onayı **günler/haftalar** sürebilir — erken başlat.

**UI kısıtı (önemli):**
CarPlay özel çizime izin vermez; sadece Apple'ın hazır şablonları (liste, grid,
bilgi panosu). Orb/animasyon yok. Tasarım: tek "Konuş" aksiyonlu basit şablon +
durum metni.

**Ses:** Mikrofon CarPlay'de otomatik telefon ses motoruna yönlenir → mevcut
`AudioPipeline` çalışır.

**Wake word:** CarPlay bağlamında Siri/direksiyon butonu ile tetikleme önerilir;
sürekli dinleme yerine buton kısayolu.

---

## Önerilen sıra ve kaba efor

| Faz | İş | Tahmini |
|---|---|---|
| 0 | MateCore + `ConversationManager` ayrıştırma | ~2-3 hafta (en kritik) |
| A | Apple Watch hedefi (push-to-talk) | ~2-3 hafta |
| B | CarPlay hedefi | ~1-2 hafta + Apple onay süresi (paralel başlat) |

---

## Netleştirilecek açık kararlar

1. **Watch ses stratejisi:** Watch kendi mikrofonu mu (yalnız S9+), yoksa iPhone
   üzerinden relay mi? (S9+ ile sınırlamak çok daha basit.)
2. **Hedef sürümler:** watchOS 10+ ve CarPlay için iOS 17+ uygun mu?
3. **Ayar senkronizasyonu:** Watch ayarları iPhone'dan mı gelsin?
4. **CarPlay entitlement** başvurusunu erkenden yapmak gerekir mi?

---

## İlgili dosyalar (referans)

- Network: `Mate/APIClient.swift`
- Ses: `Mate/AudioPipeline.swift`, `Mate/AudioRecorder.swift`, `Mate/AudioPlayer.swift`
- Konuşma mantığı: `Mate/ConversationManager.swift` (ayrıştırılacak)
- Ayarlar: `Mate/Settings.swift`
- On-device STT/TTS: `Mate/OnDeviceSpeech.swift`, `Mate/WakeWordDetector.swift`
- iOS UI (taşınmaz): `Mate/ContentView.swift`, `Mate/SettingsView.swift`, `Mate/Views/`
