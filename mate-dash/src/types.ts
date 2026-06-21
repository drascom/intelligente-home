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

// ---- Oturumlar / Açık İşler ----
export interface Session {
  id: number;
  scope_key: string;
  user_id: number | null;
  title: string | null;
  summary: string | null;
  status: "active" | "closed";
  created_at: number;
  updated_at: number;
  ended_at: number | null;
  turn_count: number;
}

export interface SessionTurn {
  role: "user" | "assistant";
  content: string;
  speaker: string | null;
  created_at: number;
}

export interface SessionDetail {
  session: Session;
  turns: SessionTurn[];
}

export interface OpenItem {
  id: number;
  text: string;
  session_id: number | null;
  user_id: number | null;
  status: "pending" | "done";
  created_at: number;
}

// ---- Konular (Topics) ----
export interface Topic {
  id: number;
  scope_key: string;
  user_id: number | null;
  title: string | null;
  summary: string | null;
  status: string;
  created_at: number;
  updated_at: number;
  last_activity_at: number | null;
}

// Konu detayındaki açık iş (topics endpoint'i topic_id alanını da döndürür).
export interface TopicOpenItem {
  id: number;
  text: string;
  session_id: number | null;
  topic_id: number | null;
  status: string;
  created_at: number;
}

export interface TopicDetail {
  topic: Topic;
  open_items: TopicOpenItem[];
}

// Olay türü → renk + etiket (monitör satır rozetleri)
export const TYPE_META: Record<string, { label: string; color: string }> = {
  utterance: { label: "Kullanıcı", color: "#4f9dff" },
  reply: { label: "Yanıt", color: "#34d399" },
  intent: { label: "Niyet", color: "#a78bfa" },
  tool_call: { label: "Tool →", color: "#fbbf24" },
  tool_result: { label: "Tool ✓", color: "#f59e0b" },
  task: { label: "Görev", color: "#fb923c" },
  node_status: { label: "Node", color: "#22d3ee" },
  telemetry: { label: "Telemetri", color: "#2dd4bf" },
  announce: { label: "Anons", color: "#fb7185" },
  fcm: { label: "Push", color: "#f472b6" },
  client_connect: { label: "Bağlandı", color: "#94a3b8" },
  client_disconnect: { label: "Ayrıldı", color: "#64748b" },
  session_closed: { label: "Oturum ✕", color: "#818cf8" },
  topic_updated: { label: "Konu", color: "#e879f9" },
};

export function typeMeta(type: string) {
  return TYPE_META[type] ?? { label: type, color: "#94a3b8" };
}
