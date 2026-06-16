/**
 * Pi extension: home device tools backed by the brain's REST API.
 *
 * Loaded by the project-local pi (see brain/router/pi_backend.py and ./pi-brain).
 * Gives pi the same three tools the vLLM agent has — list_entities, get_state,
 * call_service — so pi can act as the brain during development.
 *
 * Env: BRAIN_API_URL (default http://127.0.0.1:8800), BRAIN_API_TOKEN.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

const BASE = process.env.BRAIN_API_URL || "http://127.0.0.1:8800";
const TOKEN = process.env.BRAIN_API_TOKEN || "";

async function api(method: string, path: string, body?: unknown): Promise<string> {
  const resp = await fetch(`${BASE}${path}`, {
    method,
    headers: {
      Authorization: `Bearer ${TOKEN}`,
      "Content-Type": "application/json",
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await resp.text();
  if (!resp.ok) return `error ${resp.status}: ${text}`;
  return text;
}

export default function (pi: ExtensionAPI) {
  pi.registerTool({
    name: "get_time",
    label: "Get time",
    description:
      "Get the current local date and time. Hatırlatma için due_at hesaplarken bu " +
      "tool'u çağır: dönen 'ISO' alanından ofset al (ör. '2 dakika sonra' → ISO + 120 sn).",
    parameters: Type.Object({}),
    async execute() {
      const d = new Date();
      const human = d.toLocaleString("tr-TR", { dateStyle: "full", timeStyle: "medium" });
      // Yerel ISO 8601 (offset'li) — LLM bundan güvenilir due_at türetir.
      const off = -d.getTimezoneOffset();
      const sign = off >= 0 ? "+" : "-";
      const pad = (x: number) => String(Math.abs(x)).padStart(2, "0");
      const iso =
        `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}` +
        `T${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}` +
        `${sign}${pad(Math.floor(Math.abs(off) / 60))}:${pad(Math.abs(off) % 60)}`;
      const text = `${human}\nISO: ${iso}`;
      return { content: [{ type: "text", text }], details: {} };
    },
  });

  pi.registerTool({
    name: "list_entities",
    label: "List entities",
    description:
      "List smart home devices/entities, optionally filtered by area name and/or domain (light, switch, climate, media_player, sensor, ...). Returns entity_id, name, state, area.",
    parameters: Type.Object({
      area: Type.Optional(Type.String({ description: "Area/room name, e.g. 'Salon'" })),
      domain: Type.Optional(Type.String({ description: "Entity domain, e.g. 'light'" })),
    }),
    async execute(_id, params) {
      const q = new URLSearchParams();
      if (params.area) q.set("area", params.area);
      if (params.domain) q.set("domain", params.domain);
      const text = await api("GET", `/api/devices?${q}`);
      return { content: [{ type: "text", text }], details: {} };
    },
  });

  pi.registerTool({
    name: "get_state",
    label: "Get state",
    description: "Get the full state and attributes of one entity.",
    parameters: Type.Object({
      entity_id: Type.String(),
    }),
    async execute(_id, params) {
      const text = await api("GET", `/api/devices/${encodeURIComponent(params.entity_id)}`);
      return { content: [{ type: "text", text }], details: {} };
    },
  });

  pi.registerTool({
    name: "call_service",
    label: "Call service",
    description:
      "Control a device by calling a Home Assistant service, e.g. domain='light', service='turn_on', entity_id='light.salon', data={'brightness_pct': 50}.",
    parameters: Type.Object({
      domain: Type.String(),
      service: Type.String(),
      entity_id: Type.Optional(Type.String()),
      data: Type.Optional(Type.Object({}, { additionalProperties: true })),
    }),
    async execute(_id, params) {
      const text = await api("POST", "/api/devices/service", params);
      return { content: [{ type: "text", text }], details: {} };
    },
  });

  // --- Görev (task) tool'ları: triage'ın "sonraya bırak" dalı ---

  pi.registerTool({
    name: "create_task",
    label: "Create task",
    description:
      "Kullanıcı sonradan yapılacak/hatırlanacak bir şey söylediğinde görev olarak kaydet " +
      "(not, hatırlatma, yapılacak iş — ör. 'akşam Ali'yi aramayı unutma'). Soruları/sohbeti " +
      "yanıtlamak için KULLANMA. user_id'yi mesajdaki '(Konuşan: ... user_id=N)' bağlamından al. " +
      "Kullanıcı bir ZAMAN belirttiyse asistan vakti gelince kendisi hatırlatır. " +
      "GÖRELİ süre için ('10 dakika sonra', 'yarım saat sonra') in_seconds ver (ör. 600). " +
      "MUTLAK saat için ('yarın saat 10'da', 'akşam 8'de') önce get_time çağır, ISO alanından " +
      "hesapla ve due_at'e yerel ISO 8601 yaz. Zaman yoksa ikisini de boş bırak.",
    parameters: Type.Object({
      text: Type.String({
        description: "Görev metni: KISA EMİR KİPİ aksiyon ('su iç', 'Ali'yi ara', 'ara ver') — " +
          "'hatırlat'/'unutma' ekleme; vakti gelince kullanıcıya aynen okunacak.",
      }),
      user_id: Type.Optional(Type.Number({ description: "Konuşan kişinin user_id'si (bağlamdan)" })),
      due_at: Type.Optional(Type.String({
        description: "Mutlak hatırlatma zamanı, yerel ISO 8601 (ör. '2026-06-17T10:00:00').",
      })),
      in_seconds: Type.Optional(Type.Number({
        description: "Göreli hatırlatma: şu andan kaç saniye sonra (ör. 10 dk = 600).",
      })),
    }),
    async execute(_id, params) {
      let dueEpoch: number | null = null;
      if (params.in_seconds && params.in_seconds > 0) {
        dueEpoch = Date.now() / 1000 + params.in_seconds;
      } else if (params.due_at) {
        const ms = new Date(params.due_at).getTime();
        if (!Number.isNaN(ms)) dueEpoch = ms / 1000;
      }
      const text = await api("POST", "/api/tasks", {
        text: params.text,
        user_id: params.user_id ?? null,
        due_at: dueEpoch,
      });
      return { content: [{ type: "text", text }], details: {} };
    },
  });

  pi.registerTool({
    name: "list_tasks",
    label: "List tasks",
    description:
      "Kullanıcının görevlerini listele ('görevlerim ne', 'neler var' gibi isteklerde). " +
      "user_id (bağlamdan) ve status (pending/done) ile filtrele.",
    parameters: Type.Object({
      user_id: Type.Optional(Type.Number()),
      status: Type.Optional(Type.String({ description: "pending | done" })),
    }),
    async execute(_id, params) {
      const q = new URLSearchParams();
      if (params.user_id !== undefined) q.set("user_id", String(params.user_id));
      if (params.status) q.set("status", params.status);
      const text = await api("GET", `/api/tasks?${q}`);
      return { content: [{ type: "text", text }], details: {} };
    },
  });

  pi.registerTool({
    name: "complete_task",
    label: "Complete task",
    description: "Bir görevi tamamlandı olarak işaretle (id ile).",
    parameters: Type.Object({ id: Type.Number() }),
    async execute(_id, params) {
      const text = await api("POST", `/api/tasks/${params.id}/complete`);
      return { content: [{ type: "text", text }], details: {} };
    },
  });
}
