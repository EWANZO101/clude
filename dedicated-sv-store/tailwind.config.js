/** @type {import('tailwindcss').Config} */
module.exports = {
  darkMode: "class",
  content: [
    "./app/templates/**/*.html",
    "./app/static/js/**/*.js",
  ],
  theme: {
    extend: {
      colors: {
        surface: {
          950: "#05070a",
          900: "#0b0e14",
          850: "#0f131b",
          800: "#141922",
          700: "#1b212c",
          600: "#252c39",
          500: "#333c4d",
        },
        border: {
          DEFAULT: "#232a37",
          light: "#2d3546",
        },
        text: {
          primary: "#e6e9ef",
          secondary: "#9aa4b2",
          muted: "#6b7484",
        },
        brand: {
          50: "#eefbff",
          100: "#d6f4ff",
          200: "#b0e9ff",
          300: "#75d9ff",
          400: "#33c2ff",
          500: "#0aa4f2",
          600: "#0082cc",
          700: "#0067a3",
          800: "#075686",
          900: "#0b476f",
        },
        status: {
          success: "#22c55e",
          warning: "#f59e0b",
          danger: "#ef4444",
          info: "#3b82f6",
          neutral: "#6b7484",
        },
      },
      fontFamily: {
        sans: [
          "Inter",
          "ui-sans-serif",
          "system-ui",
          "-apple-system",
          "Segoe UI",
          "Roboto",
          "sans-serif",
        ],
        mono: ["JetBrains Mono", "ui-monospace", "SFMono-Regular", "monospace"],
      },
      boxShadow: {
        card: "0 1px 2px 0 rgba(0,0,0,0.4)",
        panel: "0 4px 16px -4px rgba(0,0,0,0.5)",
      },
    },
  },
  plugins: [],
};
