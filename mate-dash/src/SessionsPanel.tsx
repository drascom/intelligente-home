import { useCallback, useEffect, useState } from "react";
import type { Session, SessionDetail } from "./types";
import { apiBase, fmtClock } from "./util";

interface Props {
  brainUrl: string;
  token: string;
  // session_closed olayı geldiğinde değişir → listeyi tazele.
  refreshSignal: number;
}

export default function SessionsPanel({ brainUrl, token, refreshSignal }: Props) {
  const [sessions, setSessions] = useState<Session[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [expanded, setExpanded] = useState<number | null>(null);

  const load = useCallback(async () => {
    if (!brainUrl || !token) return;
    setLoading(true);
    setError(null);
    try {
      const url = `${apiBase(brainUrl)}/api/sessions?token=${encodeURIComponent(token)}&limit=100`;
      const resp = await fetch(url);
      if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
      const j = (await resp.json()) as { sessions: Session[] };
      setSessions(j.sessions ?? []);
    } catch (e) {
      setError(String(e));
    } finally {
      setLoading(false);
    }
  }, [brainUrl, token]);

  // Açılışta + her session_closed olayında tazele.
  useEffect(() => {
    load();
  }, [load, refreshSignal]);

  return (
    <div className="panel-view">
      <div className="panel-head">
        <strong>Oturumlar</strong>
        <span className="muted">{sessions.length}</span>
        <span className="grow" />
        <button className="btn" onClick={load} disabled={loading}>
          {loading ? "Yükleniyor…" : "↻ Yenile"}
        </button>
      </div>

      {error && <div className="empty err">Hata: {error}</div>}
      {!error && loading && sessions.length === 0 && (
        <div className="empty">Yükleniyor…</div>
      )}
      {!error && !loading && sessions.length === 0 && (
        <div className="empty">Oturum yok</div>
      )}

      <div className="cards">
        {sessions.map((s) => (
          <SessionCard
            key={s.id}
            session={s}
            brainUrl={brainUrl}
            token={token}
            open={expanded === s.id}
            onToggle={() => setExpanded(expanded === s.id ? null : s.id)}
          />
        ))}
      </div>
    </div>
  );
}

function SessionCard({
  session,
  brainUrl,
  token,
  open,
  onToggle,
}: {
  session: Session;
  brainUrl: string;
  token: string;
  open: boolean;
  onToggle: () => void;
}) {
  const [detail, setDetail] = useState<SessionDetail | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!open || detail || loading) return;
    let cancelled = false;
    (async () => {
      setLoading(true);
      setError(null);
      try {
        const url = `${apiBase(brainUrl)}/api/sessions/${session.id}?token=${encodeURIComponent(
          token
        )}`;
        const resp = await fetch(url);
        if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
        const j = (await resp.json()) as SessionDetail;
        if (!cancelled) setDetail(j);
      } catch (e) {
        if (!cancelled) setError(String(e));
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [open, detail, loading, brainUrl, token, session.id]);

  const closed = session.status === "closed";
  const endTs = session.ended_at ?? session.updated_at;

  return (
    <div className={`card ${open ? "open" : ""}`}>
      <div className="card-head" onClick={onToggle}>
        <span className={`badge ${closed ? "closed" : "active"}`}>
          {closed ? "kapalı" : "açık"}
        </span>
        <span className="card-title">{session.title || "(başlıksız)"}</span>
        <span className="grow" />
        <span className="muted">{session.turn_count} tur</span>
        <span className="muted time">
          {fmtClock(session.created_at)} → {endTs ? fmtClock(endTs) : "…"}
        </span>
      </div>
      {session.summary && <div className="card-summary">{session.summary}</div>}

      {open && (
        <div className="card-body">
          {loading && <div className="empty">Yükleniyor…</div>}
          {error && <div className="empty err">Hata: {error}</div>}
          {detail && detail.turns.length === 0 && (
            <div className="empty">Tur yok</div>
          )}
          {detail &&
            detail.turns.map((t, i) => (
              <div key={i} className={`msg ${t.role}`}>
                <span className="msg-role">
                  {t.role === "user" ? t.speaker || "Kullanıcı" : "Asistan"}
                </span>
                <span className="msg-text">{t.content}</span>
              </div>
            ))}
        </div>
      )}
    </div>
  );
}
