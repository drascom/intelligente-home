"""Brain service entrypoint: FastAPI app wiring HA mirror + LLM agent + APIs.

Run locally:  python -m brain.main   (from the repo root, with .env present)
"""

import asyncio
import logging
from contextlib import asynccontextmanager

import uvicorn
from fastapi import FastAPI

from brain.api import client_api, openai_compat, voice
from brain.config import settings
from brain.db import Database
from brain.ha.mirror import HAMirror
from brain.intent.router import IntentRouter
from brain.router.agent import Agent
from brain.router.llm import LLMClient
from brain.voice.satellite import Satellite, parse_satellites

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(levelname)s %(message)s")
log = logging.getLogger("brain")


@asynccontextmanager
async def lifespan(app: FastAPI):
    db = Database(settings.brain_db_path)
    await db.connect()
    mirror = HAMirror(settings.ha_url, settings.ha_token)
    llm = LLMClient()

    intent = IntentRouter() if settings.intent_fastpath else None
    pi_backend = None
    if settings.llm_backend == "pi":
        from brain.router.pi_backend import PiBackend

        pi_backend = PiBackend()
        log.info("dev mode: agent turns delegated to pi (%s)", settings.pi_model)

    app.state.db = db
    app.state.mirror = mirror
    app.state.agent = Agent(llm, mirror, intent, pi_backend)
    tasks = [asyncio.create_task(mirror.run())]
    if intent:
        tasks.append(asyncio.create_task(intent.start()))

    app.state.satellites = [
        Satellite(name, host, port, app.state.agent, db, settings)
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

        app.state.nodes = NodeManager(settings, db)
        tasks.append(asyncio.create_task(app.state.nodes.run()))

    # Announce/bildirim altyapısı
    from brain.notify.fcm import FCMSender

    app.state.fcm = FCMSender(settings.fcm_credentials_path)
    app.state.ws_clients = set()

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
app.include_router(openai_compat.router)
app.include_router(client_api.router)
app.include_router(voice.router)


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=settings.brain_port)
