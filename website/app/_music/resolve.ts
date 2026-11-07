import {NextResponse} from 'next/server';
import {songRelations, storefrontFromURL} from '@/lib/apple-music';
import {db, init, songURL} from '@/lib/db';
import {albumHref, catalogAlbumHref, catalogArtistHref} from '@/lib/links';

/** Finds a translated song's Apple Music album or artist and redirects to its catalog page. */
export async function redirectToRelation(request: Request, song: string, relation: 'album' | 'artist') {
  const found = /^\d+$/.test(song) ? await songURL(song) : null;
  if (!found) return new Response('Song not found', {status: 404});
  const storefront = storefrontFromURL(found.url);
  try {
    const {albumID, artistID} = await songRelations(song, storefront);
    const id = relation === 'album' ? albumID : artistID;
    if (id) return NextResponse.redirect(new URL(relation === 'album' ? catalogAlbumHref(id, storefront) : catalogArtistHref(id, storefront), request.url));
  } catch {}
  // Apple Music unavailable: fall back to the translated songs of the album, matched by name.
  if (relation === 'album') {
    await init();
    const row = (await db().execute({sql: `SELECT json_extract(document, '$.appleMusic.artist') artist, json_extract(document, '$.appleMusic.album') album FROM shares WHERE json_extract(document, '$.appleMusic.id') = ? AND json_extract(document, '$.appleMusic.album') IS NOT NULL LIMIT 1`, args: [song]})).rows[0];
    if (row) return NextResponse.redirect(new URL(albumHref(String(row.artist), String(row.album)), request.url));
  }
  return new Response('Apple Music is unavailable right now. Try again later.', {status: 503});
}
