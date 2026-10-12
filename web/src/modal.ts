import { closeLabel, loadingLabel } from "./teaser";

/**
 * How long the engine page gets to load and say `ready` before the study counts as unavailable (the same "never
 * opened" failure as the native SDKs' 10 s presentation watchdog; the web engine page is a network download of
 * several hundred KB, so it gets the same 15 s as one API request).
 */
export const ENGINE_LOAD_TIMEOUT_MS = 15_000;

/** A resize or rotation re-measures the safe-area insets at most this often (one trailing measurement per window). */
export const INSETS_THROTTLE_MS = 150;

// Always full screen: the engine draws its own FOUNTIS top bar, progress and close button, so there is
// no backdrop card, no rounded frame and no max size, on any screen.
// The SDK's own close button (.x) sits above the iframe and shows only until the engine says `ready`: while the
// engine page is loading, or never loads, it is the only way out, because the iframe is cross-origin and its
// keystrokes never reach this document. From `ready` on, the engine's own frame (same button, from its first paint)
// takes over, so .x is drawn exactly where the engine draws its button and the hand-over does not move anything:
// start side of a centred 560 px bar (left in LTR, right in RTL), 4 px from the top, 44 px target, bare 20 px icon.
// Offsets mirror engine/src/styles.css .fc-screen + .fc-bar + .fc-iconbtn: safe-area padding on the side, the bar is
// max 560 px and centred in what is left, the button has a 4 px margin and is centred in a 52 px bar.
const BAR_INSET = "calc(max(0px,(100% - env(safe-area-inset-left,0px) - env(safe-area-inset-right,0px) - 560px)/2) + 4px)";
const CSS = `
:host{all:initial}
.bg{position:fixed;inset:0;z-index:2147483001;width:100vw;height:100vh;height:100dvh;background:#f2f5f4}
iframe{position:absolute;inset:0;border:0;width:100%;height:100%;background:#f2f5f4;display:block}
.x{position:absolute;z-index:1;top:calc(4px + env(safe-area-inset-top,0px));width:44px;height:44px;margin:0;padding:0;
 display:flex;align-items:center;justify-content:center;cursor:pointer;-webkit-tap-highlight-color:transparent;
 background:transparent;color:#43534d;border:0;border-radius:50%}
.bg[dir=ltr] .x{left:calc(env(safe-area-inset-left,0px) + ${BAR_INSET})}
.bg[dir=rtl] .x{right:calc(env(safe-area-inset-right,0px) + ${BAR_INSET})}
.x[hidden]{display:none}
.x:active{background:rgba(16,25,21,.06)}
.x svg{width:20px;height:20px;display:block}
.x:focus-visible{outline:2px solid #0e4f40;outline-offset:-2px}
.sr{position:absolute;width:1px;height:1px;margin:-1px;padding:0;overflow:hidden;clip:rect(0 0 0 0);white-space:nowrap;border:0}
`;

/**
 * The partner page's safe-area insets in CSS px. Inside the engine's iframe env(safe-area-inset-*) is 0, so on a notched
 * phone the engine cannot know where the notch is; the page measures them once with a throwaway probe and sends them with
 * `init` (`insets`), and again in a small `insets` message when the page resizes or rotates (see INSETS_THROTTLE_MS). They are 0
 * unless the page opts in with `viewport-fit=cover` (or env() is unsupported).
 */
type Insets = { top: number; right: number; bottom: number; left: number };
function measureInsets(): Insets {
  const insets = { top: 0, right: 0, bottom: 0, left: 0 };
  const probe = document.createElement("div");
  try {
    probe.style.cssText =
      "position:fixed;left:0;top:0;width:0;height:0;overflow:hidden;visibility:hidden;pointer-events:none;" +
      "padding:env(safe-area-inset-top,0px) env(safe-area-inset-right,0px) env(safe-area-inset-bottom,0px) env(safe-area-inset-left,0px)";
    document.body.appendChild(probe);
    const cs = window.getComputedStyle(probe);
    const px = (v: string) => (Number.isFinite(parseFloat(v)) ? Math.max(0, parseFloat(v)) : 0);
    insets.top = px(cs.paddingTop);
    insets.right = px(cs.paddingRight);
    insets.bottom = px(cs.paddingBottom);
    insets.left = px(cs.paddingLeft);
  } catch {
    /* the insets are a courtesy; the engine pads by 0 */
  } finally {
    probe.remove();
  }
  return insets;
}

