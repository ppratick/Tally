import type { LiabilitiesGetResponse, TransactionsRecurringGetResponse } from 'plaid/legacy';

export interface CreditStatement {
  accountID:string; dueDate:string|null; minimumPayment:number|null; statementBalance:number|null;
  statementDate:string|null; overdue:boolean|null; updatedAt:string;
}
export interface RecurringStream {
  id:string; accountID:string; merchant:string; direction:'incoming'|'outgoing'; category:string;
  frequency:string; nextDate:string|null; lastDate:string; averageAmount:number|null; lastAmount:number|null;
  currency:string; active:boolean; status:string; transactionIDs:string[];
}
export interface BankInsights {
  statements:CreditStatement[]; recurring:RecurringStream[];
  liabilityCheckedAt?:string; liabilityUpdatedAt?:string; liabilityError?:string|null;
  recurringCheckedAt?:string; recurringUpdatedAt?:string; recurringError?:string|null;
}
export function creditStatements(response:LiabilitiesGetResponse,now:string):CreditStatement[] {
  return (response.liabilities.credit||[]).filter(c=>c.account_id!=null).map(c=>({accountID:c.account_id!,dueDate:c.next_payment_due_date,
    minimumPayment:c.minimum_payment_amount,statementBalance:c.last_statement_balance,statementDate:c.last_statement_issue_date,
    overdue:c.is_overdue,updatedAt:now}));
}
export function recurringStreams(response:TransactionsRecurringGetResponse):RecurringStream[] {
  return ([['outgoing',response.outflow_streams],['incoming',response.inflow_streams]] as const).flatMap(([direction,streams])=>
    streams.map(s=>({id:s.stream_id,accountID:s.account_id,merchant:s.merchant_name||s.description||'Recurring payment',
      direction,category:s.personal_finance_category?.primary||'OTHER',frequency:s.frequency,nextDate:s.predicted_next_date||null,
      lastDate:s.last_date,averageAmount:s.average_amount.amount??null,lastAmount:s.last_amount.amount??null,
      currency:s.last_amount.iso_currency_code||s.average_amount.iso_currency_code||'USD',active:s.is_active,status:s.status,transactionIDs:s.transaction_ids})));
}
