// Look up translations by Apple Music song and by album without scanning every document.
export default {
  id: '005-song-album-indexes',
  statements: [
    `CREATE INDEX IF NOT EXISTS shares_song ON shares(json_extract(document, '$.appleMusic.id'))`,
    `CREATE INDEX IF NOT EXISTS shares_album ON shares(json_extract(document, '$.appleMusic.artist'), json_extract(document, '$.appleMusic.album'))`,
    `CREATE INDEX IF NOT EXISTS stars_share ON stars(share)`,
  ],
};
