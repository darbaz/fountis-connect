import "./dom.mjs";
import { afterEach, beforeEach, describe, it } from "node:test";
import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";
import { onEvent, setUserToken, show, signOut, start } from "../src/index";
import { ENGINE_LOAD_TIMEOUT_MS, INSETS_THROTTLE_MS, showModal } from "../src/modal";
import { API, ENGINE_ORIGIN, ENGINE_URL, engineSays, fakeApi, fakeClock, flush, modal, press, q, resetPage, teaser, track, wireFrame } from "./helpers.mjs";

// The study screen: the person can always leave it, and a page that never loads ends as noFill.

let clock;
let opened = [];
beforeEach(() => {
  resetPage();
  clock = fakeClock();
  opened = [];
});
afterEach(() => {
  // A modal a test leaves open keeps its document-level key listener; close them all so tests cannot hear each other.
  for (const m of opened) m.close();
  clock.restore();
  resetPage();
});

/** showModal on its own, recording what it reports. */
function open(extra = {}) {
  const seen = { closed: [], unavailable: 0 };
  const opener = document.createElement("button");
  opener.textContent = "Take a survey";
  document.body.appendChild(opener);
  opener.focus();
  const m = showModal({
    engineUrl: ENGINE_URL,
    init: { fountis: "init", offerId: "o1", lang: "en" },
    onClose: (outcome) => seen.closed.push(outcome),
    onUnavailable: () => seen.unavailable++,
    ...extra,
  });
  opened.push(m);
  const host = modal();
  return { m, seen, host, opener, button: q(host, ".x"), posted: wireFrame(host) };
}

describe("the SDK's own close control", () => {
  it("is on screen the moment the study opens, labelled, and holds keyboard focus", () => {
    const { host, button } = open();
    assert.ok(host, "the modal is on the page");
    assert.equal(button.getAttribute("aria-label"), "Close");
    assert.equal(button.hidden, false);
    assert.equal(host.shadowRoot.activeElement, button, "focus is on the host side, so Escape reaches this document");
    const dialog = q(host, '[role="dialog"]');
    assert.equal(dialog.getAttribute("aria-modal"), "true");
    assert.equal(dialog.getAttribute("aria-label"), "FOUNTIS");
    assert.equal(button.closest("iframe"), null, "the button is not inside the iframe");
  });

  it("is labelled in the study's language and the screen follows its direction", () => {
    for (const [lang, label, dir] of [["ku", "داخستن", "rtl"], ["kmr", "داخستن", "rtl"], ["ar", "إغلاق", "rtl"], ["en", "Close", "ltr"]]) {
      resetPage();
      const { host, button, m } = open({ init: { fountis: "init", lang } });
      assert.equal(button.getAttribute("aria-label"), label, lang);
      assert.equal(q(host, ".bg").dir, dir, lang);
      m.close();
    }
  });

  it("dismisses while the study is still loading, and gives focus back to the page", () => {
    const { seen, button, opener } = open();
    button.click();
    assert.deepEqual(seen.closed, [null]);
    assert.equal(seen.unavailable, 0);
    assert.equal(modal(), undefined, "the modal is gone");
    assert.equal(document.activeElement, opener, "focus returns to the element that had it");
    assert.equal(document.body.style.overflow, "", "page scroll is unlocked");
  });

  it("returns focus to an element the caller names", () => {
    const other = document.createElement("a");
    other.href = "#x";
    document.body.appendChild(other);
    const { button } = open({ returnFocus: other });
    button.click();
    assert.equal(document.activeElement, other);
  });

  it("closes on Escape pressed on the close button, and on the page", () => {
    let a = open();
    press(a.button, "Escape");
    assert.deepEqual(a.seen.closed, [null]);
    assert.equal(modal(), undefined);

    resetPage();
    a = open();
    press(document.body, "Escape");
    assert.deepEqual(a.seen.closed, [null]);
    assert.equal(modal(), undefined);
  });

  it("is not fooled by a page handler that stops keydown from bubbling", () => {
    const { seen } = open();
    document.body.addEventListener("keydown", (e) => e.stopPropagation()); // bubbling phase: runs after the SDK's capture listener
    press(document.body, "Escape");
    assert.deepEqual(seen.closed, [null]);
  });

  it("ignores other keys", () => {
    const { seen } = open();
    press(document.body, "Enter");
    press(document.body, "a");
    assert.deepEqual(seen.closed, []);
    assert.ok(modal());
  });

  it("stops listening once closed (no second report, no leaked handler)", () => {
    const { seen, button } = open();
    button.click();
    press(document.body, "Escape");
    window.dispatchEvent(new window.MessageEvent("message", { data: { fountis: "engine", type: "close" }, origin: ENGINE_ORIGIN }));
    assert.deepEqual(seen.closed, [null]);
  });
});

