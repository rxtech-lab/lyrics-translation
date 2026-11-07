import Link from 'next/link';
import type {CatalogSong} from '@/lib/apple-music';
import type {SongCount} from '@/lib/db';
import {songHref} from '@/lib/links';

const time = (seconds?: number) => seconds == null ? '' : `${Math.floor(seconds / 60)}:${String(Math.floor(seconds % 60)).padStart(2, '0')}`;

/** Catalog songs with how many community translations each has. */
export default function SongList({songs, counts, numbered = 'track', showArtwork = false, offset = 0}: {songs: CatalogSong[]; counts: Map<string, SongCount>; numbered?: 'track' | 'rank'; showArtwork?: boolean; offset?: number}) {
  const discs = new Set(songs.map(s => s.disc ?? 1)).size > 1;
  return <ol className="song-list">
    {songs.map((song, index) => {
      const count = counts.get(song.id);
      // Always open the song's translations list, even when there is only one translation.
      const href = count ? songHref(count.song) : undefined;
      const number = numbered === 'rank' ? offset + index + 1 : song.track ?? index + 1;
      const showDisc = numbered === 'track' && discs && (index === 0 || (songs[index - 1].disc ?? 1) !== (song.disc ?? 1));
      return <li key={song.id} className={count ? 'is-translated' : undefined}>
        {showDisc && <p className="song-list-disc">Disc {song.disc ?? 1}</p>}
        <div className="song-list-row">
          <span className="song-list-number">{number}</span>
          {showArtwork && <span className="song-list-art" aria-hidden="true">{song.artwork ? <img src={song.artwork} alt="" loading="lazy" /> : '♫'}</span>}
          <div className="song-list-title">
            {href ? <Link href={href}>{song.name}</Link> : <span>{song.name}</span>}
            {(numbered === 'rank' ? song.album : song.artist) && <small>{numbered === 'rank' ? song.album : song.artist}</small>}
          </div>
          <span className="song-list-duration">{time(song.duration)}</span>
          {count
            ? <Link className="song-list-status" href={href!}>{count.translations} {count.translations === 1 ? 'translation' : 'translations'} →</Link>
            : <span className="song-list-status is-empty">Not translated yet</span>}
        </div>
      </li>;
    })}
  </ol>;
}
