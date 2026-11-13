import type { dashboard } from './index';
import type { Entry } from './model';
import { reservedFor } from './payment-tracking.ts';

export type FinancialData = Awaited<ReturnType<typeof dashboard>>;
type Args = Record<string, unknown>;
const string = (description:string) => ({type:['string','null'],description});
const strings = (description:string) => ({type:['array','null'],items:{type:'string'},description});
const filters = {
  startDate:string('Inclusive YYYY-MM-DD; null means earliest saved date.'),
  endDate:string('Inclusive YYYY-MM-DD; null means latest saved date.'),
  accountIDs:strings('Exact account IDs from the overview. Null means all accounts, including saved disconnected accounts.'),
  category:string('Exact category code; null means all categories.'),
  merchant:string('Case-insensitive merchant substring; null means all merchants.'),
  currency:{type:'string',description:'One currency code, e.g. USD. Never combine currencies.'},
  includePending:{type:'boolean',description:'Include unreplaced pending transactions.'},
  excludeTransactionIDs:strings('Exact transaction IDs to omit, for what-if follow-ups.'),
};
function tool(name:string,description:string,properties:Args) {
  return {type:'function',name,description,strict:true,parameters:{type:'object',properties,required:Object.keys(properties),additionalProperties:false}};
}
export const financialTools = [
  tool('getOverview','Account balances, bank freshness, available transaction dates, and category codes. No transaction list.',{}),
  tool('summarizeSpending','Exact spending totals over ALL matches, by category and merchant. Excludes income, transfers, loan/card payments; refunds reduce spending. Includes top 8 transactions as examples, not the entire total.',filters),
  tool('compareSpending','Compare two explicit inclusive date ranges with the same filters. For month-to-date comparisons, align elapsed days. All arithmetic is performed by Tally.',{
    ...filters,previousStartDate:{type:'string'},previousEndDate:{type:'string'},
  }),
  tool('searchTransactions','Search all activity, including income and transfers. Returns an exact signed net total, count, and one page. Positive amounts are outflows, negative amounts inflows. Do not call net activity spending.',{
    ...filters,offset:{type:'integer',minimum:0,maximum:1000000},
  }),
  tool('getPayments','Credit statements and detected recurring payments for the selected accounts. Statement balance is not remaining amount due; recurring dates are estimates.',{
    accountIDs:strings('Null means all accounts.'),offset:{type:'integer',minimum:0,maximum:1000000},
  }),
  tool('getBalanceHistory','Saved daily balance observations, not a forecast. Each row includes its currency; never sum across currencies. Returns one page.',{
    startDate:filters.startDate,endDate:filters.endDate,accountIDs:filters.accountIDs,offset:{type:'integer',minimum:0,maximum:1000000},
  }),
];

