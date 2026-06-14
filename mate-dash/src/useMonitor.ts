import { useCallback, useEffect, useRef, useState } from "react";
import type { BrainEvent, ConnState } from "./types";

const MAX_EVENTS = 1000; // UI'da tutulan tavan (bellek sınırı)

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

  return { events, state, clear };
}
