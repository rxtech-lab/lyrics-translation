/**
 * Public Apple Music catalog lookups. Catalog endpoints only need the developer token,
 * so visitors can browse albums and artists without signing in. The token is limited to
 * the site's origins, so requests send the site origin.
 */
const base = 'https://api.music.apple.com/v1/catalog/';
const day = 86400;

export const storefrontOf = (value?: string | string[] | null) =>
  typeof value === 'string' && /^[a-z]{2}$/.test(value) ? value : 'us';

/** Storefront from a song URL such as https://music.apple.com/jp/album/…; defaults to the US store. */
export const storefrontFromURL = (url?: string | null) => storefrontOf(url?.match(/^https:\/\/music\.apple\.com\/([a-z]{2})\//)?.[1]);

type Artwork = {url: string; width?: number; height?: number};
type Resource<A, R = Record<string, {data: Resource<unknown>[]; next?: string}>> = {id: string; type: string; attributes?: A; relationships?: R};
type SongAttributes = {name: string; artistName: string; albumName?: string; trackNumber?: number; discNumber?: number; durationInMillis?: number; url?: string; artwork?: Artwork};
type AlbumAttributes = {name: string; artistName: string; trackCount?: number; releaseDate?: string; url?: string; artwork?: Artwork; isSingle?: boolean; copyright?: string};
type ArtistAttributes = {name: string; url?: string; artwork?: Artwork; genreNames?: string[]};

export type CatalogSong = {id: string; name: string; artist: string; album?: string; track?: number; disc?: number; duration?: number; url?: string; artwork?: string};
export type CatalogAlbum = {id: string; name: string; artist: string; trackCount: number; released?: string; url?: string; artwork?: string; single: boolean};

export class CatalogUnavailable extends Error {}

async function catalog<T>(path: string): Promise<T | null> {
  const token = process.env.APPLE_MUSIC_DEVELOPER_TOKEN;
  if (!token) throw new CatalogUnavailable('Apple Music is not configured');
  const response = await fetch(base + path, {
    headers: {Authorization: 'Bearer ' + token, Origin: new URL(process.env.SITE_URL || 'http://localhost:3000').origin},
    next: {revalidate: day},
  });
  if (response.status === 404) return null;
  if (!response.ok) throw new CatalogUnavailable('Apple Music request failed (' + response.status + ')');
  return response.json() as Promise<T>;
}

export const artworkURL = (artwork?: Artwork, size = 600) => artwork?.url.replaceAll('{w}', String(size)).replaceAll('{h}', String(size));

const song = (s: Resource<SongAttributes>): CatalogSong => ({
  id: s.id, name: s.attributes!.name, artist: s.attributes!.artistName, album: s.attributes!.albumName,
  track: s.attributes!.trackNumber, disc: s.attributes!.discNumber,
  duration: s.attributes!.durationInMillis == null ? undefined : s.attributes!.durationInMillis / 1000,
  url: s.attributes!.url, artwork: artworkURL(s.attributes!.artwork, 160),
});
const album = (a: Resource<AlbumAttributes>): CatalogAlbum => ({
  id: a.id, name: a.attributes!.name, artist: a.attributes!.artistName, trackCount: a.attributes!.trackCount ?? 0,
  released: a.attributes!.releaseDate, url: a.attributes!.url, artwork: artworkURL(a.attributes!.artwork), single: Boolean(a.attributes!.isSingle),
});

/** The album and primary artist of a song. */
export async function songRelations(id: string, storefront: string) {
  const data = await catalog<{data: Resource<SongAttributes>[]}>(`${storefront}/songs/${encodeURIComponent(id)}?include=albums,artists`);
  const relations = data?.data[0]?.relationships;
  return {albumID: relations?.albums?.data[0]?.id, artistID: relations?.artists?.data[0]?.id};
}

/** An album with its full track list, in disc and track order. */
export async function getAlbum(id: string, storefront: string) {
  const data = await catalog<{data: Resource<AlbumAttributes>[]}>(`${storefront}/albums/${encodeURIComponent(id)}?include=artists`);
  const resource = data?.data[0];
  if (!resource?.attributes) return null;
  const tracks = (resource.relationships?.tracks?.data ?? []) as Resource<SongAttributes>[];
  let next = resource.relationships?.tracks?.next;
  while (next && tracks.length < 600) {
    const page = await catalog<{data: Resource<SongAttributes>[]; next?: string}>(next.replace('/v1/catalog/', ''));
    tracks.push(...(page?.data ?? []));
    next = page?.next;
  }
  return {
    ...album(resource),
    copyright: resource.attributes.copyright,
    artistID: resource.relationships?.artists?.data[0]?.id,
    tracks: tracks.filter(t => t.type === 'songs' && t.attributes).map(song),
  };
}

/** An artist with their top songs and every album and single, newest first. */
export async function getArtist(id: string, storefront: string) {
  const data = await catalog<{data: (Resource<ArtistAttributes> & {views?: Record<string, {data: Resource<SongAttributes>[]}>})[]}>(
    `${storefront}/artists/${encodeURIComponent(id)}?views=top-songs&limit[views:top-songs]=20`);
  const resource = data?.data[0];
  if (!resource?.attributes) return null;
  const albums: CatalogAlbum[] = [];
  let next: string | undefined = `${storefront}/artists/${encodeURIComponent(id)}/albums?limit=100`;
  while (next && albums.length < 1000) {
    const page: {data: Resource<AlbumAttributes>[]; next?: string} | null = await catalog(next);
    albums.push(...(page?.data ?? []).filter(a => a.attributes).map(album));
    next = page?.next ? page.next.replace('/v1/catalog/', '') + '&limit=100' : undefined;
  }
  albums.sort((a, b) => (b.released ?? '').localeCompare(a.released ?? '') || a.name.localeCompare(b.name));
  return {
    id: resource.id, name: resource.attributes.name, url: resource.attributes.url, genres: resource.attributes.genreNames ?? [],
    artwork: artworkURL(resource.attributes.artwork),
    topSongs: (resource.views?.['top-songs']?.data ?? []).filter(s => s.attributes).map(song),
    albums,
  };
}
