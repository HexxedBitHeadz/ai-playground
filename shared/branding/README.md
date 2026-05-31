# shared/branding

Static logo / favicon assets served at `/static/branding/...` by the dashboard and mounted read-only into each lab's `webui` container.

| File | Used by | Notes |
|---|---|---|
| `logo.png` | Dashboard nav, lab WebUI nav | Recommended 60×60 PNG (rendered at 30px height). If missing, the dashboard falls back to a cyan hexagon glyph; the lab WebUI does the same. |
| `logo.svg` | Reserved | Not currently used by the dashboard, but consumers expect it as the vector version of `logo.png`. |
| `favicon.svg` | Dashboard browser tab | Stylized "H" inside a duotone hex frame — cyberpunk-themed, scales cleanly. |
| `favicon.png` | Dashboard browser tab (legacy) | Optional 32×32 PNG fallback for browsers that don't support SVG favicons. Safe to omit. |

## Conventions

- Color palette is locked to the dashboard theme: `#7c3aed` (accent purple), `#22d3ee` (cyan), `#a855f7` (acid), `#e2e8f0` (text), `#06070d` (background).
- Keep assets small (<50 KB each). They're hot-mounted into every lab container; bloat compounds.
- SVGs preferred — they scale across the dashboard's responsive breakpoints without artifacts.

## Replacing the logo

Drop in a new `logo.png` (and optionally `logo.svg`) at this path. No rebuild needed — lab webui containers mount this directory read-only with `:ro`, so the next container start picks it up.
