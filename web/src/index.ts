import { carriedAttrs, decodeToken, matches, subKey, type Survey } from "./match";
import { installId, loadState, saveState, type Local } from "./state";
import { showModal } from "./modal";
import { showTeaser, langOf } from "./teaser";

/**
 * @fountispanel/connect: web SDK. Public API (same names as the native SDKs):
 *   start, setUserToken, enableNotifications, show, setUserConsent, signOut, onEvent
 * Guests: when the token provider returns null or undefined (nobody is signed in) and FOUNTIS has switched guests
 * on for your app, the SDK offers the free studies marked open to guests, after an 18+ confirmation. Nothing to
 * call; an app without accounts can pass setUserToken(() => null).
 * Only null or undefined means signed out. An empty string is not signed out (it is an unusable token), and a
 * provider that throws, rejects, or does not answer within 10 seconds is a failure: nothing is shown, and the
 * person is never treated as a guest because of it.
 * Every failure is silent and becomes "noFill". The SDK never throws into the host page.
 */
export type ShowResult = "noFill" | "dismissed" | "completed";
export type ConnectEvent = { type: "shown" | "started" | "dismissed" | "completed" | "noFill"; offerId?: string };
/**
 * The signed user token, or a function that returns it (sync or async). null or undefined = nobody is signed in
 * (a guest, if the app allows guests). Throw or reject when the token request fails, so the SDK shows nothing
 * rather than offering the guest studies to a signed-in person. A function that does not answer within 10
 * seconds counts as a failure. An empty string is not "signed out": it is an unusable token and shows nothing.
 */
type TokenProvider = string | null | (() => string | null | Promise<string | null>);

/** How long the host's token function may take before the check gives up (same as the React Native and Flutter wrappers). */
const PROVIDER_TIMEOUT_MS = 10_000;

/** How long one API request may take, body included, before it counts as a failure (a request that never settles would otherwise keep `busy` set for the life of the page). */
const API_TIMEOUT_MS = 15_000;

const DEFAULT_API = "https://ucclsekjekdxzfwzyuji.supabase.co/functions/v1/connect-api/v1";
const DEFAULT_ENGINE = "https://fountis.org/connect/engine.html";

let cfg: { key: string; apiBase: string; engineUrl: string } | null = null;
let provider: TokenProvider = null;
// setUserToken (or signOut) was called: the host has told us it handles sign-in, so a null token means a guest.
let providerSet = false;
let consent = true;
let notifications = false;
let listeners: Array<(e: ConnectEvent) => void> = [];
let cache: { lang: string; at: number; data: { app: { name: string; guests?: boolean }; config: Config; surveys: Survey[] } } | null = null;
let guestSession: { token: string; until: number } | null = null;
let busy = false;
// Bumped whenever the person signs out or the host swaps the token provider; a check that began earlier must not present a study.
let epoch = 0;
let autoTimer: ReturnType<typeof setTimeout> | null = null;

type Config = { max_notifications_per_day?: number; quiet_hours?: [number, number] };

function emit(e: ConnectEvent) {
  listeners.slice().forEach((f) => {
    try {
      f(e);
    } catch {
      /* partner callback errors stay theirs */
    }
  });
}

export function start(opts: { key: string; apiBase?: string; engineUrl?: string }): void {
  cfg = { key: opts.key, apiBase: (opts.apiBase || DEFAULT_API).replace(/\/$/, ""), engineUrl: opts.engineUrl || DEFAULT_ENGINE };
  cache = null;
  scheduleAuto();
}

export function setUserToken(p: TokenProvider): void {
  provider = p;
  providerSet = true;
  epoch++;
  scheduleAuto();
}

/** Web has no push: this just turns on the in-page invitation that appears after page load. */
export function enableNotifications(): void {
  notifications = true;
  scheduleAuto();
}

export function setUserConsent(allowed: boolean): void {
  consent = !!allowed;
  if (!consent) {
    cache = null;
    closeUi?.();
  }
}

