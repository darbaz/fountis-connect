type Reward = { units: number; unit_name: string } | null;

const T: Record<string, { head: string; min: string; earn: string; start: string; later: string; close: string; loading: string }> = {
  en: { head: "A new FOUNTIS study is ready", min: "~{n} min", earn: "Earn {units} {unit}", start: "Start", later: "Not now", close: "Close", loading: "Loading…" },
  ku: { head: "توێژینەوەیەکی نوێی FOUNTIS ئامادەیە", min: "~{n} خولەک", earn: "{units} {unit} بەدەست بهێنە", start: "دەست پێبکە", later: "ئێستا نا", close: "داخستن", loading: "بارکردن…" },
  kmr: { head: "ڤەکۆلینەکا نوی یا FOUNTIS ئامادەیە", min: "~{n} خولەک", earn: "{units} {unit} بەردەست بێخە", start: "دەستپێبکە", later: "نوکە نە", close: "داخستن", loading: "بارکرن…" },
  ar: { head: "دراسة جديدة من FOUNTIS جاهزة", min: "~{n} دقيقة", earn: "احصل على {units} {unit}", start: "ابدأ", later: "ليس الآن", close: "إغلاق", loading: "جارٍ التحميل…" },
};

export function langOf(l: unknown): string {
  const c = String(l || (typeof navigator !== "undefined" ? navigator.language : "en") || "en").toLowerCase().split("-")[0];
  return c in T ? c : c === "ckb" ? "ku" : "en";
}

/** The label of the SDK's own close button on the study screen (same words as `connect.close` in i18n/*.json). */
export function closeLabel(lang: string): string {
  return (T[lang] ?? T.en).close;
}

/** The "Loading…" line the study screen announces to screen readers while the engine starts (same words as `connect.loading`). */
export function loadingLabel(lang: string): string {
  return (T[lang] ?? T.en).loading;
}

const f = (s: string, v: Record<string, string | number>) => s.replace(/\{(\w+)\}/g, (_, k) => String(v[k]));

const CSS = `
:host{all:initial}
.card{position:fixed;z-index:2147483000;bottom:calc(16px + env(safe-area-inset-bottom,0px));inset-inline-end:16px;width:min(340px,calc(100vw - 24px));box-sizing:border-box;
 background:#fff;color:#101915;border:1px solid #e3eae7;border-radius:16px;padding:14px 14px 12px;
 font:14px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI","Noto Sans Arabic",Tahoma,sans-serif;
 box-shadow:0 12px 40px rgba(16,25,21,.22);animation:in .22s cubic-bezier(.22,1,.36,1)}
@keyframes in{from{opacity:0;transform:translateY(10px)}to{opacity:1;transform:none}}
.row{display:flex;gap:10px;align-items:flex-start}
.dot{flex:none;width:34px;height:34px;border-radius:50%;background:#e6f4ef;display:flex;align-items:center;justify-content:center}
.dot svg{width:18px;height:18px}
.head{font-weight:700;font-size:14.5px}
.meta{color:#6d7d77;font-size:12.5px;margin-top:2px}
.btns{display:flex;gap:8px;margin-top:12px}
button{font:inherit;cursor:pointer;border:0;border-radius:11px;height:40px;padding:0 16px}
.go{flex:1;background:#0e4f40;color:#fff;font-weight:700}
.no{background:transparent;color:#6d7d77;font-weight:600}
button:focus-visible{outline:2px solid #0e4f40;outline-offset:2px}
@media (max-width:480px){.card{inset-inline:12px;width:auto}}
`;

export function showTeaser(o: {
  lang: string;
  minutes?: number;
  reward: Reward;
  onStart: () => void;
  onDismiss: () => void;
}) {
  const t = T[o.lang] ?? T.en;
  const host = document.createElement("div");
  const root = host.attachShadow({ mode: "open" });
  const parts = [o.minutes ? f(t.min, { n: o.minutes }) : "", o.reward && o.reward.units > 0 ? f(t.earn, { units: o.reward.units, unit: o.reward.unit_name }) : ""].filter(Boolean);
  const rtl = o.lang !== "en";
  root.innerHTML = `<style>${CSS}</style>
<div class="card" role="dialog" aria-label="FOUNTIS" dir="${rtl ? "rtl" : "ltr"}">
 <div class="row"><span class="dot"><svg viewBox="0 0 16 16" fill="none"><circle cx="8" cy="8" r="5.2" stroke="#ff8a63" stroke-width="1.8"/></svg></span>
 <div><div class="head"></div><div class="meta"></div></div></div>
 <div class="btns"><button class="go" type="button"></button><button class="no" type="button"></button></div></div>`;
  // textContent, never innerHTML, for anything that came from the network
  root.querySelector(".head")!.textContent = t.head;
  root.querySelector(".meta")!.textContent = parts.join(" · ");
  const go = root.querySelector(".go") as HTMLButtonElement;
  const no = root.querySelector(".no") as HTMLButtonElement;
  go.textContent = t.start;
  no.textContent = t.later;
  let open = true;
  const close = () => {
    if (!open) return;
    open = false;
    host.remove();
  };
  go.onclick = () => {
    close();
    o.onStart();
  };
  no.onclick = () => {
    close();
    o.onDismiss();
  };
  document.body.appendChild(host);
  return { close };
}
