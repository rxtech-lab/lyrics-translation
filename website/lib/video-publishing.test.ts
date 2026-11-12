import {test} from 'node:test';
import assert from 'node:assert/strict';
import {documentSchema} from './document';
import {createVideoUpload, validateVideo, videoPrefix, videoURL, streamKey, streamContentType, streamingURL} from './video-storage';

const documentId = '9c630ee3-5ce0-4dfa-88c6-148fe464302e';
const key = `${videoPrefix('alice', documentId)}9c630ee3-5ce0-4dfa-88c6-148fe464302e.mp4`;
const legacy = {target: 'English', lines: [{original: 'Hello', translated: 'Hello'}]};

test('legacy publications validate and private fields are stripped', () => {
  const result = documentSchema.parse({...legacy, privatePrompt: 'secret'});
  assert.equal(result.lyricVideo, undefined);
  assert.equal('privatePrompt' in result, false);
});
test('video metadata survives publishing but external URLs and traversal fail', () => {
  assert.deepEqual(documentSchema.parse({...legacy, lyricVideo: {key, hasAudio: false}}).lyricVideo, {key, hasAudio: false});
  for (const badKey of ['https://example.com/video.mp4', '../video.mp4', key + '/../other.mp4']) {
    assert.equal(documentSchema.safeParse({...legacy, lyricVideo: {key: badKey, hasAudio: false}}).success, false);
  }
});
test('video keys are scoped to owner and document before accessing S3', async () => {
  assert.notEqual(videoPrefix('alice', documentId), videoPrefix('bob', documentId));
  await assert.rejects(validateVideo('bob', documentId, key), /Invalid video owner/);
  await assert.rejects(validateVideo('alice', 'other-document', key), /Invalid video owner/);
});
test('presigned upload binds media type and size and resolves media URL', async () => {
  const prior = {...process.env};
  try {
    process.env.S3_VIDEO_BUCKET = 'test-lyric-videos';
    process.env.S3_VIDEO_PUBLIC_URL = 'https://media.example.com/videos/';
    process.env.AWS_REGION = 'us-east-1';
    process.env.AWS_ACCESS_KEY_ID = 'test-access-key';
    process.env.AWS_SECRET_ACCESS_KEY = 'test-secret-key';
    delete process.env.AWS_SESSION_TOKEN;
    delete process.env.S3_ENDPOINT;
    const upload = await createVideoUpload('alice', documentId, 1024);
    const url = new URL(upload.uploadURL);
    assert.equal(url.protocol, 'https:');
    assert.equal(url.searchParams.get('X-Amz-Expires'), '900');
    assert.match(url.searchParams.get('X-Amz-SignedHeaders')!, /content-length/);
    assert.match(url.searchParams.get('X-Amz-SignedHeaders')!, /content-type/);
    assert.ok(upload.key.startsWith(videoPrefix('alice', documentId)));
    assert.equal(videoURL(upload.key), `https://media.example.com/videos/${upload.key}`);
    process.env.S3_ENDPOINT = 'https://account.r2.cloudflarestorage.com/lyrics-studio';
    process.env.S3_VIDEO_PUBLIC_URL = 'https://lyricss3.rxlab.app';
    const nestedUpload = await createVideoUpload('alice', documentId, 1024);
    assert.ok(new URL(nestedUpload.uploadURL).pathname.endsWith(`/lyrics-studio/${nestedUpload.key}`));
    assert.equal(videoURL(nestedUpload.key), `https://lyricss3.rxlab.app/lyrics-studio/${nestedUpload.key}`);
    process.env.S3_VIDEO_PUBLIC_URL = 'https://lyricss3.rxlab.app/lyrics-studio/';
    assert.equal(videoURL(key), `https://lyricss3.rxlab.app/lyrics-studio/${key}`);
    process.env.S3_VIDEO_PUBLIC_URL = 'http://media.example.com';
    assert.throws(() => videoURL(upload.key), /HTTPS/);
  } finally {
    for (const name of Object.keys(process.env)) if (!(name in prior)) delete process.env[name];
    Object.assign(process.env, prior);
  }
});

const streamID = '1c630ee3-5ce0-4dfa-88c6-148fe464302e';
test('streaming metadata requires paired rendition files and a master playlist', () => {
  const streaming = {id: streamID, files: ['360.ts', '360.m3u8', 'master.m3u8']};
  assert.deepEqual(documentSchema.parse({...legacy, lyricVideo: {key, hasAudio: true, streaming}}).lyricVideo?.streaming, streaming);
  for (const files of [['360.ts', '360.m3u8'], ['360.ts', 'master.m3u8', 'master.m3u8'], ['../360.ts', '360.m3u8', 'master.m3u8'], ['360.ts', '720.m3u8', 'master.m3u8']]) {
    assert.equal(documentSchema.safeParse({...legacy, lyricVideo: {key, hasAudio: false, streaming: {...streaming, files}}}).success, false);
  }
  assert.throws(() => streamKey('alice', documentId, streamID, '../master.m3u8'));
  assert.throws(() => streamKey('alice', documentId, '../other', 'master.m3u8'));
  assert.notEqual(streamKey('alice', documentId, streamID, 'master.m3u8'), streamKey('bob', documentId, streamID, 'master.m3u8'));
});
test('HLS presigning binds content type and preserves relative package paths', async () => {
  const prior = {...process.env};
  try {
    Object.assign(process.env, {S3_VIDEO_BUCKET: 'test', S3_VIDEO_PUBLIC_URL: 'https://media.example.com', AWS_REGION: 'us-east-1', AWS_ACCESS_KEY_ID: 'test', AWS_SECRET_ACCESS_KEY: 'test'});
    delete process.env.S3_ENDPOINT;
    for (const filename of ['master.m3u8', '360.m3u8', '360.ts']) {
      const upload = await createVideoUpload('alice', documentId, 100, {id: streamID, filename});
      assert.equal(upload.key, streamKey('alice', documentId, streamID, filename));
      assert.match(new URL(upload.uploadURL).searchParams.get('X-Amz-SignedHeaders')!, /content-type/);
      assert.equal(new URL(filename, streamingURL(key, streamID)).href, videoURL(upload.key));
    }
    assert.equal(streamContentType('360.ts'), 'video/mp2t');
    assert.equal(streamContentType('master.m3u8'), 'application/vnd.apple.mpegurl');
    await assert.rejects(createVideoUpload('alice', documentId, 0));
  } finally {
    for (const name of Object.keys(process.env)) if (!(name in prior)) delete process.env[name];
    Object.assign(process.env, prior);
  }
});
