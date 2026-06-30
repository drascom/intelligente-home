"""Self-update version check for mate_voice.

The plugin is installed as a subdirectory of a monorepo (`drascom/intelligente-home`),
so the installed copy has no `.git` directory and `hermes plugins update` can't
git-pull it (see PluginOperationError in hermes_cli/plugins_cmd.py). The only way
to refresh it is a full reinstall (`hermes plugins install ... --force`).

This module just answers "is there a newer version published?" by comparing the
local `plugin.yaml` version against the same file's version on the upstream
default branch (fetched as raw content, no git clone needed for the check itself).
"""

from __future__ import annotations

import asyncio
import logging
import urllib.request
from pathlib import Path
from typing import Optional

import yaml

log = logging.getLogger(__name__)

PLUGIN_IDENTIFIER = "drascom/intelligente-home/mate_voice"
_MANIFEST_RAW_URL = (
    "https://raw.githubusercontent.com/drascom/intelligente-home/main/mate_voice/plugin.yaml"
)
_LOCAL_MANIFEST = Path(__file__).resolve().parent / "plugin.yaml"
_FETCH_TIMEOUT_S = 10

_AFFIRMATIVE_WORDS = {
    "evet", "güncelle", "guncelle", "yükle", "yukle", "tamam", "olur",
    "yes", "update", "ok", "okay",
}


def installed_version() -> str:
    try:
        with _LOCAL_MANIFEST.open("r", encoding="utf-8") as f:
            return str(yaml.safe_load(f).get("version") or "0")
    except Exception:
        return "0"


def _version_tuple(v: str) -> tuple:
    parts = []
    for p in v.strip().split("."):
        try:
            parts.append(int(p))
        except ValueError:
            parts.append(0)
    return tuple(parts)


def is_newer(remote: str, local: str) -> bool:
    return _version_tuple(remote) > _version_tuple(local)


def is_affirmative_reply(text: str) -> bool:
    lowered = text.casefold()
    return any(word in lowered for word in _AFFIRMATIVE_WORDS)


def _fetch_remote_version_sync() -> Optional[str]:
    try:
        with urllib.request.urlopen(_MANIFEST_RAW_URL, timeout=_FETCH_TIMEOUT_S) as resp:
            data = yaml.safe_load(resp.read().decode("utf-8")) or {}
            version = str(data.get("version") or "")
            return version or None
    except Exception as e:
        log.warning("mate_voice: güncelleme kontrolü başarısız: %r", e)
        return None


async def fetch_remote_version() -> Optional[str]:
    return await asyncio.to_thread(_fetch_remote_version_sync)


async def check_for_update() -> Optional[str]:
    """Returns the newer remote version string if one is published, else None."""
    remote = await fetch_remote_version()
    if remote and is_newer(remote, installed_version()):
        return remote
    return None
