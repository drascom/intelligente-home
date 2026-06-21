// Ortak yardımcılar (App + paneller).

export function fmtTime(ts: number): string {
  const d = new Date(ts * 1000);
  return (
    d.toLocaleTimeString("tr-TR", { hour12: false }) +
    "." +
    String(d.getMilliseconds()).padStart(3, "0")
  );
}

// Saniye + tarih (oturum kartı zaman aralığı için kısa biçim).
export function fmtClock(ts: number): string {
  const d = new Date(ts * 1000);
  return d.toLocaleTimeString("tr-TR", { hour12: false });
}

export function apiBase(brainUrl: string): string {
  return brainUrl.replace(/\/$/, "");
}
