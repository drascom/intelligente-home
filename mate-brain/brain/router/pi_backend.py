"""Dev-time agent backend: the project-local pi coding agent over RPC.

On the Mac dev server there is no vLLM; instead the brain delegates whole
conversation turns to a pi subprocess (`--mode rpc`) running the
`openai-codex` provider (Codex subscription). Pi runs its own tool loop using
the HA tools from brain/pi/ha-tools.ts, which call back into this brain's
REST API. On the real Linux server, LLM_BACKEND=vllm switches back to the
native tool-loop agent and this module is never started.

Isolation from the global pi agent: project-local binary
(node_modules/.bin/pi), --no-extensions/--no-skills/--no-context-files, and
ephemeral sessions. Only the OAuth in ~/.pi/agent/auth.json is shared.
"""

import asyncio
import json
import logging
import time

from brain.config import settings

log = logging.getLogger("brain.pi")

SYSTEM_PROMPT = (
    "You are the home assistant brain for this household. You can see and "
    "control every device through your tools (list_entities, get_state, "
    "call_service). Be brief and natural — your answers are often spoken "
    "aloud. Answer in the language the user used. Use list_entities to find "
    "the right entity before controlling it. After acting, confirm in one "
    "short sentence. You are not a coding assistant.\n"
    "Görev (task) yönetimi: Kullanıcı sonradan yapılacak/hatırlanacak bir şey "
    "söylerse (ör. 'akşam Ali'yi aramayı unutma', 'yarın çöpü çıkar') bunu "
    "create_task ile kaydet ve tek kısa cümleyle onayla — soruya çevirme, uzatma. "
    "ÖNEMLİ: görev text'ini KISA EMİR KİPİ aksiyon olarak yaz ('su iç', 'Ali'yi ara', "
    "'çöpü çıkar', 'ara ver') — 'hatırlat'/'unutma' EKLEME; çünkü vakti gelince bu metin "
    "kullanıcıya aynen okunacak. "
    "'Görevlerim ne', 'neler var' gibi isteklerde list_tasks; bir iş bittiyse "
    "complete_task kullan. Sorular ve sohbeti normal yanıtla, görev oluşturma. "
    "Kullanıcı bir zaman belirtirse asistan vakti gelince kendisi hatırlatır: GÖRELİ "
    "süre için ('10 dakika sonra') create_task'a in_seconds ver (10 dk = 600); MUTLAK "
    "saat için ('yarın saat 10'da') önce get_time al, hesapla, due_at (yerel ISO 8601) ver. "
    "Her kullanıcı mesajı '(Konuşan: <ad>, user_id=<N>)' ile başlar; görev "
    "oluştururken/listelerken bu user_id'yi geçir (bilinmiyorsa boş bırak)."
)


