import { useMemo, useState } from "react";
import { useMonitor } from "./useMonitor";
import { typeMeta, TYPE_META } from "./types";
import type { BrainEvent } from "./types";
import "./App.css";

const LS_URL = "mate-dash.brainUrl";
const LS_TOKEN = "mate-dash.token";

// Build-zamanı env (mate-dash/.env: VITE_BRAIN_URL / VITE_BRAIN_TOKEN).
// Set'liyse localStorage/forma göre ÖNCELİKLİ → bağlantı dosyadan yönetilir.
const env = import.meta.env as Record<string, string | undefined>;
const ENV_URL = env.VITE_BRAIN_URL || "";
const ENV_TOKEN = env.VITE_BRAIN_TOKEN || "";

function fmtTime(ts: number): string {
  const d = new Date(ts * 1000);
  return (
    d.toLocaleTimeString("tr-TR", { hour12: false }) +
    "." +
    String(d.getMilliseconds()).padStart(3, "0")
  );
}

export default function App() {
  const [brainUrl, setBrainUrl] = useState(
    () => ENV_URL || localStorage.getItem(LS_URL) || "http://127.0.0.1:8800"
  );
  const [token, setToken] = useState(
    () => ENV_TOKEN || localStorage.getItem(LS_TOKEN) || ""
  );
  const [enabled, setEnabled] = useState(false);
  const [paused, setPaused] = useState(false);
  const [filter, setFilter] = useState<Set<string>>(new Set());
  const [expanded, setExpanded] = useState<string | null>(null);

  const { events, state, clear } = useMonitor({ brainUrl, token, enabled, paused });

  const connect = () => {
    localStorage.setItem(LS_URL, brainUrl);
    localStorage.setItem(LS_TOKEN, token);
    setEnabled(true);
  };

  const toggleFilter = (type: string) =>
    setFilter((prev) => {
      const next = new Set(prev);
      if (next.has(type)) next.delete(type);
      else next.add(type);
      return next;
    });

  const shown = useMemo(
    () => (filter.size ? events.filter((e) => filter.has(e.type)) : events),
    [events, filter]
  );

  const counts = useMemo(() => {
    const m: Record<string, number> = {};
    for (const e of events) m[e.type] = (m[e.type] || 0) + 1;
    return m;
  }, [events]);

  return (
    <div className="app">
      <header className="bar">
        <div className="brand">
          <span className={`dot ${state}`} />
          <strong>mate-dash</strong>
          <span className="muted">canlı akış</span>
        </div>
        <div className="conn">
          <input
            className="in url"
            value={brainUrl}
            onChange={(e) => setBrainUrl(e.target.value)}
            placeholder="http://127.0.0.1:8800"
            spellCheck={false}
          />
          <input
            className="in token"
            type="password"
            value={token}
            onChange={(e) => setToken(e.target.value)}
            placeholder="admin token"
            spellCheck={false}
          />
          {enabled ? (
            <button className="btn" onClick={() => setEnabled(false)}>
              Kes
            </button>
          ) : (
            <button className="btn primary" onClick={connect}>
              Bağlan
            </button>
          )}
          <button
            className={`btn ${paused ? "warn" : ""}`}
            onClick={() => setPaused((p) => !p)}
            disabled={!enabled}
          >
            {paused ? "Devam" : "Duraklat"}
          </button>
          <button className="btn" onClick={clear}>
            Temizle
          </button>
        </div>
      </header>

      <div className="filters">
        {Object.keys(TYPE_META).map((type) => {
          const m = typeMeta(type);
          const active = filter.has(type);
          const c = counts[type] || 0;
          return (
            <button
              key={type}
              className={`chip ${active ? "on" : ""}`}
              style={active ? { borderColor: m.color, color: m.color } : undefined}
              onClick={() => toggleFilter(type)}
              title={type}
            >
              <span className="swatch" style={{ background: m.color }} />
              {m.label}
              {c > 0 && <span className="cnt">{c}</span>}
            </button>
          );
        })}
        {filter.size > 0 && (
          <button className="chip clear" onClick={() => setFilter(new Set())}>
            filtreyi sıfırla
          </button>
        )}
        <span className="grow" />
        <span className="muted total">
          {shown.length}/{events.length} olay
        </span>
      </div>

      <main className="stream">
        {shown.length === 0 && (
          <div className="empty">
            {state === "connected"
              ? "Olay bekleniyor… (brain'e bir mesaj/sesli komut gönder)"
              : "Bağlan'a basıp brain URL + admin token gir."}
          </div>
        )}
        {groupTurns(shown).map((t) => (
          <TurnCard
            key={t.key}
            turn={t}
            open={expanded === t.key}
            onToggle={() => setExpanded(expanded === t.key ? null : t.key)}
          />
        ))}
      </main>
    </div>
  );
}

