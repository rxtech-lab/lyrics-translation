import {formatNumber} from '@/lib/format-number';
import Link from 'next/link';
import {list} from '@/lib/db';
import CoverArtwork from './cover-artwork';
import {tokens, Document} from '@/lib/document';

export default function Collection({data, basePath = '/discover'}: {data: Awaited<ReturnType<typeof list>>; basePath?: string}) {
  const {rows, page, pageSize, total, totalPages} = data;
  return <>
    <div className="discover-grid">
      {rows.map(r => {
        const d = JSON.parse(String(r.document)) as Document;
        return <article className="glass discover-card" key={String(r.id)}>
          <Link href={'/s/' + r.id} aria-label={String(r.title)}><CoverArtwork src={d.appleMusic?.artworkURL} /></Link>
          <div className="discover-card-body">
            <span className="language-tag">{d.target}</span>
            <h2><Link href={'/s/' + r.id}>{String(r.title)}</Link></h2>
            <p className="discover-author">Translated by <Link href={'/authors/' + r.author_id}>{String(r.author_name)}</Link></p>
            {d.appleMusic?.artist && <p className="discover-artist">{d.appleMusic.artist}</p>}
            {d.appleMusic?.album && <p className="discover-album"><span>Album</span>{d.appleMusic.album}</p>}
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
      {page > 1 ? <Link className="pill" href={basePath + '?page=' + (page - 1)} rel="prev">← Previous</Link> : <span className="pill" aria-disabled="true">← Previous</span>}
      <div><strong>Page {page} of {totalPages}</strong><small>{((page - 1) * pageSize + 1).toLocaleString()}–{Math.min(page * pageSize, total).toLocaleString()} of {total.toLocaleString()}</small></div>
      {page < totalPages ? <Link className="pill" href={basePath + '?page=' + (page + 1)} rel="next">Next →</Link> : <span className="pill" aria-disabled="true">Next →</span>}
    </nav>}
  </>;
}
