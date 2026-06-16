"""Brain service entrypoint: FastAPI app wiring HA mirror + LLM agent + APIs.

Run locally:  python -m brain.main   (from the repo root, with .env present)
"""

import asyncio
import logging
from contextlib import asynccontextmanager

import uvicorn
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from brain.api import client_api, monitor, openai_compat, speaker_api, task_api, voice
from brain.config import settings
from brain.db import Database
from brain.ha.mirror import HAMirror
from brain.intent.router import IntentRouter
from brain.monitor.bus import EventBus, persist_events
from brain.router.agent import Agent
from brain.router.llm import LLMClient
from brain.voice.satellite import Satellite, parse_satellites
from brain.voice.speaker import build_speaker_id

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(levelname)s %(message)s")
log = logging.getLogger("brain")


@asynccontextmanager
async def lifespan(app: FastAPI):
    db = Database(settings.brain_db_path)
    await db.connect()
    mirror = HAMirror(settings.ha_url, settings.ha_token)
    llm = LLMClient()

    # İzleme düzlemi: braine gelip giden olayları dashboard'a akıtan veriyolu.
    bus = EventBus()
    app.state.bus = bus

    intent = IntentRouter(bus=bus) if settings.intent_fastpath else None
    pi_backend = None
    if settings.llm_backend == "pi":
        from brain.router.pi_backend import PiBackend

        pi_backend = PiBackend()
        log.info("dev mode: agent turns delegated to pi (%s)", settings.pi_model)

    app.state.db = db
    app.state.mirror = mirror
    app.state.agent = Agent(llm, mirror, intent, pi_backend, bus=bus)

    # Speaker-ID (voice-ID): kapalı/eksikse None → tanıma atlanır.
    app.state.speaker = build_speaker_id(settings)
    if app.state.speaker is not None:
        app.state.speaker.reload(await db.all_speaker_embeddings())

    tasks = [asyncio.create_task(mirror.run())]
    # pi/Codex subprocess'i açılışta ön-ısıt + her an ≥1 sıcak instance hazır tut
    # (ölürse arka planda yeniden ısıt) → kullanıcı turu cold-start yemesin.
    if pi_backend:
        tasks.append(asyncio.create_task(pi_backend.keep_warm()))
    # Olayları DB'ye kalıcılaştır (dashboard geçmişi / restart sonrası geriye gitme).
    tasks.append(asyncio.create_task(persist_events(bus, db)))
    if intent:
        tasks.append(asyncio.create_task(intent.start()))

    app.state.satellites = [
        Satellite(name, host, port, app.state.agent, db, settings, speaker=app.state.speaker)
        for name, host, port in parse_satellites(settings.satellites)
    ]
    for sat in app.state.satellites:
        tasks.append(asyncio.create_task(sat.run()))
    if app.state.satellites:
        log.info("voice: managing %d satellite(s): %s",
                 len(app.state.satellites),
                 ", ".join(s.name for s in app.state.satellites))

    # MQTT node yönetim düzlemi (MQTT_HOST boşsa kapalı)
    app.state.nodes = None
    if settings.mqtt_host:
        from brain.nodes.manager import NodeManager

        app.state.nodes = NodeManager(settings, db, bus=bus)
        tasks.append(asyncio.create_task(app.state.nodes.run()))

    # Announce/bildirim altyapısı
    from brain.notify.fcm import FCMSender

    app.state.fcm = FCMSender(settings.fcm_credentials_path, bus=bus)
    app.state.ws_clients = set()
    # Canlı voice-bridge bağlantıları, client_id → {WebSocket}. Proaktif chime'ı
    # bağlı uygulamaya (mac/iPhone) açık WS üzerinden yollamak için (FCM yerine).
    app.state.voice_clients = {}

    # Zamanlı hatırlatma scheduler'ı (vakti gelen görev → chime → uyandırınca teslim).
    if settings.reminder_enabled:
        from brain.notify.reminders import ReminderScheduler

        app.state.reminder = ReminderScheduler(app, settings)
        tasks.append(asyncio.create_task(app.state.reminder.run()))
        log.info("reminder scheduler: %ss aralıkla yokluyor", settings.reminder_poll_seconds)

    if not settings.brain_admin_token:
        log.warning("BRAIN_ADMIN_TOKEN is not set — admin endpoints are disabled")

    yield

    for t in tasks:
        t.cancel()
    if pi_backend:
        await pi_backend.stop()
    await llm.close()
    await db.close()


app = FastAPI(title="Home AI Brain", lifespan=lifespan)
app.add_middleware(
    CORSMiddleware,
    allow_origins=[o.strip() for o in settings.monitor_cors_origins.split(",") if o.strip()],
    allow_credentials=True,
    allow_methods=["GET", "POST"],
    allow_headers=["Authorization", "Content-Type"],
)
app.include_router(openai_compat.router)
app.include_router(client_api.router)
app.include_router(speaker_api.router)
app.include_router(task_api.router)
app.include_router(voice.router)
app.include_router(monitor.router)


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=settings.brain_port)
