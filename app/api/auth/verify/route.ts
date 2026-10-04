import { authBody, authFailure, authResponse, phoneService, sessionCookie } from '@/lib/phone-auth';
export async function POST(request:Request){try{const body=await authBody(request),result=await phoneService().verify(body.challengeId,body.code);return authResponse({ok:true},200,sessionCookie(request,result.token,30*86400));}catch(error){return authFailure(error);}}
