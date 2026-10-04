import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import ts from 'typescript';
import {initialLedger} from '../lib/ledger.ts';

fs.mkdirSync('.sites-runtime',{recursive:true});
const source=fs.readFileSync('lib/xlsx.ts','utf8');
const compiled=ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.ESNext,target:ts.ScriptTarget.ES2022}}).outputText.replace("'./ledger'","'../lib/ledger.ts'");
fs.writeFileSync('.sites-runtime/xlsx-test.mjs',compiled);
const {xlsxExport}=await import('../.sites-runtime/xlsx-test.mjs');
test('XLSX exports numeric amounts and original formula-like remarks as strings',()=>{
  const state=initialLedger();state.transactions=[{id:'test',type:'expense',amount:1234,fee:0,date:'2026-10-04T12:30',createdAt:'2026-10-04T12:30',accountId:'bank',toAccountId:'',categoryId:'food-lunch',note:'=1+1,中文\n"引号"'}];
  const bytes=xlsxExport(state.transactions,state);assert.equal(new DataView(bytes.buffer).getUint32(0,true),0x04034b50);
  const text=new TextDecoder().decode(bytes);assert.ok(text.includes('<v>12.34</v>'));assert.ok(text.includes('=1+1,中文'));assert.ok(!text.includes("'=1+1"));assert.ok(text.includes('&quot;引号&quot;'));assert.ok(text.includes('t="inlineStr"'));
  fs.writeFileSync('.sites-runtime/test.xlsx',bytes);
});
