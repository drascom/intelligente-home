# Test sunucusu deploy (Mac dev → GitHub → otomatik deploy)

Test sunucusu: Ubuntu 24.04 LXC (`192.168.0.25`), RTX 3090 (host'tan bind-mount).
Yığın native + systemd: **vllm** (:8000) → **whisper** (:10300) + **vox** (:8808)
→ **brain** (:8800). LLM backend = vLLM (Qwen2.5-7B-AWQ, paylaşımlı GPU için).

## Tek seferlik kurulum
```sh
ssh root@192.168.0.25
bash <(curl -fsSL https://raw.githubusercontent.com/drascom/intelligente-home/main/deploy/server-bootstrap.sh)
# /etc/intelligente-home/brain.env içindeki kalan CHANGE_ME'leri doldur
systemctl start vllm whisper vox brain
curl localhost:8800/api/health
```

## CI: push → otomatik deploy
`.github/workflows/deploy.yml` main'e her push'ta **self-hosted runner** (sunucunun
kendisi) üzerinde `deploy/server-deploy.sh` çalıştırır: `git reset --hard origin/main`
→ değişen requirements/systemd'i senkronla → brain (+ gerekirse vox/whisper) restart
→ `/api/health` doğrula. Bulut runner kullanılamaz (özel LAN IP); runner outbound
bağlanır.

### Runner kurulumu (tek seferlik)
```sh
# Mac'te registration token al:
gh api -X POST repos/drascom/intelligente-home/actions/runners/registration-token --jq .token
# Sunucuda:
useradd -m -s /bin/bash actions || true
mkdir -p /opt/actions-runner && cd /opt/actions-runner
curl -fsSL -o r.tar.gz https://github.com/actions/runner/releases/download/v2.XXX/actions-runner-linux-x64-2.XXX.tar.gz
tar xzf r.tar.gz && chown -R actions:actions /opt/actions-runner
sudo -u actions ./config.sh --url https://github.com/drascom/intelligente-home --token <TOKEN> --labels self-hosted,linux --unattended
./svc.sh install actions && ./svc.sh start
# Deploy scriptine sudo (NOPASSWD):
echo 'actions ALL=(root) NOPASSWD: /opt/intelligente-home/deploy/server-deploy.sh' > /etc/sudoers.d/actions-deploy
```

## Env stratejisi
Gerçek prod değerleri repo dışında: `/etc/intelligente-home/brain.env`
(brain.service `EnvironmentFile=`). pydantic-settings'te env-var > .env dosyası,
yani commit'li `mate-brain/.env` (dev) override edilir; `git pull` dokunmaz.

## GPU bütçesi
Paylaşımlı 24GB (~5GB host'taki başka guest'te). vLLM 7B-AWQ @ util 0.45 (~11GB)
+ whisper (~2GB) + vox (~5GB). 14B veya dedicated GPU'da `deploy/systemd/vllm.service`
+ `brain.env` modelini büyüt.

## Servisler
`systemctl {status,restart,stop} {vllm,whisper,vox,brain}` · loglar:
`journalctl -u brain -f`.
