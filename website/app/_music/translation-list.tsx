import Link from 'next/link';
import type {Row} from '@libsql/client';
import type {Document} from '@/lib/document';
import {formatNumber} from '@/lib/format-number';
import {tokens} from '@/lib/document';

const date = new Intl.DateTimeFormat('en-US', {month: 'short', day: 'numeric', year: 'numeric', timeZone: 'UTC'});

/** One song's community translations as rows, ranked by likes. */
export default function TranslationList({rows, offset = 0}: {rows: Row[]; offset?: number}) {
  return <ol className="song-list translation-list">
    {rows.map((row, index) => {
      const d = JSON.parse(String(row.document)) as Document;
      const href = '/s/' + row.id;
      const created = row.created ? new Date(String(row.created).replace(' ', 'T') + 'Z') : undefined;
      const stars = Number(row.stars);
      return <li key={String(row.id)} className="is-translated">
        <div className="song-list-row">
          <span className="song-list-number">{offset + index + 1}</span>
          <span className="language-tag translation-list-language">{d.target}</span>
          <div className="song-list-title">
            <Link href={href}>{String(row.author_name)}</Link>
            <small>
              {d.lines.length} {d.lines.length === 1 ? 'line' : 'lines'}
              {created && !Number.isNaN(created.getTime()) && <> · {date.format(created)}</>}
              {tokens(d) > 0 && <> · {formatNumber(tokens(d))} tokens</>}
            </small>
          </div>
          <span className="translation-list-likes" aria-label={`${stars} ${stars === 1 ? 'like' : 'likes'}`}>☆ {stars}</span>
          <Link className="song-list-status" href={href}>Open →</Link>
        </div>
      </li>;
    })}
  </ol>;
}
