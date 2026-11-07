import Link from 'next/link';
import {notFound} from 'next/navigation';
import {CatalogUnavailable, getAlbum, storefrontOf} from '@/lib/apple-music';
import {songCounts} from '@/lib/db';
import {catalogAlbumHref, catalogArtistHref} from '@/lib/links';
import SongList from '../../_music/song-list';
import FilterTabs, {songFilter} from '../../_music/filter';

export const dynamic = 'force-dynamic';

type Props = {params: Promise<{id: string}>; searchParams: Promise<{storefront?: string | string[]; show?: string | string[]}>};

async function load({params, searchParams}: Props) {
  const {id} = await params;
  const query = await searchParams;
  if (!/^\d+$/.test(id)) notFound();
  const storefront = storefrontOf(query.storefront);
  try {
    const album = await getAlbum(id, storefront);
    if (!album) notFound();
    return {album, storefront, query};
  } catch (error) {
    if (error instanceof CatalogUnavailable) return {album: null, storefront, query};
    throw error;
  }
}

export async function generateMetadata(props: Props) {
  const {album} = await load(props);
  if (!album) return {title: 'Album'};
  return {title: `${album.name} · ${album.artist}`, description: `Songs from ${album.name} by ${album.artist} and their community lyric translations.`};
}

export default async function Album(props: Props) {
  const {album, storefront, query} = await load(props);
  if (!album) return <main className="page discover-page"><Link className="translation-back" href="/discover">← Discover</Link><div className="glass card"><h2>Apple Music is unavailable.</h2><p>Album details can’t be loaded right now. Try again in a moment.</p></div></main>;
  const counts = await songCounts(album.tracks);
  const translatedSongs = album.tracks.filter(t => counts.has(t.id)).length;
  const translations = album.tracks.reduce((sum, t) => sum + (counts.get(t.id)?.translations ?? 0), 0);
  const filter = songFilter(query.show);
  const shown = album.tracks.filter(t => filter === 'all' || (filter === 'translated') === counts.has(t.id));
  const year = album.released?.slice(0, 4);
  return <main className="page discover-page catalog-page">
    <Link className="translation-back" href="/discover">← Discover</Link>
    <div className="translation-heading">
      <div className="translation-cover" aria-hidden="true">{album.artwork ? <img src={album.artwork} alt=""/> : <><span>𝄞</span><i/></>}</div>
      <div className="translation-intro">
        <p className="eyebrow">{album.single ? 'SINGLE' : 'ALBUM'}</p>
        <h1>{album.name}</h1>
        <p className="translation-artist">{album.artistID ? <Link className="album-link" href={catalogArtistHref(album.artistID, storefront)}>{album.artist}</Link> : album.artist}{year && ` · ${year}`}</p>
        {album.url && <a className="catalog-listen" href={album.url} target="_blank" rel="noopener noreferrer">Listen on Apple Music ↗</a>}
      </div>
    </div>
    <dl className="catalog-stats">
      <div><dt>Songs</dt><dd>{album.tracks.length}</dd></div>
      <div><dt>Translated</dt><dd>{translatedSongs}</dd></div>
      <div><dt>Not translated</dt><dd>{album.tracks.length - translatedSongs}</dd></div>
      <div><dt>Translations</dt><dd>{translations}</dd></div>
    </dl>
    <FilterTabs basePath={catalogAlbumHref(album.id, storefront)} active={filter} total={album.tracks.length} translated={translatedSongs} />
    {shown.length ? <SongList songs={shown} counts={counts} /> : <div className="glass card"><p>{filter === 'translated' ? 'No songs on this album have been translated yet.' : 'Every song on this album has a translation.'}</p></div>}
    {album.copyright && <p className="catalog-copyright">{album.copyright}</p>}
  </main>;
}
