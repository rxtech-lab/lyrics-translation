import {test} from 'node:test';
import assert from 'node:assert/strict';
import {documentSchema} from './document';
import {createVideoUpload, validateVideo, videoPrefix, videoURL} from './video-storage';

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