export function signOut(): void {
  // Signed out means a guest (when the app allows guests); never an error.
  provider = null;
  providerSet = true;
  epoch++;
  cache = null;
  guestSession = null;
  closeUi?.();
  scheduleAuto();
}

export function onEvent(fn: (e: ConnectEvent) => void): () => void {
  listeners.push(fn);
  return () => {
    listeners = listeners.filter((f) => f !== fn);
  };
}

let closeUi: (() => void) | null = null;

/** Look for a matching study and present the teaser. Resolves when the person decides. */
export async function show(): Promise<ShowResult> {
  return run(true);
}

function scheduleAuto() {
  if (!notifications || !cfg || !providerSet || autoTimer) return;
  const go = () => {
    autoTimer = setTimeout(() => {
      autoTimer = null;
      void run(false);
    }, 1200);
  };
  if (document.readyState === "complete") go();
  else window.addEventListener("load", go, { once: true });
}

/** A guest session token, kept in memory for most of its hour. */
async function getGuestSession(force = false): Promise<string> {
  if (!force && guestSession && guestSession.until > Date.now()) return guestSession.token;
  const r = await api<{ guest_session: string }>("/guest/session", { method: "POST", body: JSON.stringify({ install_id: installId() }) });
  guestSession = { token: r.guest_session, until: Date.now() + 55 * 60_000 };
  return guestSession.token;
}

/**
 * Ask the host's token function, but never wait forever: a promise that never settles would otherwise keep
 * `busy` set for the life of the page. Rejects on a throw (sync or async) or after PROVIDER_TIMEOUT_MS.
 */
function askProvider(fn: () => string | null | Promise<string | null>): Promise<string | null> {
  return new Promise((resolve, reject) => {
    const t = setTimeout(() => reject(new Error("token provider timed out")), PROVIDER_TIMEOUT_MS);
    Promise.resolve()
      .then(() => fn())
      .then(
        (v) => {
          clearTimeout(t);
          resolve(v);
        },
        (e) => {
          clearTimeout(t);
          reject(e);
        },
      );
  });
}

async function api<T>(path: string, init?: RequestInit): Promise<T> {
  const ctl = new AbortController();
  const t = setTimeout(() => ctl.abort(), API_TIMEOUT_MS);
  try {
    const r = await fetch(cfg!.apiBase + path, {
      ...init,
      signal: ctl.signal,
      credentials: "omit",
      headers: { "X-Fountis-Key": cfg!.key, "Content-Type": "application/json" },
    });
    if (!r.ok) throw new Error(String(r.status));
    return r.status === 204 ? (null as T) : ((await r.json()) as T);
  } finally {
    clearTimeout(t);
  }
}

function quiet(h: [number, number] | undefined) {
  if (!h) return false;
  const now = new Date().getHours();
  const [from, to] = h;
  return from > to ? now >= from || now < to : now >= from && now < to;
}

