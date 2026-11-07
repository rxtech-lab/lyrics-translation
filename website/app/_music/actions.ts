'use server';

import {CatalogUnavailable, getAlbum, storefrontOf, type CatalogSong} from '@/lib/apple-music';
import {songCounts, type SongCount} from '@/lib/db';

export type AlbumSongs = {songs: CatalogSong[]; counts: [string, SongCount][]} | {error: string};

/** Every song on an album with its translation count, loaded when an album row is expanded. */
export async function loadAlbumSongs(id: string, storefront: string): Promise<AlbumSongs> {
  if (!/^\d+$/.test(id)) return {error: 'Album not found'};
  try {
    const album = await getAlbum(id, storefrontOf(storefront));
    if (!album) return {error: 'Album not found'};
    return {songs: album.tracks, counts: [...(await songCounts(album.tracks))]};
  } catch (error) {
    if (error instanceof CatalogUnavailable) return {error: 'Apple Music is unavailable right now. Try again later.'};
    throw error;
  }
}
