import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {randomBytes,createHash} from 'node:crypto';
import {generateKeyPair,exportJWK,SignJWT} from 'jose';
import worker from '../src/index.ts';
import {encrypt} from '../src/plaid.ts';
import {historyStatements} from '../src/repository.ts';
import {database} from './fixtures/database.ts';
const {DB,sqlite}=database(readFileSync('schema.sql','utf8'));
const env:any={DB,PLAID_CLIENT_ID:'test-client',PLAID_SECRET:'test-secret',PLAID_ENV:'sandbox',PLAID_ITEMS:'[]',APP_TOKEN:randomBytes(32).toString('hex'),WIDGET_TOKEN:randomBytes(32).toString('hex'),TOKEN_ENCRYPTION_KEY:randomBytes(32).toString('base64'),PUBLIC_URL:'https://example.com'};
const account={id:'checking',bankID:'test-bank',bank:'Test Bank',name:'Checking',mask:'0000',type:'depository',current:100,available:100,limit:null,currency:'USD'};
const previous={id:'saved',accountID:'checking',merchant:'Example',amount:5,currency:'USD',date:'2026-11-01',pending:false,category:'FOOD_AND_DRINK',pendingID:null};
sqlite.prepare("INSERT INTO app_settings VALUES('connections_initialized','1')").run();
sqlite.prepare('INSERT INTO connections(item_id,institution_id,token_encrypted,created_at) VALUES(?,?,?,?)').run('test-bank','test-institution',await encrypt(env,'test-access'),new Date().toISOString());
sqlite.prepare('INSERT INTO snapshots(id,data) VALUES(?,?)').run('test-bank',JSON.stringify({bank:'Test Bank',metadataLoaded:true,cursor:'original',accounts:[account],transactions:[previous],importComplete:true,balanceUpdatedAt:'2026-11-08T10:00:00Z',bankUpdatedAt:'2026-11-09T10:00:00Z'}));
const {privateKey,publicKey}=await generateKeyPair('ES256');const jwk=await exportJWK(publicKey);
let fail=true,transactionCalls=0,deliverDuringSync=false,refreshCalls=0,refreshFails=false,noChanges=false,pendingReplacement=false;
const routes:string[]=[];
const ctx:any={waitUntil(){throw Error('Work must be persisted, not run in HTTP waitUntil');}};
async function signed(event:any,targetEnv=env){const raw=JSON.stringify(event),hash=createHash('sha256').update(raw).digest('hex');const jwt=await new SignJWT({request_body_sha256:hash}).setProtectedHeader({alg:'ES256',kid:'test-key'}).setIssuedAt().sign(privateKey);return worker.fetch(new Request('https://example.com/webhooks/plaid',{method:'POST',body:raw,headers:{'Plaid-Verification':jwt}}),targetEnv,ctx);}
globalThis.fetch=async(input:any,init:any)=>{
 const route=new URL(String(input)).pathname;
 routes.push(route);
 if(route==='/transactions/refresh'){
  refreshCalls++;
  return refreshFails?Response.json({error_code:'INSTITUTION_DOWN'},{status:503}):Response.json({request_id:'test-refresh'});
 }
 if(route==='/webhook_verification_key/get')return Response.json({key:{...jwk,alg:'ES256',expired_at:null}});
 if(route==='/transactions/sync'){
  transactionCalls++;
  if(fail)return Response.json({error_code:'INSTITUTION_DOWN',request_id:'test-request'},{status:503});
  if(deliverDuringSync){deliverDuringSync=false;assert.equal((await signed({webhook_type:'LIABILITIES',webhook_code:'DEFAULT_UPDATE',item_id:'test-bank'})).status,200);}
  return Response.json({added:noChanges?[]:[{transaction_id:pendingReplacement?'posted-pending':'new',pending_transaction_id:pendingReplacement?'cached-pending':null,account_id:'checking',merchant_name:'Example',amount:pendingReplacement?3.25:10,iso_currency_code:'USD',date:'2026-11-10',pending:false,personal_finance_category:{primary:'FOOD_AND_DRINK'}}],modified:[],removed:pendingReplacement?[{transaction_id:'cached-pending'}]:[],next_cursor:'next',has_more:false,transactions_update_status:'HISTORICAL_UPDATE_COMPLETE'});
 }
 if(route==='/accounts/get'||route==='/accounts/balance/get')return Response.json({accounts:[{account_id:'checking',name:'Checking',mask:'0000',type:'depository',balances:{current:100,available:100,iso_currency_code:'USD',limit:null}}]});
 if(route==='/item/get')return Response.json({item:{error:null,consented_products:[]},status:{transactions:{last_successful_update:'2026-11-09T10:00:00Z'}}});
 if(route==='/transactions/recurring/get')return Response.json({inflow_streams:[],outflow_streams:[]});
 throw Error('Unexpected route '+route);
};
const event={webhook_type:'TRANSACTIONS',webhook_code:'SYNC_UPDATES_AVAILABLE',item_id:'test-bank'};
assert.equal((await signed(event)).status,200);assert.equal(transactionCalls,0);
assert.equal(sqlite.prepare('SELECT count(*) AS count FROM sync_jobs').get()!.count,1);
await worker.scheduled({} as any,env);
let row=sqlite.prepare('SELECT * FROM sync_jobs').get()!;assert.equal(row.attempts,1);assert.equal(row.last_error,'INSTITUTION_DOWN');
assert.equal(JSON.parse(String(sqlite.prepare('SELECT data FROM snapshots WHERE id=?').get('test-bank')!.data)).cursor,'original');
fail=false;deliverDuringSync=true;sqlite.prepare('UPDATE sync_jobs SET due_at=0').run();await worker.scheduled({} as any,env);
assert.equal(sqlite.prepare('SELECT count(*) AS count FROM sync_jobs').get()!.count,1);
await worker.scheduled({} as any,env);assert.equal(sqlite.prepare('SELECT count(*) AS count FROM sync_jobs').get()!.count,0);
assert.equal(sqlite.prepare('SELECT count(*) AS count FROM transactions').get()!.count,2);
assert.equal(JSON.parse(String(sqlite.prepare('SELECT data FROM snapshots WHERE id=?').get('test-bank')!.data)).cursor,'next');
const brokenEnv={...env,DB:{...DB,prepare(sql:string){if(sql.startsWith('INSERT INTO sync_jobs'))throw Error('Storage unavailable');return DB.prepare(sql);}}};
assert.equal((await signed(event,brokenEnv)).status,503);
const readWidget=async()=>{const response=await worker.fetch(new Request('https://example.com/v1/widget',{headers:{Authorization:'Bearer '+env.WIDGET_TOKEN}}),env,ctx);assert.equal(response.status,200);return response.json() as any;};
const first=await readWidget(),second=await readWidget();assert.equal(first.accounts[0].updatedAt,'2026-11-08T10:00:00Z');assert.equal(second.accounts[0].updatedAt,first.accounts[0].updatedAt);
const manual=async(mode='balances',targetEnv=env,token=env.APP_TOKEN)=>worker.fetch(new Request('https://example.com/v1/banks/test-bank/'+mode,{method:'POST',headers:{Authorization:'Bearer '+token}}),targetEnv,ctx);
const clearRequestGate=()=>sqlite.prepare("UPDATE snapshots SET lease_until=0 WHERE id='_request_gate:test-bank'").run();
// Safe by default: deployments without verified free-plan configuration never request the add-on.
assert.equal((await manual()).status,200);assert.equal(refreshCalls,0);
env.TRANSACTIONS_REFRESH_ENABLED='true';clearRequestGate();routes.length=0;
assert.equal((await manual()).status,200);assert.equal(refreshCalls,1);
assert.ok(routes.indexOf('/transactions/refresh')<routes.indexOf('/transactions/sync'));
assert.equal((await manual()).status,429);assert.equal(refreshCalls,1);
clearRequestGate();assert.equal((await manual()).status,200);assert.equal(refreshCalls,2);
clearRequestGate();assert.equal((await manual('sync')).status,200);assert.equal(refreshCalls,2);
assert.equal((await signed(event)).status,200);await worker.scheduled({} as any,env);assert.equal(refreshCalls,2);
assert.equal((await manual('balances',env,env.WIDGET_TOKEN)).status,401);assert.equal(refreshCalls,2);
clearRequestGate();refreshFails=true;const callsBeforeFailure=transactionCalls;
const previousSuccess=sqlite.prepare("SELECT value FROM app_settings WHERE key='full_refresh:test-bank'").get()!.value;
const failedRefresh=await manual();assert.equal(failedRefresh.status,200);assert.equal((await failedRefresh.json() as any).completed,false);
assert.equal(refreshCalls,3);assert.equal(transactionCalls,callsBeforeFailure);
assert.equal(sqlite.prepare("SELECT value FROM app_settings WHERE key='full_refresh:test-bank'").get()!.value,previousSuccess);
clearRequestGate();refreshFails=false;assert.equal((await manual()).status,200);assert.equal(refreshCalls,4);
assert.equal(sqlite.prepare('SELECT count(*) AS count FROM connections').get()!.count,1);
assert.equal(sqlite.prepare('SELECT count(*) AS count FROM transactions').get()!.count,2);
console.log('Worker integration passed: signed webhook persists before acknowledgement; storage failure returns 503; transient failure retains cursor; scheduled retry succeeds; event during sync survives; transactions stay unique; widget source time stays unchanged.');
console.log('Manual refresh passed: opt-in only; refresh precedes sync; cooldown suppresses repeat requests; automatic sync never refreshes; widget access denied; failed refresh stays queued without changing last success; no new connections.');

