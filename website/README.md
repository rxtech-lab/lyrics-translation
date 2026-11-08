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

Publishing sends curated JSON capped at 1 MB. Optional MP4 videos (up to 2 GiB) upload directly to S3 using a 15-minute presigned PUT URL, never through Next.js. In Lyric Video, choose **Publish Video…** to render and open the publishing sheet, or choose an exported MP4 in Share Translation. Updates retain an existing video; turn off Include Lyric Video to remove it. Videos are available only inside the music player, using its fullscreen **Video / Live lyrics** switch. Silent videos follow Apple Music in fullscreen; videos with audio use native controls and pause Apple Music.

Configure `S3_VIDEO_BUCKET`, `AWS_REGION`, and an HTTPS `S3_VIDEO_PUBLIC_URL` (bucket or CDN base URL). The AWS SDK uses its default credential chain; provide a role or `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` (and `AWS_SESSION_TOKEN` when needed). Optional `S3_ENDPOINT` supports S3-compatible storage. Grant PutObject and GetObject (for HeadObject) only for `lyric-videos/*`; configure public/CDN read and byte-range serving for MP4 playback. Configure cleanup for unreferenced uploads. Unpublishing removes the page but does not revoke copied public media URLs. No AI Gateway key is required.

The endpoint contract is in [video-publishing.md](../docs/video-publishing.md). Presigning follows the [AWS SDK S3 guidance](https://docs.aws.amazon.com/sdk-for-javascript/v3/developer-guide/javascript_s3_code_examples.html).

Live OAuth, remote Turso persistence, Apple Music playback, and deployment require the credentials above and must be validated on the configured deployment. Browser sessions expire with the access token and require signing in again.

## Database migrations

From `website/`, run `bun run db:migrate`. Bun loads `TURSO_DATABASE_URL` and `TURSO_AUTH_TOKEN` from `.env.local`; exported environment variables take precedence. Set the target explicitly—the migration script does not silently choose a database.

For a local database:

```sh
TURSO_DATABASE_URL=file:local.db bun run db:migrate
```

For remote Turso, configure its URL and token in `.env.local` or your deployment environment, then run the same command before deploying. Do not commit credentials.

The initial migration safely adopts existing `shares` and `stars` tables without deleting data. Applied migrations are recorded with checksums in `schema_migrations`; repeated runs skip them. Each migration and its record commit in one write transaction. Add future numbered files in `migrations/` and register them in `scripts/migrate.ts`; never edit an applied migration.
