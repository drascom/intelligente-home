"""FCM push bildirimi (HTTP v1).

FCM_CREDENTIALS_PATH bir service-account JSON'una işaret ediyorsa ve
`google-auth` kuruluysa gerçek push atılır; aksi halde dry-run: gönderilecek
mesaj loglanır ve "sent" sayılmaz. Telefon token'ları `clients.fcm_token`
kolonunda tutulur (POST /api/clients/me/fcm ile kaydedilir).
"""

import json
import logging

import httpx

log = logging.getLogger("brain.notify")

FCM_SCOPE = "https://www.googleapis.com/auth/firebase.messaging"


class FCMSender:
    def __init__(self, credentials_path: str = ""):
        self.credentials_path = credentials_path
        self._credentials = None
        self._project_id: str | None = None
        if credentials_path:
            self._load(credentials_path)

    def _load(self, path: str) -> None:
        try:
            from google.oauth2 import service_account  # type: ignore

            self._credentials = service_account.Credentials.from_service_account_file(
                path, scopes=[FCM_SCOPE]
            )
            with open(path) as f:
                self._project_id = json.load(f).get("project_id")
            log.info("fcm: service account loaded (project=%s)", self._project_id)
        except ImportError:
            log.warning("fcm: google-auth kurulu değil — dry-run modu")
        except Exception as e:
            log.warning("fcm: credentials yüklenemedi (%s) — dry-run modu", e)

    @property
    def live(self) -> bool:
        return self._credentials is not None and self._project_id is not None

    async def send(self, fcm_token: str, title: str, body: str, data: dict | None = None) -> bool:
        """Tek cihaza push. Dry-run'da loglar ve False döner."""
        if not self.live:
            log.info("fcm (dry-run): to=%s… title=%r body=%r", fcm_token[:12], title, body)
            return False

        import google.auth.transport.requests  # type: ignore

        request = google.auth.transport.requests.Request()
        self._credentials.refresh(request)
        message = {
            "message": {
                "token": fcm_token,
                "notification": {"title": title, "body": body},
                **({"data": {k: str(v) for k, v in data.items()}} if data else {}),
            }
        }
        url = f"https://fcm.googleapis.com/v1/projects/{self._project_id}/messages:send"
        async with httpx.AsyncClient(timeout=10) as http:
            resp = await http.post(
                url,
                json=message,
                headers={"Authorization": f"Bearer {self._credentials.token}"},
            )
        if resp.status_code >= 400:
            log.warning("fcm: send failed %s: %s", resp.status_code, resp.text[:200])
            return False
        return True

    async def broadcast(self, clients: list[dict], title: str, body: str,
                        data: dict | None = None) -> int:
        """fcm_token'ı olan tüm istemcilere gönder; başarı sayısını döner."""
        sent = 0
        for client in clients:
            try:
                if await self.send(client["fcm_token"], title, body, data):
                    sent += 1
            except Exception as e:
                log.warning("fcm: %s için gönderilemedi: %s", client.get("name"), e)
        return sent
