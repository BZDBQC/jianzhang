import { getChatGPTUser } from '@/app/chatgpt-auth';
import { initialLedger, validateLedger } from '@/lib/ledger';
import { ledgerDb } from '@/lib/ledger-db';
import { splitPayload } from '@/lib/storage';
const response=(data:unknown,status=200)=>Response.json(data,{status,headers:{'Cache-Control':'no-store'}});
export async function GET() {
  const user=await getChatGPTUser();
  if(!user)return response({error:'请先登录'},401);
  try {
    const db=ledgerDb();
    await db.prepare('INSERT OR IGNORE INTO ledgers (user_id, payload, revision, updated_at) VALUES (?, ?, 0, ?)').bind(user.userId,JSON.stringify(initialLedger()),new Date().toISOString()).run();
    const [metadata,chunks]=await db.batch([
      db.prepare('SELECT payload, revision FROM ledgers WHERE user_id = ?').bind(user.userId),
      db.prepare('SELECT chunk_index, payload FROM ledger_chunks WHERE user_id = ? ORDER BY chunk_index').bind(user.userId),
    ]);
    const row=metadata.results[0] as {payload:string;revision:number}|undefined;
    if(!row)throw new Error('账本读取失败');
    const payload=chunks.results.length?chunks.results.map(r=>(r as {payload:string}).payload).join(''):row.payload;
    return response({ledger:JSON.parse(payload),revision:row.revision,user:{name:user.fullName??'我的账本'}});
  } catch(error) {console.error('ledger-load',error);return response({error:'暂时无法读取账本，请稍后重试'},503);}
}
export async function PUT(request: Request) {
  const user=await getChatGPTUser();
  if(!user)return response({error:'登录已失效，请重新登录'},401);
  const origin=request.headers.get('origin');
  if(!origin||origin!==new URL(request.url).origin)return response({error:'请求来源无效'},403);
  let body: {ledger:unknown;revision:number};
  try {
    if(Number(request.headers.get('content-length'))>8_000_000)throw new Error('数据过大');
    const raw=await request.text();if(new TextEncoder().encode(raw).byteLength>8_000_000)throw new Error('账本数据不能超过 8 MB，请先导出旧账单');
    body=JSON.parse(raw);
    if(!Number.isSafeInteger(body.revision)||body.revision<0)throw new Error('版本号无效');
    validateLedger(body.ledger);
  } catch(error) {return response({error:error instanceof Error?error.message:'数据格式不正确'},400);}
  try {
    const db=ledgerDb(),token=crypto.randomUUID(),chunks=splitPayload(JSON.stringify(body.ledger));
    const statements=[
      db.prepare('UPDATE ledgers SET payload = ?, revision = revision + 1, updated_at = ?, write_token = ? WHERE user_id = ? AND revision = ?').bind('',new Date().toISOString(),token,user.userId,body.revision),
      db.prepare('DELETE FROM ledger_chunks WHERE user_id = ? AND EXISTS (SELECT 1 FROM ledgers WHERE user_id = ? AND write_token = ?)').bind(user.userId,user.userId,token),
      ...chunks.map((payload,index)=>db.prepare('INSERT INTO ledger_chunks (user_id, chunk_index, payload) SELECT ?, ?, ? WHERE EXISTS (SELECT 1 FROM ledgers WHERE user_id = ? AND write_token = ?)').bind(user.userId,index,payload,user.userId,token)),
    ];
    const [result]=await db.batch(statements);
    if(result.meta.changes===0)return response({error:'账本已在其他页面更新，请刷新后再保存'},409);
    return response({revision:body.revision+1});
  } catch(error) {console.error('ledger-save',error);return response({error:'保存失败，请检查网络后重试'},503);}
}
