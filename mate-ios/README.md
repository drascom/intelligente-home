# Mate. iOS

Mate'in sesli istemcisi. Wake word ile uyanır, kullanıcı konuştuğunda kaydı bridge'e gönderir, Pi Agent yanıtını cümle cümle TTS'e çevirip çalar. SwiftUI ile yazıldı.

## Akış

1. Uygulama açıldığında STT, TTS ve Bridge için health kontrolü yapılır; biri erişilemezse "Sunucu bağlantısı yok" uyarısı çıkar ve otomatik dinleme başlamaz.
2. Wake word aktifse mikrofon `WakeWordDetector` üzerinden uyanma kelimesini dinler. Algılandığında kısa ortam kalibrasyonu yapılır, ardından bip çalar — kullanıcı bip'ten sonra konuşur.
3. VAD adaptive noise filter ile konuşma başlangıcını yakalar; ~1.4 sn sessizlikten sonra segmenti kapatır. Pre-roll buffer sayesinde ilk hece kaçmaz.
4. Kayıt STT'ye (`POST /v1/audio/transcriptions`) gönderilir. Whisper hallucination/noise filtresi (kısa kelimeler, "izlediğiniz için teşekkür" benzeri kalıplar) tetiklenirse istek bridge'e gönderilmez.
5. Transcript bridge'e (`POST /chat`) gider. Bridge Pi Agent'ı çalıştırır, ses persona prompt'unu uygular, yanıtı döner.
6. Yanıt cümle sonlarına göre (`.`, `!`, `?`, `…`) parçalanır. İlk parça TTS'e (`POST /v1/audio/speech`) gönderilip çalmaya başlarken sonraki parça arka planda sentezlenir (pseudo-streaming).
7. TTS çalarken kullanıcı araya girerse (barge-in) kalan parçalar iptal edilir, mic tekrar dinlemeye geçer.
8. Tur bittiğinde follow-up penceresi açılır — wake kelimesi söylemeden ~15 sn boyunca konuşmaya devam edilebilir.

## Özellikler
- **Wake word + manuel mod**: Wake kelimesi `SFSpeechRecognizer` ile (cihaz üstü), Türkçe varsayılan. Wake kapalıyken sürekli dinleme.
- **Health checks**: STT/TTS/Bridge için açılışta ve dinlemeye başlamadan önce kontrol; aşamalı `diagnosticStatus` ile kullanıcıya görünür.
- **Adaptive VAD**: Ortam gürültüsünden baseline çıkarıp eşiği uyarlar; kuş/fan gibi süreğen sese karşı dayanıklı.
- **Barge-in**: TTS sırasında AEC warmup + echo baseline kalibrasyonu, ardından gerçek konuşmayı yakalayıp TTS'i kesip mic'i açar.
- **Pseudo-streaming TTS**: Uzun yanıtlarda ilk ses cümle bazında erken başlar.
- **Diagnostic durum satırı**: Ana ekranda STT → Bridge → TTS aşamasını ve elapsed süreyi gösterir.
- **OpenAI uyumlu STT/TTS**: STT için multipart, TTS için JSON `synthesize`.
- **Settings**: Remote / Local / Custom preset; bridge URL'i, STT/TTS URL'leri, dil, ses adı, wake word, barge-in, noise filter, cue sesleri.

## Varsayılanlar
| Servis | Adres |
|---|---|
| Bridge | `http://192.168.0.183:8643` |
| STT | `https://stt.drascom.uk` (`/v1/audio/transcriptions`) |
| TTS | `https://tts.drascom.uk` (`/v1/audio/speech`) |
| Voice | `ayhan` |
| Language | `tr` |

## Build

Bu repo Xcode projesi (`.xcodeproj`) içermez — `XcodeGen` ile generate ediliyor.

```bash
brew install xcodegen          # bir kerelik
cd mate-ios
xcodegen generate              # Mate.xcodeproj üretir
open Mate.xcodeproj
```

Xcode'da:
1. Sol panelde **Mate** target → **Signing & Capabilities**
2. **Team** olarak Apple ID seç (ücretsiz personal team yeterli).
3. iPhone'u USB ile bağla, üst barda hedef cihaz olarak seç.
4. ⌘R — build & run.

İlk açılışta mikrofon ve (wake aktifse) konuşma tanıma izni ister.

## Yapı
```
mate-ios/
├── project.yml                    # XcodeGen tanımı
└── Mate/
    ├── MateApp.swift              # @main
    ├── ContentView.swift          # Ana ekran (orb, bar equalizer, diagnostic)
    ├── SettingsView.swift         # Sunucu ve davranış ayarları
    ├── Settings.swift             # SettingsStore (UserDefaults)
    ├── ConversationManager.swift  # State machine, VAD, barge-in, tur akışı
    ├── AudioPipeline.swift        # AVAudioEngine (paylaşımlı), voice processing
    ├── AudioRecorder.swift        # Mic tap + level metering + segment buffer
    ├── AudioPlayer.swift          # TTS playback + amplitude
    ├── APIClient.swift            # STT/TTS/Bridge HTTP
    ├── WakeWordDetector.swift     # SFSpeechRecognizer wake listener
    ├── CueSounds.swift            # Bip / wake / sleep cue sesleri
    └── Views/
        ├── OrbView.swift          # Konuşan ajan animasyonu
        ├── BarsView.swift         # Equalizer barları
        └── RoutePickerView.swift  # AirPlay/BT route seçici
```

## Notlar
- ATS: `NSAllowsArbitraryLoads = YES` — LAN bridge için. Production'da daraltılmalı.
- Audio session: `.playAndRecord` + `.voiceChat` + `.allowBluetoothHFP`. `.defaultToSpeaker` KASTEN yok — BT seçimini iptal ediyor; output route manuel `applyAudioRoute()` ile yönetiliyor.
- Ses formatı: AAC/M4A, 16 kHz mono — Whisper için optimal.
- VAD ve barge-in parametreleri `ConversationManager` içinde sabit; cihaz davranışına göre kalibre edilmiş durumda.