describe("while the study loads (before the engine says ready)", () => {
  it("Tab and Shift+Tab are cancelled and keep focus on the close button", () => {
    const { host, button } = open();
    const outside = document.createElement("a");
    outside.href = "#behind";
    document.body.appendChild(outside);
    for (const shiftKey of [false, true]) {
      const e = press(button, "Tab", { shiftKey });
      assert.equal(e.defaultPrevented, true, shiftKey ? "Shift+Tab is cancelled" : "Tab is cancelled");
      assert.equal(host.shadowRoot.activeElement, button, "focus stays on the button");
    }
    // Focus that slipped elsewhere on the page is pulled back by the next Tab.
    outside.focus();
    assert.equal(document.activeElement, outside);
    const e = press(document.body, "Tab");
    assert.equal(e.defaultPrevented, true);
    assert.equal(host.shadowRoot.activeElement, button);
    assert.ok(modal(), "Tab never closes anything");
  });

  it("Tab is left alone once the engine is ready, and focus moves into the study", () => {
    const { host, button } = open();
    engineSays(host, { type: "ready" });
    const e = press(document.body, "Tab");
    assert.equal(e.defaultPrevented, false, "the engine owns Tab now");
    assert.equal(button.hidden, true);
    assert.equal(host.shadowRoot.activeElement, q(host, "iframe"), "focus moved into the study");
  });

  it("marks the study frame busy until ready, with a hidden live line OUTSIDE the busy subtree", () => {
    const { host } = open();
    const dialog = q(host, '[role="dialog"]');
    const frame = q(host, "iframe");
    const status = q(host, '[role="status"]');
    assert.equal(frame.getAttribute("aria-busy"), "true");
    assert.equal(dialog.hasAttribute("aria-busy"), false, "the dialog itself is not marked busy: the status line lives inside it");
    assert.equal(status.textContent, "Loading…");
    assert.equal(dialog.contains(status), true, "the status line is inside the dialog (aria-modal hides what is outside it)");
    assert.equal(status.closest("[aria-busy]"), null, "no busy ancestor, so screen readers announce it");
    assert.equal(frame.contains(status), false);
    engineSays(host, { type: "ready" });
    assert.equal(frame.hasAttribute("aria-busy"), false, "no longer busy");
    assert.equal(status.textContent, "", "the engine announces its own loading line from here");
  });

  it("says Loading in the study's language", () => {
    for (const [lang, text] of [["ku", "بارکردن…"], ["kmr", "بارکرن…"], ["ar", "جارٍ التحميل…"], ["en", "Loading…"]]) {
      resetPage();
      const { host, m } = open({ init: { fountis: "init", lang } });
      assert.equal(q(host, '[role="status"]').textContent, text, lang);
      m.close();
    }
  });

  it("stays busy when the engine never comes up, and the timeout still ends it", async () => {
    const { host } = open();
    const frame = q(host, "iframe");
    await clock.tick(ENGINE_LOAD_TIMEOUT_MS - 1);
    assert.equal(frame.getAttribute("aria-busy"), "true");
    await clock.tick(1);
    assert.equal(modal(), undefined);
  });
});

