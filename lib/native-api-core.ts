import { AuthError } from './auth-core';
import { validateLedger, type Ledger } from './ledger';

export const CLOUD_BODY_LIMIT = 8_000_000;

// Native clients authenticate exclusively with an explicit bearer token. Cookies
// and browser origins are deliberately not accepted by this separate API.
export function nativeTransport(request: Request) {
  const url = new URL(request.url);
  const loopback = url.protocol === 'http:' && ['localhost', '127.0.0.1', '[::1]'].includes(url.hostname);
  if (url.protocol !== 'https:' && !loopback) throw new AuthError('TRANSPORT', '登录和同步需要安全连接', 403);
  if (request.headers.has('origin')) throw new AuthError('ORIGIN', '请使用简账客户端接口', 403);
}

export function nativeBearer(request: Request) {
  nativeTransport(request);
  const header = request.headers.get('authorization') ?? '';
  const match = /^Bearer ([a-f0-9]{64})$/.exec(header);
  return match?.[1] ?? '';
}

export async function nativeBody(request: Request, limit = 4096): Promise<Record<string, unknown>> {
  nativeTransport(request);
  if ((request.headers.get('content-type') ?? '').split(';')[0].trim().toLowerCase() !== 'application/json') {
    throw new AuthError('BODY', '请使用 JSON 请求');
  }
  const length = request.headers.get('content-length');
  if (length !== null && (!/^\d+$/.test(length) || Number(length) > limit)) throw new AuthError('BODY_LIMIT', '数据超过上传限制');
  const reader = request.body?.getReader();
  if (!reader) throw new AuthError('BODY', '请求格式不正确');
  const chunks: Uint8Array[] = [];
  let size = 0;
  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > limit) {
        await reader.cancel();
        throw new AuthError('BODY_LIMIT', '云端请求不能超过 8 MB，本机账本仍可使用和导出');
      }
      chunks.push(value);
    }
  } finally { reader.releaseLock(); }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
  let body: unknown;
  try { body = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes)); }
  catch { throw new AuthError('BODY', '请求格式不正确'); }
  if (!body || typeof body !== 'object' || Array.isArray(body)) throw new AuthError('BODY', '请求格式不正确');
  return body as Record<string, unknown>;
}

export function nativeUpload(body: Record<string, unknown>, userId: string): { ledger: Ledger; revision: number } {
  if (body.expectedUserId !== userId) throw new AuthError('ACCOUNT_CONFLICT', '云端账户已改变，请重新选择同步账本', 409);
  if (typeof body.revision !== 'number' || !Number.isSafeInteger(body.revision) || body.revision < 0 || body.revision >= Number.MAX_SAFE_INTEGER) {
    throw new AuthError('REVISION', '版本号无效');
  }
  validateLedger(body.ledger);
  return { ledger: body.ledger, revision: body.revision };
}
