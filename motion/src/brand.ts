// Brand tokens shared across compositions. Keep these in sync with
// web/assets/css/tailwind.css `--tac-amber` and the dark surface
// palette used by ClipPlayer.vue so the baked-in branding feels
// continuous with the rest of the product.

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

export const FONT_STACK =
  '"Inter", "Helvetica Neue", "Segoe UI", "DejaVu Sans", sans-serif';
