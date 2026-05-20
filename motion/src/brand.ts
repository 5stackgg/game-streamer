// Keep `amber` in sync with web/assets/css/tailwind.css --tac-amber.
export const BRAND = {
  amber: "hsl(33, 94%, 58%)",
  amberDim: "hsl(33, 94%, 58%, 0.18)",
  amberBorder: "hsl(33, 94%, 58%, 0.75)",
  destructive: "hsl(0, 72%, 51%)",
  surface: "#0a0a0a",
  surface2: "#15151a",
  textPrimary: "#ffffff",
  textMuted: "#d4d4d4",
} as const;

// Matches web/tailwind.config.js → fontFamily.sans. Oxanium is
// the 5stack brand font; loaded in src/fonts.ts.
export const FONT_STACK =
  '"Oxanium", "Inter", "Helvetica Neue", "Segoe UI", "DejaVu Sans", sans-serif';
