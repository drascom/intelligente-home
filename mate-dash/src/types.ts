export interface BrainEvent {
  id: number;
  ts: number;
  type: string;
  source: string;
  summary: string;
  payload: Record<string, unknown>;
  conversation_id: string | null;
  client_id: number | null;
}

export type ConnState = "disconnected" | "connecting" | "connected";

// Olay türü → renk + etiket (monitör satır rozetleri)
export const TYPE_META: Record<string, { label: string; color: string }> = {
  utterance: { label: "Kullanıcı", color: "#4f9dff" },
  reply: { label: "Yanıt", color: "#34d399" },
  intent: { label: "Niyet", color: "#a78bfa" },
  tool_call: { label: "Tool →", color: "#fbbf24" },
  tool_result: { label: "Tool ✓", color: "#f59e0b" },
  node_status: { label: "Node", color: "#22d3ee" },
  telemetry: { label: "Telemetri", color: "#2dd4bf" },
  announce: { label: "Anons", color: "#fb7185" },
  fcm: { label: "Push", color: "#f472b6" },
  client_connect: { label: "Bağlandı", color: "#94a3b8" },
  client_disconnect: { label: "Ayrıldı", color: "#64748b" },
};

export function typeMeta(type: string) {
  return TYPE_META[type] ?? { label: type, color: "#94a3b8" };
}
