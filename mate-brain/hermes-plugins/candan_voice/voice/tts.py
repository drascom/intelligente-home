"""Unified TTS streaming over the configured engine (settings.tts_engine).

Yields a normalized event stream regardless of engine:

    ("start", AudioFormat)   — rate / sample width (bytes) / channels
    ("chunk", bytes)         — raw PCM in the engine's native width
    ("end", None)

Engines:
- "vox":   VoxCPM2 bridge server (vox/server.py) over its Bridge v0 WS —
           pcm_f32le, 48 kHz, supports cloned voices (voices/*.wav stems).
- "piper": wyoming-piper — pcm_s16le, 22.05 kHz.

Consumers convert width as needed: the Bridge `/api/voice` endpoint wants
f32le (vox passes through untouched), satellites want s16le Wyoming chunks
(piper passes through untouched).
"""

import json
import logging
from array import array
from collections.abc import AsyncIterator
from dataclasses import dataclass

import websockets

from .config import settings
from . import services

log = logging.getLogger("candan_voice.tts")


@dataclass
class AudioFormat:
    rate: int
    width: int  # bytes per sample: 2 = s16le, 4 = f32le
    channels: int


async def synthesize_stream(
    text: str, voice: str | None = None
) -> AsyncIterator[tuple[str, object]]:
    if settings.tts_engine == "vox":
        async for item in _vox_stream(text, voice):
            yield item
    else:
        async for item in _piper_stream(text, voice):
            yield item


async def _vox_stream(text: str, voice: str | None) -> AsyncIterator[tuple[str, object]]:
    url = f"ws://{settings.vox_host}:{settings.vox_port}/ws"
    if settings.vox_api_key:
        url += f"?token={settings.vox_api_key}"
    async with websockets.connect(url, max_size=16 * 1024 * 1024) as ws:
        msg: dict = {"type": "speak", "id": "brain", "text": text}
        if voice:
            msg["voice"] = voice
        await ws.send(json.dumps(msg, ensure_ascii=False))
        async for raw in ws:
            if isinstance(raw, (bytes, bytearray)):
                yield ("chunk", bytes(raw))
                continue
            event = json.loads(raw)
            etype = event.get("type")
            if etype == "audio_start":
                yield (
                    "start",
                    AudioFormat(
                        rate=int(event.get("sample_rate", 48000)),
                        width=4,
                        channels=int(event.get("channels", 1)),
                    ),
                )
            elif etype == "audio_end":
                yield ("end", None)
                return
            elif etype == "error":
                raise ConnectionError(f"vox: {event.get('message')}")


async def _piper_stream(text: str, voice: str | None) -> AsyncIterator[tuple[str, object]]:
    async for event in services.synthesize(
        settings.tts_host, settings.tts_port, text, voice=voice
    ):
        if event.type == "audio-start":
            data = event.data or {}
            yield (
                "start",
                AudioFormat(
                    rate=data.get("rate", 22050),
                    width=data.get("width", 2),
                    channels=data.get("channels", 1),
                ),
            )
        elif event.type == "audio-chunk" and event.payload:
            yield ("chunk", event.payload)
        elif event.type == "audio-stop":
            yield ("end", None)
            return


def to_f32le(payload: bytes, fmt: AudioFormat) -> bytes:
    if fmt.width == 4:
        return payload
    samples = array("h")
    samples.frombytes(payload[: len(payload) - len(payload) % 2])
    return array("f", (s / 32768.0 for s in samples)).tobytes()


def to_s16le(payload: bytes, fmt: AudioFormat) -> bytes:
    if fmt.width == 2:
        return payload
    floats = array("f")
    floats.frombytes(payload[: len(payload) - len(payload) % 4])
    return array(
        "h", (max(-32768, min(32767, int(f * 32767.0))) for f in floats)
    ).tobytes()
