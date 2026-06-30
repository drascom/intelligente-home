"""Plugin self-install: eksik Python bağımlılıklarını Hermes gateway venv'ine kur.

Hermes'in native plugin installer'ı (hermes plugins install) deps'i KURMAZ —
sadece git clone + .example kopya + requires_env prompt + after-install.md gösterir
(bkz. hermes_cli/plugins_cmd.py). Python deps native akışta otomatik değil. Bu
modül o boşluğu plugin TARAFINDA kapatır: yalnız ETKİN özelliklerin eksik
modüllerini `sys.executable -m pip install` ile kurar. FAIL-OPEN — kurulum
başarısızsa özellik (turn-detector/speaker-ID) zaten graceful degrade eder.

Çekirdeğe DOKUNMAZ (Hermes kodu değişmez); sadece gateway'in çalıştığı venv'e
paket ekler — `sys.executable` o venv'in python'u olduğu için doğru hedefe gider.
"""

import importlib
import importlib.util
import logging
import subprocess
import sys

log = logging.getLogger("mate_voice._deps")

# import-edilen modül adı → pip paket spec'i
_PIP_SPEC = {
    "numpy": "numpy",
    "livekit": "livekit",
    "wyoming": "wyoming",
    "aiohttp": "aiohttp",
    "onnxruntime": "onnxruntime",
    "transformers": "transformers",
    "huggingface_hub": "huggingface_hub",
    "sherpa_onnx": "sherpa-onnx",
    "qrcode": "qrcode",
}

# adapter/voice top-level'da daima gereken çekirdek modüller
_CORE_MODULES = ["numpy", "livekit", "wyoming", "aiohttp"]

# özellik → gereken import modülleri
_FEATURE_MODULES = {
    "turn_detector": ["numpy", "onnxruntime", "transformers", "huggingface_hub"],
    "speaker_id": ["numpy", "onnxruntime", "sherpa_onnx"],
}


def _missing(modules: list[str]) -> list[str]:
    out = []
    for m in modules:
        if importlib.util.find_spec(m) is None:
            out.append(m)
    return out


def _ensure_pip() -> None:
    """Bazı venv'ler (örn. hermes gateway) pip'siz oluşturuluyor. ensurepip ile
    pip'i venv'e bootstrap et — yoksa self-install hiç çalışamaz. Fail-open."""
    if importlib.util.find_spec("pip") is not None:
        return
    try:
        subprocess.run([sys.executable, "-m", "ensurepip", "--upgrade"],
                       capture_output=True, text=True, timeout=300)
        importlib.invalidate_caches()
    except Exception as e:
        log.warning("mate_voice: ensurepip başarısız: %r", e)


def _pip_install(specs: list[str], timeout: int = 900) -> bool:
    _ensure_pip()
    cmd = [sys.executable, "-m", "pip", "install", "--disable-pip-version-check", *specs]
    log.warning("mate_voice: eksik deps kuruluyor (%s) → %s", specs, sys.executable)
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except Exception as e:
        log.warning("mate_voice: pip install çağrılamadı: %r", e)
        return False
    if r.returncode != 0:
        log.warning("mate_voice: pip install başarısız (rc=%s): %s",
                    r.returncode, (r.stderr or r.stdout or "")[-800:])
        return False
    log.info("mate_voice: deps kuruldu: %s", specs)
    importlib.invalidate_caches()
    return True


def ensure_deps(*, core: bool = False, turn_detector: bool = False, speaker_id: bool = False) -> None:
    """Etkin özelliklerin eksik modüllerini kur. Hepsi varsa no-op (hızlı).
    `core=True` ise adapter/voice top-level'ın daima gerektirdiği çekirdek
    modülleri (wyoming·livekit·aiohttp·numpy) de garanti edilir.
    Fail-open: kurulamazsa sessizce devam (özellik kendi try/except'inde degrade).
    Kapatmak için env MATE_VOICE_AUTO_INSTALL_DEPS=0."""
    import os

    if os.getenv("MATE_VOICE_AUTO_INSTALL_DEPS", "1").strip().lower() in {"0", "false", "no", "off"}:
        return

    wanted: list[str] = []
    if core:
        wanted += _CORE_MODULES
    if turn_detector:
        wanted += _FEATURE_MODULES["turn_detector"]
    if speaker_id:
        wanted += _FEATURE_MODULES["speaker_id"]
    # dedupe, sırayı koru
    seen = set()
    wanted = [m for m in wanted if not (m in seen or seen.add(m))]
    if not wanted:
        return

    missing_mods = _missing(wanted)
    if not missing_mods:
        return
    specs = [_PIP_SPEC[m] for m in missing_mods if m in _PIP_SPEC]
    if specs:
        _pip_install(specs)
