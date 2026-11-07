import Link from 'next/link';
import {notFound} from 'next/navigation';
import {CatalogUnavailable, getArtist, storefrontOf} from '@/lib/apple-music';
import {artistAlbumCounts, songCounts} from '@/lib/db';
import {catalogArtistHref, pageHref} from '@/lib/links';
import AlbumList from '../../_music/album-list';
import SongList from '../../_music/song-list';

export const dynamic = 'force-dynamic';

type Props = {params: Promise<{id: string}>; searchParams: Promise<{storefront?: string | string[]; page?: string | string[]}>};
const pageSize = 25;

async function load({params, searchParams}: Props) {
  const {id} = await params;
  const query = await searchParams;
  if (!/^\d+$/.test(id)) notFound();
  const storefront = storefrontOf(query.storefront);
  try {
    const artist = await getArtist(id, storefront);
    if (!artist) notFound();
    return {artist, storefront, query};
  } catch (error) {
    if (error instanceof CatalogUnavailable) return {artist: null, storefront, query};
    throw error;
  }
}

export async function generateMetadata(props: Props) {
  const {artist} = await load(props);
  if (!artist) return {title: 'Artist'};
  return {title: artist.name, description: `Songs and albums by ${artist.name} and their community lyric translations.`};
}

export default async function Artist(props: Props) {
  const {artist, storefront, query} = await load(props);
  if (!artist) return <main className="page discover-page"><Link className="translation-back" href="/discover">← Discover</Link><div className="glass card"><h2>Apple Music is unavailable.</h2><p>Artist details can’t be loaded right now. Try again in a moment.</p></div></main>;
  const [counts, albumCounts] = await Promise.all([songCounts(artist.topSongs), artistAlbumCounts(artist.name)]);
  const totalPages = Math.max(1, Math.ceil(artist.albums.length / pageSize));
  const requested = typeof query.page === 'string' && /^\d+$/.test(query.page) ? Number(query.page) : 1;
  const page = Math.min(totalPages, Math.max(1, requested));
  const albums = artist.albums.slice((page - 1) * pageSize, page * pageSize);
  const translatedAlbums = artist.albums.filter(a => albumCounts.albums.has(a.name)).length;
  const basePath = catalogArtistHref(artist.id, storefront);
  return <main className="page discover-page catalog-page">
    <Link className="translation-back" href="/discover">← Discover</Link>
    <div className="translation-heading">
      <div className="translation-cover is-round" aria-hidden="true">{artist.artwork ? <img src={artist.artwork} alt=""/> : <><span>𝄞</span><i/></>}</div>
      <div className="translation-intro">
        <p className="eyebrow">ARTIST</p>
        <h1>{artist.name}</h1>
        {artist.genres.length > 0 && <p className="translation-artist">{artist.genres.slice(0, 3).join(' · ')}</p>}
        {artist.url && <a className="catalog-listen" href={artist.url} target="_blank" rel="noopener noreferrer">Listen on Apple Music ↗</a>}
      </div>
    </div>
    <dl className="catalog-stats">
      <div><dt>Albums & singles</dt><dd>{artist.albums.length}</dd></div>
      <div><dt>With translations</dt><dd>{translatedAlbums}</dd></div>
      <div><dt>Translated songs</dt><dd>{albumCounts.songs}</dd></div>
      <div><dt>Translations</dt><dd>{albumCounts.translations}</dd></div>
    </dl>
    {artist.topSongs.length > 0 && <section aria-labelledby="top-songs">
      <div className="collection-heading"><h2 id="top-songs">Top songs</h2><small>{artist.topSongs.filter(s => counts.has(s.id)).length} of {artist.topSongs.length} translated</small></div>
      <SongList songs={artist.topSongs} counts={counts} numbered="rank" showArtwork />
    </section>}
    <section aria-labelledby="albums">
      <div className="collection-heading"><h2 id="albums">Albums & singles</h2><small>Newest first · Open an album to see its songs</small></div>
      <AlbumList albums={albums} counts={[...albumCounts.albums]} storefront={storefront} offset={(page - 1) * pageSize} />
      {totalPages > 1 && <nav className="discover-pagination" aria-label="Album pagination">
        {page > 1 ? <Link className="pill" href={pageHref(basePath, page - 1)} rel="prev">← Previous</Link> : <span className="pill" aria-disabled="true">← Previous</span>}
        <div><strong>Page {page} of {totalPages}</strong><small>{(page - 1) * pageSize + 1}–{Math.min(page * pageSize, artist.albums.length)} of {artist.albums.length}</small></div>
        {page < totalPages ? <Link className="pill" href={pageHref(basePath, page + 1)} rel="next">Next →</Link> : <span className="pill" aria-disabled="true">Next →</span>}
      </nav>}
    </section>
  </main>;
}
