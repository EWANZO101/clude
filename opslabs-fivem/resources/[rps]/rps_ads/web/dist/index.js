import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { useState, useEffect, useRef } from "react";
import { jsx, jsxs } from "react/jsx-runtime";

// ── hooks/useNui ──────────────────────────────
const isDebug = typeof window.GetParentResourceName !== "function";
if (isDebug) document.body.style.background = "rgba(0, 0, 0, 0.6)";

function debugNuiEvent(action, data) {
  window.dispatchEvent(new MessageEvent("message", { data: { action, data } }));
}

function useNuiEvent(action, handler) {
  const saved = useRef(handler);
  useEffect(() => { saved.current = handler; }, [handler]);
  useEffect(() => {
    function listener(event) {
      let payload = event.data;
      if (typeof payload === "string") { try { payload = JSON.parse(payload); } catch {} }
      const { action: a, data } = payload ?? {};
      if (a === action) saved.current(data ?? {});
    }
    window.addEventListener("message", listener);
    return () => window.removeEventListener("message", listener);
  }, [action]);
}

async function fetchNui(eventName, data = {}, mockData) {
  if (isDebug && mockData !== undefined) { console.log(`[NUI Dev] ${eventName}:`, mockData); return mockData; }
  if (isDebug) { console.warn(`[NUI Dev] No mock for '${eventName}'. Pass mockData as 3rd arg.`); return {}; }
  const res = window.GetParentResourceName();
  const r = await fetch(`https://${res}/${eventName}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(data),
  });
  return r.json();
}

if (isDebug) {
  setTimeout(() => debugNuiEvent("showAd", {
    title: "Premium Vehicle Sale",
    category: "VEHICLES",
    message: "Get 20% off on all sports cars this week at Downtown Motors!",
    duration: 8000,
    type: "gang",
  }), 100);
}

// ── App ───────────────────────────────────────
const EXIT_MS = 280;

const THEMES = {
  default: { accent: "79, 140, 255", accent2: "139, 92, 246", label: "Sponsored" },
  gang: { accent: "255, 59, 59", accent2: "255, 138, 59", label: "Street Word" },
  lifeinvader: { accent: "236, 72, 120", accent2: "255, 120, 90", label: "Lifeinvader" },
};

const MEGAPHONE = "M10.34 15.84c-.69-.03-1.38-.04-2.09-.04H7.5a4.5 4.5 0 110-9h.75c.7 0 1.4-.02 2.09-.05m0 9.09c.25.97.59 1.9 1 2.8.26.57.06 1.25-.48 1.56l-.66.38c-.55.32-1.26.11-1.53-.46a17.9 17.9 0 01-1.44-4.28m3.11.99c-.39-1.5-.59-3.07-.59-4.69s.2-3.19.59-4.69m0 9.38a48.1 48.1 0 018.62 2.86c.33.14.7-.08.7-.44V3.75c0-.36-.37-.58-.7-.44a48.1 48.1 0 01-8.62 2.86";

function App() {
  const [visible, setVisible] = useState(isDebug);
  const [closing, setClosing] = useState(false);
  const [adKey, setAdKey] = useState(0);
  const [ad, setAd] = useState({
    title: "Premium Vehicle Sale",
    category: "VEHICLES",
    message: "Get 20% off on all sports cars this week at Downtown Motors!",
    duration: 8000,
    type: "default",
  });

  useNuiEvent("showAd", (data) => {
    setAd(data);
    setClosing(false);
    setAdKey((k) => k + 1);
    setVisible(true);
  });

  useNuiEvent("hideAd", () => setClosing(true));

  useEffect(() => {
    if (!visible || closing) return;
    const t = setTimeout(() => setClosing(true), ad.duration || 8000);
    return () => clearTimeout(t);
  }, [visible, closing, adKey, ad.duration]);

  useEffect(() => {
    if (!closing) return;
    const t = setTimeout(() => {
      setVisible(false);
      setClosing(false);
      fetchNui("adExpired", {}, { success: true });
    }, EXIT_MS);
    return () => clearTimeout(t);
  }, [closing]);

  if (!visible) return null;

  const theme = ad.type === "gang" ? THEMES.gang : ad.type === "lifeinvader" ? THEMES.lifeinvader : THEMES.default;
  const duration = ad.duration || 8000;

  const thumb = ad.imageUrl
    ? jsx("img", { src: ad.imageUrl, alt: "", className: "w-full h-full object-cover" })
    : jsx("div", {
        className: "w-full h-full flex items-center justify-center text-white/40",
        children: jsx("svg", {
          className: "w-7 h-7", fill: "none", viewBox: "0 0 24 24", stroke: "currentColor", strokeWidth: 1.6,
          children: jsx("path", { strokeLinecap: "round", strokeLinejoin: "round", d: MEGAPHONE }),
        }),
      });

  return jsx("div", {
    className: "fixed top-6 left-1/2 -translate-x-1/2 z-50",
    children: jsxs("div", {
      className: `ad-card relative w-[440px] rounded-[22px] overflow-hidden ${closing ? "ad-exit" : "ad-enter"}`,
      style: { "--accent-rgb": theme.accent, "--accent2-rgb": theme.accent2 },
      children: [
        jsx("div", { className: "ad-glow pointer-events-none absolute -top-16 -left-10 w-48 h-48 rounded-full" }),
        jsxs("div", {
          className: "relative flex items-center gap-4 p-4 pr-5",
          children: [
            jsx("div", {
              className: "ad-thumb relative flex-shrink-0 w-[68px] h-[68px] rounded-2xl overflow-hidden",
              children: thumb,
            }),
            jsxs("div", {
              className: "flex-1 min-w-0",
              children: [
                jsxs("div", {
                  className: "flex items-center gap-2 mb-1",
                  children: [
                    jsx("span", { className: "ad-dot w-1.5 h-1.5 rounded-full" }),
                    jsx("span", { className: "text-[10px] font-semibold uppercase tracking-[0.16em] text-white/50", children: theme.label }),
                    jsx("span", { className: "text-white/20 text-[10px]", children: "•" }),
                    jsx("span", { className: "ad-chip text-[10px] font-semibold uppercase tracking-[0.12em] px-2 py-[2px] rounded-full", children: ad.category }),
                  ],
                }),
                jsx("h2", { className: "text-white text-[17px] font-semibold leading-tight truncate", children: ad.title }),
                ad.message ? jsx("p", { className: "text-white/65 text-[13px] leading-snug mt-1 line-clamp-2", children: ad.message }) : null,
              ],
            }),
          ],
        }),
        jsx("div", {
          className: "relative h-[3px] bg-white/[0.06]",
          children: jsx("div", { className: "ad-progress h-full", style: { animationDuration: `${duration}ms` } }),
        }),
      ],
    }, adKey),
  });
}

createRoot(document.getElementById("root")).render(jsx(StrictMode, { children: jsx(App, {}) }));
