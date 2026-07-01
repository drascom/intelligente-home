"""Self-update version check for mate_voice.

The plugin is installed as a subdirectory of a monorepo (`drascom/intelligente-home`),
so the installed copy has no `.git` directory and `hermes plugins update` can't
git-pull it (see PluginOperationError in hermes_cli/plugins_cmd.py). The only way
to refresh it is a full reinstall (`hermes plugins install ... --force`).

This module compares the local `plugin.yaml` version against upstream and powers
the manual `check-update` CLI action, including the interactive install/restart
flow.
"""

from __future__ import annotations

import asyncio
import logging
import subprocess
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
_LOCAL_ENV = Path(__file__).resolve().parent / ".env"
_FETCH_TIMEOUT_S = 10
_PRESERVE_PATTERNS = (
    ".env",
    ".env.*",
    "*.db",
    "*.db-*",
    "*.sqlite",
    "*.sqlite-*",
    "*.sqlite3",
    "*.sqlite3-*",
)
_PRESERVE_EXCLUDE_NAMES = {".env.example"}

_AFFIRMATIVE_WORDS = {
    "evet", "güncelle", "guncelle", "yükle", "yukle", "tamam", "olur",
    "yes", "update", "ok", "okay",
}
_CLI_YES = {"e", "evet", "y", "yes"}
_CLI_NO = {"h", "hayır", "hayir", "n", "no"}


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


def run_install_force() -> tuple[bool, str]:
    preserved = _snapshot_local_state()

    try:
        result = subprocess.run(
            ["hermes", "plugins", "install", PLUGIN_IDENTIFIER, "--force", "--enable"],
            capture_output=True, text=True, timeout=120,
        )
        output = (result.stdout or "") + (result.stderr or "")
        restored, errors = _restore_local_state(preserved)
        if restored:
            names = ", ".join(str(path) for path in restored)
            output += f"\nmate_voice: lokal state korundu: {names}"
        for rel_path, error in errors:
            output += f"\nmate_voice: lokal state geri yazılamadı ({rel_path}): {error!r}"
        return result.returncode == 0, output
    except Exception as e:
        return False, repr(e)


def _snapshot_local_state() -> dict[Path, tuple[bytes, int]]:
    snapshot: dict[Path, tuple[bytes, int]] = {}
    for pattern in _PRESERVE_PATTERNS:
        for path in _LOCAL_ENV.parent.rglob(pattern):
            if not path.is_file():
                continue
            if path.name in _PRESERVE_EXCLUDE_NAMES:
                continue
            try:
                snapshot[path.relative_to(_LOCAL_ENV.parent)] = (
                    path.read_bytes(),
                    path.stat().st_mode,
                )
            except Exception:
                continue
    return snapshot


def _restore_local_state(
    snapshot: dict[Path, tuple[bytes, int]]
) -> tuple[list[Path], list[tuple[Path, Exception]]]:
    restored: list[Path] = []
    errors: list[tuple[Path, Exception]] = []
    for rel_path, (data, mode) in snapshot.items():
        path = _LOCAL_ENV.parent / rel_path
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
            path.chmod(mode)
            restored.append(rel_path)
        except Exception as e:
            errors.append((rel_path, e))
    return restored, errors


def run_gateway_restart() -> tuple[bool, str]:
    try:
        result = subprocess.run(
            ["sudo", "hermes", "gateway", "restart"],
            capture_output=True, text=True, timeout=60,
        )
        return result.returncode == 0, (result.stdout or "") + (result.stderr or "")
    except Exception as e:
        return False, repr(e)


def run_check_update_cli() -> int:
    latest = asyncio.run(check_for_update())
    current = installed_version()
    if not latest:
        print(f"Güncel (sürüm {current}).")
        return 0

    print(f"Güncelleme mevcut: {current} → {latest}")
    answer = input("Güncelleme yapmak ister misiniz? [yes/no]: ").strip().casefold()
    if answer in _CLI_NO or answer == "":
        print("Güncelleme iptal edildi.")
        return 0
    if answer not in _CLI_YES:
        print("Yanıt anlaşılamadı; güncelleme yapılmadı.")
        return 2

    print(f"Çalıştırılıyor: hermes plugins install {PLUGIN_IDENTIFIER} --force --enable")
    ok, output = run_install_force()
    if output.strip():
        print(output.strip())
    if not ok:
        print("Güncelleme başarısız oldu.")
        return 1

    print("Güncelleme tamamlandı. Gateway yeniden başlatılıyor: sudo hermes gateway restart")
    ok, output = run_gateway_restart()
    if output.strip():
        print(output.strip())
    if not ok:
        print("Gateway restart başarısız oldu; elle çalıştırın: sudo hermes gateway restart")
        return 1
    print(f"Güncellendi ve gateway yeniden başlatıldı (sürüm {latest}).")
    return 0
