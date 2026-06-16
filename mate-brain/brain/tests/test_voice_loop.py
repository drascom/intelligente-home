"""End-to-end test of the brain's Wyoming voice plane with fake services.

Runs a fake wyoming-satellite, fake Whisper, and fake Piper on localhost,
then drives one full utterance through Satellite: wake → audio → transcript
→ agent → TTS audio back to the satellite. No hardware needed.

Run: .venv/bin/python -m brain.tests.test_voice_loop
"""

import asyncio
import logging

from wyoming.event import Event, async_read_event, async_write_event

from brain.config import settings
from brain.voice.satellite import Satellite

logging.basicConfig(level=logging.INFO)

SPEECH = (b"\x10\x27" * 320)  # loud int16 frames (0x2710 = 10000)
SILENCE = (b"\x00\x00" * 320)
CHUNK_DATA = {"rate": 16000, "width": 2, "channels": 1}


class FakeDB:
    async def resolve_session(self, scope_key, user_id=None):
        return 1

    async def recent_messages(self, session_id):
        return []

    async def add_message(self, session_id, role, content, speaker=None):
        pass


class FakeAgent:
    async def respond(self, history, text, speaker=None, speaker_id=None, conversation_id=None):
        return f"You said: {text}"


async def fake_whisper(reader, writer):
    while True:
        event = await async_read_event(reader)
        if event is None:
            return
        if event.type == "audio-stop":
            await async_write_event(
                Event(type="transcript", data={"text": "turn on the lights"}), writer
            )


async def fake_piper(reader, writer):
    event = await async_read_event(reader)
    assert event.type == "synthesize", event.type
    await async_write_event(Event(type="audio-start", data=CHUNK_DATA), writer)
    await async_write_event(
        Event(type="audio-chunk", data=CHUNK_DATA, payload=SILENCE), writer
    )
    await async_write_event(Event(type="audio-stop"), writer)


async def fake_satellite(reader, writer, results: dict):
    event = await async_read_event(reader)
    assert event.type == "run-satellite", event.type
    # wake word fired
    await async_write_event(Event(type="run-pipeline"), writer)
    # ~1s of speech then ~1.5s of silence (each chunk = 20ms)
    for payload in [SPEECH] * 50 + [SILENCE] * 75:
        await async_write_event(
            Event(type="audio-chunk", data=CHUNK_DATA, payload=payload), writer
        )
    # collect what the brain sends back
    while True:
        event = await asyncio.wait_for(async_read_event(reader), 10)
        results.setdefault("events", []).append(event.type)
        if event.type == "transcript":
            results["transcript"] = event.data["text"]
        if event.type == "audio-stop":
            results["done"].set()
            return


async def main():
    results = {"done": asyncio.Event()}
    servers = [
        await asyncio.start_server(fake_whisper, "127.0.0.1", 18300),
        await asyncio.start_server(fake_piper, "127.0.0.1", 18200),
        await asyncio.start_server(
            lambda r, w: fake_satellite(r, w, results), "127.0.0.1", 18700
        ),
    ]
    settings.stt_host, settings.stt_port = "127.0.0.1", 18300
    settings.tts_host, settings.tts_port = "127.0.0.1", 18200
    settings.tts_engine = "piper"

    sat = Satellite("test", "127.0.0.1", 18700, FakeAgent(), FakeDB(), settings)
    task = asyncio.create_task(sat.run())
    await asyncio.wait_for(results["done"].wait(), 15)
    task.cancel()
    for s in servers:
        s.close()

    assert results["transcript"] == "turn on the lights", results
    assert "audio-start" in results["events"] and "audio-stop" in results["events"]
    print("\nPASS — satellite events received:", results["events"])


if __name__ == "__main__":
    asyncio.run(main())
