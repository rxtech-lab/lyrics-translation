import usageSummary from '../migrations/004-usage-summary';
import authors from '../migrations/003-authors';
import initial from '../migrations/001-initial';
import publications from '../migrations/002-publications';
import {createClient} from '@libsql/client';
export const db = () => createClient({url: process.env.TURSO_DATABASE_URL || 'file:local.db', authToken:process.env.TURSO_AUTH_TOKEN});
export async function init(){await db().batch([...initial.statements, ...publications.statements, ...authors.statements, ...usageSummary.statements], 'write');}
export async function list(requestedPage = 1, authorID?: string){
  await init();
  const client = db();
  const pageSize = 12;
  const filter = authorID ? ' WHERE shares.owner = (SELECT owner FROM authors WHERE id = ?)' : '';
  const filterArgs = authorID ? [authorID] : [];
  const total = Number((await client.execute({sql: 'SELECT count(*) AS total FROM shares' + filter, args: filterArgs})).rows[0].total);
  const totalPages = Math.max(1, Math.ceil(total / pageSize));
  const page = Math.min(totalPages, Number.isSafeInteger(requestedPage) && requestedPage > 0 ? requestedPage : 1);
  const {rows} = await client.execute({
    sql: `SELECT shares.*, authors.id author_id, authors.name author_name, (SELECT count(*) FROM stars WHERE share=shares.id) stars FROM shares JOIN authors ON authors.owner=shares.owner${filter} ORDER BY shares.created DESC, shares.id DESC LIMIT ? OFFSET ?`,
    args: [...filterArgs, pageSize, (page - 1) * pageSize],
  });
  return {rows, page, pageSize, total, totalPages};
}
export async function get(id:string){await init();return (await db().execute({sql:`SELECT shares.*, authors.id author_id, authors.name author_name, (SELECT count(*) FROM stars WHERE share=shares.id) stars FROM shares JOIN authors ON authors.owner=shares.owner WHERE shares.id=?`,args:[id]})).rows[0];}

export async function getAuthor(id: string) { await init(); return (await db().execute({sql: "SELECT id, name FROM authors WHERE id=?", args: [id]})).rows[0]; }
