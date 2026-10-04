import { env } from 'cloudflare:workers';
export function ledgerDb(): D1Database {
  const db=env.DB;
  if(!db)throw new Error('账本数据库暂不可用');
  return db;
}
