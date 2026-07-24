# bentoai.dev — landing page

Static, no build step. Content blueprint: `../docs/landing-content.md`.

## Design language

Product-forward, premium dark. The hero is a faithful CSS mock of the real
workspace, built from the app's own tokens (swap `.showcase` for a Retina
capture later). One rule holds the palette together: **saturated color only
ever appears where it means something** — a pane's state (working blue
`#0A84FF` / awaiting amber `#FF9F0A` / done green `#30D158` / idle grey), a
diff, or the brand emerald spark. Everything else is graphite + near-white.
No purple, no warm paper, no terminal cosplay.

Type is **Geist** (sans) + **Geist Mono** (commands/labels only), self-hosted
under `assets/fonts/` — honours the "no third-party trackers" privacy claim.

## Deploy (Cloudflare Pages)

```sh
env -u XDG_CONFIG_HOME npx wrangler pages deploy site --project-name bentoai
```

(or point a Pages project at this repo with build output directory `site`).
Custom domain: `bentoai.dev`. Analytics: Cloudflare built-in only — no
third-party scripts, the privacy section is a product claim.

## Asset slots

All `[ASSET-*]` media are currently branded CSS stand-ins, marked with
`<!-- ASSET-… -->` comments in both `index.html` and `cn/index.html`.
Replace each `<figure>`'s contents with a real capture per the production
list in `docs/landing-content.md`. `_redirects` note: `/install.sh` still
redirects to the repo — replace with a served script before the iOS
Linux-host onboarding ships.

## Local preview

```sh
python3 -m http.server 8080 --directory site
```
