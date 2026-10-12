export type Local = { taken: Record<string, number>; dismissed: Record<string, number>; day: string; count: number };
const prefix = "fountis:connect:";

/** Per-user local state (taken / dismissed offers, daily count). Never sent anywhere. */
export function loadState(sub: string): Local {
  try {
    const raw = localStorage.getItem(prefix + sub);
    if (raw) return { taken: {}, dismissed: {}, day: "", count: 0, ...JSON.parse(raw) };
  } catch {
    /* storage blocked: start fresh each time */
  }
  return { taken: {}, dismissed: {}, day: "", count: 0 };
}

/**
 * The guest install id: 24 random bytes made on first use and kept in this origin's localStorage. It is not a
 * device identifier. FOUNTIS stores only a hash of it. Without storage a new id is made every time.
 */
export function installId(): string {
  const k = prefix + "install";
  try {
    const have = localStorage.getItem(k);
    if (have && have.length >= 22) return have;
  } catch {
    /* storage blocked: a fresh id each time */
  }
  const bytes = crypto.getRandomValues(new Uint8Array(24));
  const id = btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  try {
    localStorage.setItem(k, id);
  } catch {
    /* ignore */
  }
  return id;
}

export function saveState(sub: string, s: Local) {
  try {
    localStorage.setItem(prefix + sub, JSON.stringify(s));
  } catch {
    /* ignore */
  }
}
