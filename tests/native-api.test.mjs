import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import ts from 'typescript';
import { DatabaseSync } from 'node:sqlite';

fs.mkdirSync('.sites-runtime', {recursive: true});
for (const name of ['ledger', 'auth-core', 'storage', 'native-api-core', 'native-ledger-store']) {
  const source = fs.readFileSync(`lib/${name}.ts`, 'utf8');
  const output = ts.transpileModule(source, {compilerOptions: {
    module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2022,
  }}).outputText.replaceAll("'./auth-core'", "'./native-fixture-auth-core.mjs'")
    .replaceAll("'./ledger'", "'./native-fixture-ledger.mjs'")
    .replaceAll("'./storage'", "'./native-fixture-storage.mjs'");
  fs.writeFileSync(`.sites-runtime/native-fixture-${name}.mjs`, output);
}
const {nativeBody, nativeBearer, nativeTransport, nativeUpload} =
  await import('../.sites-runtime/native-fixture-native-api-core.mjs');
const {initialLedger} = await import('../.sites-runtime/native-fixture-ledger.mjs');
const {readNativeLedger,writeNativeLedger} = await import('../.sites-runtime/native-fixture-native-ledger-store.mjs');
const endpoint = 'https://test.example/api/native/v1/ledger';
const request = (body, headers={}) => new Request(endpoint, {
  method: 'PUT', body: JSON.stringify(body), headers: {'content-type': 'application/json', ...headers},
});

test('native API accepts only explicit bearer and rejects browser Origin / insecure transport', () => {
  const token = 'a'.repeat(64);
  assert.equal(nativeBearer(new Request(endpoint, {headers: {authorization:`Bearer ${token}`}})), token);
  assert.equal(nativeBearer(new Request(endpoint, {headers: {cookie:`__Host-jianzhang-session=${token}`}})), '');
  for (const authorization of ['', 'Basic '+token, 'Bearer '+token.toUpperCase(), 'Bearer '+token+' trailing'])
    assert.equal(nativeBearer(new Request(endpoint, {headers:{authorization}})), '');
  assert.throws(() => nativeBearer(new Request(endpoint, {headers:{origin:'https://test.example'}})), e=>e.status===403);
  assert.throws(() => nativeTransport(new Request('http://test.example/api/native/v1/auth/send')), e=>e.status===403);
  nativeTransport(new Request('http://127.0.0.1/api/native/v1/auth/send'));
});

test('JSON byte limit includes envelope / Unicode and stops a streamed oversized request', async () => {
  const body = {note:'中文😀'}, size = new TextEncoder().encode(JSON.stringify(body)).length;
  assert.deepEqual(await nativeBody(request(body), size), body);
  await assert.rejects(nativeBody(request(body),size-1), e=>e.code==='BODY_LIMIT');
  await assert.rejects(nativeBody(request(body, {'content-length':'9000'})), e=>e.code==='BODY_LIMIT');
  await assert.rejects(nativeBody(request(body, {'content-type':'application/jsonx'})), e=>e.code==='BODY');
  for (const bad of [[], null, true, 7]) await assert.rejects(nativeBody(request(bad)), e=>e.code==='BODY');
  let cancelled = false;
  const stream = new ReadableStream({pull(controller){controller.enqueue(new Uint8Array(100));},cancel(){cancelled=true;}});
  await assert.rejects(nativeBody(new Request(endpoint,{method:'PUT',body:stream,duplex:'half',headers:{'content-type':'application/json'}}),99),e=>e.code==='BODY_LIMIT');
  assert.equal(cancelled,true);
});

test('native upload requires account binding, safe revision and the legacy cloud ledger contract', () => {
  const ledger = initialLedger(), body = {ledger, revision:0, expectedUserId:'phone:fixture'};
  assert.deepEqual(nativeUpload(body,'phone:fixture'),{ledger,revision:0});
  for (const expectedUserId of [undefined, '', 'phone:another'])
    assert.throws(()=>nativeUpload({...body,expectedUserId},'phone:fixture'),e=>e.status===409);
  for (const revision of [-1, .5, '0', Number.MAX_SAFE_INTEGER, Infinity])
    assert.throws(()=>nativeUpload({...body,revision},'phone:fixture'),e=>e.code==='REVISION');
  const tooMany = structuredClone(ledger);
  tooMany.transactions = Array.from({length:20001},(_,i)=>({id:`t${i}`}));
  assert.throws(()=>nativeUpload({...body,ledger:tooMany},'phone:fixture'),/数量/);
});

test('old web endpoints retain Cookie / same-origin protection', () => {
  assert.match(fs.readFileSync('lib/phone-auth.ts','utf8'), /get\('origin'\)!==new URL\(request.url\).origin/);
  assert.match(fs.readFileSync('app/api/ledger/route.ts','utf8'), /origin!==new URL\(request.url\).origin/);
  for (const route of ['send','verify','session','logout']) {
    const source = fs.readFileSync(`app/api/native/v1/auth/${route}/route.ts`,'utf8');
    assert.ok(source.includes('@/lib/native-auth'));
  }
});

function databaseFixture() {
  const sql = new DatabaseSync(':memory:');
  sql.exec(fs.readFileSync('drizzle/0000_slim_smasher.sql','utf8'));
  let failChunk = false;
  const run = stmt => {
    if (failChunk && stmt.query.startsWith('INSERT INTO ledger_chunks')) throw Error('simulated full database');
    if (stmt.query.startsWith('SELECT')) return {results:sql.prepare(stmt.query).all(...stmt.values),meta:{changes:0}};
    const result = sql.prepare(stmt.query).run(...stmt.values);
    return {results:[],meta:{changes:Number(result.changes)}};
  };
  const db = {
    prepare(query) { return {query,values:[],bind(...values){this.values=values;return this;},async run(){return run(this);}}; },
    async batch(statements) {
      sql.exec('BEGIN');
      try {const result=statements.map(run);sql.exec('COMMIT');return result;}
      catch(error){sql.exec('ROLLBACK');throw error;}
    },
  };
  return {db,sql,failWrites(value){failChunk=value;}};
}

test('cloud compare-and-swap isolates accounts and conflicts preserve winning chunks', async () => {
  const f = databaseFixture();
  try {
    const original = initialLedger();
    assert.equal(await writeNativeLedger(f.db,'phone:a',original,0),1);
    const changed = structuredClone(original);changed.accounts[0].name='中文账户😀';
    assert.equal(await writeNativeLedger(f.db,'phone:a',changed,1),2);
    await assert.rejects(writeNativeLedger(f.db,'phone:a',original,1),e=>e.status===409);
    assert.deepEqual(await readNativeLedger(f.db,'phone:a'),{ledger:changed,revision:2});
    assert.deepEqual(await readNativeLedger(f.db,'phone:b'),{ledger:original,revision:0});
  } finally {f.sql.close();}
});

test('failed cloud chunk write rolls back metadata, chunk deletion and first-use creation', async () => {
  const f = databaseFixture();
  try {
    const original = initialLedger();
    await writeNativeLedger(f.db,'phone:a',original,0);
    f.failWrites(true);
    await assert.rejects(writeNativeLedger(f.db,'phone:a',original,1),/full/);
    await assert.rejects(writeNativeLedger(f.db,'phone:new',original,0),/full/);
    assert.deepEqual(await readNativeLedger(f.db,'phone:a'),{ledger:original,revision:1});
    assert.equal(f.sql.prepare('SELECT COUNT(*) AS n FROM ledgers WHERE user_id=?').get('phone:new').n,0);
  } finally {f.sql.close();}
});
