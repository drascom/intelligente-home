"""OpenAI-compatible /v1/chat/completions — what Home Assistant's Assist
pipeline talks to (configured as an OpenAI conversation agent pointed at the
brain). The brain runs the tool loop itself; HA just gets the final text."""

import json
import time
import uuid

from fastapi import APIRouter, Depends, Request
from fastapi.responses import StreamingResponse
from pydantic import BaseModel

from brain.api.auth import current_client

router = APIRouter()


class ChatCompletionRequest(BaseModel):
    messages: list[dict]
    model: str | None = None
    stream: bool = False

    class Config:
        extra = "ignore"


@router.get("/v1/voices")
async def v1_voices(request: Request, client: dict = Depends(current_client)):
    """OpenAI-style voices list — what mate-ios's settings screen calls."""
    from brain.api.client_api import voices

    return await voices(request, client)


@router.post("/v1/chat/completions")
async def chat_completions(
    body: ChatCompletionRequest,
    request: Request,
    client: dict = Depends(current_client),
):
    agent = request.app.state.agent
    history = [
        m for m in body.messages
        if m.get("role") in ("user", "assistant") and m.get("content")
    ]
    if not history:
        answer = "Hello."
    else:
        user_text = history.pop()["content"]
        answer = await agent.respond(history, user_text)

    completion_id = f"chatcmpl-{uuid.uuid4().hex}"
    created = int(time.time())
    model = body.model or "brain"

    if body.stream:
        def sse():
            chunk = {
                "id": completion_id,
                "object": "chat.completion.chunk",
                "created": created,
                "model": model,
                "choices": [
                    {"index": 0, "delta": {"role": "assistant", "content": answer},
                     "finish_reason": None}
                ],
            }
            yield f"data: {json.dumps(chunk, ensure_ascii=False)}\n\n"
            done = {**chunk, "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]}
            yield f"data: {json.dumps(done, ensure_ascii=False)}\n\n"
            yield "data: [DONE]\n\n"

        return StreamingResponse(sse(), media_type="text/event-stream")

    return {
        "id": completion_id,
        "object": "chat.completion",
        "created": created,
        "model": model,
        "choices": [
            {
                "index": 0,
                "message": {"role": "assistant", "content": answer},
                "finish_reason": "stop",
            }
        ],
        "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0},
    }