describe("after the engine is ready, focus cannot rest on the page behind", () => {
  /** A page with controls before and after the overlay's host, like a real partner page. */
  function pageControls() {
    const before = document.createElement("a");
    before.href = "#before";
    document.body.prepend(before);
    const after = document.createElement("button");
    after.textContent = "after";
    document.body.appendChild(after);
    return { before, after };
  }

  it("sends focus that lands on the page (Tab past the last control, Shift+Tab before the first) back into the iframe", () => {
    const { before, after } = pageControls();
    const { host } = open();
    engineSays(host, { type: "ready" });
    const frame = q(host, "iframe");
    for (const stray of [after, before, after]) {
      stray.focus();
      assert.equal(host.shadowRoot.activeElement, frame, "focus went straight back into the study");
      assert.notEqual(document.activeElement, stray);
    }
    assert.ok(modal(), "this never closes the study");
  });

  it("leaves focus that is already inside the overlay alone", () => {
    pageControls();
    const { host } = open();
    engineSays(host, { type: "ready" });
    const frame = q(host, "iframe");
    frame.focus();
    assert.equal(host.shadowRoot.activeElement, frame);
    assert.ok(modal());
  });

  it("does nothing before ready: the Tab trap owns that phase, focus is not pulled into a page that is not there yet", () => {
    const { after } = pageControls();
    const { host } = open();
    after.focus();
    assert.equal(document.activeElement, after, "not redirected while loading");
    assert.notEqual(host.shadowRoot.activeElement, q(host, "iframe"));
    const e = press(document.body, "Tab");
    assert.equal(e.defaultPrevented, true, "the Tab trap still applies");
    assert.equal(host.shadowRoot.activeElement, q(host, ".x"));
  });

  it("is gone when the study closes: no handler left behind, and focus goes back to the page's element", () => {
    const registered = new Set();
    const add = document.addEventListener;
    const remove = document.removeEventListener;
    document.addEventListener = function (type, fn, ...rest) {
      if (type === "focusin") registered.add(fn);
      return add.call(this, type, fn, ...rest);
    };
    document.removeEventListener = function (type, fn, ...rest) {
      if (type === "focusin") registered.delete(fn);
      return remove.call(this, type, fn, ...rest);
    };
    try {
      const { after } = pageControls();
      const { host, opener, seen } = open();
      assert.equal(registered.size, 1, "one focusin listener while the study is open");
      engineSays(host, { type: "ready" });
      engineSays(host, { type: "close" });
      assert.deepEqual(seen.closed, [null]);
      assert.equal(registered.size, 0, "removed on close");
      assert.equal(document.activeElement, opener, "focus returned to where the person was, not pulled back into a closed study");
      after.focus();
      assert.equal(document.activeElement, after, "the page is a normal page again");
    } finally {
      document.addEventListener = add;
      document.removeEventListener = remove;
    }
  });

  it("is removed by the load timeout and by a host close() too", async () => {
    const { after } = pageControls();
    open();
    await clock.tick(ENGINE_LOAD_TIMEOUT_MS);
    assert.equal(modal(), undefined);
    after.focus();
    assert.equal(document.activeElement, after);
    resetPage();
    const b = open();
    engineSays(b.host, { type: "ready" });
    b.m.close();
    const again = document.createElement("button");
    document.body.appendChild(again);
    again.focus();
    assert.equal(document.activeElement, again);
  });

  it("through show(): Tab-stray focus after a ready study is pulled back, and the finished study frees the page", async () => {
    fakeApi({ guests: true });
    start({ key: "pk_test_x", apiBase: API, engineUrl: ENGINE_URL });
    setUserToken(() => null);
    const { after } = pageControls();
    const result = track(show());
    await flush();
    q(teaser(), ".go").click();
    const host = modal();
    wireFrame(host);
    engineSays(host, { type: "ready" });
    after.focus();
    assert.equal(host.shadowRoot.activeElement, q(host, "iframe"));
    engineSays(host, { type: "done", outcome: "complete" });
    engineSays(host, { type: "close" });
    assert.equal(await result.done, "completed");
    after.focus();
    assert.equal(document.activeElement, after);
    signOut();
  });
});

