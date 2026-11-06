import Link from 'next/link';
import {notFound} from 'next/navigation';
import {getAuthor, list} from '@/lib/db';
import Collection from '../../discover/collection';
export const dynamic = 'force-dynamic';
export const metadata = {title: 'Translator’s works'};
export default async function Author({params, searchParams}: {params: Promise<{id: string}>; searchParams: Promise<{page?: string | string[]}>}) {
  const {id} = await params;
  const author = await getAuthor(id);
  if (!author) notFound();
  const query = await searchParams;
  const page = typeof query.page === 'string' && /^\d+$/.test(query.page) ? Number(query.page) : 1;
  const data = await list(page, id);
  return <main className="page discover-page">
    <Link href="/discover">← Discover</Link>
    <p className="eyebrow">TRANSLATOR</p>
    <h1>{String(author.name)}</h1>
    <div className="collection-heading"><p>Public translations</p><small>{data.total} {data.total === 1 ? 'translation' : 'translations'} · Newest first</small></div>
    <Collection data={data} basePath={'/authors/' + id} />
  </main>;
}
