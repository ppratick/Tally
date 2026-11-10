import type { Env } from './plaid';

export interface SyncJob {
  id:string;kind:'bank'|'link';subject:string;revision:number;attempts:number;
  live_balance:number;force_insights:number;due_at:number;lease:string|null;lease_until:number;state:string;
}
export class JobFailure extends Error {
  code:string;blocked:boolean;
  constructor(code:string,blocked=false){super(code);this.code=code;this.blocked=blocked;}
}
const actionRequired=new Set(['ITEM_LOGIN_REQUIRED','ITEM_LOCKED','USER_PERMISSION_REVOKED','ACCESS_NOT_GRANTED',
  'ADDITIONAL_CONSENT_REQUIRED','INVALID_PRODUCT','PRODUCT_NOT_SUPPORTED','INSTITUTION_NOT_SUPPORTED']);
export function blocksAutomaticRetry(code:string):boolean {return actionRequired.has(code);}
export function failureCode(error:unknown):string {
  const code=error&&typeof error==='object'&&'code' in error?String(error.code):'CONNECTION_ERROR';
  return /^[A-Z_]{1,80}$/.test(code)?code:'CONNECTION_ERROR';
}
export async function enqueueJob(env:Pick<Env,'DB'>,kind:SyncJob['kind'],subject:string,options:{live?:boolean;insights?:boolean}={},now=Date.now()):Promise<string> {
  const id=kind+':'+subject;
  await env.DB.prepare(`INSERT INTO sync_jobs(id,kind,subject,live_balance,force_insights,due_at) VALUES(?,?,?,?,?,?)
    ON CONFLICT(id) DO UPDATE SET revision=revision+1,live_balance=MAX(live_balance,excluded.live_balance),
    force_insights=MAX(force_insights,excluded.force_insights),due_at=MIN(due_at,excluded.due_at),
    state=CASE WHEN state='blocked' THEN 'pending' ELSE state END,
    attempts=CASE WHEN state='blocked' THEN 0 ELSE attempts END,last_error=NULL`)
    .bind(id,kind,subject,options.live?1:0,options.insights?1:0,now).run();
  return id;
}
export async function runJob(env:Pick<Env,'DB'>,id:string,execute:(job:SyncJob)=>Promise<void>,now=Date.now()):Promise<boolean> {
  const job=await env.DB.prepare("SELECT * FROM sync_jobs WHERE id=? AND state!='blocked' AND due_at<=? AND lease_until<=?")
    .bind(id,now,now).first<SyncJob>();
  if(!job)return false;
  const lease=crypto.randomUUID();
  const claimed=await env.DB.prepare("UPDATE sync_jobs SET lease=?,lease_until=?,state='running' WHERE id=? AND state!='blocked' AND lease_until<=? AND due_at<=?")
    .bind(lease,now+15*60000,id,now,now).run();
  if(!claimed.meta.changes)return false;
  try {
    await execute(job);
    // An event arriving during execution increments revision. Never delete that newer work.
    await env.DB.prepare('DELETE FROM sync_jobs WHERE id=? AND lease=? AND revision=?').bind(id,lease,job.revision).run();
    await env.DB.prepare("UPDATE sync_jobs SET state='pending',lease=NULL,lease_until=0 WHERE id=? AND lease=?").bind(id,lease).run();
    return true;
  } catch(error) {
    const code=failureCode(error),blocked=error instanceof JobFailure?error.blocked:blocksAutomaticRetry(code);
    const attempt=job.attempts+1;
    const delay=Math.min(6*3600000,30000*2**Math.min(attempt-1,10));
    await env.DB.prepare(`UPDATE sync_jobs SET state=CASE WHEN revision!=? THEN 'pending' ELSE ? END,
      due_at=CASE WHEN revision!=? THEN MIN(due_at,?) ELSE ? END,attempts=?,last_error=?,lease=NULL,lease_until=0 WHERE id=? AND lease=?`)
      .bind(job.revision,blocked?'blocked':'pending',job.revision,now,now+delay,attempt,code,id,lease).run();
    return false;
  }
}
export async function runNextJob(env:Pick<Env,'DB'>,execute:(job:SyncJob)=>Promise<void>,now=Date.now()):Promise<boolean> {
  const next=await env.DB.prepare("SELECT id FROM sync_jobs WHERE state!='blocked' AND due_at<=? AND lease_until<=? ORDER BY due_at,id LIMIT 1")
    .bind(now,now).first<{id:string}>();
  return next?runJob(env,next.id,execute,now):false;
}
