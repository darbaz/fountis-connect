export type Cond = { attr: string; op: "in" | "not_in" | "eq" | "gte" | "lte" | "between"; value: unknown };
export type Survey = {
  offer_id: string;
  conditions?: { all?: Cond[] };
  required_attrs?: string[];
  loi_minutes?: number;
  reward?: { mode: "rewarded"; units: number; unit_name: string } | { mode: "free" };
  expires_at?: string;
  /** Open to guests (people with no signed token); only ever true on apps FOUNTIS allowed guests in. */
  guest?: boolean;
};
export type Claims = { sub: string; exp?: number; attrs?: Record<string, unknown> };

/** Decode a JWS payload without verifying it. The server verifies on POST /attempts. */
export function decodeToken(token: string): Claims | null {
  try {
    const part = token.split(".")[1];
    const b64 = part.replace(/-/g, "+").replace(/_/g, "/");
    const bin = atob(b64 + "=".repeat((4 - (b64.length % 4)) % 4));
    const json = decodeURIComponent(Array.from(bin, (c) => "%" + c.charCodeAt(0).toString(16).padStart(2, "0")).join(""));
    const c = JSON.parse(json);
    return typeof c.sub === "string" ? c : null;
  } catch {
    return null;
  }
}

const ATTR_ORDER = ["gender", "birth_year", "governorate", "city", "lang"];

/**
 * Every attribute the token carries, for the consent screen. FOUNTIS stores all of them when the study opens,
 * not only the ones the study's conditions use (`required_attrs`), so the list comes from the token itself.
 */
export function carriedAttrs(attrs: Record<string, unknown> | undefined): string[] {
  const rank = (k: string) => {
    const i = ATTR_ORDER.indexOf(k);
    return i < 0 ? ATTR_ORDER.length : i;
  };
  return Object.keys(attrs ?? {})
    .filter((k) => attrs![k] !== null && attrs![k] !== undefined)
    .sort((a, b) => rank(a) - rank(b) || (a < b ? -1 : 1));
}

/** Short stable hash of the sub, used only to key local storage. */
export async function subKey(sub: string): Promise<string> {
  try {
    const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(sub));
    return Array.from(new Uint8Array(d).slice(0, 8), (b) => b.toString(16).padStart(2, "0")).join("");
  } catch {
    let h = 2166136261;
    for (let i = 0; i < sub.length; i++) h = Math.imul(h ^ sub.charCodeAt(i), 16777619);
    return (h >>> 0).toString(16);
  }
}

function valueOf(attr: string, attrs: Record<string, unknown>): unknown {
  if (attr === "age") {
    const y = Number(attrs.birth_year);
    return Number.isFinite(y) && y > 1900 ? new Date().getFullYear() - y : undefined;
  }
  return attrs[attr];
}

export function matches(s: Survey, attrs: Record<string, unknown>): boolean {
  for (const a of s.required_attrs ?? []) if (attrs[a] === undefined || attrs[a] === null) return false;
  for (const c of s.conditions?.all ?? []) {
    const v = valueOf(c.attr, attrs);
    if (v === undefined || v === null) return false;
    const list = Array.isArray(c.value) ? c.value : [c.value];
    const n = Number(v);
    switch (c.op) {
      case "in": if (!list.includes(v)) return false; break;
      case "not_in": if (list.includes(v)) return false; break;
      case "eq": if (v !== c.value) return false; break;
      case "gte": if (!(n >= Number(c.value))) return false; break;
      case "lte": if (!(n <= Number(c.value))) return false; break;
      case "between": if (!(n >= Number(list[0]) && n <= Number(list[1]))) return false; break;
      default: return false;
    }
  }
  return true;
}
