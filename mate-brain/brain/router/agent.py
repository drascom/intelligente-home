"""The conversation agent: LLM tool-loop over the live HA mirror.

Every chat turn (from HA Assist, the Flutter app, or the web client) lands in
`Agent.respond`. The model gets three tools — list devices, read a state, call
a service — and we loop until it produces a plain answer.
"""

import json
import logging
from datetime import datetime

from brain.ha.mirror import HAMirror
from brain.router.llm import LLMClient

log = logging.getLogger("brain.agent")

MAX_TOOL_ROUNDS = 6

TOOLS = [
    {
        "type": "function",
        "function": {
            "name": "list_entities",
            "description": "List smart home devices/entities, optionally filtered by area name and/or domain (light, switch, climate, media_player, sensor, ...). Returns entity_id, name, state, area.",
            "parameters": {
                "type": "object",
                "properties": {
                    "area": {"type": "string", "description": "Area/room name, e.g. 'Living Room'"},
                    "domain": {"type": "string", "description": "Entity domain, e.g. 'light'"},
                },
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_state",
            "description": "Get the full state and attributes of one entity.",
            "parameters": {
                "type": "object",
                "properties": {"entity_id": {"type": "string"}},
                "required": ["entity_id"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "call_service",
            "description": "Control a device by calling a Home Assistant service, e.g. domain='light', service='turn_on', entity_id='light.living_room', data={'brightness_pct': 50}.",
            "parameters": {
                "type": "object",
                "properties": {
                    "domain": {"type": "string"},
                    "service": {"type": "string"},
                    "entity_id": {"type": "string"},
                    "data": {"type": "object", "description": "Extra service data"},
                },
                "required": ["domain", "service"],
            },
        },
    },
]


def chat_prompt() -> str:
    return (
        "You are the warm, brief home assistant of this household, replying to "
        "casual conversation (greetings, feelings, small talk). No device "
        "control is needed for this message. Answers are often spoken aloud — "
        "keep them short and natural, in the language the user used.\n"
        f"Current time: {datetime.now().strftime('%Y-%m-%d %H:%M')}"
    )


def system_prompt(mirror: HAMirror) -> str:
    areas = ", ".join(sorted(mirror.areas.values())) or "none yet"
    if not mirror.connected:
        return (
            "You are the home assistant brain for this household. The smart-home "
            "connector (Home Assistant) is currently unreachable, so you cannot "
            "see or control devices right now — say so briefly if asked, and "
            "answer everything else normally. Be brief and natural; answer in "
            "the language the user used."
        )
    return (
        "You are the home assistant brain for this household. You can see and "
        "control every device through your tools. Be brief and natural — your "
        "answers are often spoken aloud. Answer in the language the user used.\n"
        f"Current time: {datetime.now().strftime('%Y-%m-%d %H:%M')}\n"
        f"Areas in the home: {areas}\n"
        "Use list_entities to find the right entity before controlling it. "
        "After acting, confirm in one short sentence."
    )


class Agent:
    def __init__(self, llm: LLMClient, mirror: HAMirror, intent=None, pi_backend=None, bus=None):
        self.llm = llm
        self.mirror = mirror
        self.intent = intent  # IntentRouter or None
        self.pi = pi_backend  # PiBackend (dev) or None (prod: native tool loop)
        self.bus = bus  # EventBus or None (izleme düzlemi; None ise emit no-op)

    async def respond(
        self, history: list[dict], user_text: str,
        speaker: str | None = None, speaker_id: int | None = None,
        conversation_id: str | None = None,
    ) -> str:
        if self.pi is not None:
            # Dev backend: pi runs the whole turn (its own context + tool loop).
            # Intent classification still runs for log/tuning purposes.
            if self.intent:
                self.intent.classify(user_text, conversation_id=conversation_id)
            return await self.pi.respond(user_text, speaker_id=speaker_id, speaker=speaker)
        # Fast path: confident chitchat skips the tool loop — one plain LLM
        # call, big latency win on the voice path.
        pred = self.intent.classify(user_text, conversation_id=conversation_id) if self.intent else None
        if pred and not pred.abstain and pred.label == "sohbet":
            reply = await self.llm.chat(
                [
                    {"role": "system", "content": chat_prompt()},
                    *history,
                    {"role": "user", "content": user_text},
                ]
            )
            return reply.get("content") or ""

        messages = [
            {"role": "system", "content": system_prompt(self.mirror)},
            *history,
            {"role": "user", "content": user_text},
        ]
        for _ in range(MAX_TOOL_ROUNDS):
            reply = await self.llm.chat(messages, tools=TOOLS)
            tool_calls = reply.get("tool_calls")
            if not tool_calls:
                return reply.get("content") or ""
            messages.append(reply)
            for call in tool_calls:
                result = await self._execute(call["function"])
                messages.append(
                    {
                        "role": "tool",
                        "tool_call_id": call["id"],
                        "content": json.dumps(result, ensure_ascii=False, default=str),
                    }
                )
        return "I couldn't finish that request — too many steps."

    async def _execute(self, fn: dict):
        name = fn["name"]
        try:
            args = json.loads(fn.get("arguments") or "{}")
        except json.JSONDecodeError:
            return {"error": "invalid tool arguments"}
        log.info("tool %s %s", name, args)
        if self.bus:
            self.bus.emit("tool_call", "agent", f"{name} {json.dumps(args, ensure_ascii=False)}",
                          payload={"name": name, "args": args})
        result = await self._dispatch(name, args)
        if self.bus:
            self.bus.emit("tool_result", "agent", f"{name} → {self._result_summary(result)}",
                          payload={"name": name, "result": result})
        return result

    async def _dispatch(self, name: str, args: dict):
        try:
            if name == "list_entities":
                return self.mirror.list_entities(args.get("area"), args.get("domain"))
            if name == "get_state":
                return self.mirror.entity_info(args["entity_id"]) or {
                    "error": f"unknown entity {args['entity_id']}"
                }
            if name == "call_service":
                await self.mirror.call_service(
                    args["domain"],
                    args["service"],
                    args.get("data"),
                    args.get("entity_id"),
                )
                return {"ok": True}
            return {"error": f"unknown tool {name}"}
        except Exception as e:
            return {"error": str(e)}

    @staticmethod
    def _result_summary(result) -> str:
        if isinstance(result, list):
            return f"{len(result)} sonuç"
        if isinstance(result, dict):
            if "error" in result:
                return f"hata: {result['error']}"
            if result.get("ok"):
                return "ok"
            return result.get("state") or result.get("name") or "sonuç"
        return "sonuç"
