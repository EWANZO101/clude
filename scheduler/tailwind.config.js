/** @type {import('tailwindcss').Config} */
module.exports = {
  content: [
    "./app/templates/**/*.html",
    "./app/static/js/**/*.js",
  ],
  darkMode: "class",
  safelist: [
    // Status classes are built dynamically from the user's status value
    // (e.g. bg-status-{{ status }}), so Tailwind's static scanner can't see
    // them in the templates — list them explicitly instead.
    "bg-status-available", "bg-status-busy", "bg-status-away", "bg-status-offline", "bg-status-unavailable",
    "text-status-available", "text-status-busy", "text-status-away", "text-status-offline", "text-status-unavailable",
    "border-status-available", "border-status-busy", "border-status-away", "border-status-offline", "border-status-unavailable",
  ],
  theme: {
    extend: {
      colors: {
        base: {
          DEFAULT: "#12141A", // app background — graphite ink, not pure black
        },
        surface: {
          DEFAULT: "#1B1E27", // cards / panels
          raised: "#232733",  // hovered / elevated surfaces
        },
        border: {
          DEFAULT: "#2C3140",
        },
        ink: {
          DEFAULT: "#EDEEF2", // primary text
          muted: "#8B93A7",   // secondary text
          faint: "#545B6E",   // disabled / placeholder
        },
        accent: {
          DEFAULT: "#E8A33D", // warm amber — the "open sign" glow
          hover: "#F2B65C",
          muted: "#3A2D18",
        },
        status: {
          available: "#3DDC97",
          busy: "#F2637B",
          away: "#5B8DEF",
          unavailable: "#B98BF2",
          offline: "#5B6478",
        },
      },
      fontFamily: {
        sans: ["Inter", "ui-sans-serif", "system-ui", "sans-serif"],
        display: ["Space Grotesk", "ui-sans-serif", "system-ui", "sans-serif"],
      },
      borderRadius: {
        card: "0.875rem",
      },
      boxShadow: {
        card: "0 1px 0 0 rgba(255,255,255,0.02) inset, 0 8px 24px -12px rgba(0,0,0,0.5)",
      },
      keyframes: {
        pulseSoft: {
          "0%, 100%": { opacity: 1 },
          "50%": { opacity: 0.45 },
        },
      },
      animation: {
        "pulse-soft": "pulseSoft 2.2s ease-in-out infinite",
      },
    },
  },
  plugins: [require("@tailwindcss/forms")],
};