const appRequest=(path:string,method='GET',body?:string,token=env.APP_TOKEN)=>worker.fetch(new Request('https://example.com'+path,{method,body,headers:{Authorization:'Bearer '+token,'Content-Type':'application/json'}}),env,ctx);
const callsBeforeRead=refreshCalls;
const savedDashboard=await (await appRequest('/v1/dashboard')).json() as any;
assert.equal(savedDashboard.automaticRefreshMinutes,30);assert.ok(savedDashboard.lastFullRefreshAt);assert.equal(refreshCalls,callsBeforeRead);
assert.equal((await appRequest('/v1/settings','PUT','{"automaticRefreshMinutes":15}')).status,200);
assert.equal((await (await appRequest('/v1/dashboard')).json() as any).automaticRefreshMinutes,15);
for(const body of ['{"automaticRefreshMinutes":5}','{"automaticRefreshMinutes":"15"}','null','broken'])assert.equal((await appRequest('/v1/settings','PUT',body)).status,400);
assert.equal((await appRequest('/v1/settings','PUT','{"automaticRefreshMinutes":60}',env.WIDGET_TOKEN)).status,401);
sqlite.prepare("UPDATE app_settings SET value=? WHERE key='full_refresh:test-bank'").run(String(Date.now()-16*60000));
await worker.scheduled({} as any,env);assert.equal(refreshCalls,callsBeforeRead+1);
assert.equal(sqlite.prepare('SELECT count(*) AS count FROM sync_jobs').get()!.count,0);
const afterScheduled=await (await appRequest('/v1/dashboard')).json() as any;
assert.ok(Date.parse(afterScheduled.lastFullRefreshAt)>Date.now()-60000);
assert.equal(afterScheduled.transactions.length,2);
await worker.scheduled({} as any,env);assert.equal(refreshCalls,callsBeforeRead+1);
console.log('Server refresh passed: cron refreshes due banks with no phone; reads call no Plaid APIs; settings are authenticated and validated; completed refresh time is server-owned; repeated ticks do not refresh fresh banks.');
// Preserve pending balances without reading transaction rows when the cursor has no changes.
const cachedPending={...previous,id:'cached-pending',amount:2.75,pending:true};
sqlite.prepare('INSERT INTO transactions VALUES(?,?,?,?)').run(cachedPending.id,'test-bank','checking',JSON.stringify(cachedPending));
let cachedState=JSON.parse(String(sqlite.prepare("SELECT data FROM snapshots WHERE id='test-bank'").get()!.data));
cachedState.pendingTotals={checking:2.75};
sqlite.prepare("UPDATE snapshots SET data=? WHERE id='test-bank'").run(JSON.stringify(cachedState));
const queries:string[]=[];
const trackedEnv={...env,DB:{...DB,prepare(sql:string){queries.push(sql);return DB.prepare(sql);}}};
const historyReads=()=>queries.filter(sql=>sql==='SELECT data FROM transactions WHERE bank_id=?').length;
noChanges=true;clearRequestGate();
assert.equal((await manual('balances',trackedEnv)).status,200);assert.equal(historyReads(),0);
cachedState=JSON.parse(String(sqlite.prepare("SELECT data FROM snapshots WHERE id='test-bank'").get()!.data));
assert.equal(cachedState.pendingTotals.checking,2.75);
assert.equal(sqlite.prepare("SELECT pending FROM balance_history WHERE account_id='checking' ORDER BY day DESC LIMIT 1").get()!.pending,2.75);
assert.equal(sqlite.prepare('SELECT count(*) AS count FROM transactions').get()!.count,3);
// On a pending-to-posted change, read the saved history and recompute instead of reusing the cached pending total.
noChanges=false;pendingReplacement=true;queries.length=0;clearRequestGate();
assert.equal((await manual('balances',trackedEnv)).status,200);assert.equal(historyReads(),1);
cachedState=JSON.parse(String(sqlite.prepare("SELECT data FROM snapshots WHERE id='test-bank'").get()!.data));
assert.equal(cachedState.pendingTotals.checking,0);
assert.equal(sqlite.prepare("SELECT pending FROM balance_history WHERE account_id='checking' ORDER BY day DESC LIMIT 1").get()!.pending,0);
assert.equal(sqlite.prepare("SELECT count(*) AS count FROM transactions WHERE id='cached-pending'").get()!.count,0);
assert.equal(sqlite.prepare('SELECT count(*) AS count FROM transactions').get()!.count,3);
// A legacy snapshot without cached pending totals must still load history and repair the cache.
delete cachedState.pendingTotals;
sqlite.prepare("UPDATE snapshots SET data=? WHERE id='test-bank'").run(JSON.stringify(cachedState));
noChanges=true;pendingReplacement=false;queries.length=0;clearRequestGate();
assert.equal((await manual('balances',trackedEnv)).status,200);assert.equal(historyReads(),1);
// An unrelated credential must not be decrypted during a targeted refresh.
sqlite.prepare('INSERT INTO connections(item_id,institution_id,token_encrypted,created_at) VALUES(?,?,?,?)').run('unrelated','test','invalid','test');
clearRequestGate();assert.equal((await manual()).status,200);
sqlite.prepare("DELETE FROM connections WHERE item_id='unrelated'").run();
const testBank={item_id:'test-bank',access_token:'test-only',institution_id:'test',active:true};
for(const [observed,day,zone] of [
 ['2026-03-08T04:59:00Z','2026-03-07','America/New_York'],
 ['2026-03-08T07:01:00Z','2026-03-08','America/New_York'],
 ['2026-11-02T04:59:00Z','2026-11-01','America/New_York'],
 ['2026-11-02T05:00:00Z','2026-11-02','America/New_York'],
 ['2026-11-10T07:59:00Z','2026-11-09','America/Los_Angeles']
]) {
 const statement=historyStatements({...env,HISTORY_TIME_ZONE:zone},testBank,{...cachedState,checkedAt:observed},'test-lease')[0] as any;
 assert.equal(statement.args[1],day);
}
console.log('Refresh optimization passed: unchanged sync skips saved-history reads while preserving pending balances; changes and legacy caches load history; only the target credential is decrypted; cached date formatters handle DST and configured time zones.');
