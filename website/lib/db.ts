import usageSummary from '../migrations/004-usage-summary';
import songAlbumIndexes from '../migrations/005-song-album-indexes';
import authors from '../migrations/003-authors';
import initial from '../migrations/001-initial';
import publications from '../migrations/002-publications';
import {createClient} from '@libsql/client';
export const db = () => createClient({url: process.env.TURSO_DATABASE_URL || 'file:local.db', authToken:process.env.TURSO_AUTH_TOKEN});
export async function init(){await db().batch([...initial.statements, ...publications.statements, ...authors.statements, ...usageSummary.statements, ...songAlbumIndexes.statements], 'write');}
const pageSize = 12;
const songID = "json_extract(shares.document, '$.appleMusic.id')";
const shareColumns = `shares.*, authors.id author_id, authors.name author_name, (SELECT count(*) FROM stars WHERE share=shares.id) stars,
  (SELECT count(*) FROM shares other WHERE json_extract(other.document, '$.appleMusic.id') = ${songID}) song_translations`;
function pagination(total: number, requestedPage: number) {
  const totalPages = Math.max(1, Math.ceil(total / pageSize));
  const page = Math.min(totalPages, Number.isSafeInteger(requestedPage) && requestedPage > 0 ? requestedPage : 1);
  return {page, pageSize, total, totalPages, offset: (page - 1) * pageSize};
}
export async function list(requestedPage = 1, authorID?: string){
  await init();
  const client = db();
  const filter = authorID ? ' WHERE shares.owner = (SELECT owner FROM authors WHERE id = ?)' : '';
  const filterArgs = authorID ? [authorID] : [];
  const total = Number((await client.execute({sql: 'SELECT count(*) AS total FROM shares' + filter, args: filterArgs})).rows[0].total);
  const {page, totalPages, offset} = pagination(total, requestedPage);
  const {rows} = await client.execute({
    sql: `SELECT ${shareColumns} FROM shares JOIN authors ON authors.owner=shares.owner${filter} ORDER BY shares.created DESC, shares.id DESC LIMIT ? OFFSET ?`,
    args: [...filterArgs, pageSize, offset],
  });
  return {rows, page, pageSize, total, totalPages};
}
export async function get(id:string){await init();return (await db().execute({sql:`SELECT ${shareColumns} FROM shares JOIN authors ON authors.owner=shares.owner WHERE shares.id=?`,args:[id]})).rows[0];}

export async function getAuthor(id: string) { await init(); return (await db().execute({sql: "SELECT id, name FROM authors WHERE id=?", args: [id]})).rows[0]; }

/** Every public translation of one Apple Music song, most liked first. */
export async function songTranslations(song: string, requestedPage = 1) {
  await init();
  const client = db();
  const total = Number((await client.execute({sql: `SELECT count(*) AS total FROM shares WHERE ${songID} = ?`, args: [song]})).rows[0].total);
  const {page, totalPages, offset} = pagination(total, requestedPage);
  const {rows} = await client.execute({
    sql: `SELECT ${shareColumns} FROM shares JOIN authors ON authors.owner=shares.owner WHERE ${songID} = ? ORDER BY stars DESC, shares.created DESC, shares.id DESC LIMIT ? OFFSET ?`,
    args: [song, pageSize, offset],
  });
  return {rows, page, pageSize, total, totalPages};
}

/** Songs of one album that have translations; each song is represented by its most liked translation. */
export async function albumSongs(artist: string, album: string, requestedPage = 1) {
  await init();
  const client = db();
  const where = "json_extract(shares.document, '$.appleMusic.artist') = ? AND json_extract(shares.document, '$.appleMusic.album') = ?";
  const counts = (await client.execute({sql: `SELECT count(DISTINCT ${songID}) songs, count(*) translations FROM shares WHERE ${where}`, args: [artist, album]})).rows[0];
  const total = Number(counts.songs);
  const {page, totalPages, offset} = pagination(total, requestedPage);
  const {rows} = await client.execute({
    sql: `SELECT * FROM (
        SELECT ranked.*, row_number() OVER (PARTITION BY song ORDER BY stars DESC, created DESC, id DESC) song_rank
        FROM (SELECT ${shareColumns}, ${songID} song FROM shares JOIN authors ON authors.owner=shares.owner WHERE ${where}) ranked
      ) WHERE song_rank = 1 ORDER BY lower(json_extract(document, '$.appleMusic.title')), song LIMIT ? OFFSET ?`,
    args: [artist, album, pageSize, offset],
  });
  return {rows, page, pageSize, total, totalPages, translations: Number(counts.translations)};
}

