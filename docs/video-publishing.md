# Video publishing contract

Native bearer authentication is required for all publishing requests.

- `POST /api/shares/video-upload`: `{documentId: UUID, size: integer (1…2 GiB)}` → `{uploadURL, key}`. Returns a 15-minute presigned S3 PUT URL bound to `video/mp4` and the declared size. Upload the MP4 directly to that URL.
- `POST /api/shares`: optional `document.lyricVideo: {key, hasAudio}`. Keys must belong to the signed-in owner and document. The server checks the S3 object's size and media type before publishing. Omit the field to remove the video on update.
- `GET /api/shares?documentId=…`: returns `{url, lyricVideo}` so updates preserve an existing video unless explicitly removed.

Published pages resolve the key against the configured media origin. Fullscreen playback can switch between live lyrics and video; silent videos follow the Apple Music clock, while videos containing audio use native video controls and pause Apple Music.

Video bytes never pass through the web server. Failed and superseded uploads may be left in S3; configure storage retention/cleanup for unreferenced objects. Unpublishing removes the page, but does not revoke previously copied public media URLs.
