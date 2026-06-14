# mate-dash

Brain'in canlı akış monitörü (dashboard v1). Braine gelip giden olayları —
kullanıcı sözü, asistan yanıtı, niyet sınıflandırması, HA tool çağrıları, MQTT
node olayları, anons, push — gerçek zamanlı gösterir.

Brain'in `GET /api/monitor/stream` SSE endpoint'ine `EventSource` ile bağlanır;
bağlanınca son 500 olayı (ring backfill) gösterir, sonra canlı akıtır.

## Çalıştırma (dev)

```sh
npm install        # ilk sefer
npm run dev        # http://localhost:5173
```

Brain ayakta olmalı (`./start.sh` veya `./brain_run.sh`, repo kökünde). Tarayıcıda:
- **Brain URL**: `http://127.0.0.1:8800`
- **admin token**: `.env`'deki `BRAIN_ADMIN_TOKEN`
- **Bağlan**'a bas → olaylar akmaya başlar.

Dev origin (`localhost:5173`) brain'de CORS'a ekli (`MONITOR_CORS_ORIGINS`).

## Özellikler
- Tür bazlı renkli rozetler + tür filtresi (sayaçlı).
- Satıra tıkla → olay `payload` JSON detayı.
- Duraklat / Temizle; URL+token localStorage'da saklanır.
- Bağlantı kopunca EventSource otomatik reconnect + ring backfill.

## Build
```sh
npm run build      # dist/ — statik, istenirse brain veya başka sunucudan servis edilir
```

## Mimari notu
v1 yalnızca canlı izleme. Olay şeması ileri-uyumlu (`conversation_id`,
`client_id` alanları zaten var); sohbet sezonları / çok-kullanıcı / kalıcılık
sonraki fazlarda ek alan + yeni bus abonesi olarak gelecek (brain producer'ları
değişmeden). Backend tasarımı: `mate-brain/brain/monitor/bus.py`,
`mate-brain/brain/api/monitor.py`.
