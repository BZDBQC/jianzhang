import { AuthError, type CloudUser } from './auth-core';
import { phoneReady, phoneService, authResponse, authFailure } from './phone-auth';
import { nativeBearer, nativeBody, nativeTransport } from './native-api-core';

export { authResponse as nativeResponse, nativeBody };
export function nativeFailure(error: unknown) {
  if (error instanceof AuthError) return authFailure(error);
  return authResponse({ error: '云服务暂时不可用，请继续在本机记账。', code: 'UNAVAILABLE' }, 503);
}
export async function nativeUser(request: Request): Promise<CloudUser | null> {
  const token = nativeBearer(request);
  if (!token || !phoneReady()) return null;
  return phoneService().session(token);
}
export async function nativeSend(request: Request) {
  try {
    const body = await nativeBody(request);
    if (!phoneReady()) throw new AuthError('SMS_NOT_CONFIGURED', '手机号登录尚未配置短信服务。你的账单可继续保存在本机。', 503);
    return authResponse(await phoneService().send(body.phone, request.headers.get('cf-connecting-ip') ?? 'local'));
  } catch (error) { return nativeFailure(error); }
}
export async function nativeVerify(request: Request) {
  try {
    const body = await nativeBody(request);
    if (!phoneReady()) throw new AuthError('SMS_NOT_CONFIGURED', '手机号登录尚未配置短信服务。请继续在本机记账。', 503);
    const service = phoneService();
    const result = await service.verify(body.challengeId, body.code);
    const user = await service.session(result.token);
    if (!user) throw new AuthError('SESSION', '未能建立登录会话', 503);
    return authResponse({ token: result.token, expires: result.expires, user });
  } catch (error) { return nativeFailure(error); }
}
export async function nativeSession(request: Request) {
  try {
    nativeTransport(request);
    const user = await nativeUser(request);
    return authResponse({ user, configured: phoneReady() });
  } catch (error) { return nativeFailure(error); }
}
export async function nativeLogout(request: Request) {
  try {
    await nativeBody(request);
    const token = nativeBearer(request);
    if (token && phoneReady()) await phoneService().logout(token);
    return authResponse({ ok: true });
  } catch (error) { return nativeFailure(error); }
}
