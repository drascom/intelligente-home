import { useCallback, useEffect, useRef, useState } from "react";
import type { BrainEvent, ConnState } from "./types";

const MAX_EVENTS = 5000; // UI'da tutulan tavan (canlı + yüklenen geçmiş)

interface Options {
  brainUrl: string;
  token: string;
  enabled: boolean;
  paused: boolean;
}

/** Brain SSE akışına bağlanır; olayları (id'ye göre tekilleştirip) biriktirir.
 *  Tarayıcı EventSource'u kopuklukta otomatik reconnect eder; backfill ring'den
 *  gelen tekrarları id ile süzeriz. */
export function useMonitor({ brainUrl, token, enabled, paused }: Options) {
  const [events, setEvents] = useState<BrainEvent[]>([]);
  const [state, setState] = useState<ConnState>("disconnected");
  const esRef = useRef<EventSource | null>(null);
  const seenRef = useRef<Set<number>>(new Set());
  const pausedRef = useRef(paused);
  pausedRef.current = paused;

  const clear = useCallback(() => {
    seenRef.current = new Set();
    setEvents([]);
  }, []);

  // Kalıcı geçmişten daha eski olayları yükle (DB). En eski görünen id'den geriye.
  const loadOlder = useCallback(async (): Promise<number> => {
    if (!brainUrl || !token) return 0;
    let oldest = Infinity;
    for (const id of seenRef.current) if (id < oldest) oldest = id;
    const beforeQ = Number.isFinite(oldest) ? `&before=${oldest}` : "";
    const url = `${brainUrl.replace(/\/$/, "")}/api/monitor/history?token=${encodeURIComponent(
      token
    )}&limit=100${beforeQ}`;
    try {
      const resp = await fetch(url);
      if (!resp.ok) return 0;
      const { events: older } = (await resp.json()) as { events: BrainEvent[] };
      const fresh = older.filter((e) => !seenRef.current.has(e.id));
      fresh.forEach((e) => seenRef.current.add(e.id));
      if (fresh.length) setEvents((prev) => [...prev, ...fresh]); // eski → sona
      return fresh.length;
    } catch {
      return 0;
    }
  }, [brainUrl, token]);

  useEffect(() => {
    if (!enabled || !brainUrl || !token) {
      esRef.current?.close();
      esRef.current = null;
      setState("disconnected");
      return;
    }
    setState("connecting");
    const url = `${brainUrl.replace(/\/$/, "")}/api/monitor/stream?token=${encodeURIComponent(token)}`;
    const es = new EventSource(url);
    esRef.current = es;

    es.onopen = () => setState("connected");
    es.onerror = () => {
      // 401/sunucu kapalı → tarayıcı CLOSED'a düşer ve denemeyi keser;
      // ağ kopukluğunda kendisi reconnect eder.
      setState(es.readyState === EventSource.CLOSED ? "disconnected" : "connecting");
    };
    es.onmessage = (e) => {
      if (pausedRef.current) return;
      let ev: BrainEvent;
      try {
        ev = JSON.parse(e.data);
      } catch {
        return;
      }
      if (seenRef.current.has(ev.id)) return;
      seenRef.current.add(ev.id);
      setEvents((prev) => {
        const next = [ev, ...prev];
        return next.length > MAX_EVENTS ? next.slice(0, MAX_EVENTS) : next;
      });
    };

    return () => {
      es.close();
      esRef.current = null;
    };
  }, [brainUrl, token, enabled]);

  return { events, state, clear, loadOlder };
}
