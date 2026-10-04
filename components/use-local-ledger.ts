'use client';
import { useCallback, useEffect, useRef, useState } from 'react';
import { toast } from 'sonner';
import { initialLedger, validateLedger, budgetSpent, localDateTime, type Ledger } from '@/lib/ledger';
import { readLocal, readWorkspace, saveLocal, adoptCloud, switchToGuest, backupLedger, localClientId, LocalConflict, type LocalRecord } from '@/lib/local-ledger';
import { type CloudUser } from '@/lib/auth-core';

type CloudSnapshot={ledger:Ledger;revision:number;user:CloudUser};
export type SyncChoice={cloud:CloudSnapshot;local:LocalRecord;cached?:LocalRecord};
export function useLocalLedger(){
  const [s,setS]=useState<Ledger>(initialLedger),[loading,setLoading]=useState(true),[busy,setBusy]=useState(false),[loadError,setLoadError]=useState('');
  const [stale,setStale]=useState(false);
  const [user,setUser]=useState<CloudUser|null>(null),[smsReady,setSmsReady]=useState(false),[loginOpen,setLoginOpen]=useState(false),[choice,setChoice]=useState<SyncChoice|null>(null),[book,setBook]=useState<LocalRecord|null>(null);
  const current=useRef<LocalRecord|null>(null),lock=useRef(false),identity=useRef<CloudUser|null>(null);
  const adopt=useCallback((value:LocalRecord)=>{current.current=value;setBook(value);setS(value.ledger);},[]);
  const load=useCallback(async()=>{setLoading(true);try{adopt(await readLocal());setLoadError('');setStale(false);}catch(error){setLoadError((error as Error).message);}finally{setLoading(false);}},[adopt]);
  const refreshSession=useCallback(async()=>{const response=await fetch('/api/auth/session',{cache:'no-store'});if(!response.ok)throw new Error('暂时无法连接登录服务，本机账本仍可使用。');const data=await response.json() as {user:CloudUser|null;smsReady:boolean};identity.current=data.user;setUser(data.user);setSmsReady(data.smsReady);return data.user;},[]);
  useEffect(()=>{void Promise.resolve().then(load);void Promise.resolve().then(refreshSession).catch(()=>{});const channel=typeof BroadcastChannel==='undefined'?null:new BroadcastChannel('jianzhang-local');if(channel)channel.onmessage=event=>{if(event.data?.sender!==localClientId)setStale(true);};return()=>channel?.close();},[load,refreshSession]);
  useEffect(()=>{const handler=(event:BeforeUnloadEvent)=>{if(lock.current)event.preventDefault();};window.addEventListener('beforeunload',handler);return()=>window.removeEventListener('beforeunload',handler);},[]);
  async function commit(next:Ledger,message='已保存到本机'){
    if(lock.current||!current.current)return false;lock.current=true;setBusy(true);
    const notifications:string[]=[];
    try{
      if(next.settings.notifications){const notified=[...next.settings.notified];for(const b of next.budgets){if(b.month!==localDateTime().slice(0,7))continue;const percent=budgetSpent(b,next)/b.amount*100;for(const threshold of [...new Set([b.threshold,100])]){const key=`${b.month}:${b.categoryId}:${b.amount}:${threshold}`;if(percent>=threshold&&!notified.includes(key)){notified.push(key);notifications.push(`${b.categoryId?next.categories.find(c=>c.id===b.categoryId)?.name:'月度总预算'}已使用 ${Math.round(percent)}%`);}}}next={...next,settings:{...next.settings,notified:notified.slice(-2000)}};}
      adopt(await saveLocal(current.current,next));setLoadError('');toast.success(message);notifications.forEach(n=>toast.warning(n,{duration:7000}));return true;
    }catch(error){
      if(error instanceof LocalConflict){setStale(true);try{const latest=await readLocal();if(latest.key===current.current?.key){adopt(latest);setStale(false);toast.warning('账本已更新并重新读取。输入仍保留，请核对后再次保存。',{duration:9000});return false;}}catch{/* Keep the original form if the latest record cannot be read. */}}
      toast.error((error as Error).message,{duration:7000});return false;
    }finally{lock.current=false;setBusy(false);}
  }
  async function beginSync(){
    if(lock.current||!current.current)return;lock.current=true;setBusy(true);
    try{
      const account=await refreshSession();if(!account){setLoginOpen(true);return;}
      const response=await fetch('/api/ledger',{cache:'no-store'});const cloud=await response.json() as CloudSnapshot&{error?:string};if(!response.ok)throw new Error(cloud.error??'无法读取云端账本');validateLedger(cloud.ledger);
      if(cloud.user.userId!==account.userId)throw new Error('登录账户已改变，请重新同步');
      const cached=await readWorkspace('cloud:'+account.userId);setChoice({cloud,local:current.current,...(cached&&cached.key!==current.current.key?{cached}:{})});
    }catch(error){toast.error((error as Error).message,{duration:7000});}finally{lock.current=false;setBusy(false);}
  }
  async function choose(source:'local'|'cloud'|'cached'){
    if(lock.current||!choice||!current.current)return;lock.current=true;setBusy(true);
    const snapshot=choice,base=snapshot.local;
    try{
      if(current.current.key!==base.key||current.current.sequence!==base.sequence)throw new Error('本机账本已改变，请关闭此窗口后重新同步');
      const account=await refreshSession();if(account?.userId!==snapshot.cloud.user.userId)throw new Error('登录账户已改变，请重新同步');
      const ledger=source==='cloud'?snapshot.cloud.ledger:source==='cached'?snapshot.cached!.ledger:base.ledger;
      let revision=snapshot.cloud.revision;
      if(source!=='cloud'){
        await backupLedger(snapshot.cloud.ledger,'覆盖前云端账本');
        await backupLedger(ledger,'上传前本机账本');
        const response=await fetch('/api/ledger',{method:'PUT',headers:{'Content-Type':'application/json'},body:JSON.stringify({ledger,revision,expectedUserId:account.userId})});
        const data=await response.json() as {revision:number;error?:string};if(!response.ok)throw new Error(data.error??'云端保存失败');revision=data.revision;
      }
      adopt(await adoptCloud(base,'cloud:'+account.userId,{...ledger,started:true},revision));setChoice(null);setLoadError('');toast.success(source==='cloud'?'云端账本已保存到本机':'账本已同步到云端');
    }catch(error){toast.error((error as Error).message+'。两份账本已保留，请关闭选择窗口后重试。',{duration:9000});}finally{lock.current=false;setBusy(false);}
  }
  async function logout(){if(lock.current)return;lock.current=true;setBusy(true);try{const previous=identity.current;const response=await fetch('/api/auth/logout',{method:'POST',headers:{'Content-Type':'application/json'},body:'{}'});if(!response.ok)throw new Error('退出失败，请重试');adopt(await switchToGuest());identity.current=null;setUser(null);setChoice(null);toast.success('已回到本机账本');if(previous?.kind==='chatgpt')window.location.assign(new URL('/signout-with-chatgpt?return_to=%2F',window.location.origin));}catch(error){toast.error((error as Error).message);}finally{lock.current=false;setBusy(false);}}
  return {s,loading,busy,loadError,load,commit,user,smsReady,loginOpen,setLoginOpen,choice,setChoice,beginSync,choose,logout,book,refreshSession,stale};
}