class PiBackend:
    def __init__(self):
        self._proc: asyncio.subprocess.Process | None = None
        self._lock = asyncio.Lock()  # one turn at a time through the subprocess

    async def _ensure_proc(self) -> asyncio.subprocess.Process:
        if self._proc and self._proc.returncode is None:
            return self._proc
        cmd = [
            settings.pi_binary,
            "--mode", "rpc",
            "--provider", settings.pi_model.split("/")[0],
            "--model", settings.pi_model,
            "--no-session",
            "--no-extensions",
            "--no-skills",
            "--no-prompt-templates",
            "--no-context-files",
            "--no-builtin-tools",
            "-e", "brain/pi/ha-tools.ts",
            "--system-prompt", SYSTEM_PROMPT,
        ]
        env = {
            "BRAIN_API_URL": f"http://127.0.0.1:{settings.brain_port}",
            "BRAIN_API_TOKEN": settings.brain_admin_token,
        }
        import os

        self._proc = await asyncio.create_subprocess_exec(
            *cmd,
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL,
            env={**os.environ, **env},
        )
        log.info("pi backend started (pid=%s, model=%s)", self._proc.pid, settings.pi_model)
        return self._proc

    async def keep_warm(self, interval: float = 30.0) -> None:
        """En az 1 pi instance HER AN hazır beklesin. Açılışta ön-ısıt; sonra
        periyodik kontrol — süreç ölürse (idle-exit/crash/timeout-kill) kullanıcı
        turu beklemeden arka planda yeniden ısıt. Tek instance turları seri işler
        (lock); eşzamanlı çok-kullanıcı için ileride havuz gerekebilir."""
        await self.warmup()
        while True:
            await asyncio.sleep(interval)
            if self._proc is None or self._proc.returncode is not None:
                log.info("pi backend kapandı → keep-warm yeniden ısıtıyor")
                await self.warmup()

    async def warmup(self) -> None:
        """pi subprocess'i + Codex oturumunu önceden ısıt → ilk gerçek kullanıcı turu
        cold-start (node boot + oturum init) gecikmesi yemesin. Süreç zaten sıcaksa
        _ensure_proc onu yeniden kullanır. Başarısızsa zarar yok (sonraki tur ısıtır)."""
        try:
            async with self._lock:
                t0 = time.monotonic()
                proc = await self._ensure_proc()
                t_spawn = time.monotonic() - t0
                t1 = time.monotonic()
                await asyncio.wait_for(self._turn(proc, "ping"), 90)
                t_ping = time.monotonic() - t1
            log.info("pi backend warmup OK (spawn %.1fs + ilk-tur %.1fs)", t_spawn, t_ping)
        except Exception as e:
            log.warning("pi backend warmup failed: %s", e)

    async def stop(self) -> None:
        if self._proc and self._proc.returncode is None:
            self._proc.terminate()

    async def complete_once(self, prompt: str, timeout: float = 60.0) -> str:
        """Stateless tek-seferlik Codex çağrısı — asistanın kalıcı proc'unu/bağlamını
        KULLANMAZ. Taze geçici pi süreci açar, tek prompt gönderir, yanıtı okur, süreci
        kapatır. Oturum özeti gibi yan-kanal işler için (bağlam kirlenmez). Hata → ''."""
        import os
        cmd = [
            settings.pi_binary, "--mode", "rpc",
            "--provider", settings.pi_model.split("/")[0],
            "--model", settings.pi_model,
            "--no-session", "--no-extensions", "--no-skills",
            "--no-prompt-templates", "--no-context-files", "--no-builtin-tools",
            "--system-prompt", "Sen kısa bir özetleyicisin. Yalnızca istenen çıktıyı (ör. JSON) ver, başka hiçbir şey yazma.",
        ]
        proc = None
        try:
            proc = await asyncio.create_subprocess_exec(
                *cmd, stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.DEVNULL, env={**os.environ},
            )
            return await asyncio.wait_for(self._turn(proc, prompt), timeout)
        except Exception as e:
            log.warning("pi complete_once failed: %s", e)
            return ""
        finally:
            if proc is not None and proc.returncode is None:
                try:
                    proc.kill()
                except Exception:
                    pass

    async def respond(
        self, user_text: str, speaker_id: int | None = None,
        speaker: str | None = None, timeout: float = 120.0,
    ) -> str:
        """One conversation turn. Pi keeps context for the life of the process.
        speaker/speaker_id (voice-ID) tura bağlam olarak eklenir → görevler doğru
        kullanıcıya yazılsın."""
        if speaker or speaker_id is not None:
            user_text = (
                f"(Konuşan: {speaker or 'bilinmeyen'}, "
                f"user_id={speaker_id if speaker_id is not None else 'yok'})\n{user_text}"
            )
        async with self._lock:
            for attempt in (1, 2):
                proc = await self._ensure_proc()
                try:
                    t0 = time.monotonic()
                    reply = await asyncio.wait_for(self._turn(proc, user_text), timeout)
                    log.info("pi turn done in %.1fs (pid=%s)", time.monotonic() - t0, proc.pid)
                    return reply
                except asyncio.CancelledError:
                    # Barge-in / superseded turn: pi is still generating — abort
                    # it (shielded; we're being cancelled) so the NEXT prompt
                    # isn't rejected with "Agent is already processing".
                    await asyncio.shield(self._abort(proc))
                    raise
                except (asyncio.TimeoutError, ConnectionError, BrokenPipeError) as e:
                    log.error("pi turn failed (%s); restarting backend (attempt %d)", e, attempt)
                    if proc.returncode is None:
                        proc.kill()
                    self._proc = None
                    if attempt == 2:
                        raise RuntimeError(f"pi backend failed: {e}")

    async def _abort(self, proc: asyncio.subprocess.Process) -> None:
        """Stop pi's in-flight run and drain its event stream until idle.
        If pi doesn't settle quickly, restart it — a stale agent_end left in
        the pipe would corrupt the next turn's read loop."""
        try:
            proc.stdin.write((json.dumps({"type": "abort"}) + "\n").encode())
            await proc.stdin.drain()

            async def drain():
                while True:
                    line = await proc.stdout.readline()
                    if not line:
                        return
                    try:
                        event = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    if event.get("type") == "agent_end":
                        return

            await asyncio.wait_for(drain(), 10)
            log.info("pi turn aborted (barge-in)")
        except Exception as e:
            log.warning("pi abort failed (%s); restarting backend", e)
            if proc.returncode is None:
                proc.kill()
            self._proc = None

    async def _turn(self, proc: asyncio.subprocess.Process, user_text: str) -> str:
        cmd = json.dumps({"type": "prompt", "message": user_text}, ensure_ascii=False)
        proc.stdin.write((cmd + "\n").encode())
        await proc.stdin.drain()

        while True:
            line = await proc.stdout.readline()
            if not line:
                raise ConnectionError("pi process closed stdout")
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            if event.get("type") == "response" and not event.get("success", True):
                raise ConnectionError(f"pi rejected prompt: {event}")
            if event.get("type") == "agent_end":
                return self._final_text(event.get("messages", []))

    @staticmethod
    def _final_text(messages: list[dict]) -> str:
        for msg in reversed(messages):
            if msg.get("role") != "assistant":
                continue
            parts = [
                c.get("text", "")
                for c in msg.get("content", [])
                if isinstance(c, dict) and c.get("type") == "text"
            ]
            text = "\n".join(p for p in parts if p).strip()
            if text:
                return text
        return ""
