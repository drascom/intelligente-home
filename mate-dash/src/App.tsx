import { useMemo, useState } from "react";
import { useMonitor } from "./useMonitor";
import { typeMeta, TYPE_META } from "./types";
import type { BrainEvent } from "./types";
import "./App.css";

const LS_URL = "mate-dash.brainUrl";
const LS_TOKEN = "mate-dash.token";

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
    () => localStorage.getItem(LS_URL) || "http://127.0.0.1:8800"
  );
  const [token, setToken] = useState(() => localStorage.getItem(LS_TOKEN) || "");
  const [enabled, setEnabled] = useState(false);
  const [paused, setPaused] = useState(false);
  const [filter, setFilter] = useState<Set<string>>(new Set());
  const [expanded, setExpanded] = useState<number | null>(null);

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
        {shown.map((e) => (
          <Row
            key={e.id}
            ev={e}
            open={expanded === e.id}
            onToggle={() => setExpanded(expanded === e.id ? null : e.id)}
          />
        ))}
      </main>
    </div>
  );
}

function Row({
  ev,
  open,
  onToggle,
}: {
  ev: BrainEvent;
  open: boolean;
  onToggle: () => void;
}) {
  const m = typeMeta(ev.type);
  return (
    <div className={`row ${open ? "open" : ""}`} onClick={onToggle}>
      <span className="time">{fmtTime(ev.ts)}</span>
      <span className="badge" style={{ background: m.color }}>
        {m.label}
      </span>
      <span className="src">{ev.source}</span>
      <span className="summary">{ev.summary}</span>
      {typeof ev.payload?.speaker === "string" && (
        <span className="conv">🗣 {ev.payload.speaker}</span>
      )}
      {ev.conversation_id && <span className="conv">{ev.conversation_id}</span>}
      {open && (
        <pre className="payload" onClick={(e) => e.stopPropagation()}>
          {JSON.stringify(ev.payload, null, 2)}
        </pre>
      )}
    </div>
  );
}
