import { decodeProtectedHeader, importJWK, jwtVerify } from 'jose';
import type { AccountsGetResponse, TransactionsSyncResponse, Transaction, ItemGetResponse, InstitutionsGetByIdResponse } from 'plaid/legacy';
import { applyChanges, type Account, type Entry, type Snapshot } from './model';
import { plaid, matchesBearer, PlaidError, type Env, type Bank } from './plaid';
import { banks, load, history, historyStatements, pendingAmount, transactionStatements, accountMappings } from './repository';
import { loadInsights, syncInsights } from './insights';
import { relinkJobs, finalizeRelink } from './relink';
import { mergeReplacementHistory } from './relink-model';
import { startSession, finishSession, finishByToken, pendingSessionID } from './link';
function transaction(t: Transaction): Entry {
  return {id:t.transaction_id, accountID:t.account_id, merchant:t.merchant_name || t.original_description || t.name || 'Transaction',
    amount:t.amount,currency:t.iso_currency_code || t.unofficial_currency_code || 'USD',date:t.date,pending:t.pending,
    category:t.personal_finance_category?.primary || 'OTHER',pendingID:t.pending_transaction_id || null};
}
function accountsFrom(response: AccountsGetResponse, bank: Bank, name: string, logo?:string|null): Account[] {
  return response.accounts.filter(a=>['credit','depository'].includes(a.type)).map(a=>({id:a.account_id, bankID:bank.item_id,
    bank:name, name:a.name, mask:a.mask || '',type:a.type,current:a.balances.current, available:a.balances.available,
    limit:a.balances.limit ?? null,currency:a.balances.iso_currency_code || a.balances.unofficial_currency_code || 'USD',logo:logo||null}));
}
export async function syncBank(env: Env,bank:Bank,liveBalance=false,forceInsights=false):Promise<void> {
  await env.DB.prepare('INSERT OR IGNORE INTO snapshots (id) VALUES (?)').bind(bank.item_id).run();
  const lease=crypto.randomUUID();
  const acquired=await env.DB.prepare('UPDATE snapshots SET lease=?,lease_until=? WHERE id=? AND lease_until<?')
    .bind(lease,Date.now()+180000,bank.item_id,Date.now()).run();
  if (!acquired.meta.changes) return;
  const old=await load(env,bank.item_id);
  const aliases=await accountMappings(env,bank.item_id);
  try {
    let name=old.bank,logo=old.logo||null;
    if (!old.metadataLoaded || name==='Bank' || !name) {
      const info=await plaid<InstitutionsGetByIdResponse>(env,'/institutions/get_by_id',{institution_id:bank.institution_id,country_codes:['US'],options:{include_optional_metadata:true}});
      name=info.institution.name;logo=info.institution.logo||null;
    }
    let added:Entry[]=[],modified:Entry[]=[],removed:string[]=[],cursor=old.cursor,complete=false;
    // Restart from the original cursor on mutation; never persist a partial page.
    for (let retry=0;retry<3;retry++) {
      added=[];modified=[];removed=[];cursor=old.cursor;
      try {
        let more=true, pages=0;
        while(more) {
          if (++pages>100) throw new Error('IMPORT_TOO_LARGE');
          const page=await plaid<TransactionsSyncResponse>(env,'/transactions/sync',{access_token:bank.access_token,...(cursor?{cursor}:{}),count:500,options:{include_original_description:true,personal_finance_category_version:'v2'}});
          added.push(...page.added.map(transaction).map(t=>({...t,accountID:aliases.get(t.accountID)||t.accountID})));modified.push(...page.modified.map(transaction).map(t=>({...t,accountID:aliases.get(t.accountID)||t.accountID})));removed.push(...page.removed.map(r=>r.transaction_id));
          cursor=page.next_cursor;more=page.has_more;complete=page.transactions_update_status==='HISTORICAL_UPDATE_COMPLETE';
        }
        break;
      } catch(e) {if (!(e instanceof PlaidError && e.code==='TRANSACTIONS_SYNC_MUTATION_DURING_PAGINATION' && retry<2)) throw e;}
    }
    const response=await plaid<AccountsGetResponse>(env,liveBalance?'/accounts/balance/get':'/accounts/get',{access_token:bank.access_token});
    const health=await plaid<ItemGetResponse>(env,'/item/get',{access_token:bank.access_token});
    const shared=accountsFrom(response,bank,name,logo).map(a=>({...a,id:aliases.get(a.id)||a.id}));
    const sharedIDs=new Set(shared.map(a=>a.id));
    const archived=old.accounts.filter(a=>!sharedIDs.has(a.id)).map(a=>({...a,archived:true}));
    const state: Snapshot={cursor,bank:name, accounts:[...shared,...archived], transactions:applyChanges(old.transactions,added,modified,removed),
      checkedAt:new Date().toISOString(),bankUpdatedAt:health.status?.transactions?.last_successful_update || null,
      balanceUpdatedAt:liveBalance?new Date().toISOString():old.balanceUpdatedAt,error:health.item.error?.error_code || null,importComplete:complete,metadataLoaded:true,logo};
    const active=await env.DB.prepare('SELECT active FROM connections WHERE item_id=?').bind(bank.item_id).first<{active:number}>();
    if(active?.active===1){
      const pendingTotals=Object.fromEntries(state.accounts.map(a=>[a.id,pendingAmount(state,a.id,a.currency)]));
      const stored={...state,transactions:[],transactionsExternal:true,pendingTotals};
      await env.DB.batch([env.DB.prepare('UPDATE snapshots SET data=? WHERE id=? AND lease=?').bind(JSON.stringify(stored),bank.item_id,lease),
        ...transactionStatements(env,bank,old.transactionsExternal?[...added,...modified]:state.transactions,removed,lease),...historyStatements(env,bank,state,lease)]);
      try { await syncInsights(env,bank,state,health.item,forceInsights); } catch { console.warn('Supplemental data could not be saved'); }
    }
  } catch(e) {
    const code=e instanceof PlaidError?e.code:'CONNECTION_ERROR';
    await env.DB.prepare('UPDATE snapshots SET data=? WHERE id=? AND lease=?').bind(JSON.stringify({...old,error:code}),bank.item_id,lease).run();
    // Only opaque support request IDs, never tokens or financial payloads.
    if (e instanceof PlaidError && e.requestID) console.warn('Plaid request',e.requestID,code);
  } finally {await env.DB.prepare('UPDATE snapshots SET lease=NULL,lease_until=0 WHERE id=? AND lease=?').bind(bank.item_id,lease).run();}
  try {await finalizeRelink(env,bank.item_id);} catch {console.warn('Replacement completion will retry on next update');}
}
async function dashboard(env:Env) {
  const entries=await Promise.all((await banks(env,true)).map(async bank=>({id:bank.item_id,active:bank.active,...await load(env,bank.item_id),insights:await loadInsights(env,bank.item_id)})));
  const jobs=await relinkJobs(env);
  for(const job of jobs.filter(j=>j.status==='complete')){
    const next=entries.find(e=>e.id===job.new_bank_id),previous=entries.find(e=>e.id===job.old_bank_id);
    if(next&&previous)next.transactions=mergeReplacementHistory(previous.transactions,next.transactions);
  }
  const hidden=new Set(jobs.flatMap(j=>j.status==='complete'?[j.old_bank_id]:j.new_bank_id?[j.new_bank_id]:[]));
  const visible=entries.filter(e=>!hidden.has(e.id));
  return {accounts:visible.flatMap(e=>e.accounts.map(a=>({...a,archived:!e.active||a.archived===true}))),transactions:visible.flatMap(e=>e.transactions),
    statements:visible.flatMap(e=>e.insights.statements),recurring:visible.flatMap(e=>e.insights.recurring),
    history:await history(env),pendingLinkID:await pendingSessionID(env),
    banks:visible.map(e=>({id:e.id,name:e.bank,archived:!e.active,checkedAt:e.checkedAt||null,updatedAt:e.bankUpdatedAt||null,
      balanceUpdatedAt:e.balanceUpdatedAt||null,liabilityError:e.insights.liabilityError||null,liabilityUpdatedAt:e.insights.liabilityUpdatedAt||null,
      recurringError:e.insights.recurringError||null,recurringUpdatedAt:e.insights.recurringUpdatedAt||null,error:e.active?(e.error||null):null,importComplete:e.importComplete||false}))};
}
async function widgetSnapshot(env:Env) {
  const jobs=await relinkJobs(env);
  const hidden=new Set(jobs.filter(j=>j.status!=='complete').map(j=>j.new_bank_id));
  const connections=(await banks(env)).filter(b=>!hidden.has(b.item_id));
  const accounts=[];
  for(const bank of connections) {
    const state=await load(env,bank.item_id,false);
    for(const account of state.accounts.filter(a=>!a.archived)) {
      const pending=pendingAmount(state,account.id,account.currency);
      accounts.push({id:account.id,bank:account.bank,name:account.name,mask:account.mask,isCredit:account.type==='credit',currency:account.currency,
        balance:account.type==='credit'?(account.current==null?null:Math.round((account.current+pending)*100)/100):(account.available??account.current)});
    }
  }
  return {date:new Date().toISOString(),accounts};
}
function json(value:unknown,status=200):Response {return Response.json(value,{status,headers:{'Cache-Control':'no-store','X-Content-Type-Options':'nosniff'}});}
async function verifyWebhook(request:Request,env:Env,raw:string) {
  const token=request.headers.get('Plaid-Verification');if(!token)throw new Error('Missing signature');
  const header=decodeProtectedHeader(token);if(header.alg!=='ES256' || !header.kid)throw new Error('Invalid signature');
  const result=await plaid<{key:JsonWebKey & {expired_at?:number|null}}>(env,'/webhook_verification_key/get',{key_id:header.kid});
  if(result.key.expired_at && result.key.expired_at < Date.now()/1000)throw new Error('Expired key');
  const key=await importJWK(result.key,'ES256');
  const {payload}=await jwtVerify(token,key,{algorithms:['ES256'],maxTokenAge:'5m',clockTolerance:5});
  const digest=await crypto.subtle.digest('SHA-256',new TextEncoder().encode(raw));
  const hash=[...new Uint8Array(digest)].map(n=>n.toString(16).padStart(2,'0')).join('');
  if(payload.request_body_sha256!==hash)throw new Error('Invalid body');
}
export default {
  async fetch(request:Request,env:Env,ctx:ExecutionContext):Promise<Response> {
    const path=new URL(request.url).pathname;
    if(path==='/v1/widget'&&request.method==='GET'){if(!await matchesBearer(request,env.WIDGET_TOKEN))return json({error:'Unauthorized'},401);return json(await widgetSnapshot(env));}
    if(path==='/health' && request.method==='GET')return json({status:'ok',service:'Tally'});
    if(path==='/webhooks/plaid' && request.method==='POST') {
      if(Number(request.headers.get('Content-Length') || 0)>65536)return json({error:'Too large'},413);
      const raw=await request.text();if(raw.length>65536)return json({error:'Too large'},413);
      try {await verifyWebhook(request,env,raw);}catch{return json({error:'Invalid signature'},401);}
      try {
        const event=JSON.parse(raw);
        if(event.webhook_type==='LINK'&&event.webhook_code==='SESSION_FINISHED'&&typeof event.link_token==='string'){ctx.waitUntil(finishByToken(env,event.link_token,syncBank));return json({received:true});}
        const bank=(await banks(env)).find(b=>b.item_id===event.item_id);
        if(bank && ['SYNC_UPDATES_AVAILABLE','ERROR','PENDING_EXPIRATION','LOGIN_REPAIRED','WEBHOOK_UPDATE_ACKNOWLEDGED','DEFAULT_UPDATE','RECURRING_TRANSACTIONS_UPDATE'].includes(event.webhook_code)) {
          const active=await env.DB.prepare('SELECT lease_until FROM snapshots WHERE id=?').bind(bank.item_id).first<{lease_until:number}>();
          // A new update arriving after the final sync page must be retried, never silently acknowledged.
          if(active && active.lease_until>Date.now())return json({error:'Sync in progress; retry delivery'},503);
          ctx.waitUntil(syncBank(env,bank,false,event.webhook_type==='LIABILITIES'||event.webhook_code==='RECURRING_TRANSACTIONS_UPDATE'));
        }
        return json({received:true});
      }catch{return json({error:'Invalid event'},400);}
    }
    if(!await matchesBearer(request,env.APP_TOKEN))return json({error:'Unauthorized'},401);
    try {
      if(path==='/v1/widget/access'&&request.method==='GET')return json({token:env.WIDGET_TOKEN});
      if(path.startsWith('/v1/relink/')&&request.method==='POST')return json(await startSession(env,path.split('/').pop()));
      if(path==='/v1/link/start'&&request.method==='POST')return json(await startSession(env));
      if(path.startsWith('/v1/link/')&&path.endsWith('/complete')&&request.method==='POST'){const id=path.split('/')[3];return json(await finishSession(env,id,syncBank));}
      if(path.startsWith('/v1/link/')&&path.endsWith('/cancel')&&request.method==='POST'){const id=path.split('/')[3];const result=await finishSession(env,id,syncBank);if(result.status==='pending')await env.DB.prepare("UPDATE link_sessions SET status='cancelled' WHERE id=?").bind(id).run();return json({status:result.status==='pending'?'cancelled':result.status,message:result.message});}
      if(path.startsWith('/v1/connections/')&&request.method==='DELETE'){
        const id=path.split('/').pop();const bank=(await banks(env)).find(b=>b.item_id===id);
        if(!bank)return json({error:'Connection not found'},404);
        try{await plaid(env,'/item/remove',{access_token:bank.access_token});}catch(e){if(!(e instanceof PlaidError&&e.code==='ITEM_NOT_FOUND'))throw e;}
        await env.DB.prepare('UPDATE connections SET active=0,token_encrypted=NULL,disconnected_at=? WHERE item_id=?').bind(new Date().toISOString(),id).run();
        return json(await dashboard(env));
      }
      if(path==='/v1/dashboard' && request.method==='GET')return json(await dashboard(env));
      if(['/v1/sync','/v1/balances'].includes(path) && request.method==='POST') {
        // Avoid concurrent UI gestures causing repeated bank calls.
        const gate=await env.DB.prepare("INSERT INTO snapshots(id,lease_until) VALUES('_request_gate',?) ON CONFLICT(id) DO UPDATE SET lease_until=excluded.lease_until WHERE lease_until<?").bind(Date.now()+30000,Date.now()).run();
        if(!gate.meta.changes)return json({error:'Please wait a moment before refreshing again.'},429);
        // Sequential calls keep free-tier subrequest usage bounded.
        for(const bank of await banks(env))await syncBank(env,bank,path==='/v1/balances');
        return json(await dashboard(env));
      }
      if(path.startsWith('/v1/reconnect/') && request.method==='POST') {
        const bank=(await banks(env)).find(b=>b.item_id===path.split('/').pop());if(!bank)return json({error:'Unknown bank'},404);
        const result=await plaid<{hosted_link_url:string}>(env,'/link/token/create',{user:{client_user_id:'tally-owner'},client_name:'Tally',country_codes:['US'],language:'en',access_token:bank.access_token,products:[],additional_consented_products:['liabilities'],update:{account_selection_enabled:true},hosted_link:{completion_redirect_uri:'tally://link-complete'}});
        return json({url:result.hosted_link_url});
      }
      return json({error:'Not found'},404);
    }catch {return json({error:'Unable to complete the request. Try again shortly.'},503);}
  }
};
