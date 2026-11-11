import { test } from 'node:test';
import assert from 'node:assert/strict';
import { runFinancialTool, financialTools, type FinancialData } from '../src/chat-tools.ts';

const entry=(id:string,amount:number,extra:Record<string,unknown>={})=>({id,accountID:'card',merchant:'Cafe',amount,currency:'USD',date:'2026-11-10',pending:false,category:'FOOD_AND_DRINK',pendingID:null,...extra});
const filters={startDate:'2026-11-01',endDate:'2026-11-11',accountIDs:null,category:null,merchant:null,currency:'USD',includePending:true,excludeTransactionIDs:null};
function fixture():FinancialData {
  return {accounts:[{id:'card',bankID:'bank',bank:'Bank',name:'Card',mask:'0000',type:'credit',current:100,available:900,limit:1000,currency:'USD'},
    {id:'cash',bankID:'bank',bank:'Bank',name:'Checking',mask:'0001',type:'depository',current:500,available:450,limit:null,currency:'USD'}],
    transactions:[entry('charge',120),entry('refund',-20),entry('pending',5,{pending:true}),entry('replaced',10,{pending:true}),entry('posted',12,{pendingID:'replaced'}),
      entry('payment',100,{category:'LOAN_PAYMENTS'}),entry('income',-2000,{category:'INCOME'}),entry('transfer',1000,{category:'TRANSFER_OUT'}),
      entry('foreign',999,{currency:'EUR'}),entry('old',50,{date:'2026-10-10'}),entry('orphan',100,{accountID:'unknown'})],
    banks:[{name:'Bank',archived:false,error:null,importComplete:false,checkedAt:'2026-11-10T12:00:00Z'}],history:[],statements:[],recurring:[],
  } as unknown as FinancialData;
}
test('spending matches app rules for refunds, transfers, currencies and pending replacements',()=>{
  const result=runFinancialTool('summarizeSpending',filters,fixture()).data as any;
  assert.equal(result.total,117);assert.equal(result.pendingTotal,5);assert.equal(result.count,4);
  assert.equal(runFinancialTool('summarizeSpending',{...filters,includePending:false},fixture()).data.total,112);
  assert.equal(runFinancialTool('summarizeSpending',{...filters,excludeTransactionIDs:['charge']},fixture()).data.total,-3);
});
test('aggregates cover every matching transaction despite bounded pages and examples',()=>{
  const data=fixture();data.transactions=Array.from({length:105},(_,i)=>entry(String(i),0.1));
  const summary=runFinancialTool('summarizeSpending',filters,data).data as any;
  assert.equal(summary.total,10.5);assert.equal(summary.examples.length,8);
  const page=runFinancialTool('searchTransactions',{...filters,offset:40},data).data as any;
  assert.equal(page.count,105);assert.equal(page.netOutflow,10.5);assert.equal(page.transactions.length,40);assert.equal(page.nextOffset,80);
});
test('comparison calculates deltas and explicit merchant/category/account filters',()=>{
  const data=fixture();
  const result=runFinancialTool('compareSpending',{...filters,previousStartDate:'2026-10-01',previousEndDate:'2026-10-11'},data).data as any;
  assert.equal(result.current.total,117);assert.equal(result.previous.total,50);assert.equal(result.change,67);assert.equal(result.categoryChanges[0].change,67);
  assert.equal(runFinancialTool('summarizeSpending',{...filters,merchant:'cAfE',accountIDs:['cash']},data).data.total,0);
  assert.equal(runFinancialTool('summarizeSpending',{...filters,merchant:"' OR 1=1 --"},data).data.total,0);
});
test('overview matches credit and checking balance treatment, preserves missing values and excludes secrets',()=>{
  const data=fixture();(data as any).secret='should-not-leak';(data.accounts[0] as any).access_token='secret';
  const result=runFinancialTool('getOverview',{},data).data as any;
  assert.equal(result.accounts[0].displayedBalance,105);assert.equal(result.accounts[1].displayedBalance,450);
  assert.equal(result.totals[0].netBalance,345);assert.equal(result.totals[0].missingBalances,0);
  assert.equal(result.banks[0].importComplete,false);assert.equal(JSON.stringify(result).includes('secret'),false);
  data.accounts[0].current=null;
  assert.equal(runFinancialTool('getOverview',{},data).data.accounts[0].displayedBalance,null);
  assert.equal(runFinancialTool('getOverview',{},data).data.totals[0].missingBalances,1);
});
test('invalid arguments fail without broadening account/date scope',()=>{
  const data=fixture();
  for(const patch of [{startDate:'2026-02-30'},{startDate:'2026-12-01'},{accountIDs:['missing']},{includePending:'true'},{currency:'USD OR 1=1'},{excludeTransactionIDs:[2]}]) {
    assert.throws(()=>runFinancialTool('summarizeSpending',{...filters,...patch},data));
  }
  assert.throws(()=>runFinancialTool('searchTransactions',{...filters,offset:-1},data));
  assert.throws(()=>runFinancialTool('executeSQL',{sql:'DELETE FROM transactions'},data));
});
test('payments and balance observations are paginated and scoped to saved accounts',()=>{
  const data=fixture();
  data.recurring=Array.from({length:45},(_,i)=>({id:String(i),accountID:'card'})) as any;
  data.history=[{accountID:'cash',day:'2026-11-10',current:500,currency:'USD'},{accountID:'card',day:'2026-11-10',current:100,currency:'USD'}] as any;
  const payments=runFinancialTool('getPayments',{accountIDs:['card'],offset:40},data).data as any;
  assert.equal(payments.count,45);assert.equal(payments.payments.length,5);assert.equal(payments.nextOffset,null);
  const history=runFinancialTool('getBalanceHistory',{startDate:null,endDate:null,accountIDs:['cash'],offset:0},data).data as any;
  assert.equal(history.count,1);assert.equal(history.observations[0].current,500);
  assert.equal(history.changes[0].change,0);assert.equal(history.observations[0].displayedBalance,500);
});
test('all strict function schemas declare every field as required and disallow extras',()=>{
  for(const tool of financialTools) {
    assert.equal(tool.strict,true);assert.equal(tool.parameters.additionalProperties,false);
    assert.deepEqual(tool.parameters.required,Object.keys(tool.parameters.properties));
  }
});
