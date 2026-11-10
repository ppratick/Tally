import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {randomBytes,createHash} from 'node:crypto';
import {generateKeyPair,exportJWK,SignJWT} from 'jose';
import worker from '../src/index.ts';
import {encrypt} from '../src/plaid.ts';
import {database} from './fixtures/database.ts';
const {DB,sqlite}=database(readFileSync('schema.sql','utf8'));
const env:any={DB,PLAID_CLIENT_ID:'test-client',PLAID_SECRET:'test-secret',PLAID_ENV:'sandbox',PLAID_ITEMS:'[]',APP_TOKEN:randomBytes(32).toString('hex'),WIDGET_TOKEN:randomBytes(32).toString('hex'),TOKEN_ENCRYPTION_KEY:randomBytes(32).toString('base64'),PUBLIC_URL:'https://example.com'};
const account={id:'checking',bankID:'test-bank',bank:'Test Bank',name:'Checking',mask:'0000',type:'depository',current:100,available:100,limit:null,currency:'USD'};
const previous={id:'saved',accountID:'checking',merchant:'Example',amount:5,currency:'USD',date:'2026-11-01',pending:false,category:'FOOD_AND_DRINK',pendingID:null};
sqlite.prepare("INSERT INTO app_settings VALUES('connections_initialized','1')").run();
sqlite.prepare('INSERT INTO connections(item_id,institution_id,token_encrypted,created_at) VALUES(?,?,?,?)').run('test-bank','test-institution',await encrypt(env,'test-access'),new Date().toISOString());
sqlite.prepare('INSERT INTO snapshots(id,data) VALUES(?,?)').run('test-bank',JSON.stringify({bank:'Test Bank',metadataLoaded:true,cursor:'original',accounts:[account],transactions:[previous],importComplete:true,balanceUpdatedAt:'2026-11-08T10:00:00Z',bankUpdatedAt:'2026-11-09T10:00:00Z'}));
const {privateKey,publicKey}=await generateKeyPair('ES256');const jwk=await exportJWK(publicKey);
let fail=true,transactionCalls=0,deliverDuringSync=false;
const ctx:any={waitUntil(){throw Error('Work must be persisted, not run in HTTP waitUntil');}};
async function signed(event:any,targetEnv=env){const raw=JSON.stringify(event),hash=createHash('sha256').update(raw).digest('hex');const jwt=await new SignJWT({request_body_sha256:hash}).setProtectedHeader({alg:'ES256',kid:'test-key'}).setIssuedAt().sign(privateKey);return worker.fetch(new Request('https://example.com/webhooks/plaid',{method:'POST',body:raw,headers:{'Plaid-Verification':jwt}}),targetEnv,ctx);}
globalThis.fetch=async(input:any,init:any)=>{
 const route=new URL(String(input)).pathname;
 if(route==='/webhook_verification_key/get')return Response.json({key:{...jwk,alg:'ES256',expired_at:null}});
 if(route==='/transactions/sync'){
  transactionCalls++;
  if(fail)return Response.json({error_code:'INSTITUTION_DOWN',request_id:'test-request'},{status:503});
  if(deliverDuringSync){deliverDuringSync=false;assert.equal((await signed({webhook_type:'LIABILITIES',webhook_code:'DEFAULT_UPDATE',item_id:'test-bank'})).status,200);}
  return Response.json({added:[{transaction_id:'new',account_id:'checking',merchant_name:'Example',amount:10,iso_currency_code:'USD',date:'2026-11-10',pending:false,personal_finance_category:{primary:'FOOD_AND_DRINK'}}],modified:[],removed:[],next_cursor:'next',has_more:false,transactions_update_status:'HISTORICAL_UPDATE_COMPLETE'});
 }
 if(route==='/accounts/get')return Response.json({accounts:[{account_id:'checking',name:'Checking',mask:'0000',type:'depository',balances:{current:100,available:100,iso_currency_code:'USD',limit:null}}]});
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
console.log('Worker integration passed: signed webhook persists before acknowledgement; storage failure returns 503; transient failure retains cursor; scheduled retry succeeds; event during sync survives; transactions stay unique; widget source time stays unchanged.');
