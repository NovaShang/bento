# bentoai.dev — landing page

Static, no build step. Content blueprint: `../docs/landing-content.md`.
Palette mirrors `BentoTheme.swift` / `docs/bento-icon.svg` — don't invent colors.

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
