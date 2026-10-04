import { initialLedger, validateLedger, type Ledger } from './ledger';

export type LocalRecord = { key:string; ledger:Ledger; sequence:number; cloudRevision:number|null; dirty:boolean };
export class LocalConflict extends Error { constructor(){super('账本已在另一个窗口更新，请重新读取后再保存；当前输入已保留。');} }
let connection:Promise<IDBDatabase>|undefined;
export const localClientId=typeof window==='undefined'?'server':crypto.randomUUID();
function database(){
  connection??=new Promise<IDBDatabase>((resolve,reject)=>{
    let blocked=false;
    const request=indexedDB.open('jianzhang-local',1);
    request.onupgradeneeded=()=>{const db=request.result;db.createObjectStore('books',{keyPath:'key'});db.createObjectStore('meta');db.createObjectStore('backups',{autoIncrement:true});};
    request.onerror=()=>{connection=undefined;reject(new Error('无法打开本机存储，请允许浏览器保存网站数据。'));};
    request.onsuccess=()=>{if(blocked){request.result.close();return;}request.result.onversionchange=()=>{request.result.close();connection=undefined;};resolve(request.result);};
    request.onblocked=()=>{blocked=true;connection=undefined;reject(new Error('请关闭其他简账窗口后重试。'));};
  });return connection;
}
const result=<T>(request:IDBRequest<T>)=>new Promise<T>((resolve,reject)=>{request.onsuccess=()=>resolve(request.result);request.onerror=()=>reject(request.error);});
function completed(tx:IDBTransaction){const p=new Promise<void>((resolve,reject)=>{tx.oncomplete=()=>resolve();tx.onabort=tx.onerror=()=>reject(tx.error??new Error('本机保存失败，请检查存储空间。'));});void p.catch(()=>{});return p;}
function checked(ledger:Ledger){validateLedger(ledger);if(new TextEncoder().encode(JSON.stringify(ledger)).length>8_000_000)throw new Error('账本超过 8 MB，请先导出备份。');}
const guest=():LocalRecord=>({key:'guest',ledger:{...initialLedger(),started:true},sequence:0,cloudRevision:null,dirty:false});
export async function readLocal():Promise<LocalRecord>{
  const db=await database(),tx=db.transaction(['books','meta'],'readwrite'),done=completed(tx);
  const key=(await result(tx.objectStore('meta').get('active')) as string|undefined)??'guest';
  let book=await result(tx.objectStore('books').get(key)) as LocalRecord|undefined;
  if(!book){book=guest();tx.objectStore('books').put(book);tx.objectStore('meta').put('guest','active');}
  checked(book.ledger);await done;return book;
}
export async function readWorkspace(key:string){const db=await database(),tx=db.transaction('books','readonly'),done=completed(tx);const book=await result(tx.objectStore('books').get(key)) as LocalRecord|undefined;if(book)checked(book.ledger);await done;return book;}
export async function saveLocal(current:LocalRecord,ledger:Ledger):Promise<LocalRecord>{
  checked(ledger);const db=await database(),tx=db.transaction(['books','meta'],'readwrite'),done=completed(tx);
  const stored=await result(tx.objectStore('books').get(current.key)) as LocalRecord|undefined;
  const active=await result(tx.objectStore('meta').get('active'));
  if(!stored||stored.sequence!==current.sequence||active!==current.key){tx.abort();throw new LocalConflict();}
  const next={...stored,ledger,sequence:stored.sequence+1,dirty:stored.key!=='guest'};
  tx.objectStore('books').put(next);await done;announce();return next;
}
export async function adoptCloud(current:LocalRecord,key:string,ledger:Ledger,cloudRevision:number):Promise<LocalRecord>{
  checked(ledger);const db=await database(),tx=db.transaction(['books','meta','backups'],'readwrite'),done=completed(tx);
  const stored=await result(tx.objectStore('books').get(current.key)) as LocalRecord|undefined;
  const active=await result(tx.objectStore('meta').get('active'));
  if(!stored||stored.sequence!==current.sequence||active!==current.key){tx.abort();throw new LocalConflict();}
  const target=await result(tx.objectStore('books').get(key)) as LocalRecord|undefined;
  tx.objectStore('backups').add({date:new Date().toISOString(),label:'同步前本机账本',ledger:stored.ledger});
  if(target&&target.key!==stored.key)tx.objectStore('backups').add({date:new Date().toISOString(),label:'同步前账户账本',ledger:target.ledger});
  const keys=await result(tx.objectStore('backups').getAllKeys());for(const old of keys.slice(0,-10))tx.objectStore('backups').delete(old);
  const next:LocalRecord={key,ledger,sequence:(target?.sequence??0)+1,cloudRevision,dirty:false};
  tx.objectStore('books').put(next);tx.objectStore('meta').put(key,'active');await done;announce();return next;
}
export async function switchToGuest():Promise<LocalRecord>{
  const db=await database(),tx=db.transaction(['books','meta'],'readwrite'),done=completed(tx);
  const next=(await result(tx.objectStore('books').get('guest')) as LocalRecord|undefined)??guest();
  tx.objectStore('books').put(next);tx.objectStore('meta').put('guest','active');await done;announce();return next;
}
export async function syncBackups(){const db=await database(),tx=db.transaction('backups','readonly'),done=completed(tx);const backups=await result(tx.objectStore('backups').getAll()) as {date:string;label:string;ledger:Ledger}[];await done;return backups.reverse();}
export async function backupLedger(ledger:Ledger,label:string){checked(ledger);const db=await database(),tx=db.transaction('backups','readwrite'),done=completed(tx);tx.objectStore('backups').add({date:new Date().toISOString(),label,ledger});const keys=await result(tx.objectStore('backups').getAllKeys());for(const old of keys.slice(0,-10))tx.objectStore('backups').delete(old);await done;}
function announce(){if(typeof BroadcastChannel!=='undefined'){const channel=new BroadcastChannel('jianzhang-local');channel.postMessage({sender:localClientId});channel.close();}}
