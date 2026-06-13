# node-image — Pi voice satellite kurulumu

Pi Zero 2 W (veya herhangi bir Pi) üzerinde Candan voice satellite'ı + MQTT
yönetim ajanını kurar. Brain bu node'lara **kendisi bağlanır** (Wyoming,
:10700) — node brain'e bağlanmaz; HA hiç devrede değildir.

## Tek node kurulumu (ilk satellite için önerilen)

1. Raspberry Pi Imager ile **Raspberry Pi OS Lite (64-bit, Bookworm)** yaz;
   imager ayarlarından hostname (örn. `salon`), SSH ve Wi-Fi'yi ayarla.
2. USB ses kartını / ReSpeaker HAT'i tak, Pi'yi başlat.
3. MQTT broker'da (192.168.0.90) node için kullanıcı aç:
   `ssh root@192.168.0.90 mosquitto_passwd -b /etc/mosquitto/passwd salon 'SIFRE'`
4. Bu klasörü Pi'ye kopyala ve çalıştır:

   ```sh
   scp -r node-image pi@salon.local:
   ssh pi@salon.local
   sudo NODE_ID=salon MQTT_HOST=192.168.0.90 \
        MQTT_USERNAME=salon MQTT_PASSWORD=SIFRE ./node-image/bootstrap.sh
   ```

5. Brain `.env` → `SATELLITES=salon@<pi-ip>:10700` ekle, brain'i yeniden başlat.
6. Doğrula: `GET /api/health` → `satellites.salon: true`;
   `GET /api/nodes` → `salon` online (MQTT, telemetri ile birlikte).

## Filo kurulumu (Ansible)

```sh
cd node-image/ansible
cp inventory.example.ini inventory.ini   # node listesi (gitignore'da)
ansible-playbook -i inventory.ini satellite.yml
```

## Ses aygıtları

`bootstrap.sh` varsayılanı `plughw:1,0` (ilk USB ses kartı). Doğrulamak için:
`arecord -L` / `aplay -L`. Farklıysa `/etc/systemd/system/wyoming-satellite.service`
içindeki `--mic-command`/`--snd-command` aygıtlarını düzeltip
`sudo systemctl daemon-reload && sudo systemctl restart wyoming-satellite`.

## Wake word

Şimdilik openWakeWord'ün hazır `ok_nabu` modeli kullanılıyor — Türkçe "candan"
için openWakeWord özel model eğitimi ayrı bir iş (synthetic-speech eğitim
defteri var; planlanan). Model değiştirmek: `WAKE_MODEL=hey_jarvis ./bootstrap.sh`
veya Ansible `wake_model` değişkeni.

## Yönetim düzlemi (MQTT) sözleşmesi

| Topic | Yön | İçerik |
|---|---|---|
| `nodes/<id>/status` | node → brain | retained `{"state":"online","kind":"satellite","version":...}` + LWT `offline` |
| `nodes/<id>/telemetry` | node → brain | 60 sn'de bir `{"cpu_temp":41.2,"uptime_s":...,"disk_free_mb":...,"load1":...}` |
| `nodes/<id>/cmd` | brain → node | `{"action":"ping"\|"telemetry"\|"restart-service","service":...}` / `{"action":"reboot"}` |

Brain API karşılıkları: `GET /api/nodes`, `POST /api/nodes/<id>/cmd` (admin),
`POST /api/announce` (admin — bağlı tüm satellite'lar söyler + WS istemcileri
+ FCM push).
