import { AuthError } from './auth-core';
import { initialLedger, validateLedger, type Ledger } from './ledger';
import { splitPayload } from './storage';

export async function readNativeLedger(db: D1Database, userId: string) {
  await db.prepare('INSERT OR IGNORE INTO ledgers (user_id, payload, revision, updated_at) VALUES (?, ?, 0, ?)')
    .bind(userId, JSON.stringify(initialLedger()), new Date().toISOString()).run();
  const [metadata, chunks] = await db.batch([
    db.prepare('SELECT payload, revision FROM ledgers WHERE user_id = ?').bind(userId),
    db.prepare('SELECT chunk_index, payload FROM ledger_chunks WHERE user_id = ? ORDER BY chunk_index').bind(userId),
  ]);
  const row = metadata.results[0] as { payload: string; revision: number } | undefined;
  if (!row) throw new Error('Missing ledger');
  const payload = chunks.results.length ? chunks.results.map(r => (r as { payload: string }).payload).join('') : row.payload;
  const ledger: unknown = JSON.parse(payload);
  validateLedger(ledger);
  return { ledger, revision: row.revision };
}

export async function writeNativeLedger(db: D1Database, userId: string, ledger: Ledger, revision: number) {
  const token = crypto.randomUUID(), chunks = splitPayload(JSON.stringify(ledger));
  // First-use creation and compare-and-swap execute atomically with the chunks.
  // The unique write token makes every statement a no-op for a losing writer.
  const [, result] = await db.batch([
    db.prepare('INSERT OR IGNORE INTO ledgers (user_id, payload, revision, updated_at) VALUES (?, ?, 0, ?)')
      .bind(userId, JSON.stringify(initialLedger()), new Date().toISOString()),
    db.prepare('UPDATE ledgers SET payload = ?, revision = revision + 1, updated_at = ?, write_token = ? WHERE user_id = ? AND revision = ?')
      .bind('', new Date().toISOString(), token, userId, revision),
    db.prepare('DELETE FROM ledger_chunks WHERE user_id = ? AND EXISTS (SELECT 1 FROM ledgers WHERE user_id = ? AND write_token = ?)')
      .bind(userId, userId, token),
    ...chunks.map((payload, index) => db.prepare('INSERT INTO ledger_chunks (user_id, chunk_index, payload) SELECT ?, ?, ? WHERE EXISTS (SELECT 1 FROM ledgers WHERE user_id = ? AND write_token = ?)')
      .bind(userId, index, payload, userId, token)),
  ]);
  if (result.meta.changes === 0) throw new AuthError('REVISION_CONFLICT', '云端账本已有新版本。已保留本机内容，请重新选择同步来源。', 409);
  return revision + 1;
}
