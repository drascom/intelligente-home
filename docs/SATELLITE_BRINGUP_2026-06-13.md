# İlk gerçek voice satellite — kurulum & uçtan-uca test (2026-06-13)

Otonom oturum özeti. Hedef: ReSpeaker'lı Raspberry Pi Zero 2 W'yi sisteme
**doğrudan brain'e konuşan** voice satellite olarak bağlamak ve satellite ↔ brain
↔ mate-mac uçtan-uca testlerini yapmak. **Sonuç: tam ses döngüsü gerçek donanımda
çalışıyor.**

## Donanım & OS

| | |
|---|---|
| Cihaz | Raspberry Pi Zero 2 W (4 çekirdek, 416 MB RAM) |
| Ses kartı | ReSpeaker 2-Mics Pi HAT (WM8960 codec, GPIO/I2S) |
| OS | Raspberry Pi OS Lite, **Debian 13 Trixie**, arm64, kernel 6.12.75 |
| Erişim | `candan@salon.local` → 192.168.0.135 (DHCP), SSH key (`id_ed25519`) + sudo (parola `doktor`) |
| Ağ | WiFi "Colak", brain'in kablolu LAN'ı ile aynı subnet (192.168.0.x) |

> Eski kart (Wyoming/HA kuruluydu ama ext4'te, macOS okuyamıyordu) **silinip sıfırdan**
> kuruldu — Raspberry Pi Imager (Lite 64-bit), hostname `salon`, kullanıcı `candan`,
> WiFi + SSH(public-key) ön-ayarlı.

## ReSpeaker sürücüsü (kritik adım)

Taze imajda mikrofon yoktu (`arecord -l` boş). Çözüm: `/boot/firmware/config.txt`'ye
```
dtparam=i2c_arm=on
dtoverlay=wm8960-soundcard
```
(imajda hazır `wm8960-soundcard.dtbo` var — eski seeed-voicecard DKMS derdi YOK).
Reboot sonrası **card 0 = wm8960soundcard**, hem playback hem capture.

ALSA mixer ayarlandı + kalıcı kaydedildi (`alsactl store 0`): Capture +11.25 dB,
mic yolu LINPUT1/RINPUT1 boost on, Speaker/Headphone açık.
- Mic testi: 6 sn kayıt → peak 32742/32768, RMS 2776 → **mikrofon çalışıyor** ✓
- Hoparlör testi: 440 Hz tonu `plughw:0,0` ile çalındı (ALSA çıkışı OK) ✓
- ALSA aygıtı: tüm servislerde `plughw:0,0` (bootstrap varsayılanı `plughw:1,0` yanlıştı).

## Kurulan servisler (systemd)

| Servis | venv | Port | Not |
|---|---|---|---|
| `wyoming-openwakeword` | `/opt/candan/venv` | 127.0.0.1:10400 | onnx/tflite-bundled sürüm (aşağıya bak) |
| `wyoming-satellite` | `/opt/candan/sat-venv` | 0.0.0.0:10700 | brain bağlanır; mic+wake+snd |
| `node-agent` | `/opt/candan/sat-venv` | — (MQTT) | yönetim düzlemi, `/etc/candan/node.env` |

### Python 3.13 / Trixie tuzakları (çözüldü)

1. **openWakeWord + tflite:** `wyoming-openwakeword` (PyPI 1.x) `tflite-runtime-nightly`
   istiyor — Py3.13 arm64'te wheel YOK → bootstrap pip çöküyordu. **Çözüm:** git sürümü
   `wyoming-openwakeword 2.1.0` + `pyopen-wakeword 1.1.0` kuruldu; bu paket **kendi
   `libtensorflowlite_c.so`'sunu ve tflite modellerini paketliyor** (alexa, hey_jarvis,
   hey_mycroft, hey_rhasspy, **okay_nabu**), harici tflite-runtime'a gerek yok.
2. **wyoming sürüm çakışması:** oww 2.1.0 `wyoming==1.9.0`, wyoming-satellite 1.0.0
   `wyoming==1.4.1` istiyor → **ayrı venv** (`sat-venv`). İki process TCP wyoming ile
   konuşur, sorun yok.
3. **wyoming-satellite console-script bozuk:** `wyoming-satellite` betiği
   `__main__:run` arıyor (yok) → `python -m wyoming_satellite` ile çalıştırıldı
   (servis ExecStart buna göre).

## Brain tarafı

- `mate-brain/.env` → `SATELLITES=salon@salon.local:10700` (DHCP IP yerine mDNS adı).
- Broker (192.168.0.90): `salon` mosquitto kullanıcısı açıldı (node-agent için).
- Brain yeniden başlatıldı → `GET /api/health`:
  `{"satellites":{"salon":true}, "ha_connected":true, "entities":285, "mqtt_connected":true}`
