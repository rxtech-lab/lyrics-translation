import Link from 'next/link';
import {pageHref} from '@/lib/links';

/** Previous / next links with the visible range. */
export default function Pagination({basePath, page, pageSize, total, totalPages, unit}: {basePath: string; page: number; pageSize: number; total: number; totalPages: number; unit: string}) {
  if (totalPages <= 1) return null;
  return <nav className="discover-pagination" aria-label="Pagination">
    {page > 1 ? <Link className="pill" href={pageHref(basePath, page - 1)} rel="prev">← Previous</Link> : <span className="pill" aria-disabled="true">← Previous</span>}
    <div><strong>Page {page} of {totalPages}</strong><small>{((page - 1) * pageSize + 1).toLocaleString()}–{Math.min(page * pageSize, total).toLocaleString()} of {total.toLocaleString()} {unit}</small></div>
    {page < totalPages ? <Link className="pill" href={pageHref(basePath, page + 1)} rel="next">Next →</Link> : <span className="pill" aria-disabled="true">Next →</span>}
  </nav>;
}