async function run(manual: boolean): Promise<ShowResult> {
  if (busy) return "noFill";
  busy = true;
  const mine = epoch;
  try {
    if (!cfg || !consent || !providerSet) return noFill();
    // A throw, a rejection or no answer in 10 s lands in the catch below: noFill, never a guest.
    const token = typeof provider === "function" ? await askProvider(provider) : provider;
    if (mine !== epoch) return noFill();
    // Only null/undefined means nobody is signed in: a guest, but only when the app allows guests and a guest
    // study exists. Anything else must be a non-empty string; "" (or a wrong type from a JS caller) is an
    // unusable token, not a signed-out person, so it shows nothing.
    const guest = token == null;
    if (!guest && (typeof token !== "string" || token === "")) return noFill();
    const claims = guest ? null : decodeToken(token);
    if (!guest && (!claims || (claims.exp && claims.exp * 1000 < Date.now()))) return noFill();

    const lang = langOf(claims?.attrs?.lang);
    // The offer list is localised, so the 60 s cache is per language (a token whose lang changed must not get the old words).
    if (!cache || cache.lang !== lang || Date.now() - cache.at > 60_000) cache = { lang, at: Date.now(), data: await api(`/surveys?lang=${lang}`) };
    if (mine !== epoch) return noFill();
    const { app, config, surveys } = cache.data;
    if (guest && (!app?.guests || !surveys.some((s) => s.guest))) return noFill();

    const key = guest ? "guest" : await subKey(claims!.sub);
    const state: Local = loadState(key);
    const today = new Date().toISOString().slice(0, 10);
    if (state.day !== today) {
      state.day = today;
      state.count = 0;
    }
    if (!manual) {
      if (quiet(config?.quiet_hours) || state.count >= (config?.max_notifications_per_day ?? 1)) return noFill();
    }
    const SUPPRESS = 7 * 86_400_000;
    const offer = surveys.find(
      (s) =>
        !state.taken[s.offer_id] &&
        !(state.dismissed[s.offer_id] && Date.now() - state.dismissed[s.offer_id] < SUPPRESS) &&
        (!s.expires_at || Date.parse(s.expires_at) > Date.now()) &&
        (guest ? s.guest === true : matches(s, claims!.attrs ?? {})),
    );
    if (!offer) return noFill();

    // The guest session is made before anything is shown, so the study can start at once.
    const session = guest ? await getGuestSession() : null;
    if (mine !== epoch) return noFill();

    state.count += 1;
    saveState(key, state);
    void api("/events", { method: "POST", body: JSON.stringify({ offer_id: offer.offer_id, type: "shown" }) }).catch(() => {});
    emit({ type: "shown", offerId: offer.offer_id });

    // Where keyboard focus returns to when the study closes (the teaser does not take focus, so this is still the page's element).
    const opener = document.activeElement;
    return await new Promise<ShowResult>((resolve) => {
      let finished = false;
      const end = (r: ShowResult, taken?: boolean) => {
        if (finished) return;
        finished = true;
        closeUi = null;
        if (r === "noFill") {
          // The study screen never opened (see showModal): nothing was shown, so the offer is neither taken nor dismissed.
          emit({ type: "noFill" });
          resolve(r);
          return;
        }
        if (r === "dismissed" && !taken) {
          state.dismissed[offer.offer_id] = Date.now();
          void api("/events", { method: "POST", body: JSON.stringify({ offer_id: offer.offer_id, type: "dismissed" }) }).catch(() => {});
        }
        if (taken) state.taken[offer.offer_id] = Date.now();
        saveState(key, state);
        emit({ type: r === "completed" ? "completed" : "dismissed", offerId: offer.offer_id });
        resolve(r);
      };
      const teaser = showTeaser({
        lang,
        minutes: offer.loi_minutes,
        reward: !guest && offer.reward && offer.reward.mode === "rewarded" ? offer.reward : null,
        onStart: () => {
          emit({ type: "started", offerId: offer.offer_id });
          const modal = showModal({
            engineUrl: cfg!.engineUrl,
            init: {
              fountis: "init",
              offerId: offer.offer_id,
              ...(guest ? { guestSession: session } : { token }),
              key: cfg!.key,
              apiBase: cfg!.apiBase,
              lang,
              partner: app?.name,
              attrs: guest ? [] : carriedAttrs(claims?.attrs),
              reward: !guest && offer.reward && offer.reward.mode === "rewarded" ? offer.reward : null,
            },
            returnFocus: opener,
            // The engine page never said ready (offline, blocked, a stalled network): nothing was shown, same as the native SDKs' presentation watchdog.
            onUnavailable: () => end("noFill"),
            onClose: (outcome) => {
              closeUi = null;
              end(outcome === "complete" ? "completed" : "dismissed", !!outcome);
            },
          });
          closeUi = () => {
            modal.close();
            end("dismissed");
          };
        },
        onDismiss: () => end("dismissed"),
      });
      closeUi = () => {
        teaser.close();
        end("dismissed");
      };
    });
  } catch {
    return noFill();
  } finally {
    busy = false;
  }
}

function noFill(): ShowResult {
  emit({ type: "noFill" });
  return "noFill";
}
