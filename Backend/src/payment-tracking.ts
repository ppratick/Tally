import type { Account, Entry } from './model';
import type { Env } from './plaid';

export interface TrackedPayment {
  transactionID:string; sourceAccountID:string; cardAccountID:string;
  amount:number; currency:string; date:string; matchedTransactionID:string|null;
}
export interface PaymentTracking extends TrackedPayment {
  status:'waiting'|'pending'|'complete'|'review'; reservedAmount:number; candidateIDs:string[];
}
const cents=(n:number)=>Math.round(n*100);
export function isCardPayment(t:Entry,accounts:Account[]):boolean {
  return accounts.some(a=>a.id===t.accountID&&a.type==='credit'&&!a.archived)&&t.amount<0&&
    (['LOAN_PAYMENTS','TRANSFER_IN','TRANSFER_OUT'].includes(t.category)||/\bpayment\b|autopay|auto pay/i.test(t.merchant));
}
export function withdrawalCandidates(p:TrackedPayment,entries:Entry[]):Entry[] {
  const replaced=new Set(entries.filter(t=>!t.pending).map(t=>t.pendingID));
  return entries.filter(t=>t.accountID===p.sourceAccountID&&t.currency===p.currency&&cents(t.amount)===cents(p.amount)&&
    (!t.pending||!replaced.has(t.id))&&Math.abs(Date.parse(t.date+'T00:00:00Z')-Date.parse(p.date+'T00:00:00Z'))<=14*86400000);
}
function paymentLike(t:Entry):boolean {
  return ['LOAN_PAYMENTS','TRANSFER_OUT'].includes(t.category)||/\bpayment\b|autopay|auto pay/i.test(t.merchant);
}
export function reconcilePayments(payments:TrackedPayment[],accounts:Account[],entries:Entry[]):PaymentTracking[] {
  const choices=payments.map(p=>{
    const candidates=withdrawalCandidates(p,entries);
    if(p.matchedTransactionID) {
      const matched=candidates.find(t=>t.id===p.matchedTransactionID||t.pendingID===p.matchedTransactionID);
      return matched?[matched]:[];
    }
    const claimed=new Set(payments.filter(other=>other.transactionID!==p.transactionID&&other.matchedTransactionID).flatMap(other=>
      entries.filter(t=>t.id===other.matchedTransactionID||t.pendingID===other.matchedTransactionID).map(t=>t.id)));
    return candidates.filter(t=>paymentLike(t)&&!claimed.has(t.id));
  });
  return payments.map((p,i)=>{
    const source=accounts.find(a=>a.id===p.sourceAccountID&&!a.archived);
    const candidates=choices[i];
    const unique=candidates.length===1&&!choices.some((other,j)=>j!==i&&other.some(t=>t.id===candidates[0].id));
    const matched=unique?candidates[0]:null;
    // A pending debit can already be included in available, but not in current.
    const reflected=matched&&(!matched.pending||source?.available!=null);
    return {...p,matchedTransactionID:matched?.id??p.matchedTransactionID,
      status:!source?'review':matched?(matched.pending?'pending':'complete'):candidates.length||p.matchedTransactionID?'review':'waiting',
      reservedAmount:source&&!reflected?p.amount:0,candidateIDs:withdrawalCandidates(p,entries).map(t=>t.id)};
  });
}
export async function loadPaymentTracking(env:Env,accounts:Account[],entries:Entry[]):Promise<PaymentTracking[]> {
  const rows=await env.DB.prepare(`SELECT transaction_id AS transactionID,source_account_id AS sourceAccountID,
    card_account_id AS cardAccountID,amount,currency,payment_date AS date,matched_transaction_id AS matchedTransactionID
    FROM tracked_card_payments ORDER BY transaction_id`).all<TrackedPayment>();
  const result=reconcilePayments(rows.results,accounts,entries);
  const updates=result.flatMap((payment,i)=>payment.matchedTransactionID&&payment.matchedTransactionID!==rows.results[i].matchedTransactionID?
    [env.DB.prepare(`UPDATE tracked_card_payments SET matched_transaction_id=? WHERE transaction_id=?
      AND matched_transaction_id IS ? AND NOT EXISTS(SELECT 1 FROM tracked_card_payments WHERE matched_transaction_id=? AND transaction_id!=?)`)
      .bind(payment.matchedTransactionID,payment.transactionID,rows.results[i].matchedTransactionID,payment.matchedTransactionID,payment.transactionID)]:[]);
  if(updates.length)await env.DB.batch(updates);
  return result;
}
export function reservedFor(accountID:string,payments:PaymentTracking[]):number {
  return payments.filter(p=>p.sourceAccountID===accountID).reduce((sum,p)=>sum+cents(p.reservedAmount),0)/100;
}
