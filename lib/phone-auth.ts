import { env } from 'cloudflare:workers';
import { headers } from 'next/headers';
import { getChatGPTUser } from '@/app/chatgpt-auth';
import { ledgerDb } from './ledger-db';
import { authService, AuthError, type CloudUser } from './auth-core';
import { smsConfig, smsReady, sendSms } from './sms';

export const configuration=()=>smsConfig(env as unknown as Record<string,string|undefined>);
export const phoneReady=()=>smsReady(configuration());
export function phoneService(){const config=configuration();if(config.secret.length<32)throw new AuthError('SMS_NOT_CONFIGURED','手机号登录尚未配置，请先在本机记账。',503);return authService(ledgerDb(),config.secret,(phone,code)=>sendSms(config,phone,code));}
function devRequest(request?:Request){if(!request)return false;const url=new URL(request.url);return url.protocol==='http:'&&['localhost','127.0.0.1','[::1]'].includes(url.hostname);}
export function sessionToken(h:Headers,request?:Request){const name=devRequest(request)?'jianzhang-dev-session':'__Host-jianzhang-session';return(h.get('cookie')??'').split(';').map(c=>c.trim()).find(c=>c.startsWith(name+'='))?.slice(name.length+1)??'';}
export async function cloudUser(request?:Request):Promise<CloudUser|null>{
  const h=request?.headers??await headers();
  if(sessionToken(h,request)&&configuration().secret.length>=32){const user=await phoneService().session(sessionToken(h,request));if(user)return user;}
  const user=await getChatGPTUser();return user?{userId:user.userId,name:user.fullName??'我的云端账本',kind:'chatgpt'}:null;
}
export function sessionCookie(request:Request,token:string,maxAge:number){if(new URL(request.url).protocol!=='https:'&&!devRequest(request))throw new AuthError('TRANSPORT','登录需要安全连接',403);const dev=devRequest(request);return `${dev?'jianzhang-dev-session':'__Host-jianzhang-session'}=${token}; Path=/; HttpOnly; SameSite=Lax; Max-Age=${maxAge}${dev?'':'; Secure'}`;}
export async function authBody(request:Request):Promise<Record<string,unknown>>{
  if(request.headers.get('origin')!==new URL(request.url).origin)throw new AuthError('ORIGIN','请求来源无效',403);
  if(!request.headers.get('content-type')?.startsWith('application/json'))throw new AuthError('BODY','请使用 JSON 请求');
  if(Number(request.headers.get('content-length'))>4096)throw new AuthError('BODY','请求过大');
  const text=await request.text();if(new TextEncoder().encode(text).length>4096)throw new AuthError('BODY','请求过大');
  let body:unknown;try{body=JSON.parse(text);}catch{throw new AuthError('BODY','请求格式不正确');}
  if(!body||typeof body!=='object'||Array.isArray(body))throw new AuthError('BODY','请求格式不正确');return body as Record<string,unknown>;
}
export function authResponse(data:unknown,status=200,cookie?:string){return Response.json(data,{status,headers:{'Cache-Control':'no-store',...(cookie?{'Set-Cookie':cookie}:{})}});}
export function authFailure(error:unknown){return error instanceof AuthError?authResponse({error:error.message,code:error.code},error.status):authResponse({error:'登录服务暂时不可用，请继续在本机记账。'},503);}
