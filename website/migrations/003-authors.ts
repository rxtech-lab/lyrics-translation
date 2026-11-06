export default {
  id: '003-authors',
  statements: [
    `CREATE TABLE IF NOT EXISTS authors(owner TEXT PRIMARY KEY, id TEXT NOT NULL UNIQUE DEFAULT (lower(hex(randomblob(16)))), name TEXT NOT NULL DEFAULT 'Community translator')`,
    `INSERT OR IGNORE INTO authors(owner) SELECT DISTINCT owner FROM shares`,
    `CREATE INDEX IF NOT EXISTS shares_owner_created ON shares(owner, created DESC, id DESC)`,
  ],
};
