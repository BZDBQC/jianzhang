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
export const authChallenges=sqliteTable('auth_challenges',{
  id:text('id').primaryKey(),phoneHash:text('phone_hash').notNull(),codeHash:text('code_hash').notNull(),phoneMasked:text('phone_masked').notNull(),expiresAt:integer('expires_at').notNull(),attempts:integer('attempts').notNull().default(0),state:text('state').notNull(),consumeToken:text('consume_token').notNull().default(''),
});
export const authSessions=sqliteTable('auth_sessions',{
  tokenHash:text('token_hash').primaryKey(),userId:text('user_id').notNull(),phoneMasked:text('phone_masked').notNull(),expiresAt:integer('expires_at').notNull(),
});
export const authLimits=sqliteTable('auth_limits',{
  key:text('key').primaryKey(),windowStart:integer('window_start').notNull(),count:integer('count').notNull(),expiresAt:integer('expires_at').notNull(),
});
