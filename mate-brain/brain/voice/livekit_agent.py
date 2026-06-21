"""LiveKit server-side voice agent — a WebRTC-transport twin of `Satellite`.

This is a DELIBERATE DUPLICATE of the satellite/voice-bridge turn orchestration
(resolve-session → presence → deliveries → agent.respond → save → emit). It does
NOT share a helper with `satellite.py` or `api/voice.py` on purpose: the existing
WebSocket + Wyoming satellite paths are the working voice plane and must not be
refactored. This agent reuses the same PRIMITIVES (WhisperSession, agent.respond,
synthesize_stream, speaker-ID) but runs over a LiveKit `rtc.Room` instead of
Wyoming TCP / the Bridge WebSocket.

Flag-gated: only started from main.py when `livekit_agent_enabled` is true AND a
LiveKit API secret is configured. With the flag off, this module is never
imported and behaviour is unchanged.

Audio plane:
- We join `settings.livekit_room` as identity "assistant", publish one mic-source
  audio track (s16le → 48 kHz mono frames the SDK delivers to subscribers).
- We subscribe to the first remote human participant's audio track and pull frames
  via `rtc.AudioStream`, asking the SDK to deliver them already resampled to
  16 kHz / mono / s16 — exactly what WhisperSession + speaker-ID want.
- Endpointing reuses the satellite RMS-silence + hard-cap detector.
- TTS replies are synthesized via `synthesize_stream`, converted to s16le, framed
  into `rtc.AudioFrame`s, and captured into the published `rtc.AudioSource`.
"""

import asyncio
import logging
from array import array

from wyoming.event import Event as WyomingEvent

from brain.api.voice import looks_hallucinated
from brain.monitor.bus import emit_turn
from brain.notify.reminders import (
    DEFER_ACK,
    consume_deliveries,
    delivery_text,
    is_defer,
    peek_deliveries,
)
from brain.voice.services import WhisperSession
from brain.voice.tts import synthesize_stream, to_s16le

log = logging.getLogger("brain.voice.livekit")

RECONNECT_DELAY = 5
SILENCE_RMS = 700          # int16 mean-abs level treated as silence (satellite ile aynı)
SILENCE_AFTER_S = 1.0      # bu kadar son-sessizlikten sonra utterance biter
MAX_UTTERANCE_S = 12.0     # utterance başına sert tavan
# Barge-in: uçuştaki TTS cevabını kesmek için gereken SÜREKLİ (ardışık) konuşma
# süresi. Tek bir gürültü/eko karesi cevabı kesmesin diye eşik (özellikle uzun
# cevaplarda gürültülü ortamda kesilme oluyordu). VPIO eko'yu zaten bastırır; bu da
# kısa dış-gürültü blip'lerini eler, gerçek (sürekli) konuşma yine barge-in yapar.
BARGE_IN_MIN_S = 0.25  # gerçek barge-in: ~0.25sn sürekli konuşma asistanı keser

# STT, speaker-ID ve endpointing'in beklediği biçim. AudioStream'e bu hedefi
# verince SDK kareleri içeride bu orana indirir (manuel AudioResampler gerekmez).
STT_RATE = 16000
STT_WIDTH = 2
STT_CHANNELS = 1

# Yayınladığımız ses kaynağının biçimi (LiveKit aboneleri 48 kHz mono ister).
PUB_RATE = 48000
PUB_CHANNELS = 1


