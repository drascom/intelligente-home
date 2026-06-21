import { useCallback, useEffect, useState } from "react";
import type { OpenItem } from "./types";
import { apiBase, fmtClock } from "./util";

interface Props {
  brainUrl: string;
  token: string;
  refreshSignal: number;
  // Üst sekmedeki sayaç rozeti için bekleyen iş sayısını dışarı bildir.
  onCount?: (n: number) => void;
}

export default function OpenItemsPanel({
  brainUrl,
  token,
  refreshSignal,
  onCount,
}: Props) {
  const [items, setItems] = useState<OpenItem[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [resolving, setResolving] = useState<Set<number>>(new Set());

  const load = useCallback(async () => {
    if (!brainUrl || !token) return;
    setLoading(true);
    setError(null);
    try {
      const url = `${apiBase(brainUrl)}/api/open-items?token=${encodeURIComponent(
        token
      )}&status=pending`;
      const resp = await fetch(url);
      if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
      const j = (await resp.json()) as { items: OpenItem[] };
      const list = j.items ?? [];
      setItems(list);
      onCount?.(list.length);
    } catch (e) {
      setError(String(e));
    } finally {
      setLoading(false);
    }
  }, [brainUrl, token, onCount]);

  useEffect(() => {
    load();
  }, [load, refreshSignal]);

  const resolve = async (id: number) => {
    setResolving((prev) => new Set(prev).add(id));
    try {
      const url = `${apiBase(brainUrl)}/api/open-items/${id}/resolve?token=${encodeURIComponent(
        token
      )}`;
      const resp = await fetch(url, { method: "POST" });
      if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
      setItems((prev) => {
        const next = prev.filter((it) => it.id !== id);
        onCount?.(next.length);
        return next;
      });
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

  return (
    <div className="panel-view">
      <div className="panel-head">
        <strong>Açık İşler</strong>
        <span className="muted">{items.length}</span>
        <span className="grow" />
        <button className="btn" onClick={load} disabled={loading}>
          {loading ? "Yükleniyor…" : "↻ Yenile"}
        </button>
      </div>

      {error && <div className="empty err">Hata: {error}</div>}
      {!error && loading && items.length === 0 && (
        <div className="empty">Yükleniyor…</div>
      )}
      {!error && !loading && items.length === 0 && (
        <div className="empty">Açık iş yok</div>
      )}

      <div className="cards">
        {items.map((it) => (
          <div key={it.id} className="card item">
            <div className="item-row">
              <span className="item-text">{it.text}</span>
              <button
                className="btn primary sm"
                onClick={() => resolve(it.id)}
                disabled={resolving.has(it.id)}
              >
                {resolving.has(it.id) ? "…" : "Çözüldü"}
              </button>
            </div>
            <div className="item-meta muted">
              {it.session_id != null && <span>oturum #{it.session_id}</span>}
              <span>{fmtClock(it.created_at)}</span>
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}
