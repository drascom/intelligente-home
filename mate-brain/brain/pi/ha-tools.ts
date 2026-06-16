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
    description: "Get the current local date and time.",
    parameters: Type.Object({}),
    async execute() {
      const now = new Date().toLocaleString("tr-TR", { dateStyle: "full", timeStyle: "short" });
      return { content: [{ type: "text", text: now }], details: {} };
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
      "yanıtlamak için KULLANMA. user_id'yi mesajdaki '(Konuşan: ... user_id=N)' bağlamından al.",
    parameters: Type.Object({
      text: Type.String({ description: "Görev metni, kısa ve net" }),
      user_id: Type.Optional(Type.Number({ description: "Konuşan kişinin user_id'si (bağlamdan)" })),
    }),
    async execute(_id, params) {
      const text = await api("POST", "/api/tasks", {
        text: params.text,
        user_id: params.user_id ?? null,
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
