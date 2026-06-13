#!/usr/bin/env python3
"""Candan node agent — her node'da çalışan küçük MQTT yönetim istemcisi.

Brain'in MQTT yönetim düzlemi sözleşmesi (brain/nodes/manager.py):
  nodes/<id>/status     retained "online" JSON'u + LWT "offline"
  nodes/<id>/telemetry  periyodik sağlık (cpu sıcaklığı, uptime, disk)
  nodes/<id>/cmd        brain'den komut: {"action": "ping"|"restart"|"reboot"
                                          |"restart-service", "service": ...}

Yapılandırma /etc/candan/node.env'den okunur (bootstrap.sh yazar):
  NODE_ID, NODE_KIND, MQTT_HOST, MQTT_PORT, MQTT_USERNAME, MQTT_PASSWORD

Bağımlılık: paho-mqtt (>=2.0). Python 3.9+ (Raspberry Pi OS Bookworm).
"""

import json
import os
import shutil
import subprocess
import time

import paho.mqtt.client as mqtt

VERSION = "0.1"
TELEMETRY_INTERVAL = 60.0


def load_env(path="/etc/candan/node.env"):
    if os.path.exists(path):
        for line in open(path):
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, _, v = line.partition("=")
                os.environ.setdefault(k.strip(), v.strip())


def cpu_temp():
    try:
        with open("/sys/class/thermal/thermal_zone0/temp") as f:
            return round(int(f.read().strip()) / 1000.0, 1)
    except OSError:
        return None


def telemetry():
    disk = shutil.disk_usage("/")
    with open("/proc/uptime") as f:
        uptime = float(f.read().split()[0])
    return {
        "cpu_temp": cpu_temp(),
        "uptime_s": int(uptime),
        "disk_free_mb": disk.free // (1024 * 1024),
        "load1": os.getloadavg()[0],
    }


def main():
    load_env()
    node_id = os.environ.get("NODE_ID") or os.uname().nodename
    kind = os.environ.get("NODE_KIND", "satellite")
    host = os.environ["MQTT_HOST"]
    port = int(os.environ.get("MQTT_PORT", "1883"))

    status_topic = f"nodes/{node_id}/status"
    telemetry_topic = f"nodes/{node_id}/telemetry"
    cmd_topic = f"nodes/{node_id}/cmd"

    client = mqtt.Client(
        mqtt.CallbackAPIVersion.VERSION2, client_id=f"node-{node_id}"
    )
    if os.environ.get("MQTT_USERNAME"):
        client.username_pw_set(
            os.environ["MQTT_USERNAME"], os.environ.get("MQTT_PASSWORD", "")
        )
    client.will_set(status_topic, "offline", qos=1, retain=True)

    def on_connect(c, userdata, flags, reason_code, properties):
        c.publish(
            status_topic,
            json.dumps({"state": "online", "kind": kind, "version": VERSION}),
            qos=1,
            retain=True,
        )
        c.subscribe(cmd_topic, qos=1)
        print(f"[node-agent] online: {node_id} ({kind}) → {host}:{port}")

    def on_message(c, userdata, msg):
        try:
            cmd = json.loads(msg.payload.decode())
        except json.JSONDecodeError:
            return
        action = cmd.get("action", "")
        print(f"[node-agent] cmd: {cmd}")
        if action == "ping":
            c.publish(telemetry_topic, json.dumps({"pong": cmd.get("echo", "pong")}))
        elif action == "telemetry":
            c.publish(telemetry_topic, json.dumps(telemetry()))
        elif action == "restart-service":
            service = cmd.get("service", "")
            if service in ("wyoming-satellite", "wyoming-openwakeword", "node-agent"):
                subprocess.run(["systemctl", "restart", service], check=False)
        elif action == "reboot":
            subprocess.run(["systemctl", "reboot"], check=False)

    client.on_connect = on_connect
    client.on_message = on_message
    client.connect(host, port, keepalive=30)
    client.loop_start()

    try:
        while True:
            client.publish(telemetry_topic, json.dumps(telemetry()))
            time.sleep(TELEMETRY_INTERVAL)
    except KeyboardInterrupt:
        pass
    finally:
        client.publish(status_topic, "offline", qos=1, retain=True)
        client.loop_stop()


if __name__ == "__main__":
    main()