describe("where the SDK's close button sits (it must not jump when the engine's takes over)", () => {
  const rule = (host, selector) => {
    const css = q(host, "style").textContent;
    const m = css.match(new RegExp(selector.replace(/[.[\]()]/g, "\\$&") + "\\{([^}]*)\\}"));
    assert.ok(m, `no rule for ${selector}`);
    return m[1];
  };

  it("sits on the start side: left in English, right in Arabic, Kurdish and Bahdini", () => {
    for (const [lang, side, other] of [["en", "left", "right"], ["ku", "right", "left"], ["kmr", "right", "left"], ["ar", "right", "left"]]) {
      resetPage();
      const { host, m } = open({ init: { fountis: "init", lang } });
      const dir = lang === "en" ? "ltr" : "rtl";
      assert.equal(q(host, ".bg").getAttribute("dir"), dir, lang);
      // The page's own direction picks the rule; jsdom does no layout, so read the rule that applies to this direction.
      const css = rule(host, `.bg[dir=${dir}] .x`);
      assert.match(css, new RegExp(`(^|;)${side}:calc\\(env\\(safe-area-inset-${side}`), `${lang}: anchored ${side}, with that side's safe-area inset`);
      assert.doesNotMatch(css, new RegExp(`(^|;)${other}:`), `${lang}: not anchored ${other}`);
      m.close();
    }
  });

  it("is drawn like the engine's button: bare, 44 px target, 20 px icon, 4 px from the top", () => {
    const { host, button } = open();
    const css = rule(host, ".x");
    assert.match(css, /top:calc\(4px \+ env\(safe-area-inset-top,0px\)\)/);
    assert.match(css, /width:44px;height:44px/);
    assert.match(css, /background:transparent/);
    assert.match(css, /border:0/);
    assert.doesNotMatch(css, /box-shadow/);
    assert.match(css, /color:#43534d/);
    assert.match(rule(host, ".x svg"), /width:20px;height:20px/);
    assert.match(rule(host, ".x:focus-visible"), /outline:2px solid/, "a visible focus ring");
    const path = button.querySelector("path");
    assert.equal(path.getAttribute("d"), "M4 4L12 12M12 4L4 12", "the engine's x");
  });

  // The numbers above are copies of the engine's frame. If the engine's CSS changes, this fails until the SDK follows.
  const engineCss = resolve(process.cwd(), "../engine/src/styles.css");
  it("matches the engine's frame (engine/src/styles.css)", { skip: !existsSync(engineCss) }, () => {
    const css = readFileSync(engineCss, "utf8").replace(/\s+/g, " ");
    assert.match(css, /\.fc-bar \{[^}]*max-width: 560px;/, "bar width");
    assert.match(css, /\.fc-bar \{[^}]*height: calc\(52px \+ var\(--fc-sa-top\)\)/, "bar height (button centred in 52 px => 4 px from the top)");
    assert.match(css, /\.fc-iconbtn \{ width: 44px; height: 44px; margin: 0 4px;/, "button size and 4 px side margin");
    assert.match(css, /\.fc-screen \{[^}]*padding-left: var\(--fc-sa-left\);[^}]*padding-right: var\(--fc-sa-right\);/, "safe-area padding on both sides");
    for (const side of ["top", "right", "bottom", "left"]) {
      assert.ok(css.includes(`--fc-sa-${side}: max(env(safe-area-inset-${side}, 0px), var(--fc-inset-${side}, 0px));`), `--fc-sa-${side} is the larger of the iframe's env() and the inset the SDK sends`);
    }
    const app = readFileSync(resolve(process.cwd(), "../engine/src/App.tsx"), "utf8");
    assert.match(app, /M4 4L12 12M12 4L4 12" stroke="#43534D"/, "icon path and colour");
    assert.match(app, /close: \(\s*<svg width="20" height="20"/, "icon size");
  });
});

describe("a study page that never loads", () => {
  it("closes itself after the load timeout and reports unavailable, not a dismissal", async () => {
    assert.equal(ENGINE_LOAD_TIMEOUT_MS, 15_000);
    const { seen, opener } = open();
    await clock.tick(ENGINE_LOAD_TIMEOUT_MS - 1);
    assert.ok(modal(), "still open one millisecond early");
    assert.equal(seen.unavailable, 0);
    await clock.tick(1);
    assert.equal(seen.unavailable, 1);
    assert.deepEqual(seen.closed, [], "nobody closed it");
    assert.equal(modal(), undefined);
    assert.equal(document.activeElement, opener);
    assert.equal(document.documentElement.style.overflow, "");
  });

  it("does not time out once the engine says ready, and hands over to the engine's own close button", async () => {
    const { seen, host, button, posted } = open();
    engineSays(host, { type: "ready" });
    assert.equal(posted.length, 1);
    assert.equal(posted[0].origin, ENGINE_ORIGIN, "init goes to the engine's exact origin");
    assert.equal(posted[0].data.offerId, "o1");
    assert.equal(button.hidden, true, "the engine draws its own close button now");
    await clock.tick(10 * ENGINE_LOAD_TIMEOUT_MS);
    assert.equal(seen.unavailable, 0);
    assert.ok(modal(), "a study the person is answering stays open");
  });

  it("sends the page's safe-area insets with init (the iframe's own env() is 0), measured once with a probe that is removed", () => {
    const real = window.getComputedStyle;
    const kids = [];
    // jsdom does not resolve env(); stand in for a notched phone in landscape. The probe is the only element asked about.
    window.getComputedStyle = (el) => {
      kids.push(el);
      return { paddingTop: "0px", paddingRight: "44px", paddingBottom: "21px", paddingLeft: "47.5px" };
    };
    try {
      const { host, posted } = open();
      engineSays(host, { type: "ready" });
      assert.deepEqual(posted[0].data.insets, { top: 0, right: 44, bottom: 21, left: 47.5 });
      assert.equal(posted[0].data.offerId, "o1", "the rest of init is untouched");
      assert.equal(kids.length, 1, "measured once");
      assert.equal(kids[0].isConnected, false, "the probe is removed again");
    } finally {
      window.getComputedStyle = real;
    }
  });

  it("sends zero insets when the page has none (no viewport-fit=cover, or no env())", () => {
    const { host, posted } = open();
    engineSays(host, { type: "ready" });
    assert.deepEqual(posted[0].data.insets, { top: 0, right: 0, bottom: 0, left: 0 });
  });

  it("does not count a ready from the wrong origin or the wrong window", async () => {
    const { seen, host, posted } = open();
    engineSays(host, { type: "ready" }, { origin: "https://evil.example" });
    engineSays(host, { type: "ready" }, { source: window });
    assert.equal(posted.length, 0, "no init was sent to either");
    await clock.tick(ENGINE_LOAD_TIMEOUT_MS);
    assert.equal(seen.unavailable, 1);
    assert.equal(modal(), undefined);
  });

  it("a host-initiated close() cancels the timer and reports nothing", async () => {
    const { m, seen } = open();
    m.close();
    await clock.tick(2 * ENGINE_LOAD_TIMEOUT_MS);
    assert.deepEqual(seen, { closed: [], unavailable: 0 });
    assert.equal(modal(), undefined);
  });

  it("a person who closes first is a dismissal, and the timer does not fire later", async () => {
    const { seen, button } = open();
    button.click();
    await clock.tick(2 * ENGINE_LOAD_TIMEOUT_MS);
    assert.deepEqual(seen, { closed: [null], unavailable: 0 });
  });
});

describe("when the page is resized or rotated", () => {
  /** jsdom does not resolve env(): stand in for the page's insets, changeable between events. */
  function fakeInsets(first) {
    const real = window.getComputedStyle;
    const now = { ...first };
    window.getComputedStyle = () => ({ paddingTop: `${now.top}px`, paddingRight: `${now.right}px`, paddingBottom: `${now.bottom}px`, paddingLeft: `${now.left}px` });
    return { set: (v) => Object.assign(now, v), restore: () => (window.getComputedStyle = real) };
  }
  const rotate = (type = "resize") => window.dispatchEvent(new window.Event(type));
  const insetMessages = (posted) => posted.filter((p) => p.data.fountis === "insets");

  it("posts the new insets once, to the engine's exact origin, and never init or the token again", async () => {
    const fake = fakeInsets({ top: 0, right: 0, bottom: 21, left: 0 });
    try {
      const { host, posted } = open();
      engineSays(host, { type: "ready" });
      assert.equal(posted.length, 1);
      fake.set({ top: 0, right: 44, bottom: 21, left: 47.5 });
      rotate("orientationchange");
      rotate("resize");
      rotate("resize");
      assert.equal(posted.length, 1, "nothing until the pause is over");
      await clock.tick(INSETS_THROTTLE_MS);
      assert.equal(posted.length, 2, "a burst of events is one message");
      assert.deepEqual(posted[1], { data: { fountis: "insets", insets: { top: 0, right: 44, bottom: 21, left: 47.5 } }, origin: ENGINE_ORIGIN });
      assert.equal(posted[1].data.offerId, undefined, "just the numbers, not init");
    } finally {
      fake.restore();
    }
  });

  it("posts nothing when the numbers did not change", async () => {
    const fake = fakeInsets({ top: 0, right: 44, bottom: 21, left: 47.5 });
    try {
      const { host, posted } = open();
      engineSays(host, { type: "ready" });
      rotate();
      await clock.tick(INSETS_THROTTLE_MS);
      assert.equal(insetMessages(posted).length, 0, "same as what init carried");
      fake.set({ left: 0 });
      rotate();
      await clock.tick(INSETS_THROTTLE_MS);
      assert.equal(insetMessages(posted).length, 1);
      rotate();
      await clock.tick(INSETS_THROTTLE_MS);
      assert.equal(insetMessages(posted).length, 1, "and not again for the same numbers");
    } finally {
      fake.restore();
    }
  });

  it("posts nothing before the engine is ready (init will carry the numbers)", async () => {
    const fake = fakeInsets({ top: 0, right: 0, bottom: 0, left: 0 });
    try {
      const { host, posted } = open();
      fake.set({ top: 0, right: 44, bottom: 0, left: 0 });
      rotate();
      await clock.tick(2 * INSETS_THROTTLE_MS);
      assert.equal(posted.length, 0);
      engineSays(host, { type: "ready" });
      assert.deepEqual(posted[0].data.insets, { top: 0, right: 44, bottom: 0, left: 0 });
    } finally {
      fake.restore();
    }
  });

  it("stops listening when the study closes, and a pending re-measure is dropped", async () => {
    const fake = fakeInsets({ top: 0, right: 0, bottom: 0, left: 0 });
    const added = [];
    const removed = [];
    const realAdd = window.addEventListener;
    const realRemove = window.removeEventListener;
    window.addEventListener = function (type, fn, ...rest) {
      if (type === "resize" || type === "orientationchange") added.push([type, fn]);
      return realAdd.call(this, type, fn, ...rest);
    };
    window.removeEventListener = function (type, fn, ...rest) {
      if (type === "resize" || type === "orientationchange") removed.push([type, fn]);
      return realRemove.call(this, type, fn, ...rest);
    };
    try {
      const { m, host, posted } = open();
      engineSays(host, { type: "ready" });
      assert.deepEqual(added.map((a) => a[0]).sort(), ["orientationchange", "resize"]);
      fake.set({ top: 0, right: 44, bottom: 0, left: 0 });
      rotate();
      m.close();
      assert.deepEqual(removed, added, "both listeners are removed with the same handlers");
      await clock.tick(2 * INSETS_THROTTLE_MS);
      rotate();
      await clock.tick(2 * INSETS_THROTTLE_MS);
      assert.equal(insetMessages(posted).length, 0);
    } finally {
      window.addEventListener = realAdd;
      window.removeEventListener = realRemove;
      fake.restore();
    }
  });
});

describe("a finished study", () => {
  it("reports the engine's outcome on close", () => {
    const { seen, host } = open();
    engineSays(host, { type: "ready" });
    engineSays(host, { type: "done", outcome: "complete" });
    engineSays(host, { type: "close" });
    assert.deepEqual(seen.closed, ["complete"]);
    assert.equal(modal(), undefined);
  });
});

// ---- through show(): what the partner's code sees ----

const OFFER = "o1";
const stateOf = () => JSON.parse(localStorage.getItem("fountis:connect:guest") || "{}");

describe("show() when the study page never loads", () => {
  let calls;
  let events;
  let off;
  beforeEach(() => {
    calls = fakeApi({ guests: true });
    events = [];
    off = onEvent((e) => events.push(e.type));
    start({ key: "pk_test_x", apiBase: API, engineUrl: ENGINE_URL });
    setUserToken(() => null); // a guest, so no token is needed
  });
  afterEach(() => {
    off();
    signOut();
  });

  /** show(), then the person taps Start on the teaser. */
  async function startStudy() {
    const result = track(show());
    await flush();
    assert.ok(teaser(), "the teaser is up");
    q(teaser(), ".go").click();
    assert.ok(modal(), "the study screen opened");
    wireFrame(modal());
    return result;
  }

  it("resolves noFill after the load timeout: offer neither taken nor dismissed, no dismissed event", async () => {
    const result = await startStudy();
    await clock.tick(ENGINE_LOAD_TIMEOUT_MS);
    assert.equal(await result.done, "noFill");
    assert.equal(modal(), undefined);
    assert.deepEqual(events, ["shown", "started", "noFill"]);
    assert.equal(stateOf().dismissed?.[OFFER], undefined, "not marked dismissed");
    assert.equal(stateOf().taken?.[OFFER], undefined, "not marked taken");
    assert.equal(calls.filter((c) => c.path === "/events" && c.body.type === "dismissed").length, 0);
  });

  it("offers the study again on the next show(), because nothing was held against it", async () => {
    const first = await startStudy();
    await clock.tick(ENGINE_LOAD_TIMEOUT_MS);
    assert.equal(await first.done, "noFill");

    const second = track(show());
    await flush();
    assert.ok(teaser(), "the same study is offered again");
    q(teaser(), ".no").click();
    assert.equal(await second.done, "dismissed");
  });

  it("resolves dismissed when the person taps the close button while it loads", async () => {
    const result = await startStudy();
    q(modal(), ".x").click();
    assert.equal(await result.done, "dismissed");
    assert.equal(modal(), undefined);
    assert.deepEqual(events, ["shown", "started", "dismissed"]);
    assert.ok(stateOf().dismissed?.[OFFER], "a close is a dismissal like any other");
    assert.equal(calls.filter((c) => c.path === "/events" && c.body.type === "dismissed").length, 1);
    await clock.tick(2 * ENGINE_LOAD_TIMEOUT_MS);
    assert.deepEqual(events, ["shown", "started", "dismissed"], "the timer did not fire afterwards");
  });

  it("resolves dismissed on Escape while it loads", async () => {
    const result = await startStudy();
    press(document.body, "Escape");
    assert.equal(await result.done, "dismissed");
    assert.equal(modal(), undefined);
  });

  it("gives keyboard focus back to the page element that had it before the teaser", async () => {
    const opener = document.createElement("button");
    document.body.appendChild(opener);
    opener.focus();
    const result = await startStudy();
    q(modal(), ".x").click();
    await result.done;
    assert.equal(document.activeElement, opener);
  });

  it("completes normally once the page loads (the existing path is untouched)", async () => {
    const result = await startStudy();
    engineSays(modal(), { type: "ready" });
    await clock.tick(2 * ENGINE_LOAD_TIMEOUT_MS);
    assert.ok(modal(), "no timeout after ready");
    engineSays(modal(), { type: "done", outcome: "complete" });
    engineSays(modal(), { type: "close" });
    assert.equal(await result.done, "completed");
    assert.deepEqual(events, ["shown", "started", "completed"]);
    assert.ok(stateOf().taken?.[OFFER]);
  });

  it("signOut() while it loads closes the screen as dismissed and cancels the timer", async () => {
    const result = await startStudy();
    signOut();
    assert.equal(await result.done, "dismissed");
    assert.equal(modal(), undefined);
    await clock.tick(2 * ENGINE_LOAD_TIMEOUT_MS);
    assert.deepEqual(events, ["shown", "started", "dismissed"]);
  });
});
