#!/usr/bin/env python3
"""
mate-sim — başsız (headless) mate-mac LiveKit istemci simülatörü.

Uçtan uca test: stage LiveKit odasına bağlan → mic yerine TEST WAV yayınla
(brain attribute'ları ile: candan.awake=1, stt_engine/voice/language) →
geri dönen `lk.transcription` text-stream'ini (candan.role: user/assistant) ve
agent TTS ses track'ini yakala. Net PASS/FAIL basar.

Token/URL/oda: env (MATE_LK_URL / MATE_LK_TOKEN / MATE_LK_ROOM / MATE_LK_IDENTITY)
veya `token.txt` (gitignored). Detay: CONNECT.md.

Çıktılar: last-run.log (çalışma logu), reply.wav (gelen TTS).
"""
import argparse
import asyncio
import contextlib
import os
import time
import wave
from pathlib import Path

from livekit import rtc

HERE = Path(__file__).resolve().parent
LOG_PATH = HERE / "last-run.log"
REPLY_WAV = HERE / "reply.wav"
PROMPT_WAV = HERE / "prompt.wav"

DEFAULT_URL = "wss://mate-livekit.drascom.uk"
DEFAULT_ROOM = "mate-demo"
# Brain'in beklediği attribute'lar (mate-mac SettingsStore.brainAttributes + awake).
# candan.awake=1 OLMAZSA brain sesi/transkripti YOK SAYAR (sunucu wake-gate).
ATTRS = {
    "candan.awake": "1",
    "stt_engine": "whisper",
    "voice": "nese",
    "language": "tr",
    "candan.barge_in": "1",
}

_log_lines = []


def log(msg: str):
    line = f"[{time.strftime('%H:%M:%S')}] {msg}"
    print(line, flush=True)
    _log_lines.append(line)


def flush_log():
    LOG_PATH.write_text("\n".join(_log_lines) + "\n", encoding="utf-8")


def load_token() -> str:
    tok = os.environ.get("MATE_LK_TOKEN", "").strip()
    if tok:
        return tok
    tf = HERE / "token.txt"
    if tf.exists():
        return tf.read_text(encoding="utf-8").strip()
    raise SystemExit(
        "TOKEN yok. MATE_LK_TOKEN env ver veya token.txt yaz (bkz. CONNECT.md)."
    )


def ensure_prompt_wav(text: str, regen: bool):
    # --text'in gerçekten yayınlanması için varsayılan: her koşuda yeniden üret.
    # MATE_SIM_KEEP_WAV=1 → mevcut prompt.wav'ı koru (özel ses dosyası kullan).
    if PROMPT_WAV.exists() and not regen:
        log(f"prompt.wav korunuyor (MATE_SIM_KEEP_WAV=1)")
        return
    log(f"prompt.wav üretiliyor: {text!r}")
    import subprocess

    subprocess.run([str(HERE / "make_wav.sh"), text, "prompt.wav"], check=True)


