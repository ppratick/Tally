import assert from 'node:assert/strict';
import { randomUUID, randomBytes } from 'node:crypto';
import { readFileSync } from 'node:fs';
import worker from '../src/index.ts';
import { chatRoute } from '../src/chat.ts';
import { database } from './fixtures/database.ts';
import { encrypt } from '../src/plaid.ts';

const {DB,sqlite}=database(readFileSync('schema.sql','utf8'));
const env:any={DB,APP_TOKEN:'a'.repeat(40),WIDGET_TOKEN:'b'.repeat(40),OPENAI_MODEL:'gpt-4.1-mini',AI_DAILY_MESSAGE_LIMIT:'100',TOKEN_ENCRYPTION_KEY:randomBytes(32).toString('base64')};
const transaction={id:'flight',accountID:'card',merchant:'Airline',amount:280,currency:'USD',date:'2026-11-10',pending:false,category:'TRAVEL',pendingID:null};
const financial:any={accounts:[{id:'card',bankID:'bank',bank:'Bank',name:'Card',type:'credit',currency:'USD',mask:'0000',current:280,available:720,limit:1000}],transactions:[transaction],banks:[],history:[],statements:[],recurring:[]};
const filters={startDate:'2026-11-01',endDate:'2026-11-11',accountIDs:null,category:null,merchant:null,currency:'USD',includePending:true,excludeTransactionIDs:null};
const originalFetch=globalThis.fetch;
let mode='normal',requests:any[]=[],dataLoads=0,release:(()=>void)|undefined;
let deviceKey='test-secret';
globalThis.fetch=async(input:any,init:any)=>{
  assert.equal(input,'https://api.openai.com/v1/responses');assert.equal(init.headers.Authorization,'Bearer '+deviceKey);
  assert.equal(init.redirect,'error');
  const body=JSON.parse(init.body);requests.push(body);
  assert.equal(body.store,false);assert.ok(!JSON.stringify(body).includes(deviceKey));
  if(body.model==='gpt-6-luna')assert.deepEqual(body.reasoning,{effort:'none'});
  else assert.equal(body.reasoning,undefined);
  if(mode==='network-error')throw new TypeError('fetch failed');
  if(mode==='upstream-error')return Response.json({error:{message:'secret internal details'}},{status:401});
  if(mode==='slow')await new Promise<void>(resolve=>{release=resolve;});
  if(mode==='incomplete')return Response.json({status:'incomplete',output:[],usage:{input_tokens:80,output_tokens:1800}});
  if(mode==='loop'||body.input.at(-1)?.role==='user') {
    const name=mode==='unknown'?'executeSQL':mode==='invalid'?'summarizeSpending':'searchTransactions';
    return Response.json({status:'completed',output:[{type:'function_call',name,call_id:'call-'+requests.length,
      arguments:JSON.stringify(mode==='invalid'?{...filters,startDate:'invalid'}:{...filters,offset:0})}],usage:{input_tokens:100,output_tokens:30}});
  }
  return Response.json({status:'completed',output:[{type:'message',role:'assistant',content:[{type:'output_text',text:'Your [flight](tally://transaction/flight) cost $280.'}]}],usage:{input_tokens:150,output_tokens:20}});
};
const request=(conversationID=randomUUID(),message='Explain my spending',requestID=randomUUID())=>new Request('https://tally.test/v1/chat',{
  method:'POST',headers:{'Content-Type':'application/json','X-OpenAI-API-Key':deviceKey},body:JSON.stringify({conversationID,message,requestID,context:'Spending screen'})});
