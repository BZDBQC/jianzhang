import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import ts from 'typescript';
import {DatabaseSync} from 'node:sqlite';

fs.mkdirSync('.sites-runtime',{recursive:true});
for (const name of ['auth-core','ledger','native-api-core','native-auth']) {
  const source=fs.readFileSync(`lib/${name}.ts`,'utf8');
  const output=ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.ESNext,
    target:ts.ScriptTarget.ES2022}}).outputText
    .replaceAll("'./auth-core'","'./native-auth-fixture-auth-core.mjs'")
    .replaceAll("'./ledger'","'./native-auth-fixture-ledger.mjs'")
    .replaceAll("'./native-api-core'","'./native-auth-fixture-native-api-core.mjs'")
    .replaceAll("'./phone-auth'","'./native-auth-provider-test.mjs'");
  fs.writeFileSync(`.sites-runtime/native-auth-fixture-${name}.mjs`,output);
}
// Dependency replacement is confined to generated test modules. Production
// SMS configuration and routes contain no test provider or accepted test code.
fs.writeFileSync('.sites-runtime/native-auth-provider-test.mjs',`
export const phoneReady=()=>globalThis.__nativeAuthTest.ready;
export const phoneService=()=>globalThis.__nativeAuthTest.service;
export const authResponse=(data,status=200,cookie)=>Response.json(data,{status,
  headers:{'Cache-Control':'no-store',...(cookie?{'Set-Cookie':cookie}:{})}});
export const authFailure=error=>authResponse({error:error.message,code:error.code},error.status??503);
`);
const {authService}=await import('../.sites-runtime/native-auth-fixture-auth-core.mjs');
const {nativeSend,nativeVerify,nativeSession,nativeLogout}=
  await import('../.sites-runtime/native-auth-fixture-native-auth.mjs');

function fixture() {
  const sql=new DatabaseSync(':memory:');
  sql.exec(fs.readFileSync('drizzle/0001_cuddly_aqueduct.sql','utf8'));
  const db={
    prepare(query){return {query,values:[],bind(...values){this.values=values;return this;},
      async first(){return sql.prepare(query).get(...this.values)??null;},
      async run(){return {meta:{changes:Number(sql.prepare(query).run(...this.values).changes)}};}};},
    async batch(statements){sql.exec('BEGIN');try{const result=statements.map(s=>({meta:
      {changes:Number(sql.prepare(s.query).run(...s.values).changes)}}));sql.exec('COMMIT');return result;}
      catch(error){sql.exec('ROLLBACK');throw error;}},
  };
  const sent=[];
  const service=authService(db,'native-only-unit-test-secret-32-characters',async(phone,code)=>{sent.push({phone,code});});
  globalThis.__nativeAuthTest={ready:true,service};
  return {sql,sent};
}
const endpoint='https://fixture.example/api/native/v1/auth/';
const post=(route,body,headers={})=>new Request(endpoint+route,{method:'POST',
  headers:{'content-type':'application/json',...headers},body:JSON.stringify(body)});

test('blank SMS native endpoints never issue a code or a usable session',async()=>{
  const f=fixture();
  try {
    globalThis.__nativeAuthTest.ready=false;
    for (const [handler,route,body] of [[nativeSend,'send',{phone:'13800138000'}],
      [nativeVerify,'verify',{challengeId:'fixture',code:'000000'}]]) {
      const response=await handler(post(route,body));
      assert.equal(response.status,503);
      assert.equal((await response.json()).code,'SMS_NOT_CONFIGURED');
      assert.equal(response.headers.get('set-cookie'),null);
    }
    assert.equal(f.sent.length,0);
    assert.equal(f.sql.prepare('SELECT COUNT(*) AS n FROM auth_sessions').get().n,0);
    const response=await nativeSession(new Request(endpoint+'session'));
    assert.deepEqual(await response.json(),{user:null,configured:false});
  } finally {f.sql.close();delete globalThis.__nativeAuthTest;}
});

test('native real auth-core flow returns bearer, ignores cookie and revokes session',async()=>{
  const f=fixture();
  try {
    const sent=await nativeSend(post('send',{phone:'13800138000'}));
    assert.equal(sent.status,200);
    const challenge=await sent.json();
    const verified=await nativeVerify(post('verify',{challengeId:challenge.challengeId,code:f.sent[0].code}));
    assert.equal(verified.status,200);
    assert.equal(verified.headers.get('set-cookie'),null);
    assert.equal(verified.headers.get('cache-control'),'no-store');
    const session=await verified.json();
    assert.match(session.token,/^[a-f0-9]{64}$/);
    assert.match(session.user.userId,/^phone:/);
    assert.ok(session.expires>Math.floor(Date.now()/1000));
    const cookie=await nativeSession(new Request(endpoint+'session',{
      headers:{cookie:`__Host-jianzhang-session=${session.token}`}}));
    assert.equal((await cookie.json()).user,null);
    const response=await nativeSession(new Request(endpoint+'session',{
      headers:{authorization:`Bearer ${session.token}`}}));
    assert.deepEqual((await response.json()).user,session.user);
    const replay=await nativeVerify(post('verify',{challengeId:challenge.challengeId,code:f.sent[0].code}));
    assert.equal(replay.status,400);
    assert.equal((await nativeLogout(post('logout',{}, {authorization:`Bearer ${session.token}`}))).status,200);
    const revoked=await nativeSession(new Request(endpoint+'session',{
      headers:{authorization:`Bearer ${session.token}`}}));
    assert.equal((await revoked.json()).user,null);
  } finally {f.sql.close();delete globalThis.__nativeAuthTest;}
});

test('browser Origin cannot access native send or verify even with JSON',async()=>{
  const f=fixture();
  try {
    for (const handler of [nativeSend,nativeVerify]) {
      const response=await handler(post('send',{phone:'13800138000'}, {origin:'https://fixture.example'}));
      assert.equal(response.status,403);
    }
    assert.equal(f.sent.length,0);
  } finally {f.sql.close();delete globalThis.__nativeAuthTest;}
});
