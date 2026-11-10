import {test} from 'node:test';
import assert from 'node:assert/strict';
import {database} from './fixtures/database.ts';
import {enqueueScheduledRefreshes,recordFullRefresh,fullRefreshTimes,refreshMinutes} from '../src/schedule.ts';
const now=1800000000000;
function fixture(){
 const env={...database(),TRANSACTIONS_REFRESH_ENABLED:'true'};
 const add=(id:string,active=1)=>env.sqlite.prepare('INSERT INTO connections(item_id,institution_id,created_at,active) VALUES(?,?,?,?)').run(id,'test','test',active);
 return {...env,add};
}
test('server schedule defaults to 30 minutes, is idempotent, and ignores fresh or disconnected banks',async()=>{
 const env=fixture();env.add('due');env.add('fresh');env.add('removed',0);
 await recordFullRefresh(env,'due',now-30*60000);await recordFullRefresh(env,'fresh',now-30*60000+1);
 assert.equal(await refreshMinutes(env),30);
 const runs=await Promise.all([enqueueScheduledRefreshes(env,now),enqueueScheduledRefreshes(env,now)]);
 assert.equal(runs.reduce((a,b)=>a+b,0),1);
 const job=env.sqlite.prepare('SELECT * FROM sync_jobs').get()!;
 assert.equal(job.kind,'refresh');assert.equal(job.subject,'due');assert.equal(job.live_balance,1);
 assert.equal(await enqueueScheduledRefreshes(env,now+60000),1); // the second bank is due on the next tick
 assert.equal(env.sqlite.prepare('SELECT count(*) AS count FROM sync_jobs').get()!.count,2);
});
test('timer ticks never reset retry backoff or reactivate a bank that needs sign-in',async()=>{
 const env=fixture();env.add('retry');env.add('blocked');await enqueueScheduledRefreshes(env,now);
 env.sqlite.prepare("UPDATE sync_jobs SET state='blocked',attempts=4,last_error='ITEM_LOGIN_REQUIRED' WHERE subject='blocked'").run();
 env.sqlite.prepare("UPDATE sync_jobs SET due_at=?,attempts=3 WHERE subject='retry'").run(now+3600000);
 assert.equal(await enqueueScheduledRefreshes(env,now+60000),0);
 assert.equal(env.sqlite.prepare("SELECT state FROM sync_jobs WHERE subject='blocked'").get()!.state,'blocked');
 const retry=env.sqlite.prepare("SELECT due_at,attempts FROM sync_jobs WHERE subject='retry'").get()!;
 assert.equal(retry.due_at,now+3600000);assert.equal(retry.attempts,3);
});
test('changing the stored interval changes the schedule without any phone activity',async()=>{
 const env=fixture();env.add('bank');await recordFullRefresh(env,'bank',now-20*60000);
 assert.equal(await enqueueScheduledRefreshes(env,now),0);
 env.sqlite.prepare("INSERT INTO app_settings VALUES('automatic_refresh_minutes','15')").run();
 assert.equal(await enqueueScheduledRefreshes(env,now),1);
 env.sqlite.prepare('DELETE FROM sync_jobs').run();
 env.sqlite.prepare("UPDATE app_settings SET value='60' WHERE key='automatic_refresh_minutes'").run();
 assert.equal(await enqueueScheduledRefreshes(env,now),0);
 env.sqlite.prepare("UPDATE app_settings SET value='invalid' WHERE key='automatic_refresh_minutes'").run();
 assert.equal(await refreshMinutes(env),30);
 assert.equal(await enqueueScheduledRefreshes({...env,TRANSACTIONS_REFRESH_ENABLED:'false'},now+3600000),0);
 assert.equal((await fullRefreshTimes(env)).get('bank'),new Date(now-20*60000).toISOString());
});
