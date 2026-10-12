// Import this first in every test file: puts a jsdom window on globalThis before the SDK source is evaluated.
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><html><body></body></html>", { url: "https://partner.example/app", pretendToBeVisual: true });
const w = dom.window;

// defineProperty, not assignment: recent Node versions define some of these (navigator, localStorage) as getter-only.
const put = (k, v) => Object.defineProperty(globalThis, k, { value: v, configurable: true, writable: true });
put("window", w);
for (const k of ["document", "location", "localStorage", "HTMLElement", "Event", "KeyboardEvent", "MessageEvent", "MouseEvent"]) put(k, w[k]);

export {};
