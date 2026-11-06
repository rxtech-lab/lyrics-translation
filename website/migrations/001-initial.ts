// Keep applied migrations immutable; add a new numbered migration for changes.
export default {
  id: '001-initial',
  statements: [
    `CREATE TABLE IF NOT EXISTS shares(id TEXT PRIMARY KEY, owner TEXT NOT NULL, title TEXT NOT NULL, document TEXT NOT NULL, created TEXT DEFAULT CURRENT_TIMESTAMP)`,
    `CREATE TABLE IF NOT EXISTS stars(share TEXT NOT NULL REFERENCES shares(id), owner TEXT NOT NULL, PRIMARY KEY(share,owner))`,
  ],
};
