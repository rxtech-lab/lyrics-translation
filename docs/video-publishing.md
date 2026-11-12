# Video publishing contract

Native bearer authentication is required for all publishing requests.

- `POST /api/shares/video-upload`: `{documentId: UUID, size: integer (1…2 GiB)}` → `{uploadURL, key}`. Returns a 15-minute presigned S3 PUT URL bound to `video/mp4` and the declared size. Upload the MP4 directly to that URL.
- `POST /api/shares`: optional `document.lyricVideo: {key, hasAudio}`. Keys must belong to the signed-in owner and document. The server checks the S3 object's size and media type before publishing. Omit the field to remove the video on update.
- `GET /api/shares?documentId=…`: returns `{url, lyricVideo}` so updates preserve an existing video unless explicitly removed.

Published pages resolve the key against the configured media origin. Fullscreen playback can switch between live lyrics and video; silent videos follow the Apple Music clock, while videos containing audio use native video controls and pause Apple Music.

For S3-compatible storage, an `S3_ENDPOINT` path is preserved by signed uploads. When `S3_VIDEO_PUBLIC_URL` is just an origin, playback includes that endpoint path too: an endpoint ending in `/lyrics-studio` produces public URLs ending in `/lyrics-studio/lyric-videos/…`. An explicit path in `S3_VIDEO_PUBLIC_URL` takes precedence and is used once. For new bucket-root setups, use an endpoint without a path; keep existing paths for already uploaded media.

Video bytes never pass through the web server. Failed and superseded uploads may be left in S3; configure storage retention/cleanup for unreferenced objects. Unpublishing removes the page, but does not revoke previously copied public media URLs.

## Adaptive streaming

New native uploads run local FFmpeg with VideoToolbox hardware decoding and H.264 hardware encoding (`h264_videotoolbox`, software fallback disabled), plus AAC audio when selected. Install FFmpeg with `brew install ffmpeg` if it is not bundled or installed in the standard Homebrew locations. Conversion failure leaves the existing publication unchanged.

Renditions target short edges of 360, 720 and 1080 pixels, preserving aspect ratio, capped at the source size (smaller sources use their original size rounded to even dimensions). Each VOD rendition uses six-second segments stored as byte ranges in one `.ts` object; its playlist references that relative filename. A master playlist enables automatic bandwidth selection. This uses FFmpeg's [HLS single-file and VOD options](https://www.ffmpeg.org/ffmpeg-formats.html#hls).

- The upload endpoint also accepts `{documentId, size, streamID: UUID, filename}`. Allowed filenames are `master.m3u8` or a numeric rendition name followed by `.m3u8` or `.ts`. Keys are scoped to owner/document/streamID. Each response signs one direct PUT with `application/vnd.apple.mpegurl` or `video/mp2t` and the declared size. Original MP4 uploads keep the existing contract.
- `lyricVideo` now optionally includes `streaming: {id: UUID, files: string[]}` with a master playlist and paired rendition playlists/media (at most seven objects). Publishing verifies every object's existence, type and size. All media upload before publication metadata changes. Existing publications without streaming metadata continue to play MP4.
- The web player prefers HLS, using Safari's native HLS or hls.js Media Source playback. Fatal streaming errors fall back to the original MP4. Silent streaming video continues following the Apple Music clock.

Storage/CDN requirements: serve correct signed MIME types, support `GET`, `HEAD`, and byte-range requests (`206 Partial Content`); allow cross-origin GET/HEAD from the website and expose `Content-Length`, `Content-Range`, and `Accept-Ranges`. Permit the `Range` request header in CORS. These apply to playlists and rendition objects as well as the original MP4. Unconfigured CORS or range serving will prevent adaptive playback and trigger fallback. No media passes through Next.js.

Validation: `bun run typecheck` and `bun test lib/video-publishing.test.ts` in `website`; hardware conversion harness instructions are at the top of `scripts/test-video-streaming.swift`. The harness expects a 1280×720 MP4 with audio.
