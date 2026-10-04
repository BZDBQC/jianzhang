import { AuthError, digest, hmac } from './auth-core';
export type SmsConfig={provider:string;secret:string;accessKey:string;accessSecret:string;signName:string;templateCode:string;relayUrl:string;relayToken:string};
export function smsConfig(env:Record<string,string|undefined>):SmsConfig{return {provider:env.SMS_PROVIDER??'',secret:env.AUTH_SECRET??'',accessKey:env.ALIYUN_ACCESS_KEY_ID??'',accessSecret:env.ALIYUN_ACCESS_KEY_SECRET??'',signName:env.ALIYUN_SMS_SIGN_NAME??'',templateCode:env.ALIYUN_SMS_TEMPLATE_CODE??'',relayUrl:env.SMS_RELAY_URL??'',relayToken:env.SMS_RELAY_TOKEN??''};}
export function smsReady(c:SmsConfig){return c.secret.length>=32&&!!c.signName&&!!c.templateCode&&(c.provider==='aliyun'&&!!c.accessKey&&!!c.accessSecret||c.provider==='relay'&&/^https:\/\//.test(c.relayUrl)&&c.relayToken.length>=32);}
const encode=(value:string)=>encodeURIComponent(value).replace(/[!'()*]/g,c=>'%'+c.charCodeAt(0).toString(16).toUpperCase());
export async function aliyunRequest(c:SmsConfig,phone:string,code:string,date=new Date(),nonce=crypto.randomUUID()){
  const params={PhoneNumbers:phone,SignName:c.signName,TemplateCode:c.templateCode,TemplateParam:JSON.stringify({code})};
  const query=Object.entries(params).sort(([a],[b])=>a.localeCompare(b)).map(([k,v])=>`${encode(k)}=${encode(v)}`).join('&');
  const hash=await digest(''),headers:Record<string,string>={host:'dysmsapi.aliyuncs.com','x-acs-action':'SendSms','x-acs-content-sha256':hash,'x-acs-date':date.toISOString().replace(/\.\d{3}Z$/,'Z'),'x-acs-signature-nonce':nonce,'x-acs-version':'2017-05-25'};
  const names=Object.keys(headers).sort(),canonical=names.map(k=>`${k}:${headers[k]}\n`).join(''),signed=names.join(';');
  const request=`POST\n/\n${query}\n${canonical}\n${signed}\n${hash}`;
  const signature=await hmac(c.accessSecret,`ACS3-HMAC-SHA256\n${await digest(request)}`);
  headers.Authorization=`ACS3-HMAC-SHA256 Credential=${c.accessKey},SignedHeaders=${signed},Signature=${signature}`;
  return {url:`https://dysmsapi.aliyuncs.com/?${query}`,headers};
}
export async function sendSms(c:SmsConfig,phone:string,code:string){
  if(!smsReady(c))throw new AuthError('SMS_NOT_CONFIGURED','短信登录暂未启用，仍可直接使用本机账本。',503);
  let res:Response;
  try{
    if(c.provider==='relay')res=await fetch(c.relayUrl,{method:'POST',redirect:'error',signal:AbortSignal.timeout(10000),headers:{'Content-Type':'application/json',Authorization:`Bearer ${c.relayToken}`},body:JSON.stringify({phone,code,signName:c.signName,templateCode:c.templateCode})});
    else{const request=await aliyunRequest(c,phone,code);res=await fetch(request.url,{method:'POST',headers:request.headers,redirect:'error',signal:AbortSignal.timeout(10000)});}
    const data=await res.json() as {Code?:string};
    if(!res.ok||data.Code!=='OK')throw new AuthError('SMS_UNAVAILABLE','短信服务暂不可用，请稍后再试。',res.status===429||data.Code==='isv.BUSINESS_LIMIT_CONTROL'?429:503);
  }catch(error){if(error instanceof AuthError)throw error;throw new AuthError('SMS_UNAVAILABLE','短信提交未确认，请稍后再试；本机记账不受影响。',503);}
}