/**
 * Modal iframe running the survey engine. Messages are accepted only from the
 * engine iframe's window AND its exact origin. The engine gets the offer + token
 * once, addressed to that exact origin.
 *
 * The person can always leave: the SDK's own close button (outside the iframe) and Escape on this document both
 * work from the moment the modal opens, and the button hides once the engine is up and shows its own (the engine draws
 * its frame, close button included, from its first paint, and handles Escape itself once focus is inside it). Until
 * then Tab stays on the button; after that, focus that strays onto the page behind is sent back into the iframe. If the
 * engine page does not say `ready` within ENGINE_LOAD_TIMEOUT_MS the modal closes itself and `onUnavailable`
 * runs (nothing was shown to the person: no outcome, no dismissal). `close()` (host-initiated) runs neither callback.
 */
export function showModal(o: {
  engineUrl: string;
  init: Record<string, unknown>;
  /** Where focus goes when the modal closes (default: whatever had focus when it opened). */
  returnFocus?: Element | null;
  onClose: (outcome: string | null) => void;
  onUnavailable: () => void;
}) {
  const engineOrigin = new URL(o.engineUrl, location.href).origin;
  const lang = typeof o.init.lang === "string" ? o.init.lang : "en";
  const opener = o.returnFocus !== undefined ? o.returnFocus : document.activeElement;
  const host = document.createElement("div");
  const root = host.attachShadow({ mode: "open" });
  const st = document.createElement("style");
  st.textContent = CSS;
  const bg = document.createElement("div");
  bg.className = "bg";
  bg.dir = lang === "en" ? "ltr" : "rtl";
  bg.setAttribute("role", "dialog");
  bg.setAttribute("aria-modal", "true");
  bg.setAttribute("aria-label", "FOUNTIS");
  const frame = document.createElement("iframe");
  frame.title = "FOUNTIS";
  frame.setAttribute("allow", "");
  frame.setAttribute("scrolling", "no");
  frame.referrerPolicy = "no-referrer";
  const sep = o.engineUrl.includes("#") ? "&" : "#";
  frame.src = o.engineUrl + sep + "o=" + encodeURIComponent(location.origin);
  const x = document.createElement("button");
  x.type = "button";
  x.className = "x";
  x.setAttribute("aria-label", closeLabel(lang));
  // The engine's own close icon (engine/src/App.tsx Icon.close), so the two buttons are one picture.
  x.innerHTML =
    '<svg width="20" height="20" viewBox="0 0 16 16" fill="none" aria-hidden="true" focusable="false"><path d="M4 4L12 12M12 4L4 12" stroke="currentColor" stroke-width="1.7" stroke-linecap="round"/></svg>';
  // Until the engine says ready the iframe is busy loading. The visually hidden live line that says so to screen readers
  // is its sibling, not inside it: a live region inside an aria-busy subtree is not announced.
  frame.setAttribute("aria-busy", "true");
  const status = document.createElement("span");
  status.className = "sr";
  status.setAttribute("role", "status");
  bg.append(frame, x, status);
  root.append(st, bg);

  let outcome: string | null = null;
  let closed = false;
  let ready = false;
  let loadTimer: ReturnType<typeof setTimeout> | null = null;
  // The insets the engine was last given (with init, or an `insets` message), and the pending re-measure after a resize.
  let sentInsets = "";
  let insetsTimer: ReturnType<typeof setTimeout> | null = null;
  const insetsKey = (i: Insets) => `${i.top},${i.right},${i.bottom},${i.left}`;
  // Lock page scroll while the survey is open (html and body, so iOS Safari does not scroll behind it).
  const de = document.documentElement.style;
  const bd = document.body.style;
  const prev = { de: de.overflow, bd: bd.overflow, dePad: de.overscrollBehavior };

  const stopLoadTimer = () => {
    if (loadTimer !== null) clearTimeout(loadTimer);
    loadTimer = null;
  };
  const close = () => {
    if (closed) return;
    closed = true;
    stopLoadTimer();
    if (insetsTimer !== null) clearTimeout(insetsTimer);
    insetsTimer = null;
    window.removeEventListener("message", onMessage);
    window.removeEventListener("resize", onViewportChange);
    window.removeEventListener("orientationchange", onViewportChange);
    document.removeEventListener("keydown", onKey, true);
    document.removeEventListener("focusin", onFocusIn, true);
    de.overflow = prev.de;
    bd.overflow = prev.bd;
    de.overscrollBehavior = prev.dePad;
    host.remove();
    // Give focus back to where the person was before the study opened (if that is still on the page).
    const back = opener as HTMLElement | null;
    if (back && back !== document.body && back.isConnected && typeof back.focus === "function") {
      try {
        back.focus({ preventScroll: true });
      } catch {
        /* focus is a courtesy */
      }
    }
  };
  const onMessage = (ev: MessageEvent) => {
    if (ev.origin !== engineOrigin || ev.source !== frame.contentWindow) return;
    const d = ev.data as { fountis?: string; type?: string; outcome?: string } | null;
    if (!d || d.fountis !== "engine") return;
    if (d.type === "ready") {
      ready = true;
      stopLoadTimer();
      frame.removeAttribute("aria-busy");
      status.textContent = "";
      const insets = measureInsets();
      sentInsets = insetsKey(insets);
      frame.contentWindow!.postMessage({ ...o.init, insets }, engineOrigin);
      // The engine shows its own close button now. If keyboard focus is still on ours (or nowhere), move it into
      // the study so the person is not left tabbing through the page behind it.
      const here = root.activeElement === x || !document.activeElement || document.activeElement === document.body;
      x.hidden = true;
      if (here) frame.focus();
    } else if (d.type === "done") outcome = d.outcome ?? null;
    else if (d.type === "close") {
      close();
      o.onClose(outcome);
    }
  };
  // A rotation or resize changes the notch insets the engine was given with init (it cannot read them itself inside the iframe).
  // Once the engine is up, re-measure after a short pause and send just the new numbers, and only if they changed: never init
  // or the token again.
  const onViewportChange = () => {
    if (!ready || closed || insetsTimer !== null) return;
    insetsTimer = setTimeout(() => {
      insetsTimer = null;
      if (closed) return;
      const insets = measureInsets();
      const key = insetsKey(insets);
      if (key === sentInsets) return;
      sentInsets = key;
      try {
        frame.contentWindow?.postMessage({ fountis: "insets", insets }, engineOrigin);
      } catch {
        /* the insets are a courtesy */
      }
    }, INSETS_THROTTLE_MS);
  };
  // Capture phase on the document: a page handler that stops keydown from bubbling must not trap the person here.
  const onKey = (e: KeyboardEvent) => {
    if (e.key === "Escape") {
      close();
      o.onClose(outcome);
    } else if (e.key === "Tab" && !ready) {
      // Until the engine is up, the close button is the only control on this screen: Tab and Shift+Tab stay on it
      // instead of walking out into the page behind the overlay.
      e.preventDefault();
      try {
        x.focus({ preventScroll: true });
      } catch {
        /* ignore */
      }
    }
  };
  // Once the engine is up the iframe owns the keyboard, but Tab past its last control (or Shift+Tab before its first)
  // lands on the page behind the overlay, where nothing is visible. Any focus that arrives outside the overlay goes
  // straight back into the iframe. (Events from inside the shadow root are retargeted to `host`.)
  const onFocusIn = (e: FocusEvent) => {
    if (!ready || closed || e.target === host) return;
    try {
      frame.focus({ preventScroll: true });
    } catch {
      /* ignore */
    }
  };
  x.addEventListener("click", () => {
    if (closed) return;
    close();
    o.onClose(outcome);
  });
  loadTimer = setTimeout(() => {
    loadTimer = null;
    if (closed || ready) return;
    close();
    o.onUnavailable();
  }, ENGINE_LOAD_TIMEOUT_MS);
  window.addEventListener("message", onMessage);
  window.addEventListener("resize", onViewportChange);
  window.addEventListener("orientationchange", onViewportChange);
  document.addEventListener("keydown", onKey, true);
  document.addEventListener("focusin", onFocusIn, true);
  de.overflow = "hidden";
  bd.overflow = "hidden";
  de.overscrollBehavior = "none";
  document.body.appendChild(host);
  status.textContent = loadingLabel(lang);
  // Focus lands on the host side, so Escape works from the first moment (focus inside the iframe never reaches this document).
  try {
    x.focus({ preventScroll: true });
  } catch {
    /* ignore */
  }
  return { close };
}
