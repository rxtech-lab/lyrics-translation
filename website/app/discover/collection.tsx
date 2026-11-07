import {formatNumber} from '@/lib/format-number';
import Link from 'next/link';
import {list} from '@/lib/db';
import CoverArtwork from './cover-artwork';
import {tokens, Document} from '@/lib/document';
import {pageHref, songAlbumHref, songArtistHref, songHref} from '@/lib/links';

type Page = Pick<Awaited<ReturnType<typeof list>>, 'rows' | 'page' | 'pageSize' | 'total' | 'totalPages'>;

/**
 * Card grid of translations. With `groupSongs`, a song translated by several people opens
 * its translations list instead of a single translation.
 */
export default function Collection({data, basePath = '/discover', groupSongs = true, unit = 'translation'}: {data: Page; basePath?: string; groupSongs?: boolean; unit?: 'translation' | 'song'}) {
  const {rows, page, pageSize, total, totalPages} = data;
  return <>
    <div className="discover-grid">
      {rows.map(r => {
        const d = JSON.parse(String(r.document)) as Document;
        const others = Number(r.song_translations ?? 0);
        const grouped = groupSongs && others > 1 && d.appleMusic?.id;
        const href = grouped ? songHref(d.appleMusic!.id) : '/s/' + r.id;
        const label = grouped ? `${String(r.title)}, ${others} translations` : String(r.title);
        return <article className="glass discover-card" key={String(r.id)}>
          <Link href={href} aria-label={label}><CoverArtwork src={d.appleMusic?.artworkURL} /></Link>
          <div className="discover-card-body">
            <div className="discover-card-tags">
              {grouped ? <span className="language-tag">{others} translations</span> : <span className="language-tag">{d.target}</span>}
            </div>
            <h2><Link href={href}>{String(r.title)}</Link></h2>
            {grouped
              ? <p className="discover-author">Most liked by <Link href={'/authors/' + r.author_id}>{String(r.author_name)}</Link></p>
              : <p className="discover-author">Translated by <Link href={'/authors/' + r.author_id}>{String(r.author_name)}</Link></p>}
            {d.appleMusic?.artist && <p className="discover-artist"><Link href={songArtistHref(d.appleMusic.id)}>{d.appleMusic.artist}</Link></p>}
            {d.appleMusic?.album && <p className="discover-album"><span>Album</span><Link href={songAlbumHref(d.appleMusic.id)}>{d.appleMusic.album}</Link></p>}
            <div className="discover-metadata">
              {d.appleMusic?.duration != null && <span aria-label="Duration">{Math.floor(d.appleMusic.duration / 60)}:{String(Math.floor(d.appleMusic.duration % 60)).padStart(2, '0')}</span>}
              <span>{d.lines.length} {d.lines.length === 1 ? 'line' : 'lines'}</span>
            </div>
            <div className="discover-card-footer"><small>☆ {String(r.stars)} · {formatNumber(tokens(d))} tokens</small><span aria-hidden="true">↗</span></div>
          </div>
        </article>;
      })}
    </div>
    {!rows.length && <div className="glass card"><h2>The first verse is yours.</h2><p>No public translations yet.</p><Link href="/share">Share from the Mac app ↗</Link></div>}
    {total > 0 && <nav className="discover-pagination" aria-label="Collection pagination">
      {page > 1 ? <Link className="pill" href={pageHref(basePath, page - 1)} rel="prev">← Previous</Link> : <span className="pill" aria-disabled="true">← Previous</span>}
      <div><strong>Page {page} of {totalPages}</strong><small>{((page - 1) * pageSize + 1).toLocaleString()}–{Math.min(page * pageSize, total).toLocaleString()} of {total.toLocaleString()} {unit}{total === 1 ? '' : 's'}</small></div>
      {page < totalPages ? <Link className="pill" href={pageHref(basePath, page + 1)} rel="next">Next →</Link> : <span className="pill" aria-disabled="true">Next →</span>}
    </nav>}
  </>;
}
