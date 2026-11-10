import { test } from 'node:test';
import assert from 'node:assert/strict';
import { enqueueJob,runJob,runNextJob,JobFailure } from '../src/jobs.ts';
import { database } from './fixtures/database.ts';
const now=1800000000000;

test('transient failures persist and back off, then disappear only after success',async()=>{
 const env=database(),id=await enqueueJob(env,'bank','test-bank',{live:true},now);
 let calls=0;
 const fail=async()=>{calls++;throw new JobFailure('CONNECTION_ERROR');};
 assert.equal(await runJob(env,id,fail,now),false);
 let saved=env.sqlite.prepare('SELECT * FROM sync_jobs WHERE id=?').get(id)!;
 assert.equal(saved.state,'pending');assert.equal(saved.attempts,1);assert.equal(saved.last_error,'CONNECTION_ERROR');
 assert.equal(saved.due_at,now+30000);assert.equal(saved.lease_until,0);
 await runNextJob(env,fail,now+29999);assert.equal(calls,1);
 await runNextJob(env,fail,now+30000);
 saved=env.sqlite.prepare('SELECT * FROM sync_jobs WHERE id=?').get(id)!;
 assert.equal(saved.due_at,now+90000);assert.equal(saved.attempts,2);
 assert.equal(await runNextJob(env,async()=>{},now+90000),true);
 assert.equal(env.sqlite.prepare('SELECT COUNT(*) AS count FROM sync_jobs').get()!.count,0);
});
test('events during an in-flight sync survive completion, with coalesced refresh options',async()=>{
 const env=database(),id=await enqueueJob(env,'bank','test-bank',{},now);
 await runJob(env,id,async()=>{await enqueueJob(env,'bank','test-bank',{insights:true,live:true},now+1);},now);
 const saved=env.sqlite.prepare('SELECT * FROM sync_jobs WHERE id=?').get(id)!;
 assert.equal(saved.revision,2);assert.equal(saved.state,'pending');assert.equal(saved.force_insights,1);assert.equal(saved.live_balance,1);
 await runJob(env,id,async()=>{},now+2);
 assert.equal(env.sqlite.prepare('SELECT COUNT(*) AS count FROM sync_jobs').get()!.count,0);
});
test('a crashed execution is reclaimed after lease expiry, without concurrent execution',async()=>{
 const env=database(),id=await enqueueJob(env,'bank','test-bank',{},now);
 env.sqlite.prepare("UPDATE sync_jobs SET lease='interrupted',lease_until=?,state='running' WHERE id=?").run(now+1000,id);
 let calls=0;
 assert.equal(await runJob(env,id,async()=>{calls++;},now+999),false);
 assert.equal(await runJob(env,id,async()=>{calls++;},now+1001),true);assert.equal(calls,1);
 const next=await enqueueJob(env,'bank','next-bank',{},now);
 let release!:()=>void;
 const executing=runJob(env,next,()=>new Promise<void>(resolve=>{release=resolve;}),now);
 await new Promise(resolve=>setImmediate(resolve));
 assert.equal(await runJob(env,next,async()=>{calls++;},now),false);
 release();await executing;assert.equal(calls,1);
});
test('login-required failures stop retrying until a new event reactivates the job',async()=>{
 const env=database(),id=await enqueueJob(env,'bank','test-bank',{},now);
 await runJob(env,id,async()=>{throw Object.assign(new Error(),{code:'ITEM_LOGIN_REQUIRED'});},now);
 assert.equal(env.sqlite.prepare('SELECT state FROM sync_jobs').get()!.state,'blocked');
 assert.equal(await runNextJob(env,async()=>{throw Error('must not run');},now+86400000),false);
 await enqueueJob(env,'bank','test-bank',{},now+86400000);
 assert.equal(await runNextJob(env,async()=>{},now+86400000),true);
});
test('empty timer ticks do not execute any bank work',async()=>{
 const env=database();let called=false;
 assert.equal(await runNextJob(env,async()=>{called=true;},now),false);assert.equal(called,false);
});
