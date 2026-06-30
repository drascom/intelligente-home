"""Mate Voice Hermes platform plugin."""
from .voice._deps import ensure_deps
ensure_deps(core=True)  # adapter/voice top-level wyoming·livekit·aiohttp·numpy importundan ÖNCE
from .adapter import register

__all__ = ["register"]
