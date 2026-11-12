import {streamingSchema, streamFileSchema} from './document';
import {z} from 'zod';
import {createHash, randomUUID} from 'node:crypto';
import {HeadObjectCommand, PutObjectCommand, S3Client} from '@aws-sdk/client-s3';
import {getSignedUrl} from '@aws-sdk/s3-request-presigner';

export const maxVideoBytes = 2 * 1024 ** 3;
export function videoPrefix(owner: string, documentId: string) {
  return `lyric-videos/${createHash('sha256').update(JSON.stringify([owner, documentId])).digest('hex')}/`;
}
function storage() {
  const bucket = process.env.S3_VIDEO_BUCKET;
  if (!bucket || !process.env.S3_VIDEO_PUBLIC_URL) throw Error('Video storage is not configured');
  return {bucket, client: new S3Client({region: process.env.AWS_REGION || 'us-east-1',
    endpoint: process.env.S3_ENDPOINT || undefined, requestChecksumCalculation: 'WHEN_REQUIRED'})};
}
export function videoURL(key: string) {
  const base = process.env.S3_VIDEO_PUBLIC_URL;
  if (!base) throw Error('Video storage is not configured');
  const url = new URL(base);
  if (url.protocol !== 'https:') throw Error('Video storage requires HTTPS');
  // The SDK preserves an endpoint's path when signing uploads. With a
  // bucket-root CDN, that path is therefore also part of the public object key.
  // An explicit public base path takes precedence (and must not be doubled).
  const prefix = url.pathname.replace(/\/+$/, '') ||
    (process.env.S3_ENDPOINT ? new URL(process.env.S3_ENDPOINT).pathname.replace(/\/+$/, '') : '');
  url.pathname = `${prefix}/${key}`;
  return url.href;
}
export function streamContentType(filename: string) {
  streamFileSchema.parse(filename);
  return filename.endsWith('.m3u8') ? 'application/vnd.apple.mpegurl' : 'video/mp2t';
}
export function streamKey(owner: string, documentId: string, streamID: string, filename: string) {
  z.string().uuid().parse(streamID);
  streamFileSchema.parse(filename);
  return `${videoPrefix(owner, documentId)}${streamID}/${filename}`;
}
export async function createVideoUpload(owner: string, documentId: string, size: number, stream?: {id: string; filename: string}) {
  const {bucket, client} = storage();
  if (!Number.isSafeInteger(size) || size <= 0 || size > maxVideoBytes) throw Error('Invalid size');
  const key = stream ? streamKey(owner, documentId, stream.id, stream.filename) : `${videoPrefix(owner, documentId)}${randomUUID()}.mp4`;
  const contentType = stream ? streamContentType(stream.filename) : 'video/mp4';
  videoURL(key);
  const uploadURL = await getSignedUrl(client, new PutObjectCommand({Bucket: bucket, Key: key,
    ContentType: contentType, ContentLength: size}), {expiresIn: 900, signableHeaders: new Set(['content-type', 'content-length'])});
  return {uploadURL, key};
}
export async function validateVideo(owner: string, documentId: string, key: string) {
  if (!key.startsWith(videoPrefix(owner, documentId))) throw Error('Invalid video owner');
  const {bucket, client} = storage();
  const object = await client.send(new HeadObjectCommand({Bucket: bucket, Key: key}));
  if (object.ContentType !== 'video/mp4' || !object.ContentLength || object.ContentLength > maxVideoBytes) throw Error('Invalid video');
}

export async function validateStreaming(owner: string, documentId: string, stream: z.infer<typeof streamingSchema>) {
  const parsed = streamingSchema.parse(stream);
  const {bucket, client} = storage();
  await Promise.all(parsed.files.map(async filename => {
    const key = streamKey(owner, documentId, parsed.id, filename);
    const object = await client.send(new HeadObjectCommand({Bucket: bucket, Key: key}));
    if (object.ContentType !== streamContentType(filename) || !object.ContentLength || object.ContentLength > maxVideoBytes) throw Error('Invalid streaming asset');
  }));
}
export function streamingURL(originalKey: string, streamID: string) {
  z.string().uuid().parse(streamID);
  return videoURL(`${originalKey.slice(0, originalKey.lastIndexOf('/') + 1)}${streamID}/master.m3u8`);
}
