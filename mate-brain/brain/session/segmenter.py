"""Konu-tabanlı oturum segmentasyonu.

Her tur için: embedding ile aktif oturumun koşan-ortalama centroid'ine cosine
bak. Eşik üstü → aynı konu. Eşik altı → DOĞRUDAN konu sınırı (yeni oturum) — eskiden
tur-içi LLM hakemi vardı ama ucuz/yan-kanal bir sohbet-LLM'i kalmadığından (vLLM
donmuş, tek canlı LLM = bağlamı tutan kalıcı pi/Codex süreci) kaldırıldı; karar artık
yalnızca embedding'e dayanıyor. Uzun sessizlik (idle) → koşulsuz yeni oturum. Oturum
kapanırken arka planda TAZE STATELESS Codex (pi.complete_once) ile başlık/özet/açık-
konular çıkarılır (tur bloklanmaz, asıl bağlam kirlenmez).

Tasarım kuralları:
- resolve_session_for_turn turu BLOKLAMAMALI: kapatma pipeline'ı her zaman
  asyncio.create_task ile arka plana atılır; yeni oturum SENKRON açılır
  (tur hemen session_id alır).
- Hiçbir yol istisna fırlatmamalı (tur yoluna sızmaz); embedding yoksa
  güvenli varsayılan = aktif oturumu sürdür (sinyal yok → aşırı bölme yapma).
"""

from __future__ import annotations

import asyncio
import json
import logging
import re
import time

import numpy as np

log = logging.getLogger("brain.session")

_LLM_CLOSE_TIMEOUT = 60.0    # kapanış özeti (arka plan, taze stateless Codex)
_LLM_ROUTE_TIMEOUT = 90.0    # konu yönlendirmesi (transkript + mevcut konular → routing)


