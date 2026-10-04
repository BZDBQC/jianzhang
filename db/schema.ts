import { integer, primaryKey, sqliteTable, text } from 'drizzle-orm/sqlite-core';
export const ledgers = sqliteTable('ledgers', {
  userId: text('user_id').primaryKey(),
  payload: text('payload').notNull(),
  revision: integer('revision').notNull().default(0),
  updatedAt: text('updated_at').notNull(),
  writeToken: text('write_token').notNull().default(''),
});
export const ledgerChunks = sqliteTable('ledger_chunks', {
  userId: text('user_id').notNull(),
  chunkIndex: integer('chunk_index').notNull(),
  payload: text('payload').notNull(),
}, table=>[primaryKey({columns:[table.userId,table.chunkIndex]})]);
