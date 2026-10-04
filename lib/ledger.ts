export type EntryType = 'expense' | 'income' | 'transfer';
export type Account = { id: string; name: string; kind: string; openingBalance: number; archived: boolean };
export type Category = { id: string; name: string; type: 'expense' | 'income'; parentId: string | null; icon: string; color: string };
export type Transaction = { id: string; type: EntryType; amount: number; fee: number; date: string; accountId: string; toAccountId: string; categoryId: string; note: string; createdAt: string };
export type Budget = { month: string; categoryId: string; amount: number; threshold: number };
export type Ledger = { version: 1; started: boolean; accounts: Account[]; categories: Category[]; transactions: Transaction[]; budgets: Budget[]; settings: { defaultAccount: string; notifications: boolean; notified: string[] } };
export type Filter = { types?: string[]; includeFees?: boolean; amountOp?: string; amountMin?: string; amountMax?: string; categoryIds?: string[]; subIds?: string[]; note?: string; noteMode?: string; start?: string; end?: string; accountIds?: string[]; accountMode?: string };
export const palette = ['#397665','#7d94b5','#c59868','#9d88a9','#6d9a99','#b5a36e','#a27d7d','#779184'];
export const typeLabels: Record<EntryType,string> = { expense:'支出', income:'收入', transfer:'转账' };
export const money = (cents: number) => (cents / 100).toLocaleString('zh-CN', { minimumFractionDigits:2, maximumFractionDigits:2 });
export function localDateTime(date=new Date()) { return new Date(date.getTime()-date.getTimezoneOffset()*60000).toISOString().slice(0,16); }
export function parseMoney(value: string, zero=false): number {
  if (!/^\d{1,9}(\.\d{1,2})?$/.test(value.trim())) throw new Error('请输入有效金额，最多两位小数');
  const [whole, decimal=''] = value.trim().split('.');
  const cents=Number(whole)*100+Number(decimal.padEnd(2,'0'));
  if(!Number.isSafeInteger(cents)||cents<0||(!zero&&cents===0)) throw new Error('金额必须大于零');
  return cents;
}
const groups: [string,string,string,string[]][] = [
  ['food','餐饮','Utensils',['早餐','午餐','晚餐','饮品','聚餐']],
  ['transport','交通','TramFront',['公共交通','打车','燃油','停车','长途出行']],
  ['shopping','购物','ShoppingBag',['日用品','服饰','数码','家居']],
  ['home','居住','House',['房租','房贷','水电燃气','物业','维修']],
  ['fun','休闲娱乐','Headphones',['影音','游戏','运动','旅行']],
  ['health','医疗健康','HeartPulse',['门诊','药品','体检']],
  ['study','学习成长','BookOpen',['书籍','课程','考试']],
  ['social','人情往来','Gift',['礼物','红包','请客']],
  ['other','其他支出','Ellipsis',['手续费','未分类']],
];
const childIds: Record<string,string[]>={food:['breakfast','lunch','dinner','drink','gather'],shopping:['daily','clothes','digital','furniture'],other:['fee','uncategorized']};
export function initialLedger(): Ledger {
  const categories: Category[]=[];
  groups.forEach(([id,name,icon,children],i)=>{
    categories.push({id,name,type:'expense',parentId:null,icon,color:palette[i%palette.length]});
    children.forEach((name,j)=>categories.push({id:`${id}-${childIds[id]?.[j]??j}`,name,type:'expense',parentId:id,icon,color:palette[i%palette.length]}));
  });
  const incomeGroups: [string,string,string[]][]=[['salary','工作收入',['工资','奖金','补贴']],['side','副业收入',['接单','兼职','稿费']],['invest','投资收益',['利息','分红','投资盈利']],['income-other','其他收入',['礼金','补助','未分类']]];
  incomeGroups.forEach(([id,name,children],i)=>{
    categories.push({id,name,type:'income',parentId:null,icon:'Wallet',color:palette[i]});
    children.forEach((name,j)=>categories.push({id:`${id}-${j===0&&id==='salary'?'main':j}`,name,type:'income',parentId:id,icon:'Wallet',color:palette[i]}));
  });
  return {version:1,started:false,accounts:[{id:'cash',name:'现金',kind:'cash',openingBalance:0,archived:false},{id:'bank',name:'银行卡',kind:'bank',openingBalance:0,archived:false},{id:'wechat',name:'微信钱包',kind:'wallet',openingBalance:0,archived:false}],categories,transactions:[],budgets:[],settings:{defaultAccount:'bank',notifications:true,notified:[]}};
}
export function demoLedger(month: string): Ledger {
  const s=initialLedger(); s.started=true;
  s.accounts=[{id:'bank',name:'招商银行卡',kind:'bank',openingBalance:320000,archived:false},{id:'wechat',name:'微信钱包',kind:'wallet',openingBalance:68000,archived:false},{id:'cash',name:'现金',kind:'cash',openingBalance:30000,archived:false}];
  const items: [EntryType,number,string,string,string,number][] = [
    ['income',1280000,'salary-main','bank','本月工资',1],['expense',260000,'home-0','bank','每月固定房租',1],
    ['expense',36000,'shopping-clothes','bank','换季的新衣服',2],['expense',8800,'fun-0','wechat','周末看场电影',2],
    ['expense',6500,'food-dinner','wechat','和朋友吃晚餐',2],['expense',3800,'food-lunch','wechat','公司附近的午餐',3],
    ['expense',6800,'study-0','bank','读完一本新书',3],['expense',2800,'transport-1','wechat','下雨天打车回家',3],
    ['expense',2400,'food-drink','wechat','一杯拿铁',4],['expense',8600,'shopping-daily','wechat','补充日常用品',4],
    ['expense',3200,'food-lunch','wechat','午餐 · 简单吃一点',4],['transfer',50000,'','bank','转入日常零钱',4],
  ];
  s.transactions=items.map(([type,amount,categoryId,accountId,note,day],i)=>({id:`demo-${i}`,type,amount,fee:0,categoryId,accountId,toAccountId:type==='transfer'?'wechat':'',date:`${month}-${String(day).padStart(2,'0')}T${i===10?'12:30':'09:00'}`,note,createdAt:`${month}-01T09:00`}));
  s.budgets=[{month,categoryId:'',amount:600000,threshold:80},{month,categoryId:'food',amount:150000,threshold:80},{month,categoryId:'shopping',amount:100000,threshold:80},{month,categoryId:'home',amount:300000,threshold:80}];
  return s;
}
export function summarize(tx: Transaction[]) {
  let income=0, expense=0;
  tx.forEach(t=>{if(t.type==='income')income+=t.amount;else if(t.type==='expense')expense+=t.amount;else expense+=t.fee;});
  return {income,expense,balance:income-expense,count:tx.length};
}
export function accountBalance(a: Pick<Account,'id'|'openingBalance'>, tx: Transaction[]) {
  return tx.reduce((balance,t)=>balance+(t.accountId===a.id?(t.type==='income'?t.amount:-t.amount-(t.type==='transfer'?t.fee:0)):0)+(t.type==='transfer'&&t.toAccountId===a.id?t.amount:0),a.openingBalance);
}
export function categoryOf(t: Transaction,s: Ledger) { return s.categories.find(c=>c.id===t.categoryId); }
export function parentOf(t: Transaction,s: Ledger) { const c=categoryOf(t,s); return s.categories.find(p=>p.id===c?.parentId); }
export function matches(t: Transaction,f: Filter,categories: Category[]) {
  const feeOnly=!!f.includeFees&&t.type==='transfer'&&t.fee>0&&!!f.types?.includes('expense')&&!f.types.includes('transfer');
  if(f.types?.length&&!f.types.includes(t.type)&&!feeOnly)return false;
  const day=t.date.slice(0,10);
  if(f.start&&day<f.start||f.end&&day>f.end)return false;
  const category=categories.find(c=>c.id===t.categoryId);
  if(f.categoryIds?.length&&!f.categoryIds.includes(category?.parentId??''))return false;
  if(f.subIds?.length) {
    const selectedParents=new Set(f.subIds.map(id=>categories.find(c=>c.id===id)?.parentId));
    if(selectedParents.has(category?.parentId)&&!f.subIds.includes(t.categoryId))return false;
    if(!f.categoryIds?.length&&!f.subIds.includes(t.categoryId))return false;
  }
  if(f.accountIds?.length) {
    const out=f.accountIds.includes(t.accountId), incoming=!feeOnly&&t.type==='transfer'&&f.accountIds.includes(t.toAccountId);
    if(f.accountMode==='out'?!out:f.accountMode==='in'?!incoming:!out&&!incoming)return false;
  }
  if(f.note?.trim()) {
    const words=f.note.toLowerCase().trim().split(/\s+/), note=t.note.toLowerCase();
    if(f.noteMode==='any'?!words.some(w=>note.includes(w)):!words.every(w=>note.includes(w)))return false;
  }
  if(f.amountOp&&f.amountMin?.trim()) {
    const min=parseMoney(f.amountMin,true);
    const amount=feeOnly?t.fee:t.amount;
    if(f.amountOp==='eq'&&amount!==min||f.amountOp==='gt'&&amount<=min||f.amountOp==='lt'&&amount>=min)return false;
    if(f.amountOp==='range'&&(amount<min||f.amountMax?.trim()&&amount>parseMoney(f.amountMax,true)))return false;
  }
  return true;
}
export function categoryTotals(tx: Transaction[],s: Ledger,type: 'expense'|'income'='expense') {
  const amounts=new Map<string,number>();
  tx.forEach(t=>{
    const id=t.type===type?parentOf(t,s)?.id:t.type==='transfer'&&type==='expense'&&t.fee?(parentOf(t,s)?.id??(s.categories.find(c=>c.id==='other')?.id??s.categories.find(c=>c.type==='expense'&&!c.parentId)?.id)):undefined;
    if(id)amounts.set(id,(amounts.get(id)??0)+(t.type==='transfer'?t.fee:t.amount));
  });
  return [...amounts].map(([id,amount])=>({category:s.categories.find(c=>c.id===id)!,amount})).filter(x=>x.category).sort((a,b)=>b.amount-a.amount);
}
export function budgetSpent(b: Budget,s: Ledger) {
  const tx=s.transactions.filter(t=>t.date.startsWith(b.month));
  return b.categoryId?categoryTotals(tx,s).find(x=>x.category.id===b.categoryId)?.amount??0:summarize(tx).expense;
}
export function removeCategory(s: Ledger,id: string,targetId: string): Ledger {
  const removed=s.categories.find(c=>c.id===id), target=s.categories.find(c=>c.id===targetId);
  if(!removed)throw new Error('分类不存在');
  const ids=new Set([id,...s.categories.filter(c=>c.parentId===id).map(c=>c.id)]);
  const fallbackFee=s.categories.find(c=>c.id==='other-fee')?.id??s.categories.find(c=>c.type==='expense'&&c.parentId)?.id??'';
  const effectiveCategory=(t:Transaction)=>t.categoryId||(t.type==='transfer'&&t.fee>0?fallbackFee:'');
  const used=s.transactions.some(t=>ids.has(effectiveCategory(t)));
  if(used&&(!target||!target.parentId||target.type!==removed.type||ids.has(target.id)))throw new Error('请选择同类型的其他小类迁移历史账单');
  return {...s,categories:s.categories.filter(c=>!ids.has(c.id)),transactions:s.transactions.map(t=>ids.has(effectiveCategory(t))?{...t,categoryId:targetId}:t),budgets:s.budgets.filter(b=>!ids.has(b.categoryId))};
}
function safeCell(value: unknown) { const v=String(value??'');return /^[\s]*[=+\-@]/.test(v)?`'${v}`:v; }
export function exportRows(tx: Transaction[],s: Ledger) {
  return tx.map(t=>[typeLabels[t.type],t.amount/100,t.date.replace('T',' '),parentOf(t,s)?.name??'',categoryOf(t,s)?.name??'',s.accounts.find(a=>a.id===t.accountId)?.name??'',t.type==='transfer'?s.accounts.find(a=>a.id===t.toAccountId)?.name??'':'',t.fee/100,t.note]);
}
export const exportHeaders=['类型','金额（元）','日期时间','大类','小类','账户 / 转出账户','转入账户','手续费（元）','备注'];
export function csvExport(tx: Transaction[],s: Ledger) {
  return '\uFEFF'+[exportHeaders,...exportRows(tx,s)].map(row=>row.map(cell=>`"${safeCell(cell).replace(/"/g,'""')}"`).join(',')).join('\r\n');
}
function fail(message: string): never { throw new Error(message); }
function validDate(value: unknown) {
  if(typeof value!=='string'||!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/.test(value))return false;
  const [d,time]=value.split('T'),parts=d.split('-').map(Number),parsed=new Date(`${d}T${time}:00Z`);
  return Number.isFinite(parsed.getTime())&&parsed.getUTCFullYear()===parts[0]&&parsed.getUTCMonth()+1===parts[1]&&parsed.getUTCDate()===parts[2];
}
export function validateLedger(raw: unknown): asserts raw is Ledger {
  if(!raw||typeof raw!=='object')fail('备份格式不正确');
  const s=raw as Ledger;
  if(s.version!==1||typeof s.started!=='boolean')fail('备份版本不支持');
  if(!Array.isArray(s.accounts)||!Array.isArray(s.categories)||!Array.isArray(s.transactions)||!Array.isArray(s.budgets))fail('备份缺少必要数据');
  if(s.transactions.length>20000||s.categories.length>1000||s.accounts.length>100||s.budgets.length>1000)fail('数据超过支持的数量');
  const ids=(rows:{id:string}[])=>{const set=new Set<string>(); rows.forEach(r=>{if(!r||typeof r.id!=='string'||r.id.length>100||!r.id||set.has(r.id))fail('数据 ID 缺失或重复');set.add(r.id);});return set;};
  const aIds=ids(s.accounts),cIds=ids(s.categories);ids(s.transactions);
  const cents=(n:number,positive=false)=>Number.isSafeInteger(n)&&Math.abs(n)<=99999999999&&(!positive||n>0);
  const name=(n:string)=>typeof n==='string'&&n.trim().length>0&&n.length<=60;
  s.accounts.forEach(a=>{if(!name(a.name)||!cents(a.openingBalance)||typeof a.kind!=='string'||typeof a.archived!=='boolean')fail('账户数据无效');});
  s.categories.forEach(c=>{
    if(!name(c.name)||!['expense','income'].includes(c.type)||typeof c.icon!=='string'||!/^#[0-9a-fA-F]{6}$/.test(c.color))fail('分类数据无效');
    if(c.parentId!==null) {const p=s.categories.find(p=>p.id===c.parentId);if(!p||p.parentId!==null||p.type!==c.type||p.id===c.id)fail('分类必须是两级结构');}
  });
  s.transactions.forEach(t=>{
    if(!['expense','income','transfer'].includes(t.type)||!cents(t.amount,true)||!cents(t.fee)||t.fee<0||!validDate(t.date)||!validDate(t.createdAt)||!aIds.has(t.accountId)||typeof t.note!=='string'||t.note.length>2000||typeof t.toAccountId!=='string'||typeof t.categoryId!=='string')fail('账单金额、日期或账户无效');
    if(t.type==='transfer'){if(!aIds.has(t.toAccountId)||t.toAccountId===t.accountId)fail('转账账户无效');if(t.fee>0||t.categoryId){const c=s.categories.find(c=>c.id===t.categoryId);if(t.fee===0||!c||!c.parentId||c.type!=='expense')fail('手续费分类无效');}}
    else {const c=s.categories.find(c=>c.id===t.categoryId);if(!c||c.parentId===null||c.type!==t.type||t.fee!==0||t.toAccountId!=='')fail('账单分类无效');}
  });
  const budgetKeys=new Set<string>();
  s.budgets.forEach(b=>{const key=`${b.month}:${b.categoryId}`;const c=s.categories.find(c=>c.id===b.categoryId);if(!/^\d{4}-(0[1-9]|1[0-2])$/.test(b.month)||!cents(b.amount,true)||![50,80,90,100].includes(b.threshold)||b.categoryId!==''&&(!cIds.has(b.categoryId)||c?.parentId!==null||c.type!=='expense')||budgetKeys.has(key))fail('预算数据无效');budgetKeys.add(key);});
  if(!s.settings||!aIds.has(s.settings.defaultAccount)||typeof s.settings.notifications!=='boolean'||!Array.isArray(s.settings.notified)||s.settings.notified.length>2000||!s.settings.notified.every(n=>typeof n==='string'&&n.length<=180))fail('设置数据无效');
}
