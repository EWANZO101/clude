/** OpsLabSystems Server Panel — Tailwind design-token configuration.
 *  Colors are wired to CSS custom properties (defined in static/css/src/tokens.css)
 *  so the same utility classes work across the dark theme, light theme, and every
 *  accent variant without needing separate class sets per theme.
 */
module.exports = {
  darkMode: ["class", '[data-mode="dark"]'],
  content: [
    "./templates/**/*.html",
    "./modules/**/templates/**/*.html",
  ],
  theme: {
    extend: {
      colors: {
        void: "var(--bg-void)",
        panel: "var(--bg-panel)",
        "panel-raised": "var(--bg-panel-raised)",
        "panel-hover": "var(--bg-panel-hover)",
        border: {
          subtle: "var(--border-subtle)",
          strong: "var(--border-strong)",
        },
        accent: {
          DEFAULT: "var(--accent)",
          deep: "var(--accent-deep)",
          dim: "var(--accent-dim)",
          ink: "var(--accent-ink)",
        },
        data: {
          DEFAULT: "var(--data)",
          dim: "var(--data-dim)",
        },
        ink: {
          primary: "var(--text-primary)",
          secondary: "var(--text-secondary)",
          muted: "var(--text-muted)",
        },
        ok: { DEFAULT: "var(--ok)", dim: "var(--ok-dim)" },
        warn: { DEFAULT: "var(--warn)", dim: "var(--warn-dim)" },
        danger: { DEFAULT: "var(--danger)", dim: "var(--danger-dim)" },
      },
      fontFamily: {
        body: ["IBM Plex Sans", "-apple-system", "BlinkMacSystemFont", "sans-serif"],
        display: ["Big Shoulders Display", "IBM Plex Sans", "sans-serif"],
        mono: ["JetBrains Mono", "Courier New", "monospace"],
      },
      borderRadius: {
        sm: "var(--radius-sm)",
        DEFAULT: "var(--radius)",
        lg: "var(--radius-lg)",
        xl: "var(--radius-xl)",
      },
      boxShadow: {
        card: "var(--shadow-card)",
        pop: "var(--shadow-pop)",
      },
      spacing: {
        sidebar: "252px",
        "sidebar-rail": "72px",
      },
      transitionTimingFunction: {
        panel: "cubic-bezier(0.4, 0, 0.2, 1)",
      },
    },
  },
  plugins: [],
};