class SessionSegmenter:
    def __init__(self, db, intent, llm, bus, settings, pi=None):
        self.db = db
        self.intent = intent      # IntentRouter (embed) — None olabilir
        # llm: eski tur-içi LLM hakemi için tutuluyordu; hakem KALDIRILDI (ucuz bir
        # sohbet-LLM'i kalmadı) → şu an KULLANILMIYOR (ileride vLLM dönerse hazır dursun).
        self.llm = llm
        self.bus = bus
        self.settings = settings
        self.pi = pi              # PiBackend — kapanış özeti için stateless Codex; None olabilir

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

        # 3) Aynı konuşma öbeği sürüyor (idle değil) → AYNI oturum.
        # Embedding ile per-turn KONU BÖLME YAPILMAZ: e5 multilingual-small Türkçe
        # kısa sözlerde konuyu ayırt edemiyor (ölçüldü: alakasız sözler ~0.85 cosine,
        # hiçbir eşik çalışmıyor). Oturum sınırı = idle boşluğu (yukarıda) — yani
        # "konuşma öbeği" oturumu. Konu detayı kapanışta Codex özeti/açık-işlerinde.
        # Centroid yine de güncellenir ("X konulu oturumu bul" cosine araması için).
        # (session_sim_threshold şu an kullanılmıyor; daha iyi embedding gelince
        # segmentasyon yeniden açılabilir.)
        if emb is not None:
            await self._extend_centroid(active, emb)
        return active["id"]

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

            # Oturum-seviyesi başlık/özet hâlâ üretilir (liste/transkript ekranı için);
            # ASIL değer artık konu thread'lerinde. Açık işler ARTIK burada DEĞİL,
            # _route_to_topics içinde ilgili konuya bağlanarak yazılır (çift yazma yok).
            title, summary, _ = await self._summarize(turns)
            await self.db.close_session(sid, title, summary, now)

            # Retrospektif konu yönlendirmesi: konuşmayı konulara böl → mevcut thread'i
            # güncelle ya da yeni aç + açık işleri konuya bağla (güvenli, asla fırlatmaz).
            routed = await self._route_to_topics(session, turns)

            if self.bus:
                self.bus.emit(
                    "session_closed", "session", title or "(oturum)",
                    payload={
                        "session_id": sid,
                        "title": title,
                        "summary": summary,
                        "topics": routed,
                        "turn_count": len(turns),
                    },
                    conversation_id=scope_key,
                )
        except Exception:
            log.exception("oturum kapatma başarısız (arka plan) — yok sayıldı")

    async def _route_to_topics(self, session: dict, turns: list[dict]) -> list[dict]:
        """RETROSPEKTİF konu yönlendirmesi (oturum kapanışında, tur başına DEĞİL).
        Tek Codex çağrısı: transkript + bu scope'taki MEVCUT konu kayıtları → konuşmayı
        konulara böl; her konuyu mevcut bir thread'le EŞLEŞTİR (güncelle) ya da YENİ aç.
        Her konunun açık işleri ilgili konu thread'ine bağlanır. Asla fırlatmaz → []."""
        try:
            scope_key = session.get("scope_key")
            user_id = session.get("user_id")
            if not scope_key:
                return []

            existing = await self.db.topics_for_scope(scope_key)
            existing_ids = {t["id"] for t in existing}

            transcript = "\n".join(
                f"{t.get('role')}: {t.get('content')}" for t in turns if t.get("content")
            )

            if self.pi is None or not transcript:
                return []

            prompt = (
                "Sen bir ev asistanının KONU BELLEĞİsin. Aşağıda biten bir konuşmanın "
                "transkripti ve şu ana kadarki MEVCUT KONU kayıtları var. Konuşmayı "
                "konulara böl; her konuyu mevcut bir kayıtla EŞLEŞTİR (devamıysa) ya da "
                "YENİ aç. SADECE geçerli JSON döndür, başka hiçbir şey yazma:\n"
                '{"topics":[{"match_id": <mevcut konu id\'si (int) VEYA null>, '
                '"title":"<kısa konu başlığı>", "summary":"<bu konunun GÜNCEL durumu: '
                "varsa eski özet + bu konuşmadaki gelişme, 1-3 cümle Türkçe>\", "
                '"open_items":["<bu konuda AÇIK KALAN iş>", ...]}]}\n'
                "match_id: konu mevcut kayıtlardan birinin DEVAMIYSA o id; değilse null.\n"
                "open_items = kullanıcının İSTEYİP de henüz GERÇEKLEŞMEYEN her şey: "
                "cevaplanmamış sorular, yerine getirilmemiş istekler VE asistanın "
                "'erişimim yok / yapamam / bilmiyorum' deyip YAPAMADIĞI istekler (kullanıcı "
                "hâlâ istiyor → açık iş). Asistan işi GERÇEKTEN yaptıysa (ör. ışığı açtı) "
                "açık iş DEĞİL. Yoksa boş liste. Hepsi Türkçe, kısa emir kipi.\n\n"
                "MEVCUT KONULAR (JSON):\n"
                f"{json.dumps(existing, ensure_ascii=False)}\n\n"
                f"TRANSKRİPT:\n{transcript}\n"
            )

            out = await self.pi.complete_once(prompt, timeout=_LLM_ROUTE_TIMEOUT)
            data = self._parse_json(out)
            topics = data.get("topics", [])
            if not isinstance(topics, list):
                return []

            applied: list[dict] = []
            for t in topics:
                if not isinstance(t, dict):
                    continue
                title = (t.get("title") or "").strip()[:120]
                summary = (t.get("summary") or "").strip() or None
                raw_items = t.get("open_items") or []
                if not isinstance(raw_items, list):
                    raw_items = []
                open_items = [
                    str(x) for x in raw_items if isinstance(x, (str, int, float))
                ]

                match_id = t.get("match_id")
                matched = isinstance(match_id, int) and match_id in existing_ids
                if matched:
                    await self.db.update_topic(match_id, title, summary)
                    tid = match_id
                else:
                    tid = await self.db.create_topic(scope_key, user_id, title, summary)

                # Açık işleri ilgili konu thread'ine bağla (çift yazma yok).
                for item in open_items:
                    item_text = (item or "").strip()
                    if item_text:
                        await self.db.add_open_item(
                            session["id"], user_id, item_text, topic_id=tid
                        )

                if self.bus:
                    self.bus.emit(
                        "topic_updated", "topic", title or "(konu)",
                        payload={
                            "topic_id": tid,
                            "title": title,
                            "summary": summary,
                            "open_items": open_items,
                            "matched": matched,
                        },
                        conversation_id=scope_key,
                    )

                applied.append({
                    "topic_id": tid, "title": title, "summary": summary,
                    "open_items": open_items, "matched": matched,
                })
            return applied
        except Exception:
            log.warning("konu yönlendirmesi (topic routing) başarısız → atlandı")
            return []

    async def _summarize(self, turns: list[dict]) -> tuple[str | None, str | None, list[str]]:
        """Transkriptten STRICT JSON başlık/özet/açık-konular. Hata → savunmacı fallback."""
        first_user = next(
            (t["content"] for t in turns if t.get("role") == "user" and t.get("content")),
            None,
        )
        fallback_title = (first_user[:60] if first_user else None)

        if self.pi is None:
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
            # Taze STATELESS Codex (asistanın kalıcı bağlamı kirlenmez). Codex çıktıyı
            # sarabildiğinden _parse_json regex'i {...} bloğunu çekip alır.
            content = await self.pi.complete_once(prompt, timeout=_LLM_CLOSE_TIMEOUT)
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
            log.warning("oturum özeti Codex hatası → fallback başlık")
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
