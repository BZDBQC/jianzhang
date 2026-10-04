import test from 'node:test';
import assert from 'node:assert/strict';
import { parseMoney, summarize, accountBalance, matches, validateLedger, initialLedger, csvExport, removeCategory, categoryTotals } from '../lib/ledger.ts';
import { splitPayload } from '../lib/storage.ts';

const expense = { id:'e', type:'expense', amount:1234, fee:0, date:'2026-10-04T12:30', accountId:'a', toAccountId:'', categoryId:'food-lunch', note:'公司, 午餐', createdAt:'2026-10-04T12:30' };
const income = { ...expense, id:'i', type:'income', amount:10000, categoryId:'salary-main' };
const transfer = { ...expense, id:'t', type:'transfer', amount:25000, fee:234, categoryId:'other-fee', toAccountId:'b' };
test('decimal money has exact cents and rejects unsupported input', () => {
  assert.equal(parseMoney('12.34'),1234); assert.equal(parseMoney('0.10'),10);
  for (const value of ['-1','0','1.234','NaN','1e2','9999999999999']) assert.throws(()=>parseMoney(value));
});
test('transfers and fees preserve balances and avoid duplicate income', () => {
  const tx=[expense,income,transfer];
  assert.deepEqual(summarize(tx),{income:10000,expense:1468,balance:8532,count:3});
  assert.equal(accountBalance({id:'a',openingBalance:100000},tx),83532);
  assert.equal(accountBalance({id:'b',openingBalance:20000},tx),45000);
  assert.equal(accountBalance({id:'a',openingBalance:100000},tx.slice(0,2)),108766);
});
test('combined filters use inclusive ranges and AND across conditions', () => {
  const state=initialLedger();
  const filter={types:['expense'],amountOp:'range',amountMin:'12.34',amountMax:'100',categoryIds:['food'],subIds:['food-lunch'],note:'公司 午餐',noteMode:'all',start:'2026-10-01',end:'2026-10-04',accountIds:['a'],accountMode:'any'};
  assert.equal(matches(expense,filter,state.categories),true);
  assert.equal(matches({...expense,note:'家里 午餐'},filter,state.categories),false);
  assert.equal(matches({...expense,amount:10001},filter,state.categories),false);
  assert.equal(matches(expense,{...filter,amountOp:'gt',amountMin:'12.34'},state.categories),false);
  assert.equal(matches(transfer,{accountIds:['b'],accountMode:'in'},state.categories),true);
  assert.equal(matches(transfer,{accountIds:['b'],accountMode:'out'},state.categories),false);
});
test('backup validation rejects broken references, invalid dates and duplicate IDs', () => {
  const state=initialLedger(); state.accounts=[{id:'a',name:'现金',openingBalance:100000,kind:'cash',archived:false},{id:'b',name:'银行卡',openingBalance:20000,kind:'bank',archived:false}]; state.transactions=[expense,income,transfer];
  state.settings.defaultAccount='a'; assert.doesNotThrow(()=>validateLedger(state));
  for(const tx of [{...expense,accountId:'missing'},{...expense,date:'2026-02-30T10:00'},{...expense,amount:-1},{...expense,categoryId:'salary-main'},{...transfer,toAccountId:'a'}]) assert.throws(()=>validateLedger({...state,transactions:[tx]}));
  assert.throws(()=>validateLedger({...state,transactions:[expense,expense]}));
});
test('category deletion migrates records and removes budgets without orphaning refs', () => {
  const state=initialLedger(); state.accounts=[{id:'a',name:'现金',openingBalance:0,kind:'cash',archived:false}]; state.transactions=[expense]; state.budgets=[{month:'2026-10',categoryId:'food',amount:10000,threshold:80}];
  state.settings.defaultAccount='a'; const next=removeCategory(state,'food','shopping-daily');
  assert.equal(next.transactions[0].categoryId,'shopping-daily'); assert.equal(next.categories.some(c=>c.parentId==='food'),false); assert.equal(next.budgets.length,0); assert.doesNotThrow(()=>validateLedger(next));
  assert.throws(()=>removeCategory(state,'food','salary-main'));
});
test('CSV preserves quoting, chinese notes and neutralizes spreadsheet formulas', () => {
  const state=initialLedger();state.transactions=[{...expense,accountId:'cash',note:'=1+1,\n"中文"'}];
  const csv=csvExport(state.transactions,state);
  assert.ok(csv.startsWith('\uFEFF')); assert.ok(csv.includes("'=1+1,")); assert.ok(csv.includes('""中文""')); assert.ok(csv.includes('12.34'));
});
test('transfer fees survive category migration',()=>{
  const state=initialLedger();state.accounts=[{id:'a',name:'A',kind:'cash',openingBalance:0,archived:false},{id:'b',name:'B',kind:'bank',openingBalance:0,archived:false}];state.settings.defaultAccount='a';state.transactions=[{...transfer,categoryId:'other-fee'}];
  const migrated=removeCategory(state,'other','shopping-daily');validateLedger(migrated);
  assert.equal(categoryTotals(migrated.transactions,migrated).reduce((sum,x)=>sum+x.amount,0),234);
  assert.equal(migrated.transactions[0].categoryId,'shopping-daily');
});
test('large Unicode payload chunks round trip without broken surrogate pairs',()=>{
  const payload='简账🙂'.repeat(300000), chunks=splitPayload(payload);
  assert.equal(chunks.join(''),payload);assert.ok(chunks.length>=10);
  assert.equal(splitPayload('🙂简账🙂',3).join(''),'🙂简账🙂');
  chunks.forEach(c=>assert.ok(new TextEncoder().encode(c).length<500000));
});
