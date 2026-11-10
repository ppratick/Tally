import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { LiabilitiesGetResponse, TransactionsRecurringGetResponse } from 'plaid/legacy';
import { creditStatements, recurringStreams } from '../src/insight-model.ts';

test('credit details preserve missing fields and never invent an amount remaining',()=>{
  const response={liabilities:{credit:[{account_id:'credit',next_payment_due_date:null,minimum_payment_amount:null,
    last_statement_balance:100,last_statement_issue_date:'2026-11-01',is_overdue:null},{account_id:null}]}} as unknown as LiabilitiesGetResponse;
  const result=creditStatements(response,'2026-11-10T12:00:00Z');
  assert.equal(result.length,1);assert.equal(result[0].dueDate,null);assert.equal(result[0].minimumPayment,null);
  assert.equal(result[0].statementBalance,100);assert.equal('remainingBalance' in result[0],false);
});
test('second persona: deposits, inactive streams, unknown schedules and currency survive normalization',()=>{
  const stream={stream_id:'deposit',account_id:'checking',merchant_name:null,description:'Payroll',frequency:'UNKNOWN',
    predicted_next_date:null,last_date:'2026-11-01',average_amount:{amount:null,iso_currency_code:'CAD'},
    last_amount:{amount:-1200,iso_currency_code:'CAD'},is_active:false,status:'TOMBSTONED',transaction_ids:['one'],personal_finance_category:null};
  const response={inflow_streams:[stream],outflow_streams:[{...stream,stream_id:'bill',merchant_name:'Power',frequency:'MONTHLY',is_active:true,status:'MATURE',last_amount:{amount:100,iso_currency_code:'USD'}}]} as unknown as TransactionsRecurringGetResponse;
  const result=recurringStreams(response);
  assert.equal(result.length,2);assert.equal(result[0].direction,'outgoing');assert.equal(result[1].direction,'incoming');
  assert.equal(result[1].currency,'CAD');assert.equal(result[1].lastAmount,-1200);assert.equal(result[1].averageAmount,null);
  assert.equal(result[1].nextDate,null);assert.equal(result[1].active,false);assert.equal(result[1].merchant,'Payroll');
  assert.deepEqual(result[1].transactionIDs,['one']);
});
