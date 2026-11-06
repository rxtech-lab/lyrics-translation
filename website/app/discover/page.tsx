import Collection from './collection';
import {list} from '@/lib/db';

export const dynamic = 'force-dynamic';
export const metadata = {title: 'Discover', description: 'Explore public lyric translations from the LyricStudio community.'};

export default async function Discover({searchParams}: {
  searchParams: Promise<{page?: string | string[]}>;
}) {
  const query = await searchParams;
  const requestedPage = typeof query.page === 'string' && /^\d+$/.test(query.page) ? Number(query.page) : 1;
  const data = await list(requestedPage);
  const {total} = data;
  return <main className="page discover-page">
    <p className="eyebrow">THE COMMUNITY COLLECTION</p>
    <h1>Different words.<br/><em>Shared feeling.</em></h1>
    <div className="collection-heading">
      <p>Explore songs through another language.</p>
      <small>{total.toLocaleString()} {total === 1 ? 'translation' : 'translations'} · Newest first</small>
    </div>
    <Collection data={data} />
  </main>;
}
