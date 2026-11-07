import Link from 'next/link';

export type SongFilter = 'all' | 'translated' | 'untranslated';
export const songFilter = (value?: string | string[]): SongFilter => value === 'translated' || value === 'untranslated' ? value : 'all';

/** All / Translated / Not translated switch with counts, kept in the URL so it can be shared. */
export default function FilterTabs({basePath, active, total, translated}: {basePath: string; active: SongFilter; total: number; translated: number}) {
  const href = (filter: SongFilter) => filter === 'all' ? basePath : basePath + (basePath.includes('?') ? '&' : '?') + 'show=' + filter;
  const tabs: [SongFilter, string, number][] = [['all', 'All', total], ['translated', 'Translated', translated], ['untranslated', 'Not translated', total - translated]];
  return <nav className="song-filter" aria-label="Filter songs">
    {tabs.map(([filter, label, count]) => <Link key={filter} href={href(filter)} aria-current={active === filter ? 'page' : undefined} scroll={false}>{label}<span>{count}</span></Link>)}
  </nav>;
}
