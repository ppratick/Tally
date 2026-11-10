import { test } from 'node:test';
import assert from 'node:assert/strict';
import { applyChanges, type Entry } from '../src/model.ts';
const entry = (id:string, pending=false, amount=10):Entry => ({id,accountID:'credit',merchant:'Cafe',amount,currency:'USD',date:'2026-11-10',pending,category:'FOOD_AND_DRINK',pendingID:null});
test('pending purchase posts once, including tip changes across pages',()=>{
 const pending=entry('pending',true,10);const posted={...entry('posted',false,12),pendingID:'pending'};
 assert.deepEqual(applyChanges([pending],[posted],[],['pending']),[posted]);
});
test('repeated updates are idempotent and removed refunds disappear',()=>{
 const purchase=entry('charge',false,20),refund=entry('refund',false,-5);
 const updated={...purchase,amount:22};
 const result=applyChanges([purchase,refund],[updated],[updated],['refund']);
 assert.equal(result.length,1);assert.equal(result[0].amount,22);
 assert.deepEqual(applyChanges(result,[updated],[updated],['refund']),result);
});
test('second persona with deposits and no credit transactions preserves signed amounts and unknown categories',()=>{
 const deposit={...entry('deposit',false,-1500),accountID:'checking',category:'INCOME'};
 const unknown={...entry('cash',false,40),accountID:'checking',category:'OTHER'};
 assert.equal(applyChanges([],[deposit,unknown],[],[]).reduce((s,t)=>s+t.amount,0),-1460);
});
