import { useCallback, useEffect, useState } from "react";
import type { Topic, TopicDetail, TopicOpenItem } from "./types";
import { apiBase, fmtTime } from "./util";

interface Props {
  brainUrl: string;
  token: string;
  // topic_updated olayı geldiğinde değişir → listeyi tazele.
  refreshSignal: number;
}

export default function TopicsPanel({ brainUrl, token, refreshSignal }: Props) {
  const [topics, setTopics] = useState<Topic[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [expanded, setExpanded] = useState<number | null>(null);

  const load = useCallback(async () => {
    if (!brainUrl || !token) return;
    setLoading(true);
    setError(null);
    try {
      const url = `${apiBase(brainUrl)}/api/topics?token=${encodeURIComponent(token)}`;
      const resp = await fetch(url);
      if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
      const j = (await resp.json()) as { topics: Topic[] };
      setTopics(j.topics ?? []);
    } catch (e) {
      setError(String(e));
    } finally {
      setLoading(false);
    }
  }, [brainUrl, token]);

  // Açılışta + her topic_updated olayında tazele.
  useEffect(() => {
    load();
  }, [load, refreshSignal]);

  return (
    <div className="panel-view">
      <div className="panel-head">
        <strong>Konular</strong>
        <span className="muted">{topics.length}</span>
        <span className="grow" />
        <button className="btn" onClick={load} disabled={loading}>
          {loading ? "Yükleniyor…" : "↻ Yenile"}
        </button>
      </div>

      {error && <div className="empty err">Hata: {error}</div>}
      {!error && loading && topics.length === 0 && (
        <div className="empty">Yükleniyor…</div>
      )}
      {!error && !loading && topics.length === 0 && (
        <div className="empty">Konu yok</div>
      )}

      <div className="cards">
        {topics.map((t) => (
          <TopicCard
            key={t.id}
            topic={t}
            brainUrl={brainUrl}
            token={token}
            open={expanded === t.id}
            onToggle={() => setExpanded(expanded === t.id ? null : t.id)}
          />
        ))}
      </div>
    </div>
  );
}

function TopicCard({
  topic,
  brainUrl,
  token,
  open,
  onToggle,
}: {
  topic: Topic;
  brainUrl: string;
  token: string;
  open: boolean;
  onToggle: () => void;
}) {
  const [items, setItems] = useState<TopicOpenItem[] | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [resolving, setResolving] = useState<Set<number>>(new Set());

  useEffect(() => {
    if (!open || items || loading) return;
    let cancelled = false;
    (async () => {
      setLoading(true);
      setError(null);
      try {
        const url = `${apiBase(brainUrl)}/api/topics/${topic.id}?token=${encodeURIComponent(
          token
        )}`;
        const resp = await fetch(url);
        if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
        const j = (await resp.json()) as TopicDetail;
        if (!cancelled) setItems(j.open_items ?? []);
      } catch (e) {
        if (!cancelled) setError(String(e));
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [open, items, loading, brainUrl, token, topic.id]);

  const resolve = async (id: number) => {
    setResolving((prev) => new Set(prev).add(id));
    try {
      const url = `${apiBase(brainUrl)}/api/open-items/${id}/resolve?token=${encodeURIComponent(
        token
      )}`;
      const resp = await fetch(url, { method: "POST" });
      if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
      setItems((prev) => (prev ? prev.filter((it) => it.id !== id) : prev));
    } catch (e) {
      alert("Çözme başarısız: " + e);
    } finally {
      setResolving((prev) => {
        const next = new Set(prev);
        next.delete(id);
        return next;
      });
    }
  };

  const isOpen = topic.status === "open";
  const lastTs = topic.last_activity_at ?? topic.updated_at;

  return (
    <div className={`card ${open ? "open" : ""}`}>
      <div className="card-head" onClick={onToggle}>
        <span className={`badge ${isOpen ? "active" : "closed"}`}>
          {topic.status}
        </span>
        <span className="card-title">{topic.title || "(başlıksız konu)"}</span>
        <span className="grow" />
        <span className="muted time">{fmtTime(lastTs)}</span>
      </div>
      {topic.summary && <div className="card-summary">{topic.summary}</div>}

      {open && (
        <div className="card-body">
          {loading && <div className="empty">Yükleniyor…</div>}
          {error && <div className="empty err">Hata: {error}</div>}
          {items && items.length === 0 && (
            <div className="empty">Açık iş yok</div>
          )}
          {items &&
            items.map((it) => (
              <div key={it.id} className="item-row">
                <span className="item-text">{it.text}</span>
                <button
                  className="btn primary sm"
                  onClick={() => resolve(it.id)}
                  disabled={resolving.has(it.id)}
                >
                  {resolving.has(it.id) ? "…" : "Çözüldü"}
                </button>
              </div>
            ))}
        </div>
      )}
    </div>
  );
}