function text(value:unknown,key:string,max=200):string|null {
  if(value==null)return null;
  if(typeof value!=='string'||value.length>max)throw new Error(`Invalid ${key}`);
  return value;
}
function date(value:unknown,key:string):string|null {
  const result=text(value,key,10);
  if(result!==null&&(!/^\d{4}-\d{2}-\d{2}$/.test(result)||!Number.isFinite(Date.parse(result+'T00:00:00Z'))||new Date(result+'T00:00:00Z').toISOString().slice(0,10)!==result))throw new Error(`Invalid ${key}`);
  return result;
}
function list(value:unknown,key:string):string[]|null {
  if(value==null)return null;
  if(!Array.isArray(value)||value.length>100||value.some(v=>typeof v!=='string'||v.length>200))throw new Error(`Invalid ${key}`);
  return value as string[];
}
function offset(args:Args):number {
  const value=args.offset;
  if(typeof value!=='number'||!Number.isInteger(value)||value<0||value>1000000)throw new Error('Invalid offset');
  return value;
}
const money = (values:number[]) => values.reduce((sum,value)=>sum+Math.round(value*100),0)/100;
function range(args:Args) {
  const start=date(args.startDate,'startDate'),end=date(args.endDate,'endDate');
  if(start&&end&&start>end)throw new Error('startDate must precede endDate');
  return {start,end};
}
function accountScope(data:FinancialData,args:Args):Set<string> {
  const ids=list(args.accountIDs,'accountIDs'),known=new Set(data.accounts.map(a=>a.id));
  if(ids?.some(id=>!known.has(id)))throw new Error('Unknown account ID; use getOverview');
  return new Set(ids??known);
}
function eligible(data:FinancialData):Entry[] {
  const known=new Set(data.accounts.map(a=>a.id));
  const replaced=new Set(data.transactions.filter(t=>!t.pending).map(t=>t.pendingID));
  return data.transactions.filter(t=>known.has(t.accountID)&&(!t.pending||!replaced.has(t.id)))
    .sort((a,b)=>b.date.localeCompare(a.date)||a.id.localeCompare(b.id));
}
function filtered(data:FinancialData,args:Args,entries:Entry[]):Entry[] {
  const {start,end}=range(args),ids=accountScope(data,args);
  const merchant=text(args.merchant,'merchant')?.toLocaleLowerCase(),category=text(args.category,'category');
  const excluded=new Set(list(args.excludeTransactionIDs,'excludeTransactionIDs')??[]);
  if(typeof args.currency!=='string'||!/^\w{3,12}$/.test(args.currency))throw new Error('Invalid currency');
  if(typeof args.includePending!=='boolean')throw new Error('Invalid includePending');
  return entries.filter(t=>ids.has(t.accountID)&&t.currency===args.currency&&(!start||t.date>=start)&&(!end||t.date<=end)
    &&(args.includePending||!t.pending)&&(!category||t.category===category)&&(!merchant||t.merchant.toLocaleLowerCase().includes(merchant))&&!excluded.has(t.id));
}
function summary(data:FinancialData,args:Args,entries:Entry[]) {
  const excluded=new Set(['INCOME','TRANSFER_IN','TRANSFER_OUT','LOAN_PAYMENTS']);
  const paymentIDs=new Set((data.paymentTracking??[]).flatMap(p=>[p.transactionID,...(p.matchedTransactionID?[p.matchedTransactionID]:[])]));
  const rows=filtered(data,args,entries).filter(t=>!excluded.has(t.category)&&!paymentIDs.has(t.id)&&!paymentIDs.has(t.pendingID??''));
  const groups=(key:'category'|'merchant')=>{
    const grouped=new Map<string,number[]>();
    for(const row of rows){const values=grouped.get(row[key])??[];values.push(row.amount);grouped.set(row[key],values);}
    return [...grouped].map(([name,values])=>({name,amount:money(values),count:values.length})).sort((a,b)=>b.amount-a.amount||a.name.localeCompare(b.name));
  };
  const merchants=groups('merchant');
  return {startDate:args.startDate,endDate:args.endDate,currency:args.currency,count:rows.length,total:money(rows.map(t=>t.amount)),
    pendingTotal:money(rows.filter(t=>t.pending).map(t=>t.amount)),categories:groups('category'),
    merchants:merchants.slice(0,20),merchantGroups:merchants.length,
    examples:[...rows].sort((a,b)=>Math.abs(b.amount)-Math.abs(a.amount)||a.id.localeCompare(b.id)).slice(0,8),
    note:'Purchases minus refunds. Transfers, income, and loan/card payments excluded. Saved history may be partial; pending amounts may change.'};
}
export interface ToolResult { data:unknown; transactions:Entry[] }
export function createFinancialToolRunner(data:FinancialData) {
  // One sorted, de-duplicated projection per request, reused across every model/tool round.
  const entries=eligible(data);
  return (name:string,args:Args)=>runFinancialTool(name,args,data,entries);
}
export function runFinancialTool(name:string,args:Args,data:FinancialData,entries=eligible(data)):ToolResult {
  if(name==='getOverview') {
    const rows=entries,categories=[...new Set(rows.map(t=>t.category))].sort();
    const accounts=data.accounts.map(a=>{
      const pending=money(rows.filter(t=>t.accountID===a.id&&t.pending&&t.currency===a.currency).map(t=>t.amount));
      const paymentReserve=reservedFor(a.id,data.paymentTracking??[]),reported=a.available??a.current;
      return {paymentReserve,id:a.id,bank:a.bank,name:a.name,mask:a.mask,type:a.type,currency:a.currency,archived:a.archived===true,
        current:a.current,available:a.available,limit:a.limit,pending,
        displayedBalance:a.type==='credit'?(a.current===null?null:money([a.current,pending])):(reported===null?null:money([reported,-paymentReserve]))};
    });
    const active=accounts.filter(a=>!a.archived);
    const totals=[...new Set(active.map(a=>a.currency))].map(currency=>{
      const matching=active.filter(a=>a.currency===currency),known=matching.filter(a=>a.displayedBalance!==null);
      const cash=money(known.filter(a=>a.type!=='credit').map(a=>a.displayedBalance!));
      const debt=money(known.filter(a=>a.type==='credit').map(a=>a.displayedBalance!));
      return {currency,cash,debt,netBalance:money([cash,-debt]),missingBalances:matching.length-known.length,
        note:'Active accounts only; totals omit unknown balances. Includes all active accounts, even those hidden on Home.'};
    });
    return {transactions:[],data:{accounts,totals,banks:data.banks.map(b=>({name:b.name,archived:b.archived,checkedAt:b.checkedAt,updatedAt:b.updatedAt,balanceUpdatedAt:b.balanceUpdatedAt,
      error:b.error,importComplete:b.importComplete,recurringError:b.recurringError,recurringUpdatedAt:b.recurringUpdatedAt,
      liabilityError:b.liabilityError,liabilityUpdatedAt:b.liabilityUpdatedAt})),
      history:{count:rows.length,earliestDate:rows.at(-1)?.date??null,latestDate:rows[0]?.date??null},categories,
      paymentTracking:data.paymentTracking??[],
      balanceNote:'Credit displayedBalance includes pending; checking uses available or current minus tracked card payment reserves. Pending withdrawals already included in available are not reserved again. History shows bank observations without reserves. Archived balances are historical. Never combine currencies.'}};
  }
  if(name==='summarizeSpending'){const result=summary(data,args,entries);return {data:result,transactions:result.examples};}
  if(name==='compareSpending') {
    const start=date(args.previousStartDate,'previousStartDate'),end=date(args.previousEndDate,'previousEndDate');
    if(!start||!end)throw new Error('Previous dates required');
    const current=summary(data,args,entries),previous=summary(data,{...args,startDate:start,endDate:end},entries);
    const categoryNames=new Set([...current.categories,...previous.categories].map(c=>c.name));
    const changes=[...categoryNames].map(name=>({category:name,change:money([current.categories.find(c=>c.name===name)?.amount??0,-(previous.categories.find(c=>c.name===name)?.amount??0)])})).sort((a,b)=>b.change-a.change);
    return {data:{current,previous,change:money([current.total,-previous.total]),categoryChanges:changes},transactions:[...current.examples,...previous.examples]};
  }
  if(name==='searchTransactions') {
    const rows=filtered(data,args,entries),start=offset(args),page=rows.slice(start,start+40);
    return {data:{count:rows.length,currency:args.currency,netOutflow:money(rows.map(t=>t.amount)),transactions:page,nextOffset:start+40<rows.length?start+40:null,
      note:'Net outflow includes transfers and income. Positive amounts are outflows; negative amounts are inflows. Page is not the full result set.'},transactions:page};
  }
  if(name==='getPayments') {
    const ids=accountScope(data,args),start=offset(args),statements=data.statements.filter(s=>ids.has(s.accountID)),recurring=data.recurring.filter(r=>ids.has(r.accountID));
    const rows=[...statements.map(value=>({kind:'statement',value})),...recurring.map(value=>({kind:'recurring',value}))];
    return {transactions:[],data:{payments:rows.slice(start,start+40),count:rows.length,nextOffset:start+40<rows.length?start+40:null,
      note:'Statement balance is the original issued balance, not remaining amount due. Recurring dates and amounts are estimates. Check bank freshness and errors in the overview.'}};
  }
  if(name==='getBalanceHistory') {
    const {start,end}=range(args),ids=accountScope(data,args),page=offset(args);
    const rows=data.history.filter(h=>ids.has(String(h.accountID))&&(!start||String(h.day)>=start)&&(!end||String(h.day)<=end)).map(h=>{
      const account=data.accounts.find(a=>a.id===h.accountID);
      const current=typeof h.current==='number'?h.current:null,available=typeof h.available==='number'?h.available:null;
      const balance=account?.type==='credit'?(current===null?null:money([current,typeof h.pending==='number'?h.pending:0])):(available??current);
      return {...h,displayedBalance:balance};
    }).sort((a,b)=>String(a.day).localeCompare(String(b.day))||String(a.accountID).localeCompare(String(b.accountID)));
    const changes=[...new Set(rows.map(h=>String(h.accountID)+'|'+String(h.currency)))].map(key=>{
      const matching=rows.filter(h=>String(h.accountID)+'|'+String(h.currency)===key),first=matching[0],last=matching.at(-1)!;
      return {accountID:first.accountID,currency:first.currency,firstDay:first.day,lastDay:last.day,firstBalance:first.displayedBalance,lastBalance:last.displayedBalance,
        change:first.displayedBalance===null||last.displayedBalance===null?null:money([last.displayedBalance,-first.displayedBalance])};
    });
    return {transactions:[],data:{observations:rows.slice(page,page+60),count:rows.length,nextOffset:page+60<rows.length?page+60:null,changes,
      note:'Changes use the first and last saved observation in the range, which may not coincide with requested dates. Credit balances include pending; checking uses available or current.'}};
  }
  throw new Error('Unknown financial tool');
}
