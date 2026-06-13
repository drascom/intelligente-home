# Gece çalışması — 2026-06-13 (sabah incelemesi için)

Kullanıcı talebi: "kalan diğer tüm adımları tamamla — diğer cihazlar, bağlantılar
ve cihazlar arası akışları hazırla."

## Plan (SYSTEM_PLAN §1.6, Layer 2, faz 5'e göre)

1. **MQTT node yönetim düzlemi** (`brain/nodes/`) — kodu hiç olmayan tek alt sistem
   - Topics: `nodes/<id>/status` (LWT, retained) · `nodes/<id>/telemetry` ·
     `nodes/<id>/cmd` (brain → node)
   - NodeManager: broker bağlantısı (yoksa zarif düşüş), DB'de node kaydı
     (id, kind, online, last_seen, version, meta), komut yayını
   - API: `GET /api/nodes`, `POST /api/nodes/{id}/cmd`
2. **Cihazlar arası anons akışı** — `POST /api/announce` {text, voice?, targets?}
   → tüm Wyoming satellite'lar sesli söyler + bağlı WS istemcilerine metin gider
   + (yapılandırılmışsa) telefonlara FCM push
3. **FCM push** (`brain/notify/`) — HTTP v1, service-account ile; kimlik dosyası
   yoksa dry-run/log modu. Token kayıt endpoint'i zaten vardı.
4. **Pi satellite kurulum paketi** (`node-image/`) — Pi Zero 2 W için bootstrap
   script + Ansible playbook + README (wyoming-satellite, brain'e bağlanacak
   şekilde; donanım gelince tak-çalıştır)
5. Testler (pytest, sahte broker/transport ile) + dokümantasyon + hafıza

## Durum

- [x] Plan yazıldı
- [x] 1. MQTT düzlemi — brain/nodes/manager.py, DB nodes tablosu+yardımcılar, /api/nodes + /api/nodes/{id}/cmd, main.py lifespan, config (mqtt_host/port/user/pass/prefix; host boş = kapalı)
- [x] 2. Anons akışı — POST /api/announce (admin token): satellites (paralel) + WS clients {"type":"announce"} + FCM push (best-effort)
- [x] 3. FCM iskeleti — brain/notify/fcm.py (HTTP v1, google-auth varsa gerçek, yoksa dry-run log; FCM_CREDENTIALS_PATH config)
- [x] 4. node-image — bootstrap.sh + ansible (satellite.yml + inventory örneği) + README (Pi Zero 2W, wyoming-satellite systemd, brain'e :10700)
- [x] 5. Testler — test_nodes.py (8/8) + test_announce.py (3/3, sahte satellite + WS yayını + FCM dry-run); mevcut voice testleri de yeşil. CANLI doğrulama: brain gerçek broker'a bağlandı (192.168.0.90, kullanıcı "brain" oluşturuldu), sahte node yayını → /api/nodes'ta göründü (telemetri dahil), POST /api/nodes/test-pi/cmd → komut MQTT'den node'a ulaştı, /api/announce çalışıyor (şu an bağlı satellite/WS/FCM olmadığından sayılar 0).

## Ek: gerçek HA bağlandı (kullanıcı verdi)

`.env` → HA_URL=https://home.drascom.uk + token. Brain aynası canlı: **281
entity, 12 alan** (Bahçe, Banyo, Mutfak, Salon…). Gece cihazlara YAZMA
yapılmadı (servis çağrısı yok) — ilk gerçek ışık komutu sabah birlikte.

## Mac istemcisi bu gece çalışır duruma geldi (yatmadan önceki son test ✓)

Zincir: wake "candan" → VAD → sunucu Whisper turbo → pi/Codex → Nese sesi.
Bilinen sınır: barge-in eşiği (0.30) Huawei BT kulaklık konuşma seviyesinin
(~0.10) üstünde — araya girme mac'te şimdilik tetiklenmez; istenirse macOS
eşiği konuşma eşiğine indirilecek.
