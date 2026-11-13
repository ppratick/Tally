import { test } from 'node:test';
import assert from 'node:assert/strict';
import { reconcilePayments, isCardPayment } from '../src/payment-tracking.ts';
const checking:any={id:'cash',type:'depository',available:1000,current:1000,currency:'USD'};
const card:any={id:'card',type:'credit',currency:'USD'};
const p:any={transactionID:'payment',sourceAccountID:'cash',cardAccountID:'card',amount:500,currency:'USD',date:'2026-11-13',matchedTransactionID:null};
const withdrawal=(id='debit',extra={})=>({id,accountID:'cash',amount:500,currency:'USD',date:'2026-11-14',pending:false,pendingID:null,category:'LOAN_PAYMENTS',merchant:'Card payment',...extra});
const run=(entries:any[]=[],accounts:any[]=[checking,card],payments:any[]=[p])=>reconcilePayments(payments,accounts,entries);
test('reserve waits for withdrawal and clears for posted or available-account pending debit',()=>{
 assert.equal(run()[0].reservedAmount,500);
 assert.equal(run([withdrawal()])[0].reservedAmount,0);
 const pending=run([withdrawal('pending',{pending:true})])[0];
 assert.equal(pending.status,'pending');assert.equal(pending.reservedAmount,0);
 assert.equal(run([withdrawal('pending',{pending:true})],[{...checking,available:null},card])[0].reservedAmount,500);
});
test('wrong source, currency, amount, date, unrelated purchases cannot release reserve',()=>{
 for(const extra of [{accountID:'other'},{currency:'EUR'},{amount:499.99},{date:'2026-10-01'},{category:'FOOD_AND_DRINK',merchant:'Restaurant'}])
  assert.equal(run([withdrawal('wrong',extra)])[0].reservedAmount,500);
});
test('ambiguous withdrawals or identical payments never consume one debit twice',()=>{
 assert.equal(run([withdrawal('one'),withdrawal('two')])[0].status,'review');
 const duplicate=run([withdrawal()],[checking,card],[p,{...p,transactionID:'another'}]);
 assert.ok(duplicate.every(x=>x.reservedAmount===500));
});
test('manual matches resolve ambiguity and survive pending replacement',()=>{
 const linked={...p,matchedTransactionID:'pending'};
 assert.equal(run([withdrawal('pending',{pending:true}),withdrawal('other')],[checking,card],[linked])[0].reservedAmount,0);
 const replaced=run([withdrawal('pending',{pending:true}),withdrawal('posted',{pendingID:'pending'})],[checking,card],[linked])[0];
 assert.equal(replaced.status,'complete');assert.equal(replaced.matchedTransactionID,'posted');
 assert.equal(run([],[checking,card],[linked])[0].reservedAmount,500);
});
test('archived accounts do not reserve money; refunds are not offered as payments',()=>{
 assert.equal(run([],[{...checking,archived:true},card])[0].status,'review');
 assert.equal(run([],[{...checking,archived:true},card])[0].reservedAmount,0);
 assert.equal(isCardPayment({...withdrawal(),accountID:'card',amount:-500},[card]),true);
 assert.equal(isCardPayment({...withdrawal(),accountID:'card',amount:-500,category:'GENERAL_MERCHANDISE',merchant:'Refund'},[card]),false);
});
