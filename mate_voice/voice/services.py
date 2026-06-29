"""Wyoming clients for the STT/TTS services (faster-whisper, piper).

The brain talks to these directly — no Home Assistant in the loop.
"""

import asyncio
from collections.abc import AsyncIterator

from wyoming.event import Event, async_read_event, async_write_event


class WhisperSession:
    """One utterance: open connection, stream chunks, get transcript."""

    def __init__(self, host: str, port: int, language: str = ""):
        self.host = host
        self.port = port
        self.language = language
        self._reader = None
        self._writer = None

    async def start(self, rate: int, width: int, channels: int) -> None:
        self._reader, self._writer = await asyncio.open_connection(self.host, self.port)
        data = {"language": self.language} if self.language else {}
        await async_write_event(Event(type="transcribe", data=data), self._writer)
        await async_write_event(
            Event(type="audio-start", data={"rate": rate, "width": width, "channels": channels}),
            self._writer,
        )

    async def feed(self, chunk: Event) -> None:
        await async_write_event(chunk, self._writer)

    async def finish(self, timeout: float = 30.0) -> str:
        await async_write_event(Event(type="audio-stop"), self._writer)
        try:
            while True:
                event = await asyncio.wait_for(async_read_event(self._reader), timeout)
                if event is None:
                    return ""
                if event.type == "transcript":
                    return (event.data or {}).get("text", "")
        finally:
            self._writer.close()

    async def abort(self) -> None:
        if self._writer:
            self._writer.close()


async def synthesize(
    host: str, port: int, text: str, voice: str | None = None, timeout: float = 30.0
) -> AsyncIterator[Event]:
    """Yield audio-start / audio-chunk / audio-stop events from Piper for `text`."""
    reader, writer = await asyncio.open_connection(host, port)
    try:
        data: dict = {"text": text}
        if voice:
            data["voice"] = {"name": voice}
        await async_write_event(Event(type="synthesize", data=data), writer)
        while True:
            event = await asyncio.wait_for(async_read_event(reader), timeout)
            if event is None:
                return
            if event.type in ("audio-start", "audio-chunk", "audio-stop"):
                yield event
            if event.type == "audio-stop":
                return
    finally:
        writer.close()
