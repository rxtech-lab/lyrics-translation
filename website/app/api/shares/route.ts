import {createHash} from 'node:crypto';
import {identity,sameOrigin,authenticatedProfile} from '@/lib/auth';
import {db,init} from '@/lib/db';
import {documentSchema} from '@/lib/document';
import {z} from 'zod';
import {validateVideo, validateStreaming} from '@/lib/video-storage';

const publicationKey = (owner: string, id: string) => createHash('sha256').update(JSON.stringify([owner,id])).digest('hex');
const documentID = z.string().uuid();
const shareURL = (id: string, r: Request) => new URL('/s/'+id, process.env.SITE_URL || r.url).href;

export async function GET(r: Request) {
  let owner: string;
  try { owner = await identity(r, true); } catch { return new Response('Sign in required', {status:401}); }
  try {
    const id = documentID.parse(new URL(r.url).searchParams.get('documentId'));
    await init();
    const {rows} = await db().execute({sql:'SELECT p.share, s.document FROM publications p JOIN shares s ON s.id=p.share WHERE p.owner=? AND p.document_id=?', args:[owner,id]});
    return Response.json({url: rows.length ? shareURL(String(rows[0].share), r) : null, lyricVideo: rows.length ? JSON.parse(String(rows[0].document)).lyricVideo ?? null : null}, {headers:{'Cache-Control':'no-store'}});
  } catch { return new Response('Invalid status request', {status:400}); }
}

export async function DELETE(r: Request) {
  let owner: string;
  try { sameOrigin(r); owner = await identity(r, true); } catch { return new Response('Sign in required', {status:401}); }
  try {
    const id = documentID.parse(new URL(r.url).searchParams.get('documentId'));
    await init();
    await db().batch([
      {sql:'DELETE FROM stars WHERE share IN (SELECT share FROM publications WHERE owner=? AND document_id=?)',args:[owner,id]},
      {sql:'DELETE FROM publications WHERE owner=? AND document_id=? RETURNING share',args:[owner,id]},
      // Remove only this owner's now-unreferenced publication, using a stable share ID.
      {sql:'DELETE FROM shares WHERE id=? AND owner=?',args:[publicationKey(owner,id),owner]},
    ], 'write');
    return Response.json({url:null});
  } catch { return new Response('Unpublish failed', {status:400}); }
}

export async function POST(r:Request) {
  let owner: string;
  let authorName: string | undefined;
  try { sameOrigin(r); const profile = await authenticatedProfile(r,true); owner=profile.owner; authorName=profile.name; } catch { return new Response('Sign in required',{status:401}); }
  try {
    const raw=await r.text();
    if(Buffer.byteLength(raw)>1000000)return new Response('Document too large',{status:413});
    const data=z.object({documentId:documentID.optional(),title:z.string().trim().min(1).max(180),document:documentSchema}).parse(JSON.parse(raw));
    if (data.document.lyricVideo) {
      if (!data.documentId) return new Response('Video requires a document ID', {status:400});
      await validateVideo(owner, data.documentId, data.document.lyricVideo.key);
      if (data.document.lyricVideo.streaming) await validateStreaming(owner, data.documentId, data.document.lyricVideo.streaming);
    }
    await init();
    const id=data.documentId ? publicationKey(owner,data.documentId) : crypto.randomUUID();
    await db().batch([
      {sql: `INSERT INTO authors(owner,name) VALUES(?,?) ON CONFLICT(owner) DO UPDATE SET name=CASE WHEN ? IS NOT NULL THEN excluded.name ELSE authors.name END`, args:[owner,authorName || 'Community translator',authorName || null]},
      {sql:'INSERT INTO shares(id,owner,title,document) VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET title=excluded.title,document=excluded.document',args:[id,owner,data.title,JSON.stringify(data.document)]},
      ...(data.documentId ? [{sql:'INSERT INTO publications(owner,document_id,share) VALUES(?,?,?) ON CONFLICT(owner,document_id) DO NOTHING',args:[owner,data.documentId,id]}] : []),
    ], 'write');
    return Response.json({url:shareURL(id,r)});
  } catch { return new Response('Publishing failed',{status:400}); }
}
