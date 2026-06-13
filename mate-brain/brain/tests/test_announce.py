"""Announce akışı testi: POST /api/announce → sahte satellite'lar konuşur,
bağlı /api/ws istemcisi {"type":"announce"} alır, FCM dry-run'da push 0 döner.

Run: .venv/bin/python -m brain.tests.test_announce
"""

import os


def main() -> None:
    os.environ.update(
        BRAIN_ADMIN_TOKEN="test-token",
        BRAIN_DB_PATH="/tmp/brain-announce-test.db",
        HA_TOKEN="x",
        HA_URL="http://127.0.0.1:1",      # erişilemez — mirror sessizce retry'da kalır
        MQTT_HOST="",                      # MQTT düzlemi kapalı
        FCM_CREDENTIALS_PATH="",           # dry-run
        INTENT_FASTPATH="false",
        LLM_BACKEND="vllm",
        SATELLITES="",
    )
    if os.path.exists("/tmp/brain-announce-test.db"):
        os.remove("/tmp/brain-announce-test.db")

    from fastapi.testclient import TestClient

    from brain.main import app

    spoken: list[tuple[str, str]] = []

    class FakeSatellite:
        def __init__(self, name, connected):
            self.name = name
            self.connected = connected

        async def announce(self, text):
            if not self.connected:
                return False
            spoken.append((self.name, text))
            return True

    class FakeAgent:
        async def respond(self, history, text):
            return f"echo: {text}"

    headers = {"Authorization": "Bearer test-token"}
    with TestClient(app) as client:
        app.state.agent = FakeAgent()
        app.state.satellites = [
            FakeSatellite("kitchen", True),
            FakeSatellite("hall", False),
        ]

        # 1) WS istemcisi bağlıyken announce her iki kanala da gider
        with client.websocket_connect("/api/ws?token=test-token") as ws:
            resp = client.post(
                "/api/announce",
                json={"text": "Yemek hazır!"},
                headers=headers,
            )
            assert resp.status_code == 200, resp.text
            result = resp.json()
            assert result["satellites"] == ["kitchen"], result   # hall bağlı değil
            assert result["ws_clients"] == 1, result
            assert result["push_sent"] == 0, result               # dry-run
            msg = ws.receive_json()
            assert msg == {"type": "announce", "title": "Candan", "text": "Yemek hazır!"}, msg
        assert spoken == [("kitchen", "Yemek hazır!")], spoken

        # 2) WS kapandıktan sonra ws_clients düşer
        resp = client.post("/api/announce", json={"text": "tekrar"}, headers=headers)
        assert resp.json()["ws_clients"] == 0, resp.json()

        # 3) Boş metin reddedilir
        resp = client.post("/api/announce", json={"text": "  "}, headers=headers)
        assert resp.status_code == 400, resp.text

    print("test_announce: 3/3 OK")


if __name__ == "__main__":
    main()
