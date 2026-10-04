import { authFailure, authResponse, cloudUser, phoneReady } from '@/lib/phone-auth';
export async function GET(request:Request){try{return authResponse({user:await cloudUser(request),smsReady:phoneReady()});}catch(error){return authFailure(error);}}
