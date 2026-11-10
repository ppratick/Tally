import type { ItemGetResponse, LiabilitiesGetResponse, TransactionsRecurringGetResponse } from 'plaid/legacy';
import { plaid, PlaidError, type Env, type Bank } from './plaid';
import type { Snapshot } from './model';
import { blocksAutomaticRetry } from './jobs';
import { accountMappings } from './repository';
import { creditStatements, recurringStreams, type BankInsights } from './insight-model';

export async function loadInsights(env:Env,id:string):Promise<BankInsights> {
  const row=await env.DB.prepare('SELECT data FROM bank_insights WHERE bank_id=?').bind(id).first<{data:string}>();
  return {statements:[],recurring:[],...(row?JSON.parse(row.data):{})};
}
function expired(date:string|undefined,age:number):boolean {return !date||Date.now()-Date.parse(date)>age;}
// Called by explicit refreshes and signed product webhooks; dashboard/widget reads never call Plaid.
export async function syncInsights(env:Env,bank:Bank,state:Snapshot,item:ItemGetResponse['item'],force=false):Promise<void> {
  const saved=await loadInsights(env,bank.item_id),now=new Date().toISOString();
  const aliases=await accountMappings(env,bank.item_id);
  const failures:string[]=[];
  if(state.accounts.some(a=>a.type==='credit'&&!a.archived)&&(force||expired(saved.liabilityCheckedAt,15*60000))) {
    saved.liabilityCheckedAt=now;
    if(!(item.consented_products||[]).some(p=>p==='liabilities'))saved.liabilityError='ADDITIONAL_CONSENT_REQUIRED';
    else try {
      saved.statements=creditStatements(await plaid<LiabilitiesGetResponse>(env,'/liabilities/get',{access_token:bank.access_token}),now).map(s=>({...s,accountID:aliases.get(s.accountID)||s.accountID}));
      saved.liabilityUpdatedAt=now;saved.liabilityError=null;
    } catch(e) {saved.liabilityError=e instanceof PlaidError?e.code:'CONNECTION_ERROR';failures.push(saved.liabilityError);}
  }
  if(state.importComplete&&(force||expired(saved.recurringCheckedAt,6*3600000))) {
    saved.recurringCheckedAt=now;
    try {
      saved.recurring=recurringStreams(await plaid<TransactionsRecurringGetResponse>(env,'/transactions/recurring/get',{
        access_token:bank.access_token,options:{personal_finance_category_version:'v2'}})).map(s=>({...s,accountID:aliases.get(s.accountID)||s.accountID}));
      saved.recurringUpdatedAt=now;saved.recurringError=null;
    } catch(e) {saved.recurringError=e instanceof PlaidError?e.code:'CONNECTION_ERROR';failures.push(saved.recurringError);}
  }
  await env.DB.prepare(`INSERT INTO bank_insights(bank_id,data) SELECT ?,? WHERE EXISTS(SELECT 1 FROM connections WHERE item_id=? AND active=1)
    ON CONFLICT(bank_id) DO UPDATE SET data=excluded.data`).bind(bank.item_id,JSON.stringify(saved),bank.item_id).run();
  const failed=failures.find(code=>!blocksAutomaticRetry(code))||failures[0];
  if(failed)throw new PlaidError(failed);
}
