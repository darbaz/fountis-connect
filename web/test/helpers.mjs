// Shared by the test files. Import "./dom.mjs" BEFORE this file and before the SDK source.
import { mock } from "node:test";
import { JSDOM } from "jsdom";

export const API = "https://api.test/v1";
export const ENGINE_URL = "https://engine.test/connect/engine.html";
export const ENGINE_ORIGIN = "https://engine.test";

/** Let every pending promise callback run (fake timers do not touch setImmediate). */
export const flush = async () => {
  for (let i = 0; i < 4; i++) await new Promise((r) => setImmediate(r));
};

/** Fake setTimeout/clearTimeout; `tick(ms)` moves the clock and then lets promise callbacks run. */
export function fakeClock() {
  mock.timers.enable({ apis: ["setTimeout"] });
  return {
    async tick(ms) {
      mock.timers.tick(ms);
      await flush();
    },
    restore: () => mock.timers.reset(),
  };
}

const json = (body) => ({ ok: true, status: 200, json: async () => body });

/** A fake FOUNTIS API on globalThis.fetch. `calls` lists every request as { path, method, body }. */
export function fakeApi({ guests = true, surveys = [{ offer_id: "o1", guest: true, loi_minutes: 5 }] } = {}) {
  const calls = [];
  globalThis.fetch = async (url, init = {}) => {
    const path = String(url).slice(API.length);
    calls.push({ path, method: init.method || "GET", body: init.body ? JSON.parse(init.body) : null });
    if (path.startsWith("/surveys")) return json({ app: { name: "Partner", guests }, config: {}, surveys });
    if (path === "/guest/session") return json({ guest_session: "gs_test" });
    if (path === "/events") return { ok: true, status: 204, json: async () => null };
    throw new Error("unexpected request " + path);
  };
  return calls;
}

/** The elements the SDK appended to the page that hold a shadow root with `selector` in it. */
export const hostWith = (selector) => [...document.body.children].find((el) => el.shadowRoot && el.shadowRoot.querySelector(selector));
export const teaser = () => hostWith(".go");
export const modal = () => hostWith("iframe");
export const q = (host, selector) => host.shadowRoot.querySelector(selector);

/**
 * jsdom gives an iframe inside a shadow root no contentWindow, and a real browser always does. Give the iframe a stand-in
 * window (a second, empty jsdom window) and record what the SDK posts into it. Call this right after the modal opens.
 */
export function wireFrame(host) {
  const posted = [];
  const win = new JSDOM("", { url: ENGINE_URL }).window;
  win.postMessage = (data, origin) => posted.push({ data, origin });
  Object.defineProperty(q(host, "iframe"), "contentWindow", { get: () => win, configurable: true });
  return posted;
}

/** What the engine page would post to the partner page. Defaults: the engine's own window and origin. */
export function engineSays(host, msg, { origin = ENGINE_ORIGIN, source } = {}) {
  const frame = q(host, "iframe");
  window.dispatchEvent(new window.MessageEvent("message", { data: { fountis: "engine", ...msg }, origin, source: source ?? frame.contentWindow }));
}

/** Dispatches a keydown on `el` and returns the event, so a test can read `defaultPrevented`. */
export function press(el, key, init = {}) {
  const e = new window.KeyboardEvent("keydown", { key, bubbles: true, composed: true, cancelable: true, ...init });
  el.dispatchEvent(e);
  return e;
}

/** Resolves with the value `p` settles with, but exposes whether it has settled yet. */
export function track(p) {
  const t = { settled: false, value: undefined };
  t.done = p.then((v) => {
    t.settled = true;
    t.value = v;
    return v;
  });
  return t;
}

export function resetPage() {
  document.body.innerHTML = "";
  document.body.style.overflow = "";
  document.documentElement.style.overflow = "";
  localStorage.clear();
}