export type SongCount = {translations: number; share: string; song: string};
const normalize = (text: string) => text.normalize('NFKC').toLowerCase().replace(/\s+/g, ' ').trim();
/**
 * Translation counts for catalog songs. A song matches by Apple Music ID, or, because each album
 * edition gives the same recording a new ID, by title and artist. `share` is the most liked
 * translation, used when there is only one; `song` is the ID the translations were saved under.
 */
export async function songCounts(songs: {id: string; name: string; artist: string}[]) {
  const counts = new Map<string, SongCount>();
  const ids = [...new Set(songs.map(s => s.id))].filter(id => /^\d+$/.test(id));
  const artists = [...new Set(songs.map(s => s.artist))];
  if (!ids.length) return counts;
  await init();
  const {rows} = await db().execute({
    sql: `SELECT song, title, artist, translations, id FROM (
        SELECT ${songID} song, json_extract(shares.document, '$.appleMusic.title') title, json_extract(shares.document, '$.appleMusic.artist') artist,
          shares.id, count(*) OVER (PARTITION BY ${songID}) translations,
          row_number() OVER (PARTITION BY ${songID} ORDER BY (SELECT count(*) FROM stars WHERE share=shares.id) DESC, shares.created DESC, shares.id DESC) song_rank
        FROM shares WHERE ${songID} IN (${ids.map(() => '?').join(',')}) OR json_extract(shares.document, '$.appleMusic.artist') IN (${artists.map(() => '?').join(',')})
      ) WHERE song_rank = 1`,
    args: [...ids, ...artists],
  });
  const byID = new Map<string, SongCount>();
  const byName = new Map<string, SongCount>();
  for (const row of rows) {
    const count = {translations: Number(row.translations), share: String(row.id), song: String(row.song)};
    byID.set(count.song, count);
    const key = normalize(String(row.title ?? '')) + '\u0000' + normalize(String(row.artist ?? ''));
    if ((byName.get(key)?.translations ?? 0) < count.translations) byName.set(key, count);
  }
  for (const song of songs) {
    const count = byID.get(song.id) ?? byName.get(normalize(song.name) + '\u0000' + normalize(song.artist));
    if (count) counts.set(song.id, count);
  }
  return counts;
}

/**
 * Translated songs and translations per album name for one artist. Songs credit several artists in one
 * string ("A, B & C"), so the artist matches anywhere in it.
 */
export async function artistAlbumCounts(artist: string) {
  await init();
  const {rows} = await db().execute({
    sql: `SELECT json_extract(document, '$.appleMusic.album') album, count(DISTINCT ${songID}) songs, count(*) translations
      FROM shares WHERE instr(lower(json_extract(document, '$.appleMusic.artist')), lower(?)) > 0 GROUP BY album`,
    args: [artist],
  });
  const albums = new Map<string, {songs: number; translations: number}>();
  let songs = 0, translations = 0;
  for (const row of rows) {
    songs += Number(row.songs); translations += Number(row.translations);
    if (row.album != null) albums.set(String(row.album), {songs: Number(row.songs), translations: Number(row.translations)});
  }
  return {albums, songs, translations};
}

/** Apple Music URL of the newest translation of a song, used to pick its storefront. */
export async function songURL(song: string) {
  await init();
  const row = (await db().execute({sql: `SELECT json_extract(document, '$.appleMusic.url') url FROM shares WHERE ${songID} = ? ORDER BY created DESC LIMIT 1`, args: [song]})).rows[0];
  return row ? {url: row.url == null ? null : String(row.url)} : null;
}