def read_wav_48k_mono(path: Path):
    """WAV oku, (int16 bytes, sample_rate, num_channels) döndür. 48k mono bekler."""
    with wave.open(str(path), "rb") as w:
        sr = w.getframerate()
        ch = w.getnchannels()
        sw = w.getsampwidth()
        data = w.readframes(w.getnframes())
    if sw != 2:
        raise SystemExit(f"WAV 16-bit olmalı (sampwidth={sw}). make_wav.sh kullan.")
    return data, sr, ch


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--text", default="Candan, merhaba, bugün nasılsın?")
    ap.add_argument("--wait", type=float, default=30.0,
                    help="Yayından sonra cevap için bekleme (sn)")
    ap.add_argument("--connect-only", action="store_true",
                    help="Yalnız bağlan+publish doğrula, cevap bekleme kısa")
    args = ap.parse_args()

    url = os.environ.get("MATE_LK_URL", DEFAULT_URL)
    room_name = os.environ.get("MATE_LK_ROOM", DEFAULT_ROOM)
    identity = os.environ.get("MATE_LK_IDENTITY", "sim-client")
    token = load_token()

    ensure_prompt_wav(args.text, regen=os.environ.get("MATE_SIM_KEEP_WAV") != "1")
    pcm, sr, ch = read_wav_48k_mono(PROMPT_WAV)
    log(f"prompt.wav: {len(pcm)} bytes, {sr}Hz, {ch}ch, ~{len(pcm)/2/sr/ch:.1f}s")

    results = {"connected": False, "published": False,
               "transcript": False, "tts": False}
    transcripts = []
    tts_bytes = 0
    tts_frames = []
    tts_sr = 48000
    tts_ch = 1

    room = rtc.Room()

    # --- Agent TTS ses track'ine abone ol → reply.wav ---
    async def drain_audio(track):
        nonlocal tts_bytes, tts_sr, tts_ch
        astream = rtc.AudioStream(track)
        async for ev in astream:
            f = ev.frame
            tts_sr = f.sample_rate
            tts_ch = f.num_channels
            b = bytes(f.data)
            tts_bytes += len(b)
            tts_frames.append(b)

    @room.on("track_subscribed")
    def _on_track(track, pub, participant):
        if track.kind == rtc.TrackKind.KIND_AUDIO:
            log(f"agent ses track'i geldi ← {participant.identity}")
            asyncio.create_task(drain_audio(track))

    @room.on("participant_connected")
    def _on_join(p):
        log(f"katılımcı geldi: {p.identity}")

    # --- Transkript: lk.transcription text-stream, candan.role ile user/assistant ---
    def on_text_stream(reader, participant_identity):
        async def _read():
            info = reader.info
            attrs = dict(getattr(info, "attributes", {}) or {})
            role = (attrs.get("candan.role") or "").lower()
            who = "user" if role == "user" else ("assistant" if role in ("assistant", "agent") else participant_identity)
            text = await reader.read_all()
            transcripts.append((who, text))
            log(f"TRANSCRIPT [{who}] {text}")
        asyncio.create_task(_read())

    room.register_text_stream_handler("lk.transcription", on_text_stream)

    # --- Bağlan ---
    log(f"bağlanılıyor: {url} room={room_name} identity={identity}")
    await room.connect(url, token,
                       options=rtc.RoomOptions(auto_subscribe=True))
    results["connected"] = True
    log(f"BAĞLANDI ✓ (sid bekleniyor)")
    with contextlib.suppress(Exception):
        log(f"room.sid={await room.sid}")
    others = list(room.remote_participants.values())
    log(f"odadaki diğer katılımcılar: {[p.identity for p in others] or 'YOK (agent odada değil?)'}")

    # --- Attribute'ları yayınla (wake-gate) ---
    with contextlib.suppress(Exception):
        await room.local_participant.set_attributes(ATTRS)
        log(f"attributes set ✓ {ATTRS}")

    # --- Mic track publish + WAV akıt ---
    source = rtc.AudioSource(sr, ch)
    track = rtc.LocalAudioTrack.create_audio_track("sim-mic", source)
    await room.local_participant.publish_track(
        track, rtc.TrackPublishOptions(source=rtc.TrackSource.SOURCE_MICROPHONE))
    results["published"] = True
    log("mic track publish ✓ — WAV akıtılıyor...")

    samples_10ms = sr // 100  # 10ms frame
    bytes_per_frame = samples_10ms * ch * 2
    sent = 0
    t0 = time.monotonic()
    for off in range(0, len(pcm), bytes_per_frame):
        chunk = pcm[off:off + bytes_per_frame]
        if len(chunk) < bytes_per_frame:
            chunk = chunk + b"\x00" * (bytes_per_frame - len(chunk))
        frame = rtc.AudioFrame(chunk, sr, ch, samples_10ms)
        await source.capture_frame(frame)
        sent += 1
        # gerçek zamanlı tempo
        target = t0 + sent * 0.01
        dt = target - time.monotonic()
        if dt > 0:
            await asyncio.sleep(dt)
    log(f"WAV akıtıldı ✓ ({sent} frame, ~{sent/100:.1f}s)")

    # --- Cevap bekle ---
    wait = 4.0 if args.connect_only else args.wait
    log(f"cevap bekleniyor ({wait:.0f}s)...")
    deadline = time.monotonic() + wait
    while time.monotonic() < deadline:
        if transcripts:
            results["transcript"] = True
        if tts_bytes > 0:
            results["tts"] = True
        # connect-only değilse her ikisi gelince erken çık
        if not args.connect_only and results["transcript"] and results["tts"]:
            await asyncio.sleep(2.0)  # son chunk'lar gelsin
            break
        await asyncio.sleep(0.5)

    results["transcript"] = bool(transcripts)
    results["tts"] = tts_bytes > 0

    # --- reply.wav yaz ---
    if tts_frames:
        with wave.open(str(REPLY_WAV), "wb") as w:
            w.setnchannels(tts_ch)
            w.setsampwidth(2)
            w.setframerate(tts_sr)
            w.writeframes(b"".join(tts_frames))
        log(f"reply.wav yazıldı: {tts_bytes} bytes, {tts_sr}Hz, {tts_ch}ch")
    else:
        log("reply.wav YOK (agent TTS sesi gelmedi)")

    with contextlib.suppress(Exception):
        await room.disconnect()

    # --- Özet ---
    log("=" * 48)
    for k in ("connected", "published", "transcript", "tts"):
        log(f"{'PASS' if results[k] else 'FAIL'}  {k}")
    if transcripts:
        log(f"transkript satırı: {len(transcripts)}")
    log("=" * 48)
    flush_log()

    # exit code: connectivity (connected+published) zorunlu; tam tur transcript+tts
    ok_conn = results["connected"] and results["published"]
    return 0 if ok_conn else 1


if __name__ == "__main__":
    try:
        rc = asyncio.run(main())
    except SystemExit:
        raise
    except Exception as e:
        log(f"HATA: {e!r}")
        flush_log()
        rc = 2
    raise SystemExit(rc)
