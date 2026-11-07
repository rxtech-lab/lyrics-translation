import Link from 'next/link';
import {notFound} from 'next/navigation';
import {albumSongs} from '@/lib/db';
import {Document} from '@/lib/document';
import {albumHref} from '@/lib/links';
import SongList from '../_music/song-list';
import type {SongCount} from '@/lib/db';
import {pageHref} from '@/lib/links';

export const dynamic = 'force-dynamic';

type Query = Promise<{artist?: string | string[]; album?: string | string[]; page?: string | string[]}>;
const text = (value?: string | string[]) => typeof value === 'string' && value.trim() && value.length <= 1000 ? value : undefined;

export async function generateMetadata({searchParams}: {searchParams: Query}) {
  const query = await searchParams;
  const artist = text(query.artist), album = text(query.album);
  if (!artist || !album) return {title: 'Album not found'};
  return {title: `${album} · ${artist}`, description: `Community lyric translations from ${album} by ${artist}.`};
}

export default async function Album({searchParams}: {searchParams: Query}) {
  const query = await searchParams;
  const artist = text(query.artist), album = text(query.album);
  if (!artist || !album) notFound();
  const page = typeof query.page === 'string' && /^\d+$/.test(query.page) ? Number(query.page) : 1;
  const data = await albumSongs(artist, album, page);
  if (!data.total) notFound();
  const songs = data.rows.map(row => {
    const music = (JSON.parse(String(row.document)) as Document).appleMusic;
    return {id: String(row.song), name: music?.title ?? String(row.title), artist: music?.artist ?? artist, duration: music?.duration ?? undefined};
  });
  const counts = new Map<string, SongCount>(data.rows.map(row => [String(row.song), {translations: Number(row.song_translations), share: String(row.id), song: String(row.song)}]));
  const artworkSource = (JSON.parse(String(data.rows[0]?.document ?? '{}')) as Partial<Document>).appleMusic?.artworkURL;
  const artwork = artworkSource?.replaceAll('{w}', '600').replaceAll('{h}', '600');
  return <main className="page discover-page">
    <Link className="translation-back" href="/discover">← Discover</Link>
    <div className="translation-heading">
      <div className="translation-cover" aria-hidden="true">{artwork ? <img src={artwork} alt=""/> : <><span>𝄞</span><i/></>}</div>
      <div className="translation-intro">
        <p className="eyebrow">ALBUM</p>
        <h1>{album}</h1>
        <p className="translation-artist">{artist}</p>
        <div className="translation-meta">
          <span>{data.total} {data.total === 1 ? 'song' : 'songs'}</span>
          <span>{data.translations} {data.translations === 1 ? 'translation' : 'translations'}</span>
        </div>
      </div>
    </div>
    <div className="collection-heading">
      <p>Translated songs</p>
      <small>A to Z · Only songs with translations</small>
    </div>
    <SongList songs={songs} counts={counts} numbered="rank" offset={(data.page - 1) * data.pageSize} />
    {data.totalPages > 1 && <nav className="discover-pagination" aria-label="Song pagination">
      {data.page > 1 ? <Link className="pill" href={pageHref(albumHref(artist, album), data.page - 1)} rel="prev">← Previous</Link> : <span className="pill" aria-disabled="true">← Previous</span>}
      <div><strong>Page {data.page} of {data.totalPages}</strong><small>{(data.page - 1) * data.pageSize + 1}–{Math.min(data.page * data.pageSize, data.total)} of {data.total} songs</small></div>
      {data.page < data.totalPages ? <Link className="pill" href={pageHref(albumHref(artist, album), data.page + 1)} rel="next">Next →</Link> : <span className="pill" aria-disabled="true">Next →</span>}
    </nav>}
  </main>;
}
