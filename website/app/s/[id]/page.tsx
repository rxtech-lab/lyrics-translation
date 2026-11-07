import ShareLines from './share-lines';
import AnalyzedLyrics from './analyzed-lyrics';
import Link from 'next/link';import {identity} from '@/lib/auth';import {db,get} from '@/lib/db';import {notFound} from 'next/navigation';import {tokens,Document} from '@/lib/document';import Player from './player';import {songAlbumHref,songArtistHref,songHref} from '@/lib/links';export const dynamic='force-dynamic';
export async function generateMetadata({params}:{params:Promise<{id:string}>}){const {id}=await params,r=await get(id);if(!r)return {title:'Not found'};const d=JSON.parse(String(r.document));return {title:String(r.title),description:`A ${d.target} lyric translation on LyricStudio`,openGraph:{title:String(r.title),description:`Discover this ${d.target} interpretation`,images:[`/s/${id}/opengraph-image`]},twitter:{card:'summary_large_image',images:[`/s/${id}/opengraph-image`]}};}
export default async function Shared({params,searchParams}:{params:Promise<{id:string}>;searchParams:Promise<{lines?:string}>}){const highlighted=new Set(((await searchParams).lines || "").split(",").filter(v=>/^[1-9]\d*$/.test(v)).map(Number));const {id}=await params,r=await get(id);if(!r)notFound();const d=JSON.parse(String(r.document)) as Document;let owner:string|undefined;try{owner=await identity()}catch{}const starred=owner ? (await db().execute({sql:'SELECT 1 FROM stars WHERE share=? AND owner=?',args:[id,owner]})).rows.length>0 : false;return <main className="page translation-page">
    <Link className="translation-back" href="/discover">← Discover</Link>
    <div className="translation-heading">
      <div className="translation-cover" aria-hidden="true">{d.appleMusic?.artworkURL ? <img src={d.appleMusic.artworkURL} alt=""/> : <><span>𝄞</span><i/></>}</div>
      <div className="translation-intro">
        <p className="eyebrow">LYRIC TRANSLATION</p><p className="discover-author">Translated by <Link href={'/authors/' + r.author_id}>{String(r.author_name)}</Link></p>
        <h1>{String(r.title)}</h1>
        {d.appleMusic?.artist && <p className="translation-artist">{d.appleMusic.artist}</p>}
        <div className="translation-meta"><span>{d.target}</span><span>{d.lines.length} lines</span></div>
        {d.appleMusic && Number(r.song_translations) > 1 && <Link className="song-translations-link" href={songHref(d.appleMusic.id)}>See all {Number(r.song_translations)} translations of this song →</Link>}
      </div>
    </div>
    {d.appleMusic && <section className="recording-info" aria-label="Apple Music recording">
      <dl>
        <div><dt>Song</dt><dd>{d.appleMusic.title}</dd></div>
        <div><dt>Artist</dt><dd><Link className="album-link" href={songArtistHref(d.appleMusic.id)}>{d.appleMusic.artist}</Link></dd></div>
        {d.appleMusic.album && <div><dt>Album</dt><dd><Link className="album-link" href={songAlbumHref(d.appleMusic.id)}>{d.appleMusic.album}</Link></dd></div>}
        {d.appleMusic.duration != null && <div><dt>Duration</dt><dd>{Math.floor(d.appleMusic.duration / 60)}:{String(Math.floor(d.appleMusic.duration % 60)).padStart(2, '0')}</dd></div>}
      </dl>
      <a href={d.appleMusic.url || `https://music.apple.com/song/${d.appleMusic.id}`} target="_blank" rel="noopener noreferrer">Listen on Apple Music ↗</a>
    </section>}
    <Player initialStarred={starred} initialStars={Number(r.stars)} tokenCount={tokens(d)} usageSummary={d.usageSummary} lines={d.lines} id={id} song={d.appleMusic?.id} title={d.appleMusic?.title} artist={d.appleMusic?.artist}><ShareLines lines={d.lines} target={d.target} title={d.appleMusic?.title || String(r.title)}/></Player>
    <section className="translation-reading" aria-label="Lyrics and translation">
      <div className="translation-columns"><span>LYRICS · {d.target.toUpperCase()} TRANSLATION</span></div>
      <AnalyzedLyrics lines={d.lines} highlighted={[...highlighted]}/>
    </section>
  </main>}
