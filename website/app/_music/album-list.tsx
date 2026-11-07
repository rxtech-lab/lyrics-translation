'use client';

import Link from 'next/link';
import {useState, useTransition} from 'react';
import type {CatalogAlbum} from '@/lib/apple-music';
import {catalogAlbumHref} from '@/lib/links';
import {loadAlbumSongs, type AlbumSongs} from './actions';
import SongList from './song-list';

type Counts = {songs: number; translations: number};

/** Albums and singles as rows. Opening a row lists every song on it with its translation count. */
export default function AlbumList({albums, counts, storefront, offset = 0}: {albums: CatalogAlbum[]; counts: [string, Counts][]; storefront: string; offset?: number}) {
  const byName = new Map(counts);
  return <ol className="song-list album-list">
    {albums.map((album, index) => <AlbumRow key={album.id} album={album} count={byName.get(album.name)} storefront={storefront} number={offset + index + 1} />)}
  </ol>;
}

function AlbumRow({album, count, storefront, number}: {album: CatalogAlbum; count?: Counts; storefront: string; number: number}) {
  const [songs, setSongs] = useState<AlbumSongs>();
  const [loading, startLoading] = useTransition();
  const load = () => startLoading(async () => {
    try { setSongs(await loadAlbumSongs(album.id, storefront)); }
    catch { setSongs({error: 'Songs couldn’t be loaded. Try again.'}); }
  });
  return <li className={count ? 'is-translated' : undefined}>
    <details onToggle={event => { if (event.currentTarget.open && (!songs || 'error' in songs) && !loading) load(); }}>
      <summary className="song-list-row">
        <span className="song-list-number">{number}</span>
        <span className="song-list-art" aria-hidden="true">{album.artwork ? <img src={album.artwork.replace('600x600', '120x120')} alt="" loading="lazy" /> : '♫'}</span>
        <span className="song-list-title">
          <span>{album.name}</span>
          <small>{[album.released?.slice(0, 4), album.single ? 'Single' : 'Album', `${album.trackCount} ${album.trackCount === 1 ? 'song' : 'songs'}`].filter(Boolean).join(' · ')}</small>
        </span>
        <span className="song-list-duration">{count ? `${count.translations} ${count.translations === 1 ? 'translation' : 'translations'}` : ''}</span>
        {count
          ? <span className="song-list-status">{count.songs} of {album.trackCount} translated</span>
          : <span className="song-list-status is-empty">Not translated yet</span>}
        <span className="album-list-chevron" aria-hidden="true">›</span>
      </summary>
      <div className="album-list-songs">
        {loading && <p className="album-list-message" role="status">Loading songs…</p>}
        {!loading && songs && 'error' in songs && <p className="album-list-message" role="alert">{songs.error} <button type="button" onClick={load}>Retry</button></p>}
        {!loading && songs && 'songs' in songs && <SongList songs={songs.songs} counts={new Map(songs.counts)} />}
        <Link className="catalog-listen" href={catalogAlbumHref(album.id, storefront)}>Open album page →</Link>
      </div>
    </details>
  </li>;
}
