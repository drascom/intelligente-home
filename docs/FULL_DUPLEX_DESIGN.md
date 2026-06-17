# Full-dupleks ses tasarımı

*Tasarım tarihi: 2026-06-17. Durum: TASLAK — onay bekliyor, inşa başlamadı.
Bu doküman, asistanı şu anki **half-dupleks (sıra-tabanlı) + barge-in** modelinden
**sürekli + araya-girilebilir (full-dupleks)** modele taşıma planıdır. Hedef: Codex/pi
LLM korunur; "konuş fazı bitmeden dinlemeye geçme" katılığı (ve onun ürettiği
"Konuşuyorum'da takılma") kökten kalkar.*

## 0. Karar ve kapsam

**Hedef = "sürekli akış + sunucu-VAD/sıra-tespiti + kesintisiz/araya-girilebilir TTS".**
Konuşma-yerel bir realtime model (OpenAI Realtime / Gemini Live) DEĞİL — o, Codex
donduruldu kararına ters, yeni altyapı + maliyet getirir. Bunun yerine mevcut yığını
(Codex/pi + Whisper + vox) koruyarak full-dupleks HİSSİ ve davranışı kurulur.

**LLM sınırı (dürüst not):** Codex/pi **sıra-tabanlı** — kullanıcı sustuğu an bir
prompt gönderilir, bir cevap döner. Yani "full-dupleks" burada: *sürekli çift-yönlü ses
+ doğal araya girme + sıra kararını sunucunun vermesi* demektir; aynı anda iki tarafın
serbestçe konuşması (speech-native) değil.

**Wake-gating ile uyum (önemli):** "hiçbir client sesi SÜREKLİ akıtmaz" kararı
([[ambient-assistant-vision]]) korunur. Full-dupleks **bir oturum İÇİNDE** geçerlidir:
oturum hâlâ "candan" ile açılır, açıkken sürekli çift-yönlü akar, sessizlik zaman
aşımıyla (örn. 30 sn) kapanıp wake'e döner. Yani sürekli akış = "oturum açıkken", "her
zaman" değil. Gizlilik modeli bozulmaz.

**Bu turda DEĞİŞMEYENLER:**
- LLM = Codex/pi (vLLM donduruldu). Tools pi `ha-tools.ts`'te.
- TTS = vox/VoxCPM2 (Türkçe).
- Wake word = "candan" (Apple: SFSpeech, Pi: openWakeWord).
- Speaker-ID = sunucu, sherpa-onnx CAM++.

## 1. Mevcut durum (half-dupleks) — gerçek kod

**İstemci (mate-mac/ios `ConversationManager`):** katı durum makinesi —
`idle → waitingForWake → listening → transcribing → synthesizing → speaking → wake`.
- Mic yakalama + **istemci-tarafı VAD/endpointing** (`handleLevel`, `silenceTimeout
  1.2s`, adaptif kalibrasyon) — utterance'ı istemci kapatır.
- Tek utterance'ı sunucuya yollar (`sendUtterance`: audio_start → binary chunks →
  audio_stop), transcript + reply + TTS bekler.
- TTS'i `AudioPlayer.streamPCM` ile çalar; **`waitForPCMStreamDrained`** ile "konuş
  fazı"nın bitmesini bekler. **Takılmanın kaynağı burası:** ses akışı tamamlandı
  sinyali gelmezse faz sınırında ~30–180 sn asılı kalır.
