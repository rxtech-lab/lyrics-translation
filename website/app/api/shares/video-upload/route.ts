import {streamFileSchema} from '@/lib/document';
import {z} from 'zod';
import {identity, sameOrigin} from '@/lib/auth';
import {createVideoUpload, maxVideoBytes} from '@/lib/video-storage';

export async function POST(request: Request) {
  let owner: string;
  try { sameOrigin(request); owner = await identity(request, true); }
  catch { return new Response('Sign in required', {status: 401}); }
  try {
    const raw = await request.text();
    if (Buffer.byteLength(raw) > 4096) return new Response('Request too large', {status: 413});
    const {documentId, size, streamID, filename} = z.object({documentId: z.string().uuid(), size: z.number().int().positive().max(maxVideoBytes), streamID: z.string().uuid().optional(), filename: streamFileSchema.optional()}).parse(JSON.parse(raw));
    if (!!streamID !== !!filename) return new Response('Incomplete streaming upload', {status: 400});
    if (!process.env.S3_VIDEO_BUCKET || !process.env.S3_VIDEO_PUBLIC_URL) return new Response('Video publishing is not configured', {status: 503});
    return Response.json(await createVideoUpload(owner, documentId, size, streamID && filename ? {id: streamID, filename} : undefined), {headers: {'Cache-Control': 'no-store'}});
  } catch { return new Response('Could not prepare video upload', {status: 400}); }
}
