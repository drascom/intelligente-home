"""Konu-tabanlı oturum segmentasyonu.

Her tur için: embedding ile aktif oturumun koşan-ortalama centroid'ine cosine
bak. Eşik üstü → aynı konu (LLM yok, ucuz). Eşik altı → kısa Türkçe LLM hakemi
(DEVAM / YENI). Uzun sessizlik (idle) → koşulsuz yeni oturum. Oturum kapanırken
arka planda LLM ile başlık/özet/açık-konular çıkarılır (tur bloklanmaz).

Tasarım kuralları:
- resolve_session_for_turn turu BLOKLAMAMALI: kapatma pipeline'ı her zaman
  asyncio.create_task ile arka plana atılır; yeni oturum SENKRON açılır
  (tur hemen session_id alır).
- Hiçbir yol istisna fırlatmamalı (tur yoluna sızmaz); embedding/LLM yoksa
  güvenli varsayılan = aktif oturumu sürdür (aşırı bölme yapma).
"""

from __future__ import annotations

import asyncio
import json
import logging
import re
import time

import numpy as np

log = logging.getLogger("brain.session")

_LLM_JUDGE_TIMEOUT = 8.0     # konu-devam hakemi (tur içinde, eşik altı)
_LLM_CLOSE_TIMEOUT = 20.0    # kapanış özeti (arka plan)


