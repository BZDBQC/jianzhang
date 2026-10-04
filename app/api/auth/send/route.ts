import { AuthError } from '@/lib/auth-core';
import { authBody, authFailure, authResponse, phoneReady, phoneService } from '@/lib/phone-auth';
export async function POST(request:Request){try{const body=await authBody(request);if(!phoneReady())throw new AuthError('SMS_NOT_CONFIGURED','手机号登录尚未配置短信服务。你的账单可继续保存在本机。',503);return authResponse(await phoneService().send(body.phone,request.headers.get('cf-connecting-ip')??'local'));}catch(error){return authFailure(error);}}
