import usageSummary from '../migrations/004-usage-summary';
import { createClient } from '@libsql/client';
import { createHash } from 'node:crypto';
import authors from '../migrations/003-authors';
import initial from '../migrations/001-initial';
import publications from '../migrations/002-publications';

// Bun loads .env.local automatically. Require an explicit target to avoid
// accidentally migrating a local file when production configuration is missing.
const url = process.env.TURSO_DATABASE_URL;
if (!url) throw new Error('Set TURSO_DATABASE_URL in .env.local or the environment. Use file:local.db for local development.');
const client = createClient({ url, authToken: process.env.TURSO_AUTH_TOKEN });
try {
  await client.execute(`CREATE TABLE IF NOT EXISTS schema_migrations (
    id TEXT PRIMARY KEY, checksum TEXT NOT NULL, applied_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
  )`);
  for (const migration of [initial, publications, authors, usageSummary]) {
    const checksum = createHash('sha256').update(JSON.stringify(migration.statements)).digest('hex');
    const tx = await client.transaction('write');
    try {
      const result = await tx.execute({ sql: 'SELECT checksum FROM schema_migrations WHERE id = ?', args: [migration.id] });
      if (result.rows.length) {
        if (result.rows[0].checksum !== checksum) throw new Error(`Applied migration ${migration.id} was modified. Add a new migration instead.`);
        await tx.commit();
        console.log(`Already applied: ${migration.id}`);
        continue;
      }
      for (const sql of migration.statements) await tx.execute(sql);
      await tx.execute({ sql: 'INSERT INTO schema_migrations(id, checksum) VALUES (?, ?)', args: [migration.id, checksum] });
      await tx.commit();
      console.log(`Applied: ${migration.id}`);
    } catch (error) {
      await tx.rollback();
      throw error;
    } finally {
      tx.close();
    }
  }
  console.log('Database migrations complete.');
} finally {
  client.close();
}
