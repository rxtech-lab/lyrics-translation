# LyricStudio website

Next.js App Router, Turso/libSQL and RxAuth OAuth with PKCE. Public translation pages have dynamic Open Graph images; the landing page uses CSS scroll timelines with reduced-motion support.

## Run

`bun install`, copy `.env.example` to `.env.local`, then `bun run dev`. Local development uses `file:local.db`; tables initialize automatically. Run `bun run build` for production validation.

## Configure production

- Set `SITE_URL` to the deployed HTTPS domain and `TURSO_DATABASE_URL` / `TURSO_AUTH_TOKEN` to a Turso database. File-backed SQLite is for local development only.
- Register a web OAuth client at RxAuth with `${SITE_URL}/api/auth/callback`; set `RXAUTH_CLIENT_ID` and, for confidential clients, `RXAUTH_CLIENT_SECRET`.
- Register a separate native client with `lyricstudio://oauth-callback`. Set its ID as `RXAUTH_NATIVE_CLIENT_ID` on the server and the `RXAUTH_CLIENT_ID` Xcode build setting. Allowed scopes: `openid read:profile read:email`. Do not reuse RxCode's registration.
- Xcode uses `http://localhost:3000` in Debug and `https://lyrics.rxlab.app` in Release, configured in `project.yml`. The native client ID is `client_366ef1a6f5d248df941dc9e02947f0cc`; set the same value as `RXAUTH_NATIVE_CLIENT_ID` on the backend.
- Provide an Apple Music developer JWT in `APPLE_MUSIC_DEVELOPER_TOKEN`; rotate it before expiry. This public developer token is passed to MusicKit; private signing keys never go to the browser. Playback requires user authorization and suitable Apple Music access.

Mac: Song → Share Translation opens a dedicated full-height publishing sheet. Web: `/share` explains how to publish from the Mac app; there is no web publishing form. The publish endpoint requires a bearer token with the native OAuth client identity and rejects web sessions. Web sign-in is for starring translations. Public fields are explicitly validated; prompts, revisions, comments and agent configuration are stripped. Usage is creator-reported input/output tokens, not verified billing. Stars are unique per account and document. Discovery shows the latest 100 public shares.

No binary file upload is implemented: publishing sends a curated JSON document capped at 1 MB. Future file/media uploads must use presigned S3 URLs. No AI Gateway key is required.

Live OAuth, remote Turso persistence, Apple Music playback, and deployment require the credentials above and must be validated on the configured deployment. Browser sessions expire with the access token and require signing in again.

## Database migrations

From `website/`, run `bun run db:migrate`. Bun loads `TURSO_DATABASE_URL` and `TURSO_AUTH_TOKEN` from `.env.local`; exported environment variables take precedence. Set the target explicitly—the migration script does not silently choose a database.

For a local database:

```sh
TURSO_DATABASE_URL=file:local.db bun run db:migrate
```

For remote Turso, configure its URL and token in `.env.local` or your deployment environment, then run the same command before deploying. Do not commit credentials.

The initial migration safely adopts existing `shares` and `stars` tables without deleting data. Applied migrations are recorded with checksums in `schema_migrations`; repeated runs skip them. Each migration and its record commit in one write transaction. Add future numbered files in `migrations/` and register them in `scripts/migrate.ts`; never edit an applied migration.