const route=(req:Request,configuration=env)=>chatRoute(req,configuration,async()=>{dataLoads++;return financial;});
try {
  // Authentication lives at the Worker boundary, before any billable AI call.
  const unauthenticated=await worker.fetch(request(),env,{} as any);assert.equal(unauthenticated.status,401);assert.equal(requests.length,0);
  const widgetRequest=request();widgetRequest.headers.set('Authorization','Bearer '+env.WIDGET_TOKEN);
  assert.equal((await worker.fetch(widgetRequest,env,{} as any)).status,401);
  const missingKey=request();missingKey.headers.delete('X-OpenAI-API-Key');
  assert.equal((await route(missingKey,{...env,OPENAI_API_KEY:'unused-server-key'})).status,400);
  for(const value of ['bad key','x'.repeat(513)]) {
    const invalidKey=request();invalidKey.headers.set('X-OpenAI-API-Key',value);
    assert.equal((await route(invalidKey)).status,400);
  }
  assert.equal((await route(new Request('https://tally.test/v1/chat',{method:'POST',headers:{'X-OpenAI-API-Key':deviceKey},body:'null'}))).status,400);
  assert.equal((await route(request(randomUUID(),'x'.repeat(4001)))).status,400);
  assert.equal((await route(new Request('https://tally.test/v1/chat',{method:'POST',headers:{'X-OpenAI-API-Key':deviceKey},body:'x'.repeat(12001)}))).status,413);
  assert.equal(requests.length,0);

  // Exercise the real authenticated route and canonical dashboard loader, not just the tool fixtures.
  sqlite.prepare('INSERT INTO connections(item_id,institution_id,token_encrypted,created_at) VALUES(?,?,?,?)')
    .run('bank','institution',await encrypt(env,'private-plaid-token'),new Date().toISOString());
  sqlite.prepare('INSERT INTO snapshots(id,data) VALUES(?,?)').run('bank',JSON.stringify({accounts:financial.accounts,transactions:[],transactionsExternal:true,bank:'Bank',importComplete:true}));
  sqlite.prepare('INSERT INTO transactions(id,bank_id,account_id,data) VALUES(?,?,?,?)').run('flight','bank','card',JSON.stringify(transaction));
  const authenticated=request();authenticated.headers.set('Authorization','Bearer '+env.APP_TOKEN);
  const routed=await worker.fetch(authenticated,env,{} as any);assert.equal(routed.status,200);
  assert.equal(((await routed.json()) as any).sources[0].id,'flight');
  assert.ok(!JSON.stringify(requests).includes('private-plaid-token'));requests=[];

  const id=randomUUID(),requestID=randomUUID();
  let response=await route(request(id,'Explain my spending',requestID));assert.equal(response.status,200);
  const reply=await response.json() as any;
  assert.equal(reply.modelCalls,2);assert.equal(reply.inputTokens,250);assert.equal(reply.outputTokens,50);assert.equal(reply.sources[0].id,'flight');assert.equal(dataLoads,1);
  assert.equal(requests[0].input.length,1);assert.equal(requests[1].input.at(-1).type,'function_call_output');
  const usage=()=>sqlite.prepare('SELECT * FROM ai_usage WHERE conversation_id=? AND request_id=? ORDER BY call_number').all(id,requestID);
  assert.equal(usage().length,2);assert.ok(usage().every(row=>row.status==='completed'&&row.model==='gpt-4.1-mini'&&row.http_status===200));
  assert.deepEqual(usage().map(row=>row.call_number),[1,2]);
  assert.equal(usage().reduce((sum,row)=>sum+Number(row.input_tokens),0),250);
  assert.equal(usage().reduce((sum,row)=>sum+Number(row.output_tokens),0),50);
  assert.ok(!JSON.stringify(sqlite.prepare('SELECT * FROM chat_sessions').all()).includes(deviceKey));
  assert.ok(!JSON.stringify(sqlite.prepare('SELECT * FROM ai_usage').all()).includes(deviceKey));
  const calls=requests.length;
  assert.deepEqual(await (await route(request(id,'Explain my spending',requestID))).json(),reply);assert.equal(requests.length,calls);
  assert.equal(usage().length,2);
  assert.equal((await route(request(id,'Different message',requestID))).status,400);
  response=await route(request(id,'What about without the flight?'));assert.equal(response.status,200);
  assert.ok(requests.at(-2).input.some((item:any)=>item.type==='function_call_output'));assert.equal(dataLoads,2);
  assert.equal(sqlite.prepare('SELECT lease_until FROM chat_sessions WHERE id=?').get(id)!.lease_until,0);

  mode='loop';requests=[];
  response=await route(request());assert.equal(response.status,502);assert.equal(requests.length,4);assert.equal(requests[3].tool_choice,'none');
  mode='unknown';requests=[];dataLoads=0;
  response=await route(request());assert.equal(response.status,200);assert.equal(dataLoads,0);
  assert.match(requests[1].input.at(-1).output,/Unknown financial tool/);
  mode='invalid';requests=[];
  response=await route(request());assert.equal(response.status,200);assert.match(requests[1].input.at(-1).output,/Invalid startDate/);
  mode='upstream-error';requests=[];
  const failureID=randomUUID();
  response=await route(request(failureID));assert.equal(response.status,502);assert.ok(!JSON.stringify(await response.json()).includes('secret internal'));
  const failed=sqlite.prepare('SELECT * FROM ai_usage WHERE conversation_id=?').get(failureID)!;
  assert.equal(failed.status,'failed');assert.equal(failed.http_status,401);assert.equal(failed.input_tokens,null);
  mode='incomplete';const incompleteID=randomUUID();assert.equal((await route(request(incompleteID))).status,502);
  const incomplete=sqlite.prepare('SELECT * FROM ai_usage WHERE conversation_id=?').get(incompleteID)!;
  assert.equal(incomplete.status,'failed');assert.equal(incomplete.output_tokens,1800);
  mode='network-error';const networkID=randomUUID();assert.equal((await route(request(networkID))).status,503);
  const network=sqlite.prepare('SELECT * FROM ai_usage WHERE conversation_id=?').get(networkID)!;
  assert.equal(network.status,'failed');assert.equal(network.http_status,null);assert.ok(network.finished_at);
  mode='normal';requests=[];
  assert.equal((await route(request(),{...env,OPENAI_MODEL:undefined})).status,200);
  assert.equal(requests[0].model,'gpt-6-luna');requests=[];
  const beforeQuota=sqlite.prepare('SELECT count(*) AS count FROM ai_usage').get()!.count;
  response=await route(request(),{...env,AI_DAILY_MESSAGE_LIMIT:'0'});assert.equal(response.status,429);assert.equal(requests.length,0);
  assert.equal(sqlite.prepare('SELECT count(*) AS count FROM ai_usage').get()!.count,beforeQuota);

  const busyID=randomUUID();
  sqlite.prepare('INSERT INTO chat_sessions(id,updated_at,lease_until) VALUES(?,?,?)').run(busyID,Date.now(),Date.now()+60000);
  assert.equal((await route(request(busyID))).status,409);
  assert.equal((await route(new Request('https://tally.test/v1/chat/'+busyID,{method:'DELETE'}))).status,409);
  const expiredID=randomUUID();sqlite.prepare('INSERT INTO chat_sessions(id,updated_at) VALUES(?,?)').run(expiredID,Date.now()-31*86400000);
  await route(request());assert.equal(sqlite.prepare('SELECT id FROM chat_sessions WHERE id=?').get(expiredID),undefined);

  // Retain complete turns, not orphaned tool outputs, as old context is dropped.
  for(let i=0;i<8;i++)assert.equal((await route(request(id,'Follow-up '+i))).status,200);
  const turns=JSON.parse(String(sqlite.prepare('SELECT data FROM chat_sessions WHERE id=?').get(id)!.data));
  assert.ok(turns.length<=6);assert.equal(turns.at(-1).message,'Follow-up 7');
  for(const turn of turns){assert.equal(turn.items[0].role,'user');assert.equal(turn.items.at(-1).type,'message');}
  assert.equal((await route(new Request('https://tally.test/v1/chat/'+id,{method:'DELETE'}))).status,200);
  assert.equal(sqlite.prepare('SELECT id FROM chat_sessions WHERE id=?').get(id),undefined);
  assert.equal(usage().length,2); // Usage survives context truncation and conversation deletion.
  deviceKey='replacement-device-key';
  const replacementID=randomUUID();assert.equal((await route(request(replacementID))).status,200);
  assert.ok(!JSON.stringify(sqlite.prepare('SELECT * FROM chat_sessions WHERE id=?').all(replacementID)).includes(deviceKey));
  assert.ok(!JSON.stringify(sqlite.prepare('SELECT * FROM ai_usage WHERE conversation_id=?').all(replacementID)).includes(deviceKey));
  const columns=sqlite.prepare('PRAGMA table_info(ai_usage)').all().map(row=>row.name);
  assert.ok(!columns.some(name=>/message|prompt|content|secret|key/.test(String(name))));
  console.log('Chat passed: authentication, retrieval, follow-ups, retry deduplication, four-call cap, failures, quota, retention/deletion, per-call usage, Luna configuration, and request-scoped device keys excluded from database storage.');
} finally {globalThis.fetch=originalFetch;sqlite.close();}
