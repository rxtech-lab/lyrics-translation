import Link from 'next/link';
import {notFound} from 'next/navigation';
import {songTranslations} from '@/lib/db';
import {Document} from '@/lib/document';
import {songAlbumHref, songArtistHref, songHref} from '@/lib/links';
import TranslationList from '../../_music/translation-list';
import Pagination from '../../_music/pagination';

export const dynamic = 'force-dynamic';

const pageNumber = (value?: string | string[]) => typeof value === 'string' && /^\d+$/.test(value) ? Number(value) : 1;

async function load(id: string, page = 1) {
  if (!/^\d+$/.test(id)) notFound();
  const data = await songTranslations(id, page);
  if (!data.total) notFound();
  return {data, song: (JSON.parse(String(data.rows[0].document)) as Document).appleMusic!};
}

export async function generateMetadata({params}: {params: Promise<{id: string}>}) {
  const {song, data} = await load((await params).id);
  return {title: `${song.title} · ${data.total} ${data.total === 1 ? 'translation' : 'translations'}`, description: `Every LyricStudio community translation of ${song.title} by ${song.artist}, most liked first.`};
}

export default async function Song({params, searchParams}: {params: Promise<{id: string}>; searchParams: Promise<{page?: string | string[]}>}) {
  const {id} = await params;
  const {data, song} = await load(id, pageNumber((await searchParams).page));
  const artwork = song.artworkURL?.replaceAll('{w}', '600').replaceAll('{h}', '600');
  return <main className="page discover-page">
    <Link className="translation-back" href="/discover">← Discover</Link>
    <div className="translation-heading">
      <div className="translation-cover" aria-hidden="true">{artwork ? <img src={artwork} alt=""/> : <><span>𝄞</span><i/></>}</div>
      <div className="translation-intro">
        <p className="eyebrow">SONG</p>
        <h1>{song.title}</h1>
        <p className="translation-artist"><Link className="album-link" href={songArtistHref(id)}>{song.artist}</Link></p>
        {song.album && <p className="discover-album"><span>Album</span><Link href={songAlbumHref(id)}>{song.album}</Link></p>}
      </div>
    </div>
    <div className="collection-heading">
      <p>Translations by the community</p>
      <small>{data.total.toLocaleString()} {data.total === 1 ? 'translation' : 'translations'} · Most liked first</small>
    </div>
    <TranslationList rows={data.rows} offset={(data.page - 1) * data.pageSize} />
    <Pagination basePath={songHref(id)} page={data.page} pageSize={data.pageSize} total={data.total} totalPages={data.totalPages} unit={data.total === 1 ? 'translation' : 'translations'} />
  </main>;
}
