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

test('XLSX filters XML-forbidden characters while preserving valid Unicode and whitespace',()=>{
  const state=initialLedger();
  const note='中文🙂\t第一行\n第二行\uFFFE\uFFFF\u0001';
  const tx={id:'xml',type:'expense',amount:1234,fee:0,date:'2026-10-04T12:30',createdAt:'2026-10-04T12:30',accountId:'bank',toAccountId:'',categoryId:'food-lunch',note};
  const bytes=xlsxExport([tx],state), view=new DataView(bytes.buffer,bytes.byteOffset,bytes.byteLength);
  let offset=0,sheet='';
  while(view.getUint32(offset,true)===0x04034b50){
    const size=view.getUint32(offset+18,true),nameSize=view.getUint16(offset+26,true),extra=view.getUint16(offset+28,true);
    const path=new TextDecoder().decode(bytes.subarray(offset+30,offset+30+nameSize));
    const start=offset+30+nameSize+extra;
    if(path==='xl/worksheets/sheet1.xml')sheet=new TextDecoder().decode(bytes.subarray(start,start+size));
    offset=start+size;
  }
  assert.ok(sheet.includes('中文🙂\t第一行\n第二行'));
  assert.ok(!/[\uFFFE\uFFFF\u0001]/u.test(sheet));
  fs.writeFileSync('.sites-runtime/unicode-export.xlsx',bytes);
});