- **Barge-in istemci-tarafı** (`handleBargeInLevel`): TTS çalarken mic açık, Apple
  voice-processing (VPIO/**AEC**) hoparlör ekosunu siler; eşik üstü sürekli ses →
  TTS iptal + dinlemeye dön.

**Sunucu bridge (`brain/api/voice.py`, `/api/voice`):**
- İstemci→sunucu: `speak` | `audio_start`/binary `audio-chunk`/`audio_stop` | `cancel`
  | `ping`.
- Sunucu→istemci: `transcript` | `reply` | `audio_start`/binary/`audio_end` | `chime`
  | `pong` | `error`.
- STT = `WhisperSession` (Wyoming, `brain/voice/services.py`) — **batch**: utterance
  bitince çözer, partial yok.
- Tur = `agent.respond` (Codex/pi, sıra-tabanlı, keep-warm).
- TTS = `synthesize_stream` (vox) → pcm_f32le parçalar.

**Satellite (`brain/voice/satellite.py`):** Apple'dan FARKLI — Pi ince istemci,
**sunucu-tarafı VAD** zaten var (RMS `SILENCE_RMS`/`SILENCE_AFTER_S`). Yani sunucu-VAD
modeli Pi yolunda kısmen mevcut; asıl yeniden-yazım Apple bridge'inde.

## 2. Hedef mimari

```
OTURUM (wake-gated: "candan" ile açılır, sessizlikte kapanır)
  İstemci (Apple): mic → AEC(VPIO) → SÜREKLİ uplink (s16le 16k) ───┐
                   downlink TTS'i SÜREKLİ çalar (faz sınırı yok)   │
        ▲ "flush" (barge-in) kontrolü                              ▼
  Sunucu bridge:
    SÜREKLİ uplink → sunucu-VAD → utterance sınırı tespiti
        → STT (faz1: VAD-segment + batch Whisper; faz2: streaming nemotron)
        → speaker-ID → agent.respond (Codex/pi) → TTS (vox) → downlink
    TTS akarken uplink-VAD'i izlemeye DEVAM → konuşma duyulursa:
        → TTS'i kes (synth iptal) + istemciye "flush" + pi turn'ü abort → yeni utterance
```

**Anahtar fikirler:**
1. **Sürekli uplink:** oturum açıkken istemci mic'i kapatmaz; sunucu endpointing yapar.
2. **Sunucu-VAD/sıra-tespiti:** "kullanıcı bitti mi" kararı sunucuda (Pi yolundaki gibi).
3. **AEC istemcide kalır:** uplink'e TTS ekosu KARIŞMAZ (VPIO siler) → sunucu-VAD temiz
   sinyal görür → TTS sırasında gerçek konuşmayı (barge-in) güvenle ayırt eder.
4. **Sunucu-tarafı barge-in:** TTS akarken uplink'te konuşma → `synthesize_stream`'i
   iptal + pi turn'ü `_abort` + istemciye `flush` (playback kuyruğunu boşalt).
5. **İstemci sadeleşir:** durum makinesi (faz/drain bekleme) kalkar → sürekli mic +
   sürekli playback. `waitForPCMStreamDrained` takılması ortadan kalkar.

## 3. Protokol değişiklikleri (bridge)

Yeni oturum-tabanlı, sürekli akış protokolü (mevcut tek-utterance'ın yerine):

İstemci → sunucu:
- `session_start` {id, rate, width, channels, voice?} — oturum aç, sürekli uplink başlar
- binary `audio-chunk` (sürekli, oturum boyunca; mic AEC'li PCM)
- `session_stop` — oturumu kapat (kullanıcı durdurdu / inactivity)
- `ping`

Sunucu → istemci:
- `vad` {state: speech_start|speech_end} — (opsiyonel, UI ipucu: "dinliyorum")
- `transcript` {text, speaker?, final:bool} — partial/final (faz2 partial)
- `reply` {text}
- `tts_start` / binary pcm_f32le / `tts_end` — downlink TTS
- `flush` — barge-in: istemci playback kuyruğunu ANINDA boşaltsın
- `chime` (proaktif bildirim — mevcut)
- `error` / `pong`

Not: WS zaten çift-yönlü; değişen **uygulama mantığı** (tek-utterance → oturum-akışı).
Eski `audio_start/stop` tek-utterance yolu, geçiş için bir süre korunabilir (geri uyum).

## 4. STT stratejisi

- **Faz 1 (düşük risk):** sürekli uplink → **sunucu-VAD ile segment** → her segment
  batch Whisper'a (mevcut `WhisperSession`). Partial yok ama full-dupleks akış +
  takılmasızlık hemen gelir. faster-whisper korunur.
- **Faz 2 (gerçek düşük gecikme):** `nemotron-3.5-asr-streaming` (sherpa-onnx,
  `STT_NEMOTRON_NOTES.md`) → partial transcript + sustuğunda hazır. Gerçek ev sesiyle
  A/B (notlardaki karar). `STT_ENGINE=whisper|nemotron` flag'iyle.

## 5. Barge-in'in sunucuya taşınması

Şu an istemci-tarafı (`handleBargeInLevel`, AEC kalibrasyonu). Full-dupleks'te:
- **AEC istemcide kalır** (VPIO/.voiceChat) — uplink ekosuz.
- **Tespit sunucuda:** TTS downlink akarken sunucu uplink-VAD'i izlemeye devam eder;
  eşik üstü sürekli konuşma → barge-in. Sunucu: synth iptal + `flush` + pi `_abort`.
- **Pi uyarısı:** Pi satellite'ta donanım AEC zayıf/yok → uplink'e TTS ekosu sızar →
  sunucu-VAD yanlış barge-in görebilir. Pi'da barge-in başta KAPALI, half-dupleks
  davranış (TTS biterken dinleme) korunur; Apple'da full-dupleks.

## 6. İstemci sadeleşmesi (takılma çözümü)

- `waitForPCMStreamDrained` + faz durum makinesi KALDIRILIR.
- İstemci iki bağımsız akış sürer: (a) sürekli mic→uplink, (b) downlink TTS→sürekli
  playback. `flush` gelince playback kuyruğu boşaltılır.
- Durum etiketi (UI) artık sunucu `vad`/`tts_start`/`tts_end` olaylarından türetilir,
  istemci faz sınırı beklemez → asılma yok.

## 7. Fazlı plan

| Faz | İş | Risk |
|---|---|---|
| 0 | Bu tasarım + onay | — |
| 1 | Bridge oturum-akış protokolü + sunucu-VAD + batch Whisper; istemci sürekli uplink/playback, durum-makinesi sadeleşir | Orta-yüksek (client+server voice loop yeniden yazımı) |
| 2 | Sunucu-tarafı barge-in (TTS kes + flush + pi abort) | Orta (AEC'ye bağlı) |
| 3 | Streaming STT (nemotron) + partial transcript A/B | Orta |
| 4 | Satellite yolunu birleştir; Pi AEC/barge-in değerlendirmesi | Düşük-orta |

## 8. Riskler ve açık sorular

- **Sunucu-VAD ayarı:** istemci adaptif kalibrasyonu (uzak-mic/TV gürültüsü) sunucuya
  taşınınca cihaz-özel ayar kaybı. Azaltma: hafif istemci ön-filtre / kalibrasyon
  bilgisini uplink'le gönder.
- **AEC kalitesi:** barge-in doğruluğu istemci AEC'sine (VPIO) bağlı. Pi'da zayıf → Pi
  half-dupleks kalır.
- **LLM gecikmesi:** Codex/pi turu ~2.5s (keep-warm sonrası inference). Full-dupleks
  hissi yine de bu sıra-gecikmesiyle sınırlı; partial STT bunu maskeler ama LLM turu kalır.
- **İptal edilebilirlik:** pi `_abort` + vox synth iptali güvenilir mi? (mevcut
  `_abort` var; vox stream iptali test edilmeli.)
- **Eşzamanlılık:** birden çok oturum/cihaz → pi tek instance seri (havuz gerekebilir).
- **Geri uyum:** eski tek-utterance protokolü ne kadar korunacak (satellite + eski app)?

## 9. Bu tasarımın çözdüğü/çözmediği

Çözer: "Konuşuyorum'da takılma" (faz sınırı kalkar), manuel-wake sürtünmesi (zaten
otomatik-dinlemeyle azaldı), doğal araya girme, daha akıcı konuşma.
Çözmez (kapsam dışı): konuşma-yerel realtime model; LLM sıra-gecikmesinin tamamen
kalkması; Pi'da tam full-dupleks (AEC sınırı).