- Çalışan brain stack (Mac, dev): brain :8800, whisper :10300 (tr), vox :8808.

## Uçtan-uca test sonuçları

### 1. Brain sesli yol (protokol seviyesi, Bridge v0 /api/voice) ✓
`vox/turkce_test.wav` (16k'ya çevrildi) → `/api/voice` WS:
- STT (whisper): *"Merhaba, bu bir Türkçe seslendirme testidir. Vox CPM2 ile uzun
  kitapları sesli kitaba dönüştürebilirsiniz."* (6.1s)
- Agent (Codex): *"Merhaba, test mesajını aldım."* (8.0s)
- TTS (vox/nese): 2.4s @48kHz, 18.6s'de tamam → **Mac hoparlöründe çalındı, anlaşılır.**

### 2. Satellite ÇIKIŞ yolu (announce) ✓
`POST /api/announce {"text":"Merhaba, ben salon uydusu..."}` →
Pi log: `Playing raw data 'stdin' : 22050 Hz Mono` → **brain vox TTS → Wyoming →
satellite hoparlörü.**

### 3. Satellite TAM döngü (wake → STT → agent → TTS → hoparlör) ✓ ⭐
Pi'nin mikrofonuna uzaktan ses veremediğim için, satellite'in mic-command'ı geçici
olarak gerçek-zaman pacer'a çevrildi (`okay nabu` + `saat kaç acaba` içeren ses).
brain.log:
```
satellite salon: wake (run-pipeline)          ← openWakeWord (Pi) "okay nabu" yakaladı
satellite salon: heard 'Saat kaç acaba?'      ← brain Whisper STT (Türkçe)
```
Agent (Codex) `get_time` aracını kullandı → cevap **"Saat 15:23."** → vox TTS →
Pi log `Playing raw data ... 22050 Hz` → **satellite hoparlörü.**
Test sonrası gerçek mikrofon (`arecord ... plughw:0,0`) geri yüklendi.

### 4. MQTT yönetim düzlemi ✓
`GET /api/nodes` → `salon` online, telemetri: cpu_temp 45.6°C, uptime 2182s,
disk_free 24.8 GB, load1 0.33.

### 5. mate-mac (Mac istemcisi) ↔ brain ✓ (kısmi)
- `MateMac.xcodeproj` temiz derlendi (**BUILD SUCCEEDED**), uygulama çalışıyor.
- Bugünkü önceki oturumun logu **gerçek bir tam turu** kanıtlıyor: kullanıcı sesi →
  sunucu STT *"ses kontrol deneme 1 2 3 beni duyuyor musun"* → reply → TTS playback →
  tur tamamlandı. Wake word *"candan" (tr-TR, SFSpeech)* aktif.
- **Otonom akustik tetikleme** (hoparlörden sentetik "candan" çalıp Huawei mic ile
  yakalama) güvenilir tetiklenmedi — sentetik TTS "candan"ı SFSpeech wake eşiğini
  geçmedi; client logları `open` ile başlatılınca stdout'a düşmüyor. **Canlı insan
  "candan" testi gelince yapılmalı** (brain tarafı + gerçek-tur zaten kanıtlı).

## Açık işler

- **Türkçe "candan" wake modeli:** şu an `okay_nabu` (İngilizce). openWakeWord için
  Türkçe "candan" özel modeli eğitilmeli (synthetic-speech defteri planlı).
- **DHCP → sabit IP:** salon şu an 192.168.0.135 (DHCP). Router'da rezervasyon veya
  statik öneri (SATELLITES `salon.local` kullandığı için kritik değil).
- **mate-mac canlı akustik:** insan "candan" ile tek bir canlı tur teyidi.
- **Broker passwd dosya sahibi:** `/etc/mosquitto/passwd` sahibi root değil (mosquitto
  uyarısı veriyor) — ileride `chown root` gerekebilir.
- Eski `test-pi` node'u `/api/nodes`'da stale/offline görünüyor (zararsız kalıntı).

## Faydalı komutlar

```sh
# Satellite servis durumu / log
ssh candan@salon.local 'systemctl is-active wyoming-openwakeword wyoming-satellite node-agent'
ssh candan@salon.local 'sudo journalctl -u wyoming-satellite -n 30'

# Brain sağlık / nodes
curl -s localhost:8800/api/health
curl -s localhost:8800/api/nodes -H "Authorization: Bearer $BRAIN_ADMIN_TOKEN"

# Satellite'e anons (hoparlör testi)
curl -s -X POST localhost:8800/api/announce -H "Authorization: Bearer $TOK" \
     -H 'Content-Type: application/json' -d '{"text":"deneme"}'

# Brain'i yeniden başlat (SATELLITES değişince)
kill $(lsof -ti tcp:8800); nohup ./brain_run.sh > .logs/brain.log 2>&1 &
```
