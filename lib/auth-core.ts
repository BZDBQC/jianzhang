export type CloudUser={userId:string;name:string;kind:'phone'|'chatgpt'};
export class AuthError extends Error {constructor(public code:string,message:string,public status=400){super(message);}}
const encoder=new TextEncoder();
export const hex=(data:ArrayBuffer)=>Array.from(new Uint8Array(data),n=>n.toString(16).padStart(2,'0')).join('');
export const digest=async(value:string)=>hex(await crypto.subtle.digest('SHA-256',encoder.encode(value)));
export async function hmac(secret:string,value:string){const key=await crypto.subtle.importKey('raw',encoder.encode(secret),{name:'HMAC',hash:'SHA-256'},false,['sign']);return hex(await crypto.subtle.sign('HMAC',key,encoder.encode(value)));}
export function normalizePhone(input:unknown){if(typeof input!=='string')throw new AuthError('INVALID_PHONE','请输入中国大陆手机号');const phone=input.trim().replace(/^\+86[ -]?|^0086[ -]?/,'');if(!/^1[3-9]\d{9}$/.test(phone))throw new AuthError('INVALID_PHONE','请输入有效的中国大陆手机号');return phone;}
export function randomCode(){const max=0x100000000-0x100000000%1000000;let n:number;do{n=crypto.getRandomValues(new Uint32Array(1))[0];}while(n>=max);return String(n%1000000).padStart(6,'0');}
const randomToken=()=>Array.from(crypto.getRandomValues(new Uint8Array(32)),n=>n.toString(16).padStart(2,'0')).join('');
export function authService(db:D1Database,secret:string,sendSms:(phone:string,code:string)=>Promise<void>){
  const phoneHash=(phone:string)=>hmac(secret,'phone:'+phone);
  return {
    async send(input:unknown,ip:string,now=Math.floor(Date.now()/1000)){
      const phone=normalizePhone(input),hash=await phoneHash(phone),ipHash=await hmac(secret,'ip:'+ip),id=crypto.randomUUID(),code=randomCode();
      const limits:[[string,number,number,number],...Array<[string,number,number,number]>]=[
        [`cool:${hash}`,now,1,60],[`hour:${hash}:${Math.floor(now/3600)}`,Math.floor(now/3600)*3600,5,3600],
        [`day:${hash}:${Math.floor(now/86400)}`,Math.floor(now/86400)*86400,10,86400],[`ip:${ipHash}:${Math.floor(now/3600)}`,Math.floor(now/3600)*3600,20,3600],
      ];
      const [cool,...windows]=limits;
      const reservations=await db.batch([
        db.prepare('INSERT INTO auth_limits (key, window_start, count, expires_at) VALUES (?, ?, 1, ?) ON CONFLICT(key) DO UPDATE SET window_start=excluded.window_start,count=1,expires_at=excluded.expires_at WHERE auth_limits.window_start <= ?').bind(cool[0],now,now+86400,now-60),
        ...windows.map(([key,start,max,size])=>db.prepare('INSERT INTO auth_limits (key, window_start, count, expires_at) VALUES (?, ?, 1, ?) ON CONFLICT(key) DO UPDATE SET count=count+1 WHERE count < ?').bind(key,start,start+size+86400,max)),
      ]);
      if(reservations.some(r=>r.meta.changes!==1))throw new AuthError('RATE_LIMIT','发送过于频繁，请稍后再试',429);
      const day=Math.floor(now/86400)*86400;
      const global=await db.prepare('INSERT INTO auth_limits (key, window_start, count, expires_at) VALUES (?, ?, 1, ?) ON CONFLICT(key) DO UPDATE SET count=count+1 WHERE count < 100').bind(`global:${Math.floor(now/86400)}`,day,day+2*86400).run();
      if(global.meta.changes!==1)throw new AuthError('RATE_LIMIT','短信发送达到每日上限，请明日重试',429);
      await db.prepare('INSERT INTO auth_challenges (id, phone_hash, code_hash, phone_masked, expires_at, attempts, state, consume_token) VALUES (?, ?, ?, ?, ?, 0, ?, ?)').bind(id,hash,await hmac(secret,`${id}:${hash}:${code}`),phone.slice(0,3)+'****'+phone.slice(-4),now+300,'sending','').run();
      await sendSms(phone,code);
      await db.batch([
        db.prepare('UPDATE auth_challenges SET state=? WHERE phone_hash=? AND id<>? AND state=?').bind('invalid',hash,id,'ready'),
        db.prepare('UPDATE auth_challenges SET state=? WHERE id=? AND state=?').bind('ready',id,'sending'),
        db.prepare('DELETE FROM auth_challenges WHERE expires_at < ?').bind(now-86400),
        db.prepare('DELETE FROM auth_limits WHERE expires_at < ?').bind(now),
        db.prepare('DELETE FROM auth_sessions WHERE expires_at < ?').bind(now),
      ]);
      return {challengeId:id,retryAfter:60,expiresIn:300};
    },
    async verify(id:unknown,code:unknown,now=Math.floor(Date.now()/1000)){
      if(typeof id!=='string'||!/^[-a-f0-9]{36}$/.test(id)||typeof code!=='string'||!/^\d{6}$/.test(code))throw new AuthError('INVALID_CODE','请输入六位短信验证码');
      const challenge=await db.prepare('SELECT phone_hash FROM auth_challenges WHERE id=?').bind(id).first<{phone_hash:string}>();
      if(!challenge)throw new AuthError('INVALID_CODE','验证码错误或已过期');
      const proof=await hmac(secret,`${id}:${challenge.phone_hash}:${code}`),consume=crypto.randomUUID(),token=randomToken(),tokenHash=await digest(token),expires=now+30*86400;
      const [,saved]=await db.batch([
        db.prepare("UPDATE auth_challenges SET attempts=attempts+1,state=CASE WHEN code_hash=? THEN 'consumed' ELSE state END,consume_token=CASE WHEN code_hash=? THEN ? ELSE consume_token END WHERE id=? AND state='ready' AND expires_at>? AND attempts<5").bind(proof,proof,consume,id,now),
        db.prepare("INSERT INTO auth_sessions (token_hash,user_id,phone_masked,expires_at) SELECT ?, 'phone:'||phone_hash,phone_masked,? FROM auth_challenges WHERE id=? AND consume_token=? AND state='consumed'").bind(tokenHash,expires,id,consume),
      ]);
      if(saved.meta.changes!==1)throw new AuthError('INVALID_CODE','验证码错误、已过期或尝试次数过多');
      return {token,expires};
    },
    async session(token:string,now=Math.floor(Date.now()/1000)):Promise<CloudUser|null>{
      if(!/^[a-f0-9]{64}$/.test(token))return null;
      const session=await db.prepare('SELECT user_id,phone_masked FROM auth_sessions WHERE token_hash=? AND expires_at>?').bind(await digest(token),now).first<{user_id:string;phone_masked:string}>();
      return session?{userId:session.user_id,name:session.phone_masked,kind:'phone'}:null;
    },
    async logout(token:string){if(/^[a-f0-9]{64}$/.test(token))await db.prepare('DELETE FROM auth_sessions WHERE token_hash=?').bind(await digest(token)).run();},
  };
}
