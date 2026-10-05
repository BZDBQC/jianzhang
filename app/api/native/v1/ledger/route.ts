import { nativeUser, nativeResponse, nativeFailure, nativeBody } from '@/lib/native-auth';
import { nativeUpload, CLOUD_BODY_LIMIT } from '@/lib/native-api-core';
import { ledgerDb } from '@/lib/ledger-db';
import { readNativeLedger, writeNativeLedger } from '@/lib/native-ledger-store';

export async function GET(request: Request) {
  try {
    const user = await nativeUser(request);
    if (!user) return nativeResponse({ error: '请先登录云端账号', code: 'UNAUTHENTICATED' }, 401);
    return nativeResponse({ ...await readNativeLedger(ledgerDb(), user.userId), user });
  } catch (error) { return nativeFailure(error); }
}

export async function PUT(request: Request) {
  try {
    const user = await nativeUser(request);
    if (!user) return nativeResponse({ error: '登录已失效，请重新登录；本机账本不受影响', code: 'UNAUTHENTICATED' }, 401);
    const body = await nativeBody(request, CLOUD_BODY_LIMIT);
    let parsed: ReturnType<typeof nativeUpload>;
    try { parsed = nativeUpload(body, user.userId); }
    catch (error) {
      if (error instanceof Error && !('status' in error)) return nativeResponse({ error: error.message, code: 'LEDGER' }, 400);
      throw error;
    }
    return nativeResponse({ revision: await writeNativeLedger(ledgerDb(), user.userId, parsed.ledger, parsed.revision) });
  } catch (error) { return nativeFailure(error); }
}
