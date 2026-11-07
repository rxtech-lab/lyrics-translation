/** Page listing every translation of an Apple Music song. */
export const songHref = (song: string) => '/songs/' + encodeURIComponent(song);
/** Page listing the translated songs of one album. Albums are identified by artist and album name. */
export const albumHref = (artist: string, album: string) => '/albums?' + new URLSearchParams({artist, album}).toString();
/** Adds a page number to a path that may already have a query string. */
export const pageHref = (basePath: string, page: number) => basePath + (basePath.includes('?') ? '&' : '?') + 'page=' + page;
/** Redirects to the song's Apple Music album page. */
export const songAlbumHref = (song: string) => songHref(song) + '/album';
/** Redirects to the song's Apple Music artist page. */
export const songArtistHref = (song: string) => songHref(song) + '/artist';
export const catalogAlbumHref = (album: string, storefront = 'us') => '/albums/' + encodeURIComponent(album) + (storefront === 'us' ? '' : '?storefront=' + storefront);
export const catalogArtistHref = (artist: string, storefront = 'us') => '/artists/' + encodeURIComponent(artist) + (storefront === 'us' ? '' : '?storefront=' + storefront);
