"""Test the Bridge v0 `/api/voice` WebSocket with a fake Piper.

Run: .venv/bin/python -m brain.tests.test_voice_bridge
"""

import asyncio
import struct
import threading

from wyoming.event import Event, async_read_event, async_write_event

PIPER_PORT = 18201
PCM16 = struct.pack("<4h", 0, 16384, -16384, 32767)


async def fake_piper(reader, writer):
    event = await async_read_event(reader)
    assert event.type == "synthesize", event.type
    data = {"rate": 22050, "width": 2, "channels": 1}
    await async_write_event(Event(type="audio-start", data=data), writer)
    await async_write_event(Event(type="audio-chunk", data=data, payload=PCM16), writer)
    await async_write_event(Event(type="audio-stop"), writer)


def run_fake_piper(started: threading.Event):
    async def serve():
        server = await asyncio.start_server(fake_piper, "127.0.0.1", PIPER_PORT)
        started.set()
        async with server:
            await server.serve_forever()

    asyncio.run(serve())


def main():
    import os

    os.environ.update(
        BRAIN_ADMIN_TOKEN="test-token",
        BRAIN_DB_PATH="/tmp/brain-bridge-test.db",
        HA_TOKEN="x",
        TTS_ENGINE="piper",
        TTS_HOST="127.0.0.1",
        TTS_PORT=str(PIPER_PORT),
        INTENT_FASTPATH="false",
        # .env'deki gerçek broker'a bağlanma: aynı "brain" client-id'si canlı
        # brain'in MQTT oturumunu düşürüyor (mosquitto kicks duplicate id).
        MQTT_HOST="",
        FCM_CREDENTIALS_PATH="",
    )
    started = threading.Event()
    threading.Thread(target=run_fake_piper, args=(started,), daemon=True).start()
    assert started.wait(5)

    from fastapi.testclient import TestClient

    from brain.main import app

    class FakeAgent:
        async def respond(self, history, text, speaker=None, speaker_id=None, conversation_id=None):
            return f"echo: {text}"

    with TestClient(app) as client:
        app.state.agent = FakeAgent()

        # bad token rejected
        try:
            with client.websocket_connect("/api/voice?token=wrong") as ws:
                ws.receive_text()
            raise AssertionError("expected close")
        except Exception:
            print("PASS bad token rejected")

        with client.websocket_connect("/api/voice?token=test-token") as ws:
            ws.send_json({"type": "ping"})
            assert ws.receive_json()["type"] == "pong"
            print("PASS ping/pong")

            # text-only turn (phone doing local TTS)
            ws.send_json({"type": "speak", "id": "t1", "text": "merhaba", "want_audio": False})
            reply = ws.receive_json()
            assert reply == {"type": "reply", "id": "t1", "text": "echo: merhaba"}, reply
            print("PASS text-only reply")

            # audio turn (Bridge v0 default)
            ws.send_json({"type": "speak", "id": "t2", "text": "saat kaç"})
            assert ws.receive_json()["type"] == "reply"
            start = ws.receive_json()
            assert start["type"] == "audio_start" and start["sample_rate"] == 22050, start
            pcm = ws.receive_bytes()
            floats = struct.unpack("<4f", pcm)
            assert abs(floats[1] - 0.5) < 0.01 and abs(floats[2] + 0.5) < 0.01, floats
            assert ws.receive_json() == {"type": "audio_end", "id": "t2"}
            print("PASS audio turn (pcm16 -> f32le verified)")

    import os as _os
    _os.remove("/tmp/brain-bridge-test.db")
    print("\nALL PASS")


if __name__ == "__main__":
    main()
