#!/bin/bash
# Candan voice satellite bootstrap — Raspberry Pi Zero 2 W (Raspberry Pi OS
# Lite Bookworm 64-bit) üzerinde TEK SEFER root olarak çalıştırılır:
#
#   sudo NODE_ID=salon MQTT_HOST=192.168.0.90 MQTT_USERNAME=salon \
#        MQTT_PASSWORD=... ./bootstrap.sh
#
# Kurduğu servisler:
#   wyoming-satellite    :10700  — brain bağlanır (BRAIN node'a değil!)
#   wyoming-openwakeword :10400  — yerel wake word (satellite kullanır)
#   node-agent                   — MQTT durum/telemetri/komut (yönetim düzlemi)
#
# Brain tarafında .env → SATELLITES="salon@<pi-ip>:10700" eklenmeli.
set -euo pipefail

NODE_ID="${NODE_ID:-$(hostname)}"
NODE_KIND="${NODE_KIND:-satellite}"
MQTT_HOST="${MQTT_HOST:?MQTT_HOST gerekli (broker adresi)}"
MQTT_PORT="${MQTT_PORT:-1883}"
MQTT_USERNAME="${MQTT_USERNAME:-}"
MQTT_PASSWORD="${MQTT_PASSWORD:-}"
# openwakeword modeli — Türkçe "candan" için özel model eğitilene kadar
# varsayılan İngilizce model (bkz. README "Wake word" bölümü).
WAKE_MODEL="${WAKE_MODEL:-ok_nabu}"

echo "== apt paketleri =="
apt-get update
apt-get install -y --no-install-recommends \
  python3-venv python3-pip git alsa-utils avahi-daemon

echo "== python ortamı =="
install -d /opt/candan
python3 -m venv /opt/candan/venv
/opt/candan/venv/bin/pip install --upgrade pip
/opt/candan/venv/bin/pip install \
  wyoming-satellite wyoming-openwakeword "paho-mqtt>=2.0"

echo "== node yapılandırması =="
install -d /etc/candan
cat > /etc/candan/node.env <<EOF
NODE_ID=${NODE_ID}
NODE_KIND=${NODE_KIND}
MQTT_HOST=${MQTT_HOST}
MQTT_PORT=${MQTT_PORT}
MQTT_USERNAME=${MQTT_USERNAME}
MQTT_PASSWORD=${MQTT_PASSWORD}
EOF
chmod 600 /etc/candan/node.env
install -m 755 "$(dirname "$0")/node-agent.py" /opt/candan/node-agent.py

echo "== systemd servisleri =="
cat > /etc/systemd/system/wyoming-openwakeword.service <<EOF
[Unit]
Description=Wyoming openWakeWord
After=network-online.target

[Service]
ExecStart=/opt/candan/venv/bin/wyoming-openwakeword \\
  --uri tcp://127.0.0.1:10400 --preload-model ${WAKE_MODEL}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Mikrofon/hoparlör aygıtları: `arecord -L` / `aplay -L` ile doğrulayın;
# çoğu USB ses kartında plughw:1,0 çalışır (bkz. README "Ses aygıtları").
cat > /etc/systemd/system/wyoming-satellite.service <<EOF
[Unit]
Description=Wyoming Satellite (Candan)
After=network-online.target wyoming-openwakeword.service
Requires=wyoming-openwakeword.service

[Service]
ExecStart=/opt/candan/venv/bin/wyoming-satellite \\
  --name "${NODE_ID}" \\
  --uri tcp://0.0.0.0:10700 \\
  --mic-command "arecord -D plughw:1,0 -r 16000 -c 1 -f S16_LE -t raw" \\
  --snd-command "aplay -D plughw:1,0 -r 22050 -c 1 -f S16_LE -t raw" \\
  --wake-uri tcp://127.0.0.1:10400 \\
  --wake-word-name ${WAKE_MODEL}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/node-agent.service <<EOF
[Unit]
Description=Candan node agent (MQTT yönetim düzlemi)
After=network-online.target

[Service]
ExecStart=/opt/candan/venv/bin/python /opt/candan/node-agent.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now wyoming-openwakeword wyoming-satellite node-agent

echo
echo "== TAMAM =="
echo "Bu node: ${NODE_ID} (:10700) — brain .env'ine ekleyin:"
echo "  SATELLITES=...,${NODE_ID}@$(hostname -I | awk '{print $1}'):10700"
echo "MQTT durumu: nodes/${NODE_ID}/status (broker: ${MQTT_HOST})"
