# Deploy — iki ayrı host, iki ayrı script (karıştırma)

Sistem iki sunucuya bölünmüştür. Her host kendi script'iyle deploy edilir; bir host'un
deploy'u diğerinin servislerine **dokunmaz**.

| Host | Adres | Servisler | Deploy script | Tetik |
|------|-------|-----------|---------------|-------|
| **oracle-stage** | `132.145.24.135` (public VPS) | **LiveKit** (:7880) + Hermes gateway (mate_voice plugin) | `deploy/deploy-stage.sh` | CI: main'e push → otomatik |
| **.25** | `192.168.0.25` (ev LAN GPU box "ollama") | **STT** whisper (:10300) + **TTS** vox (:8808) + **LLM** vllm (:8000) + dashboard | `deploy/deploy-gpu.sh` | **MANUEL** |

> Eski standalone "brain" servisi decommission edildi. HA artık Hermes'te
> (hermes-homeassistant plugin); ses katmanı `mate_voice` plugin'inde.

## oracle-stage (LiveKit) — otomatik
`.github/workflows/deploy.yml` `deploy-stage` job: main'e her push'ta bulut runner
SSH ile `ubuntu@132.145.24.135` üzerinde `sudo deploy/deploy-stage.sh` çalıştırır →
`git reset --hard origin/main` → systemd sync → (unit değişince) livekit restart.
`ubuntu` kullanıcısında NOPASSWD sudo var; SSH anahtarı repo secret `ORACLE_STAGE_SSH_KEY`.

## .25 (STT/TTS/LLM + dashboard) — manuel
.25 self-hosted CI runner **kaldırıldı** (2026-06-25). Ev LAN'ından elle deploy:
```sh
ssh root@192.168.0.25 'cd /opt/intelligente-home && sudo deploy/deploy-gpu.sh'
```
`git reset --hard origin/main` → değişen vox deps → dashboard build → systemd sync →
değişen whisper/vox/vllm/nemotron servislerini restart.

## Env stratejisi
Gerçek prod değerleri repo dışında host-yerel env dosyasında (`EnvironmentFile=`).
Hermes/plugin env'i `~/.hermes/.env`'te; `git pull` dokunmaz.

## Servisler
- oracle-stage: `systemctl {status,restart} livekit` · `journalctl -u hermes-gateway -f`
- .25: `systemctl {status,restart} {whisper,vox,vllm,nemotron,mate-dash}`
