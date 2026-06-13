"""Thin client for the vLLM OpenAI-compatible endpoint."""

import httpx

from brain.config import settings


class LLMClient:
    def __init__(self):
        self._http = httpx.AsyncClient(base_url=settings.llm_base_url, timeout=120)

    async def close(self) -> None:
        await self._http.aclose()

    async def chat(self, messages: list[dict], tools: list[dict] | None = None) -> dict:
        """One chat-completions call; returns the first choice's message."""
        body: dict = {
            "model": settings.llm_model,
            "messages": messages,
            "temperature": settings.llm_temperature,
        }
        if tools:
            body["tools"] = tools
        resp = await self._http.post("/chat/completions", json=body)
        resp.raise_for_status()
        return resp.json()["choices"][0]["message"]