class SessionSegmenter:
    def __init__(self, db, intent, llm, bus, settings):
        self.db = db
        self.intent = intent      # IntentRouter (embed) — None olabilir
        self.llm = llm            # LLMClient (chat) — None olabilir
        self.bus = bus
        self.settings = settings

    # ---- ana giriş: tur için oturum çöz ----

    async def resolve_session_for_turn(
        self, scope_key: str, user_id: int | None, text: str
    ) -> int:
        """Bu tur hangi oturuma ait? Aktif oturumu sürdür ya da yeni aç; id döner.
        Tur'u bloklamadan (kapatma arka planda) çalışır, asla istisna fırlatmaz."""
        try:
            return await self._resolve(scope_key, user_id, text)
        except Exception:
            log.exception("segmenter resolve failed — legacy resolve_session'a düş")
            # Son çare: eski tek-oturum mantığı (asla turu düşürme).
            return await self.db.resolve_session(scope_key, user_id)

    async def _resolve(self, scope_key: str, user_id: int | None, text: str) -> int:
        emb = self._embed(text)
        active = await self.db.active_session(scope_key)

        # 1) Aktif oturum yok → yeni aç.
        if active is None:
            return await self._new_session(scope_key, user_id, emb)

        now = time.time()

        # 2) Idle guard: uzun boşluk = yeni konuşma. Eskiyi kapat (arka plan) + yeni aç.
        idle = self.settings.session_idle_seconds
        if idle and (now - (active.get("updated_at") or now)) > idle:
            self._schedule_close(active, user_id)
            return await self._new_session(scope_key, user_id, emb)

        # 3) Embedding + centroid varsa: cosine ölç.
        centroid = self._centroid_unit(active.get("centroid"))
        if emb is not None and centroid is not None:
            cosine = float(np.dot(emb, centroid))
            if cosine >= self.settings.session_sim_threshold:
                # Aynı konu (LLM YOK): koşan-ortalama centroid'i güncelle.
                await self._extend_centroid(active, emb)
                return active["id"]
            # Eşik altı → LLM hakem.
            same = await self._llm_continuation(active, text)
            if same:
                await self._extend_centroid(active, emb)
                return active["id"]
            self._schedule_close(active, user_id)
            return await self._new_session(scope_key, user_id, emb)

        # 4) Embedding yok (model yok) → sadece LLM hakem; o da yoksa aktif sürer.
        same = await self._llm_continuation(active, text)
        if same:
            # Embedding yoksa centroid güncellenemez; en azından updated_at tazelenir
            # (add_message zaten yapar) — burada ekstra yazma gerekmez.
            return active["id"]
        self._schedule_close(active, user_id)
        return await self._new_session(scope_key, user_id, emb)

    # ---- yardımcılar ----

    def _embed(self, text: str):
        if self.intent is None:
            return None
        try:
            return self.intent.embed(text)
        except Exception:
            return None

    @staticmethod
    def _centroid_unit(blob):
        """Saklı float32 centroid baytlarını normalize edilmiş vektöre çevir.
        Koşan-ortalama birim-norm olmayabilir → cosine için normalize et."""
        if not blob:
            return None
        try:
            arr = np.frombuffer(blob, dtype=np.float32).astype(np.float32)
            if arr.size == 0:
                return None
            norm = float(np.linalg.norm(arr))
            if norm == 0.0:
                return None
            return arr / norm
        except Exception:
            return None

    @staticmethod
    def _to_bytes(arr) -> bytes:
        return np.asarray(arr, dtype=np.float32).tobytes()

    async def _new_session(self, scope_key: str, user_id: int | None, emb) -> int:
        centroid = self._to_bytes(emb) if emb is not None else None
        count = 1 if emb is not None else 0
        return await self.db.create_session(scope_key, user_id, centroid, count)

    async def _extend_centroid(self, active: dict, emb) -> None:
        """Koşan-ortalama: (old*count + emb) / (count+1). Ham centroid baytlarından."""
        count = int(active.get("embed_count") or 0)
        old_blob = active.get("centroid")
        if old_blob and count > 0:
            try:
                old = np.frombuffer(old_blob, dtype=np.float32).astype(np.float32)
                new_centroid = (old * count + emb) / (count + 1)
            except Exception:
                new_centroid = emb
                count = 0
        else:
            new_centroid = emb
            count = 0
        await self.db.update_session_centroid(
            active["id"], self._to_bytes(new_centroid), count + 1
        )

    def _schedule_close(self, session: dict, user_id: int | None) -> None:
        """Kapatma pipeline'ını arka plana at — tur bloklanmasın."""
        asyncio.create_task(self._close_session(session, user_id))

    async def _llm_continuation(self, active: dict, text: str) -> bool:
        """Eşik altı / embedding yok: yeni söz aktif konunun DEVAMI mı?
        Tek token bekler: DEVAM | YENI. Hata/timeout/llm yok → DEVAM (aşırı bölme)."""
        if self.llm is None:
            return True
        try:
            recent = await self.db.recent_messages(active["id"], limit=4)
        except Exception:
            recent = []
        ctx_lines = [f"{m['role']}: {m['content']}" for m in recent]
        if not ctx_lines and active.get("summary"):
            ctx_lines = [f"özet: {active['summary']}"]
        context = "\n".join(ctx_lines) if ctx_lines else "(önceki tur yok)"
        prompt = (
            "Bir sesli asistan konuşmasında konu takibi yapıyorsun. Aşağıda devam "
            "eden oturumun son turları ve kullanıcının YENİ sözü var. Yeni söz aynı "
            "konunun DEVAMI mı, yoksa YENI bir konu mu? Sadece tek kelime cevap ver: "
            "DEVAM ya da YENI.\n\n"
            f"Son turlar:\n{context}\n\n"
            f"Yeni söz:\n{text}\n\n"
            "Cevap (DEVAM/YENI):"
        )
        try:
            resp = await asyncio.wait_for(
                self.llm.chat([{"role": "user", "content": prompt}]),
                timeout=_LLM_JUDGE_TIMEOUT,
            )
            answer = (resp.get("content") or "").strip().upper()
            # "YENI"/"YENİ" → yeni konu. Aksi (DEVAM dahil belirsiz) → devam.
            if "YENI" in answer or "YENİ" in answer:
                return False
            return True
        except Exception:
            log.warning("konu hakemi LLM hatası/timeout → DEVAM varsayılan")
            return True

    async def _close_session(self, session: dict, user_id: int | None) -> None:
        """Kapatma pipeline'ı (arka plan task'ı olarak güvenli). Asla fırlatmaz."""
        try:
            now = time.time()
            sid = session["id"]
            scope_key = session.get("scope_key")
            owner = user_id if user_id is not None else session.get("user_id")

            turns = await self.db.session_turns(sid)
            if not turns:
                await self.db.close_session(sid, None, None, now)
                return

            title, summary, open_items = await self._summarize(turns)

            await self.db.close_session(sid, title, summary, now)
            for item in open_items:
                item_text = (item or "").strip()
                if item_text:
                    await self.db.add_open_item(sid, owner, item_text)

            if self.bus:
                self.bus.emit(
                    "session_closed", "session", title or "(oturum)",
                    payload={
                        "session_id": sid,
                        "title": title,
                        "summary": summary,
                        "open_items": open_items,
                        "turn_count": len(turns),
                    },
                    conversation_id=scope_key,
                )
        except Exception:
            log.exception("oturum kapatma başarısız (arka plan) — yok sayıldı")

    async def _summarize(self, turns: list[dict]) -> tuple[str | None, str | None, list[str]]:
        """Transkriptten STRICT JSON başlık/özet/açık-konular. Hata → savunmacı fallback."""
        first_user = next(
            (t["content"] for t in turns if t.get("role") == "user" and t.get("content")),
            None,
        )
        fallback_title = (first_user[:60] if first_user else None)

        if self.llm is None:
            return fallback_title, None, []

        transcript = "\n".join(
            f"{t.get('role')}: {t.get('content')}" for t in turns if t.get("content")
        )
        prompt = (
            "Aşağıda biten bir sesli asistan konuşmasının transkripti var. SADECE "
            "geçerli JSON döndür, başka hiçbir şey yazma:\n"
            '{"title": "<=6 kelime başlık", "summary": "1-2 cümle özet", '
            '"open_items": ["çözülmemiş soru/istek", ...]}\n'
            "open_items = kullanıcının sorup CEVAPLANMAYAN soruları, yerine "
            "getirilMEYEN istekleri ya da açıkça sonraya bırakılan konular; yoksa "
            "boş liste. Hepsi Türkçe.\n\n"
            f"Transkript:\n{transcript}\n"
        )
        try:
            resp = await asyncio.wait_for(
                self.llm.chat([{"role": "user", "content": prompt}]),
                timeout=_LLM_CLOSE_TIMEOUT,
            )
            content = resp.get("content") or ""
            data = self._parse_json(content)
            title = data.get("title") or fallback_title
            summary = data.get("summary")
            open_items = data.get("open_items") or []
            if not isinstance(open_items, list):
                open_items = []
            # sadece string öğeler
            open_items = [str(x) for x in open_items if isinstance(x, (str, int, float))]
            return (
                (str(title)[:120] if title else None),
                (str(summary) if summary else None),
                open_items,
            )
        except Exception:
            log.warning("oturum özeti LLM hatası → fallback başlık")
            return fallback_title, None, []

    @staticmethod
    def _parse_json(content: str) -> dict:
        """İlk {...} bloğunu yakala + json.loads. Başarısız → {}."""
        if not content:
            return {}
        m = re.search(r"\{.*\}", content, re.DOTALL)
        if not m:
            return {}
        try:
            data = json.loads(m.group(0))
            return data if isinstance(data, dict) else {}
        except (json.JSONDecodeError, TypeError, ValueError):
            return {}