// Bir konuşma turu: aynı conversation_id'li olaylar utterance…reply arası tek kart.
interface Turn {
  key: string;
  ts: number;
  convId: string | null;
  speaker: string | null;
  events: BrainEvent[];
}

function groupTurns(events: BrainEvent[]): Turn[] {
  const asc = [...events].reverse(); // gelen liste yeni→eski; kronolojik işle
  const turns: Turn[] = [];
  const open = new Map<string, Turn>(); // conversation_id → açık tur
  for (const e of asc) {
    const conv = e.conversation_id;
    if (!conv) {
      // konuşma-dışı olay (node, anons, görev…) → tek-olaylık kart
      turns.push({ key: `e${e.id}`, ts: e.ts, convId: null, speaker: null, events: [e] });
      continue;
    }
    let turn = open.get(conv);
    if (!turn) {
      turn = { key: `t${e.id}`, ts: e.ts, convId: conv, speaker: null, events: [] };
      open.set(conv, turn);
      turns.push(turn);
    }
    turn.events.push(e);
    turn.ts = e.ts;
    if (typeof e.payload?.speaker === "string") turn.speaker = e.payload.speaker;
    if (e.type === "reply") open.delete(conv); // tur kapandı
  }
  return turns.sort((a, b) => b.ts - a.ts); // en yeni tur üstte
}

function TurnCard({
  turn,
  open,
  onToggle,
}: {
  turn: Turn;
  open: boolean;
  onToggle: () => void;
}) {
  const utt = turn.events.find((e) => e.type === "utterance");
  const rep = turn.events.find((e) => e.type === "reply");
  const single = turn.events.length === 1 ? turn.events[0] : null;
  const sm = single ? typeMeta(single.type) : null;
  return (
    <div className={`turn ${open ? "open" : ""}`} onClick={onToggle}>
      <div className="turn-head">
        <span className="time">{fmtTime(turn.ts)}</span>
        {sm ? (
          <>
            <span className="badge" style={{ background: sm.color }}>{sm.label}</span>
            <span className="src">{single!.source}</span>
            <span className="summary">{single!.summary}</span>
          </>
        ) : (
          <>
            <span className="badge" style={{ background: "#6366f1" }}>Tur</span>
            <span className="summary turn-lines">
              {utt && <span className="t-utt">{utt.summary}</span>}
              {rep && <span className="t-rep"> → {rep.summary}</span>}
              {!utt && !rep && turn.events[0].summary}
            </span>
            <span className="turn-count">{turn.events.length} olay</span>
          </>
        )}
        {turn.speaker && <span className="conv">🗣 {turn.speaker}</span>}
        {turn.convId && <span className="conv">{turn.convId}</span>}
      </div>
      {open && (
        <div className="turn-body" onClick={(e) => e.stopPropagation()}>
          {turn.events.map((ev) => (
            <InnerRow key={ev.id} ev={ev} />
          ))}
        </div>
      )}
    </div>
  );
}

function InnerRow({ ev }: { ev: BrainEvent }) {
  const m = typeMeta(ev.type);
  return (
    <div className="inner-row">
      <span className="time">{fmtTime(ev.ts)}</span>
      <span className="badge" style={{ background: m.color }}>{m.label}</span>
      <span className="src">{ev.source}</span>
      <span className="summary">{ev.summary}</span>
      <pre className="payload">{JSON.stringify(ev.payload, null, 2)}</pre>
    </div>
  );
}
