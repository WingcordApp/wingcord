# Wingcord reports

The service behind Help ▸ Report a Bug… and Suggest a Feature…: a Cloudflare Worker on
`reports.wingcord.app`. Design and decisions: `docs/BUG-REPORTING.md` (D22, D24–D29, §9).

```
POST /v1/reports                         the report's JSON → { id, key, upload, repeat }
PUT  /v1/reports/:id/bundle|screenshot   each part it announced, with the key
GET  /v1/reports/:id                     its status and, once published, its links — with the key
GET  /v1/files/:id/bundle|screenshot     a signed ten-minute download link (Alex's)
GET  /v1/published/:id.png               a screenshot published with an issue (public)
POST /discord                            the inbox's buttons and forms, the pinned posts' form
POST /github                             the GitHub App's events (signed)
```

## Run it here

```sh
npm install
npm test                 # Vitest inside the Workers runtime: local D1, R2, rate limiter; Discord faked
npm run check            # TypeScript, the Worker and the tests
npx wrangler d1 migrations apply wingcord-reports --local
npm run dev              # http://localhost:8787, local bucket and database
```

`wrangler dev` reads `.dev.vars` (ignored by git) for the four secrets, e.g. `LINK_KEY=local-dev-only`, an empty
`DISCORD_BOT_TOKEN`, which leaves the inbox off, and empty `GITHUB_APP_PRIVATE_KEY` and `GITHUB_WEBHOOK_SECRET`,
which leave publishing off. The tests bring their own values (`vitest.config.ts`).

## Deploy (Alex approves each first deploy — it is public-facing)

1. `npx wrangler d1 create wingcord-reports`, and put the printed `database_id` in `wrangler.jsonc`.
2. `npx wrangler d1 migrations apply wingcord-reports --remote`
3. The 90-day rule, on the two private prefixes only (published screenshots will live elsewhere):
   `npx wrangler r2 bucket lifecycle add wingcord-reports expire-bundles bundles/ --expire-days 90`
   `npx wrangler r2 bucket lifecycle add wingcord-reports expire-screenshots screenshots/ --expire-days 90`
4. The Discord application's id and public key, the server's id and the inbox channel's id into `vars`.
5. Secrets, typed or piped — never in a file in the repository, never in a chat:
   `openssl rand -base64 32 | npx wrangler secret put LINK_KEY`
   `npx wrangler secret put DISCORD_BOT_TOKEN` (Alex pastes the token at the hidden prompt)
6. `npx wrangler deploy` — this makes the DNS record and certificate for `reports.wingcord.app`.
7. In the Discord developer portal, set the Interactions Endpoint URL to `https://reports.wingcord.app/discord`
   (Discord checks it on save).

The bot is invited with exactly what it uses — view channels, send messages and in threads, embed links,
attach files, add reactions, read history, manage threads:
`https://discord.com/oauth2/authorize?client_id=<APPLICATION_ID>&scope=bot&permissions=292057893952`

## Phase 7: publishing (Alex approves the deploy)

Publish… and Same as… in the inbox, GitHub's events back to the forum, and the pinned posts' form
(`docs/BUG-REPORTING.md` D30–D38, §12). In order — each step is safe to repeat:

1. The new tables: `npx wrangler d1 migrations apply wingcord-reports --remote` (`0002_publishing.sql` adds
   `issues` and two columns; the code running now ignores them).
2. The public tracker's labels: `../scripts/github/labels.sh` (priority, `needs triage`, the areas).
3. The GitHub App: `python3 scripts/github-app.py` — the browser opens GitHub's Create GitHub App page for
   WingcordApp, filled in; press **Create GitHub App**, then **Install** (WingcordApp/wingcord is already
   chosen). The script puts the App's key and webhook secret into the Worker with `wrangler secret bulk` (which
   redeploys the code running now, with them added) and its client ID into `wrangler.jsonc`.
4. `npx wrangler deploy`.
5. The buttons on the pinned posts: `python3 scripts/post-guides.py` (Alex, with the bot token).
6. The public tracker's files — issue forms, triage workflow, CodeRabbit's settings:
   `../scripts/github/sync-public.sh`, then again with `--push`. CodeRabbit itself is installed from
   coderabbit.ai, on WingcordApp/wingcord only.

If the App's key is ever replaced (the App's page ▸ Generate a private key), put the downloaded `.pem` with
`npx wrangler secret put GITHUB_APP_PRIVATE_KEY < key.pem` and delete the file; GitHub's PKCS #1 form is
read as it is.