class LiveKitAgent:
    def __init__(self, app, settings):
        self.app = app
        self.settings = settings
        self.db = app.state.db
        self.agent = app.state.agent
        self.speaker = getattr(app.state, "speaker", None)
        self.bus = getattr(app.state, "bus", None)
        self.connected = False
        # rtc nesneleri run() içinde kurulur (modül import edilince livekit şart olmasın).
        self._source = None          # rtc.AudioSource (yayınladığımız ses)
        self._room = None            # rtc.Room (transcript yayını için)
        self._pub_track_sid = None   # yayınladığımız ses track'inin sid'i (attribution)
        self._tts_task: asyncio.Task | None = None  # uçuşta TTS (barge-in için iptal)
        # Proaktif hatırlatma teslimi: vakti gelen bildirimleri kullanıcı konuşmadan
        # söyleyen arka plan yoklayıcısı + teslim peek/consume'u utterance yoluyla
        # serileştiren kilit (çift teslim olmasın).
        self._poll_task: asyncio.Task | None = None
        self._deliver_lock = asyncio.Lock()
        # Şu an tüketilen AudioStream referansı (bulletproof reconnect): `async for`
        # askıdayken oda koparsa harici bir handler bunu aclose() ile uyandırabilir.
        # _consume_track stream'i kurunca set eder, finally'de None'a çeker.
        self._active_stream = None
        # Uzak katılımcı attribute'ları (per-client ayarlar + candan.awake), kimlik
        # bazlı önbellek. `participant_attributes_changed` event'i ile beslenir.
        # NEDEN: bu SDK sürümünde `RemoteParticipant.attributes` view'ı utterance
        # anında boş gelebiliyor (istemci set(attributes:) ile yayınlasa bile) →
        # wake gate no-op + ayarlar etkisiz olurdu. Event her değişimde TAM/fresh
        # geldiği için _attrs() bunu canlı view'ın üstüne bindirir.
        self._attr_cache: dict[str, dict] = {}

    @property
    def conversation_id(self) -> str:
        # Tek odalı demo: oda adına bağlı kapsam (satellite-<name> ile aynı desen).
        return f"livekit-{self.settings.livekit_room}"

    def _mint_token(self) -> str:
        """Agent için sunucu-taraflı JWT (publish+subscribe). Endpoint ile aynı
        livekit-api çağrısı; kimlik 'assistant'. kind=agent → istemci tarafında
        `session.agent` algılanır (sohbet toggle'ı açılır)."""
        from datetime import timedelta

        from livekit import api

        grants = api.VideoGrants(
            room_join=True,
            room=self.settings.livekit_room,
            can_publish=True,
            can_subscribe=True,
            # Agent kendi `lk.agent.state` attribute'unu set_attributes ile güncelliyor;
            # bu izin olmadan sunucu reddeder (istemci agentState'i süremez).
            can_update_own_metadata=True,
        )
        at = (
            api.AccessToken(self.settings.livekit_api_key, self.settings.livekit_api_secret)
            .with_identity("assistant")
            .with_name("Candan")
            .with_ttl(timedelta(seconds=self.settings.livekit_token_ttl_seconds))
            .with_grants(grants)
        )
        # kind=agent: istemci bu katılımcıyı "agent" olarak görür (isConnected=true).
        # Sürüm farkına dayanıklı (with_kind yoksa standart katılımcı olarak kalır).
        try:
            at = at.with_kind("agent")
        except (AttributeError, TypeError) as e:
            log.warning("livekit agent: token kind=agent ayarlanamadı: %r", e)
        # Katılır katılmaz görünür ilk durum (varsa token attribute'una göm).
        try:
            at = at.with_attributes({"lk.agent.state": "initializing"})
        except (AttributeError, TypeError):
            pass
        return at.to_jwt()

    async def run(self) -> None:
        """Reconnect-forever loop. Arka plan task'ı olarak çalıştırılır."""
        while True:
            try:
                await self._session()
            except asyncio.CancelledError:
                raise
            except Exception as e:
                log.warning("livekit agent: oturum bitti (%s); %ss sonra tekrar",
                            e, RECONNECT_DELAY)
            self.connected = False
            self._source = None
            self._room = None
            if self._poll_task:
                self._poll_task.cancel()
                self._poll_task = None
            if self._tts_task:
                self._tts_task.cancel()
                self._tts_task = None
            await asyncio.sleep(RECONNECT_DELAY)

    async def _session(self) -> None:
        from livekit import rtc

        room = rtc.Room()
        # Uzak katılımcının ses track'i geldiğinde işlenmek üzere kuyruğa al.
        track_queue: asyncio.Queue = asyncio.Queue()

        @room.on("track_subscribed")
        def _on_track_subscribed(track, publication, participant):
            # Sadece insan (assistant olmayan) katılımcının ses track'i.
            if track.kind == rtc.TrackKind.KIND_AUDIO and participant.identity != "assistant":
                log.info("livekit agent: ses track'i abone olundu (%s)", participant.identity)
                track_queue.put_nowait((track, participant))

        @room.on("disconnected")
        def _on_disconnected(reason):
            log.warning("livekit agent: odadan koptu (%s)", reason)
            track_queue.put_nowait(None)  # _session'ı uyandır → reconnect
            # KİLİT FİX (#6): ajan o an _consume_track içinde 'async for event in
            # stream' ile bekliyorsa, oda kopunca stream yield'i kesip ASKIDA kalır →
            # None hiç okunmaz, ConnectionError fırlatılmaz, reconnect olmaz. Aktif
            # stream'i aclose ederek async for'u sonlandır (idempotent: _consume_track
            # finally'si de kapatır). İstemci mic'i sürekli yayınladığından ajan
            # neredeyse her zaman _consume_track içindedir → bu fix kritik.
            st = self._active_stream
            if st is not None:
                try:
                    asyncio.create_task(st.aclose())
                except RuntimeError:
                    pass  # çalışan loop yok (beklenmez) → sessiz geç

        @room.on("participant_attributes_changed")
        def _on_attrs_changed(changed_attributes, participant):
            # İstemcinin yayınladığı attribute'ları (candan.awake + stt_engine/
            # voice/language) kimlik bazlı önbelleğe işle. Asistanın kendi
            # attribute'larını (lk.agent.state) yok say.
            ident = getattr(participant, "identity", None)
            if not ident or ident == "assistant":
                return
            try:
                self._attr_cache.setdefault(ident, {}).update(
                    dict(changed_attributes or {})
                )
            except Exception:
                pass
            log.info("livekit agent: attrs değişti (%s): %r", ident, changed_attributes)

        # Yeni oturum → eski önbelleği temizle (kimlikler/ayarlar bayatlamasın).
        self._attr_cache = {}
        # Aktif AudioStream — kopunca _on_disconnected aclose etsin diye tutulur.
        self._active_stream = None

        token = self._mint_token()
        await room.connect(self.settings.livekit_url, token)
        self.connected = True
        log.info("livekit agent: '%s' odasına bağlandı (%s)",
                 self.settings.livekit_room, self.settings.livekit_url)

        # Yanıt sesini yayınlamak için tek bir ses kaynağı + track yayınla.
        source = rtc.AudioSource(sample_rate=PUB_RATE, num_channels=PUB_CHANNELS)
        track = rtc.LocalAudioTrack.create_audio_track("assistant", source)
        options = rtc.TrackPublishOptions(source=rtc.TrackSource.SOURCE_MICROPHONE)
        await room.local_participant.publish_track(track, options)
        self._source = source
        self._room = room
        # Yayınladığımız track'in sid'i: asistan transcript'ini bu track'e bağlamak için.
        self._pub_track_sid = getattr(track, "sid", None)
        # Yayına hazırız → REST durumu = "idle" (istemci agentState'i bununla
        # sürer; idle → 10sn oto-uyku zamanlayıcısını kurar).
        self._set_agent_state("idle")
        # Proaktif teslim yoklayıcısını başlat (vakti gelen hatırlatmaları
        # kullanıcı konuşmadan söyler).
        self._poll_task = asyncio.create_task(self._poll_deliveries())

        try:
            # Halihazırda odadaki uzak katılımcıların ses track'lerini de yakala
            # (biz katılmadan önce abone olunmuş olabilir).
            for participant in room.remote_participants.values():
                if participant.identity == "assistant":
                    continue
                for pub in participant.track_publications.values():
                    if pub.track is not None and pub.kind == rtc.TrackKind.KIND_AUDIO:
                        track_queue.put_nowait((pub.track, participant))

            while True:
                item = await track_queue.get()
                if item is None:
                    raise ConnectionError("livekit room disconnected")
                track, participant = item
                # İlk insan track'ini tükenene dek işle (utterance döngüsü içeride).
                await self._consume_track(rtc, track, participant)
        finally:
            self.connected = False
            self._source = None
            self._room = None
            if self._poll_task:
                self._poll_task.cancel()
                self._poll_task = None
            if self._tts_task:
                self._tts_task.cancel()
                self._tts_task = None
            try:
                await room.disconnect()
            except Exception:
                pass

    async def _consume_track(self, rtc, track, participant=None) -> None:
        """Bir uzak ses track'inden kareleri çek; RMS endpointing ile utterance
        sınırlarını bul; her utterance'ı işle. SDK kareleri 16 kHz/mono/s16'ya
        indirir (AudioStream sample_rate/num_channels).

        `participant`: track'in sahibi insan katılımcı. Per-client ayarları
        (`stt_engine` / `voice` / `language`) bu katılımcının LiveKit
        attribute'larından (`participant.attributes`) okunur."""
        stream = rtc.AudioStream.from_track(
            track=track, sample_rate=STT_RATE, num_channels=STT_CHANNELS
        )
        # Kopunca _on_disconnected'in sonlandırabilmesi için aktif stream'i yayınla
        # (bulletproof reconnect: askıdaki `async for`u aclose ile uyandırır).
        self._active_stream = stream
        stt: WhisperSession | None = None
        buf = bytearray()           # voice-ID için ham utterance PCM (s16le 16k mono)
        speech_seen = False
        consec_speech_s = 0.0       # ardışık konuşma süresi (barge-in eşiği için)
        silence_s = 0.0
        utterance_s = 0.0
        utterance_awake = True      # bu utterance BAŞINDA istemci uyanık mıydı (wake gate)
        try:
            async for event in stream:
                frame = event.frame  # rtc.AudioFrame
                payload = bytes(frame.data)  # s16le interleaved (mono)
                if not payload:
                    continue

                if stt is None:
                    # Per-client ayarlar: STT motoru + dil katılımcı attribute'larından.
                    attrs = self._attrs(participant)
                    # TEŞHİS: brain'in gerçekte gördüğü BİRLEŞİK attribute'lar (canlı
                    # view + event önbelleği). Wake gate + settings buradan okunuyor.
                    # Hâlâ boşsa istemci attribute'ı HİÇ yayınlamamış demek (event de
                    # gelmemiş). Doğrulama sonrası bu log kaldırılacak.
                    log.info("livekit agent: attrs=%r (participant=%s)",
                             attrs, getattr(participant, "identity", "?"))
                    # Wake gate: utterance BAŞINDA uyanık mıydı? Bitişte değil başta
                    # okunur → istemci hemen sonra uyusa bile yarış olmaz. Attribute
                    # yoksa uyanık say (geri-uyum).
                    utterance_awake = attrs.get("candan.awake", "1") != "0"
                    engine_name, stt_host, stt_port = self.settings.resolve_stt_engine(
                        attrs.get("stt_engine")
                    )
                    language = attrs.get("language") or self.settings.stt_language
                    stt = WhisperSession(stt_host, stt_port, language)
                    log.info(
                        "livekit agent: STT motoru=%s (%s:%s) dil=%s",
                        engine_name, stt_host, stt_port, language or "(auto)",
                    )
                    try:
                        await stt.start(rate=STT_RATE, width=STT_WIDTH, channels=STT_CHANNELS)
                    except (ConnectionError, OSError) as e:
                        log.warning("livekit agent: STT erişilemiyor: %s", e)
                        stt = None
                        continue
                    buf = bytearray()
                    speech_seen = False
                    consec_speech_s = 0.0
                    silence_s = 0.0
                    utterance_s = 0.0

                await stt.feed(
                    WyomingEvent(
                        type="audio-chunk",
                        data={"rate": STT_RATE, "width": STT_WIDTH, "channels": STT_CHANNELS},
                        payload=payload,
                    )
                )
                buf.extend(payload)
                n_samples = len(payload) // (STT_WIDTH * STT_CHANNELS)
                chunk_s = n_samples / STT_RATE if STT_RATE else 0.0
                utterance_s += chunk_s

                if self._is_silence(payload, STT_WIDTH):
                    silence_s += chunk_s
                    consec_speech_s = 0.0  # sessizlik ardışık konuşmayı sıfırlar
                else:
                    # Kullanıcı konuşmaya BAŞLADI (ilk gerçek konuşma karesi) →
                    # idle→listening geçişi (utterance başına bir kez). İstemci bu
                    # değişimi görünce 10sn oto-uyku zamanlayıcısını İPTAL eder →
                    # cümle ortasında uyumaz. NOT: TTS kesme (barge-in) burada DEĞİL;
                    # aşağıda SÜREKLİ konuşma eşiğiyle (BARGE_IN_MIN_S) yapılır ki kısa
                    # blip/eko uzun cevabı kesmesin (#8/#9). Sleep-timer iptali ise
                    # ilk karede olmalı: kısa komutlar 0.25sn eşiğine ulaşmadan bitebilir.
                    if not speech_seen:
                        self._set_agent_state("listening")
                    speech_seen = True
                    silence_s = 0.0
                    consec_speech_s += chunk_s
                    # Barge-in: uçuştaki TTS cevabını kes — ama TEK karede değil,
                    # SÜREKLİ konuşma eşiği (BARGE_IN_MIN_S) aşılınca. Gürültülü
                    # ortamda kısa blip/eko cevabı (özellikle uzun cevabı) kesmesin;
                    # gerçek (sürekli) konuşma yine keser.
                    if (consec_speech_s >= BARGE_IN_MIN_S
                            and self._tts_task and not self._tts_task.done()):
                        self._tts_task.cancel()

                ended = (speech_seen and silence_s >= SILENCE_AFTER_S) or (
                    utterance_s >= MAX_UTTERANCE_S
                )
                if ended:
                    session, stt = stt, None
                    # LLM/TTS'e sert tavan: utterance işleme takılırsa (model/ağ)
                    # track tüketicisi kilitlenmesin → uyar ve döngüye devam et.
                    try:
                        await asyncio.wait_for(
                            self._handle_utterance(
                                session, bytes(buf), participant, track, utterance_awake
                            ),
                            timeout=60.0,
                        )
                    except asyncio.TimeoutError:
                        log.warning(
                            "livekit agent: utterance işleme 60sn'i aştı, atlandı"
                        )
        except asyncio.CancelledError:
            raise
        except Exception as e:
            log.warning("livekit agent: track tüketimi bitti (%s)", e)
        finally:
            # finally ASLA askıda kalmamalı (aksi halde reconnect döngüsü tıkanır):
            # aclose/abort'u kısa timeout'a sar, her hatayı yut.
            self._active_stream = None
            if stt is not None:
                try:
                    await asyncio.wait_for(stt.abort(), timeout=2.0)
                except (asyncio.TimeoutError, Exception):
                    pass
            try:
                await asyncio.wait_for(stream.aclose(), timeout=2.0)
            except (asyncio.TimeoutError, Exception):
                pass

    @staticmethod
    def _is_silence(payload: bytes | None, width: int) -> bool:
        if not payload or width != 2:
            return not payload
        samples = array("h")
        samples.frombytes(payload[: len(payload) - len(payload) % 2])
        if not samples:
            return True
        mean_abs = sum(abs(s) for s in samples) / len(samples)
        return mean_abs < SILENCE_RMS

    async def _identify(self, pcm: bytes) -> str | None:
        """Biriken utterance PCM'inden kişiyi tanı (voice-ID). s16le 16k mono."""
        sp = self.speaker
        if sp is None or not pcm:
            return None
        n_samples = len(pcm) // 2
        if n_samples < int(self.settings.speaker_min_seconds * STT_RATE):
            return None
        try:
            emb = await asyncio.to_thread(sp.embed_pcm, pcm, STT_RATE, 2, 1)
            name, score = sp.identify(emb)
            log.info("livekit agent: speaker-ID %s (%.3f)", name or "unknown", score)
            return name
        except Exception as e:
            log.warning("livekit agent: speaker-ID failed: %s", e)
            return None

    async def _handle_utterance(
        self, stt: WhisperSession, pcm: bytes = b"", participant=None, track=None,
        awake: bool = True,
    ) -> None:
        """DUPLICATE turn-logic (satellite.py / api/voice.py ile aynı sıra):
        transcript → resolve-session → presence → deliveries → agent.respond →
        save → emit → TTS. Paylaşımlı helper'a çıkarılmadı (çalışan yolları
        bozmamak için bilinçli kopya).

        `awake`: utterance BAŞINDA istemci uyanık mıydı (sunucu wake gate). Uykuda
        başladıysa, transcript alınır (log için) ama işlenmez (cevap/transcript yok)."""
        try:
            text = (await stt.finish()).strip()
        except (ConnectionError, OSError, asyncio.TimeoutError) as e:
            log.warning("livekit agent: STT başarısız: %s", e)
            return
        log.info("livekit agent: duyuldu %r", text)
        # Sunucu wake gate: utterance uyku modunda BAŞLADIYSA boş/hayalet transcript
        # gibi düşür — cevap yok, add_message yok, transcript yayını yok. İstemci
        # mute'u sesi durdurmuyor; "candan" sızıntısı burada engellenir.
        if not awake:
            log.info("livekit agent: uyku modunda söz, atlandı: %r", text[:60])
            self._set_agent_state("idle")
            return
        if text and looks_hallucinated(text):
            log.info("livekit agent: transcript hayalet görünüyor, atlanıyor: %r", text[:80])
            text = ""
        if not text:
            return

        speaker = await self._identify(pcm)
        speaker_id = self.speaker.id_for(speaker) if (self.speaker and speaker) else None

        # Tanınan kişi → kullanıcı-kapsamlı oturum; yoksa oda-kapsamı.
        scope_key, user_id = (
            (f"user-{speaker_id}", speaker_id) if speaker_id else (self.conversation_id, None)
        )
        device_id = f"livekit:{self.settings.livekit_room}"
        session_id = await self.db.resolve_session(scope_key, user_id)
        if user_id is not None:
            await self.db.set_presence(user_id, device_id)
        # Teslim peek/consume'u kilit altında yap → proaktif yoklayıcı ile çift
        # teslim olmasın. Kilit kısa tutulur (LLM/TTS kilit dışında).
        async with self._deliver_lock:
            pending = await peek_deliveries(self.db, user_id, device_id=device_id)
            if pending and is_defer(text):
                answer = DEFER_ACK
            elif pending:
                await consume_deliveries(self.db, pending)
                answer = delivery_text(pending)
            else:
                answer = None
        if answer is None:
            # LLM turu başlıyor → istemci "düşünüyor" durumunu görür (teslim/defer
            # yolları respond çağırmaz; onlar doğrudan speaking'e geçer).
            self._set_agent_state("thinking")
            history = await self.db.recent_messages(session_id)
            try:
                answer = await self.agent.respond(
                    history, text, speaker=speaker, speaker_id=speaker_id,
                    conversation_id=scope_key,
                )
            except Exception as e:
                log.error("livekit agent: agent başarısız: %s", e)
                answer = "Sorry, something went wrong."
        await self.db.add_message(session_id, "user", text, speaker=speaker)
        await self.db.add_message(session_id, "assistant", answer)
        emit_turn(self.bus, scope_key, None, text, answer, speaker=speaker)
        log.info("livekit agent: yanıt %r", (answer or "")[:160])

        # İstemci sohbet arayüzü için transcript'leri yayınla. Best-effort + ayrı
        # task → turn'ü ve TTS'i bloklamaz, hata olursa turn bozulmaz.
        human_track_sid = getattr(track, "sid", None)
        asyncio.create_task(self._publish_transcripts(text, answer, human_track_sid))

        if answer:
            # İstemcinin seçtiği TTS sesi (attribute), yoksa varsayılan.
            voice = self._attrs(participant).get("voice") or None
            # TTS'i ayrı task'ta çal → bir sonraki utterance barge-in ile iptal edebilsin.
            # _speak başında "speaking", bitince "idle" durumunu yayar.
            self._tts_task = asyncio.create_task(self._speak(answer, voice))
        else:
            # Yanıt yok → REST'e dön (aksi halde "thinking"de takılı kalır).
            self._set_agent_state("idle")

    async def _poll_deliveries(self) -> None:
        """Arka plan döngüsü: vakti gelip chime çalınmış (notified) ama henüz
        teslim edilmemiş hatırlatmaları proaktif olarak söyler — kullanıcının
        konuşmasını beklemeden. Yönlendirme presence ile: bu oda cihazına
        (`livekit:<room>`) işaret eden kullanıcıların teslimleri. notified_at'i
        global ReminderScheduler ayarlar; biz sadece teslim ederiz (çift işlem yok).
        Satellite chime→teslim akışının LiveKit karşılığı (orada bir sonraki
        utterance'a iliştirilirdi; burada proaktif)."""
        device_id = f"livekit:{self.settings.livekit_room}"
        while True:
            try:
                await self._deliver_due(device_id)
            except asyncio.CancelledError:
                raise
            except Exception as e:
                log.warning("livekit agent: proaktif teslim tick hatası: %r", e)
            await asyncio.sleep(self.settings.reminder_poll_seconds)

    async def _deliver_due(self, device_id: str) -> None:
        """Bir tick: bu cihaza yönlenmiş bekleyen teslim varsa söyle. Asistan zaten
        konuşuyorsa/oda yoksa atla (üstüne konuşma). peek+consume kilit altında →
        utterance yolu ile çift teslim olmaz."""
        if self._room is None:
            return
        # Asistan konuşuyorsa bu tur atla (bir sonraki tick'te tekrar denenir).
        if self._tts_task is not None and not self._tts_task.done():
            return
        async with self._deliver_lock:
            pending = await peek_deliveries(self.db, None, device_id=device_id)
            if not pending:
                return
            await consume_deliveries(self.db, pending)

        # Kullanıcıya göre grupla → doğru oturuma yaz, ayrı ayrı teslim et.
        by_user: dict[int | None, list[dict]] = {}
        for t in pending:
            by_user.setdefault(t.get("user_id"), []).append(t)

        for user_id, tasks in by_user.items():
            answer = delivery_text(tasks)
            if not answer:
                continue
            scope_key = f"user-{user_id}" if user_id else self.conversation_id
            session_id = await self.db.resolve_session(scope_key, user_id)
            await self.db.add_message(session_id, "assistant", answer)
            emit_turn(self.bus, scope_key, None, "", answer)
            log.info("livekit agent: proaktif teslim %r", answer[:160])
            # Transcript (sadece asistan satırı; kullanıcı satırı boş → atlanır) + TTS.
            asyncio.create_task(self._publish_transcripts("", answer, None))
            # Hatırlatma geliyor → istemci kısa bir zil çalabilsin (TTS'ten ÖNCE).
            await self._send_cue("reminder")
            # _speak'i self._tts_task'a ata → kullanıcı araya girerse barge-in iptal
            # edebilsin; speaking/listening durumunu da _speak yönetir.
            self._tts_task = asyncio.create_task(self._speak(answer))
            try:
                await self._tts_task
            except asyncio.CancelledError:
                # Proaktif teslim sırasında kullanıcı konuştu (barge-in): kalan
                # kullanıcıların teslimini bu tur bırak, bir sonraki tick'te sürer.
                log.info("livekit agent: proaktif teslim barge-in ile kesildi")
                break

    async def _send_cue(self, cue: str = "reminder") -> None:
        """İstemciye kısa bir işaret gönder (topic=`candan.cue`, metin=cue) → istemci
        proaktif TTS'ten önce bir hatırlatma zili çalabilir. Best-effort: oda yoksa /
        hata olursa teslimi bozmaz (sadece log). send_text topic'i bu SDK'da çalışır
        (_publish_text de kullanıyor)."""
        room = self._room
        if room is None:
            return
        try:
            await room.local_participant.send_text(cue, topic="candan.cue")
            log.info("livekit agent: cue gönderildi (%s)", cue)
        except Exception as e:
            log.warning("livekit agent: cue gönderilemedi (%s): %r", cue, e)

    def _set_agent_state(self, state: str) -> None:
        """`lk.agent.state` attribute'unu güncelle (initializing/listening/thinking/
        speaking/idle). İstemci agentState'i bununla sürer → wake re-arm + UI.
        BLOKLAMAZ: set_attributes'i ayrı task'a zamanlar → cancel/finally yollarında
        (barge-in) bile güvenle çağrılır. set_attributes sunucuda merge'lenir (diğer
        attribute'ları silmez). Best-effort: oda yoksa/sürüm farkı/hata turn'ü bozmaz."""
        room = self._room
        if room is None:
            return

        async def _apply() -> None:
            try:
                await room.local_participant.set_attributes({"lk.agent.state": state})
            except Exception as e:
                log.warning("livekit agent: agent-state ayarlanamadı (%s): %r", state, e)

        try:
            asyncio.create_task(_apply())
        except RuntimeError:
            pass  # çalışan event loop yok (beklenmez) → sessizce atla

    def _attrs(self, participant) -> dict:
        """Katılımcının LiveKit attribute'larını dict olarak ver (yoksa boş).
        Per-client ayarlar (stt_engine / voice / language) + candan.awake buradan
        okunur. Canlı `participant.attributes` view'ı ile event-beslemeli önbelleği
        birleştirir: canlı view bu SDK sürümünde boş gelebildiği için, kimlik bazlı
        önbellek (participant_attributes_changed) üstüne bindirilir (en taze kazanır)."""
        merged: dict = {}
        try:
            a = getattr(participant, "attributes", None)
            if a:
                merged.update(dict(a))
        except Exception:
            pass
        ident = getattr(participant, "identity", None)
        if ident:
            merged.update(self._attr_cache.get(ident, {}))
        return merged

    async def _publish_transcripts(
        self, user_text: str, assistant_text: str, human_track_sid: str | None
    ) -> None:
        """Kullanıcı ve asistan satırlarını istemcinin sohbet/transkript arayüzüne
        yayınla. Önce kullanıcı (insan track'ine bağlı), sonra asistan (bizim
        yayın track'imize bağlı) → istemcide doğru kişiye atfedilir."""
        await self._publish_text(user_text, track_sid=human_track_sid, role="user")
        await self._publish_text(
            assistant_text, track_sid=self._pub_track_sid, role="assistant"
        )

    async def _publish_text(
        self, text: str, *, track_sid: str | None = None, role: str = ""
    ) -> None:
        """Tek bir metin satırını `lk.transcription` text-stream topic'inde yayınla.
        LiveKit Components (Swift) bu topic'i transkript olarak render eder; satırı
        `lk.transcribed_track_id` attribute'u ile ilgili track'in sahibine atfeder.
        Best-effort: SDK imza farkları (attributes kwarg yoksa) ve hatalar yutulur."""
        room = self._room
        if room is None or not text:
            return
        attrs = {"lk.transcription_final": "true"}
        if track_sid:
            attrs["lk.transcribed_track_id"] = track_sid
        # Açık konuşmacı rolü: istemci bunu okuyup satırı doğru kişiye atfeder.
        # (SDK'nın varsayılan transcription receiver'ı yalnız gönderen kimliğine
        # bakar → her iki satır da "assistant"tan geldiği için yanlış atfederdi.)
        if role:
            attrs["candan.role"] = role
        try:
            lp = room.local_participant
            try:
                await lp.send_text(text, topic="lk.transcription", attributes=attrs)
            except TypeError:
                # Daha eski SDK: attributes kwarg'ı yok → topic'siz/attr'siz dene.
                try:
                    await lp.send_text(text, topic="lk.transcription")
                except TypeError:
                    await lp.send_text(text)
            log.info(
                "livekit agent: transcript yayınlandı (%s, %d karakter, track=%s)",
                role, len(text), track_sid or "-",
            )
        except Exception as e:
            log.warning("livekit agent: transcript yayınlanamadı (%s): %r", role, e)

    async def _speak(self, text: str, voice: str | None = None) -> None:
        """synthesize_stream → s16le → 48 kHz mono rtc.AudioFrame'ler → kaynağa
        capture. Barge-in olursa task iptal edilir (CancelledError yutulur).
        `voice`: istemcinin seçtiği TTS sesi (None = motor varsayılanı)."""
        from livekit import rtc

        source = self._source
        if source is None:
            log.warning("livekit agent: TTS atlandı — yayın kaynağı yok")
            self._set_agent_state("idle")
            return
        fmt = None
        frames_pub = 0
        bytes_in = 0
        try:
            async for kind, value in synthesize_stream(text, voice):
                if kind == "start":
                    fmt = value
                    # Ses başladı → istemci "speaking" görür (TTS sesi ile senkron).
                    self._set_agent_state("speaking")
                    log.info("livekit agent: TTS başladı (fmt rate=%s ch=%s)",
                             getattr(fmt, "rate", "?"), getattr(fmt, "channels", "?"))
                elif kind == "chunk" and fmt is not None:
                    pcm = to_s16le(value, fmt)
                    bytes_in += len(pcm)
                    frames_pub += await self._capture_s16le(
                        rtc, source, pcm, fmt.rate, fmt.channels
                    )
            log.info("livekit agent: TTS bitti — %d giriş baytı, %d kare yayınlandı",
                     bytes_in, frames_pub)
        except asyncio.CancelledError:
            # Barge-in = kullanıcı KONUŞMAYA başladı (TTS'i kesen tek şey
            # _consume_track'teki speech-start). Doğru durum "listening" (idle DEĞİL):
            # idle yazarsak istemci 10sn oto-uyku zamanlayıcısını barge-in ORTASINDA
            # kurar → cümle ortasında uyur. speech-start zaten "listening" yaydı;
            # burada onu pekiştiriyoruz (aynı değer → istemcide no-op, ama iptal
            # task'ı sonradan koşup "idle" yazma yarışını engeller). Utterance bitince
            # _handle_utterance "thinking"/"speaking", sonunda "idle" sürer.
            log.info("livekit agent: TTS iptal edildi (barge-in)")
            self._set_agent_state("listening")
            raise
        except Exception as e:
            log.warning("livekit agent: TTS başarısız: %r", e)
        # Konuşma bitti (normal veya hata) → REST'e dön.
        self._set_agent_state("idle")

    async def _capture_s16le(self, rtc, source, pcm: bytes, rate: int, channels: int) -> int:
        """s16le PCM'i kaynağın yayın biçimine (48 kHz mono) indir ve kare kare
        yayınla. AudioResampler ile (gerekirse) yeniden örnekle, tek kanala indir.
        Yayınlanan kare sayısını döndürür (teşhis için)."""
        if not pcm:
            return 0
        # Çok kanallıysa ilk kanala indir (genelde TTS mono döner).
        if channels > 1:
            pcm = self._to_mono(pcm, channels)
        frames: list = []
        if rate != PUB_RATE:
            resampler = rtc.AudioResampler(
                input_rate=rate, output_rate=PUB_RATE, num_channels=PUB_CHANNELS
            )
            frames.extend(resampler.push(bytearray(pcm)))
            frames.extend(resampler.flush())
        else:
            # Doğrudan tek bir kareye sar.
            samples_per_channel = len(pcm) // 2
            frames.append(
                rtc.AudioFrame(
                    data=pcm,
                    sample_rate=PUB_RATE,
                    num_channels=PUB_CHANNELS,
                    samples_per_channel=samples_per_channel,
                )
            )
        for frame in frames:
            await source.capture_frame(frame)
        return len(frames)

    @staticmethod
    def _to_mono(pcm: bytes, channels: int) -> bytes:
        """Interleaved s16le çok kanallı PCM'in ilk kanalını al."""
        samples = array("h")
        samples.frombytes(pcm[: len(pcm) - len(pcm) % (2 * channels)])
        mono = array("h", samples[::channels])
        return mono.tobytes()
