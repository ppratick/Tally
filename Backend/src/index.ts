import { decodeProtectedHeader, importJWK, jwtVerify } from 'jose';
import type { AccountsGetResponse, TransactionsSyncResponse, Transaction, ItemGetResponse, InstitutionsGetByIdResponse } from 'plaid/legacy';
import { applyChanges, type Account, type Entry, type Snapshot } from './model';
import { plaid, matchesBearer, PlaidError, type Env, type Bank } from './plaid';
import { banks, load, history, historyStatements, pendingAmount, transactionStatements, accountMappings } from './repository';
import { loadInsights, syncInsights } from './insights';
import { relinkJobs, finalizeRelink } from './relink';
import { mergeReplacementHistory } from './relink-model';
import { enqueueJob, runJob, runNextJob, failureCode, JobFailure, type SyncJob } from './jobs';
import { oldestSourceTime } from './freshness';
import { enqueueScheduledRefreshes, refreshMinutes, refreshIntervals, recordFullRefresh, fullRefreshTimes } from './schedule';
import { startSession, finishSession, enqueueLinkByToken, pendingSessionID } from './link';
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
    .bind(lease,Date.now()+15*60000,bank.item_id,Date.now()).run();
  if (!acquired.meta.changes) throw new JobFailure('SYNC_BUSY');
  let old:Snapshot|undefined,committed=false;
  try {
    old=await load(env,bank.item_id);
    const aliases=await accountMappings(env,bank.item_id);
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
      balanceUpdatedAt:liveBalance?new Date().toISOString():old.balanceUpdatedAt,error:health.item.error?.error_code || null,importComplete:complete||old.importComplete,metadataLoaded:true,logo};
    const active=await env.DB.prepare('SELECT active FROM connections WHERE item_id=?').bind(bank.item_id).first<{active:number}>();
    if(active?.active===1){
      const pendingTotals=Object.fromEntries(state.accounts.map(a=>[a.id,pendingAmount(state,a.id,a.currency)]));
      const stored={...state,transactions:[],transactionsExternal:true,pendingTotals};
      await env.DB.batch([env.DB.prepare('UPDATE snapshots SET data=? WHERE id=? AND lease=?').bind(JSON.stringify(stored),bank.item_id,lease),
        ...transactionStatements(env,bank,old.transactionsExternal?[...added,...modified]:state.transactions,removed,lease),...historyStatements(env,bank,state,lease)]);
      committed=true;
      await syncInsights(env,bank,state,health.item,forceInsights);
      if(state.error)throw new PlaidError(state.error);
    }
  } catch(e) {
    const code=failureCode(e);
    if(old&&!committed) {
      const stored={...old,error:code,...(old.transactionsExternal?{transactions:[]}: {})};
      await env.DB.prepare('UPDATE snapshots SET data=? WHERE id=? AND lease=?').bind(JSON.stringify(stored),bank.item_id,lease).run();
    }
    if(e instanceof PlaidError&&e.requestID)console.warn('Plaid request',e.requestID,code);
    throw e;
  } finally {await env.DB.prepare('UPDATE snapshots SET lease=NULL,lease_until=0 WHERE id=? AND lease=?').bind(bank.item_id,lease).run();}
  await finalizeRelink(env,bank.item_id);
}
async function queueBank(env:Env,bank:Bank):Promise<void> {await enqueueJob(env,'bank',bank.item_id);}
async function executeJob(env:Env,job:SyncJob):Promise<void> {
  if(job.kind==='link') {
    const session=await env.DB.prepare('SELECT status,expires_at FROM link_sessions WHERE id=?').bind(job.subject).first<{status:string;expires_at:string}>();
    if(!session||session.status!=='pending')return;
    if(Date.parse(session.expires_at)<=Date.now()) {
      await env.DB.prepare("UPDATE link_sessions SET status='expired' WHERE id=? AND status='pending'").bind(job.subject).run();
      return;
    }
    const result=await finishSession(env,job.subject,queueBank);
    if(result.status==='pending')throw new JobFailure('LINK_PENDING');
    return;
  }
  const bank=(await banks(env)).find(b=>b.item_id===job.subject);
  if(!bank)return;
  if(job.kind==='refresh') {
    if(env.TRANSACTIONS_REFRESH_ENABLED!=='true')throw new JobFailure('REFRESH_NOT_ENABLED',true);
    await plaid(env,'/transactions/refresh',{access_token:bank.access_token});
  }
  await syncBank(env,bank,job.live_balance===1,job.force_insights===1||job.attempts>0);
  if(job.kind==='refresh')await recordFullRefresh(env,bank.item_id);
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
  const queued=(await env.DB.prepare("SELECT subject,state,last_error FROM sync_jobs WHERE kind IN ('bank','refresh')").all<{subject:string;state:string;last_error:string|null}>()).results;
  const refreshed=await fullRefreshTimes(env),active=visible.filter(e=>e.active);
  return {accounts:visible.flatMap(e=>e.accounts.map(a=>({...a,archived:!e.active||a.archived===true}))),transactions:visible.flatMap(e=>e.transactions),
    automaticRefreshMinutes:await refreshMinutes(env),
    lastFullRefreshAt:active.length&&active.every(e=>refreshed.has(e.id))?oldestSourceTime(active.map(e=>refreshed.get(e.id))):null,
    statements:visible.flatMap(e=>e.insights.statements),recurring:visible.flatMap(e=>e.insights.recurring),
    history:await history(env),pendingLinkID:await pendingSessionID(env),
    banks:visible.map(e=>({id:e.id,syncPending:queued.some(j=>j.subject===e.id&&j.state!=='blocked'),name:e.bank,archived:!e.active,checkedAt:e.checkedAt||null,updatedAt:e.bankUpdatedAt||null,
      balanceUpdatedAt:e.balanceUpdatedAt||null,liabilityError:e.insights.liabilityError||null,liabilityUpdatedAt:e.insights.liabilityUpdatedAt||null,
      recurringError:e.insights.recurringError||null,recurringUpdatedAt:e.insights.recurringUpdatedAt||null,error:e.active?(e.error||queued.find(j=>j.subject===e.id&&j.state==='blocked')?.last_error||null):null,importComplete:e.importComplete||false}))};
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
        updatedAt:oldestSourceTime([state.balanceUpdatedAt,state.bankUpdatedAt]),balance:account.type==='credit'?(account.current==null?null:Math.round((account.current+pending)*100)/100):(account.available??account.current)});
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
  async scheduled(_controller:ScheduledController,env:Env):Promise<void> {
    await enqueueScheduledRefreshes(env);
    await runNextJob(env,job=>executeJob(env,job));
  },
  async fetch(request:Request,env:Env,_ctx:ExecutionContext):Promise<Response> {
    const path=new URL(request.url).pathname;
    if(path==='/v1/widget'&&request.method==='GET'){if(!await matchesBearer(request,env.WIDGET_TOKEN))return json({error:'Unauthorized'},401);return json(await widgetSnapshot(env));}
    if(path==='/health' && request.method==='GET')return json({status:'ok',service:'Tally'});
    if(path==='/webhooks/plaid' && request.method==='POST') {
      if(Number(request.headers.get('Content-Length') || 0)>65536)return json({error:'Too large'},413);
      const raw=await request.text();if(raw.length>65536)return json({error:'Too large'},413);
      try {await verifyWebhook(request,env,raw);}catch{return json({error:'Invalid signature'},401);}
      try {
        const event=JSON.parse(raw);
        if(event.webhook_type==='LINK'&&event.webhook_code==='SESSION_FINISHED'&&typeof event.link_token==='string'){await enqueueLinkByToken(env,event.link_token);return json({received:true});}
        const bank=typeof event.item_id==='string'?await env.DB.prepare('SELECT item_id FROM connections WHERE item_id=? AND active=1').bind(event.item_id).first<{item_id:string}>():null;
        if(bank && ['SYNC_UPDATES_AVAILABLE','ERROR','PENDING_EXPIRATION','LOGIN_REPAIRED','WEBHOOK_UPDATE_ACKNOWLEDGED','DEFAULT_UPDATE','RECURRING_TRANSACTIONS_UPDATE'].includes(event.webhook_code)) {
          const repaired=event.webhook_code==='LOGIN_REPAIRED'&&env.TRANSACTIONS_REFRESH_ENABLED==='true';
          await enqueueJob(env,repaired?'refresh':'bank',bank.item_id,{live:repaired,insights:event.webhook_type==='LIABILITIES'||event.webhook_code==='RECURRING_TRANSACTIONS_UPDATE'});
        }
        return json({received:true});
      }catch(e){return e instanceof SyntaxError?json({error:'Invalid event'},400):json({error:'Unable to save update; retry delivery'},503);}
    }
    if(!await matchesBearer(request,env.APP_TOKEN))return json({error:'Unauthorized'},401);
    try {
      if(path==='/v1/settings'&&request.method==='PUT') {
        const raw=await request.text();if(raw.length>1024)return json({error:'Too large'},413);
        let body;try{body=JSON.parse(raw);}catch{return json({error:'Invalid settings'},400);}
        if(!body||!refreshIntervals.includes(body.automaticRefreshMinutes))return json({error:'Choose 15, 30, or 60 minutes'},400);
        await env.DB.prepare("INSERT INTO app_settings(key,value) VALUES('automatic_refresh_minutes',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value")
          .bind(String(body.automaticRefreshMinutes)).run();
        return json({automaticRefreshMinutes:body.automaticRefreshMinutes});
      }
      if(path==='/v1/widget/access'&&request.method==='GET')return json({token:env.WIDGET_TOKEN});
      if(path.startsWith('/v1/relink/')&&request.method==='POST')return json(await startSession(env,path.split('/').pop()));
      if(path==='/v1/link/start'&&request.method==='POST')return json(await startSession(env));
      if(path.startsWith('/v1/link/')&&path.endsWith('/complete')&&request.method==='POST'){const id=path.split('/')[3];return json(await finishSession(env,id,queueBank));}
      if(path.startsWith('/v1/link/')&&path.endsWith('/cancel')&&request.method==='POST'){const id=path.split('/')[3];const result=await finishSession(env,id,queueBank);if(result.status==='pending')await env.DB.prepare("UPDATE link_sessions SET status='cancelled' WHERE id=?").bind(id).run();return json({status:result.status==='pending'?'cancelled':result.status,message:result.message});}
      if(path.startsWith('/v1/connections/')&&request.method==='DELETE'){
        const id=path.split('/').pop();const bank=(await banks(env)).find(b=>b.item_id===id);
        if(!bank)return json({error:'Connection not found'},404);
        try{await plaid(env,'/item/remove',{access_token:bank.access_token});}catch(e){if(!(e instanceof PlaidError&&e.code==='ITEM_NOT_FOUND'))throw e;}
        await env.DB.prepare('UPDATE connections SET active=0,token_encrypted=NULL,disconnected_at=? WHERE item_id=?').bind(new Date().toISOString(),id).run();
        return json(await dashboard(env));
      }
      if(path==='/v1/dashboard' && request.method==='GET')return json(await dashboard(env));
      const bankRefresh=path.match(/^\/v1\/banks\/([^/]+)\/(sync|balances)$/);
      if(bankRefresh&&request.method==='POST') {
        const bank=(await banks(env)).find(b=>b.item_id===bankRefresh[1]);
        if(!bank)return json({error:'Unknown bank'},404);
        const gate=await env.DB.prepare("INSERT INTO snapshots(id,lease_until) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET lease_until=excluded.lease_until WHERE lease_until<?")
          .bind('_request_gate:'+bank.item_id,Date.now()+30000,Date.now()).run();
        if(!gate.meta.changes)return json({error:'Please wait a moment before refreshing again.'},429);
        const full=bankRefresh[2]==='balances'&&env.TRANSACTIONS_REFRESH_ENABLED==='true';
        const id=await enqueueJob(env,full?'refresh':'bank',bank.item_id,{live:bankRefresh[2]==='balances'});
        const completed=await runJob(env,id,job=>executeJob(env,job));
        return json({received:true,completed});
      }
      if(['/v1/sync','/v1/balances'].includes(path)&&request.method==='POST') {
        for(const bank of await banks(env))await enqueueJob(env,'bank',bank.item_id,{live:path==='/v1/balances'});
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
