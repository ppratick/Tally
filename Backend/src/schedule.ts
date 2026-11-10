import type { Env } from './plaid';

export const refreshIntervals=[15,30,60];
export async function refreshMinutes(env:Pick<Env,'DB'>):Promise<number> {
  const row=await env.DB.prepare("SELECT value FROM app_settings WHERE key='automatic_refresh_minutes'").first<{value:string}>();
  const value=Number(row?.value);
  return refreshIntervals.includes(value)?value:30;
}
export async function enqueueScheduledRefreshes(env:Pick<Env,'DB'|'TRANSACTIONS_REFRESH_ENABLED'>,now=Date.now()):Promise<number> {
  if(env.TRANSACTIONS_REFRESH_ENABLED!=='true')return 0;
  const minutes=await refreshMinutes(env);
  // One atomic insert: concurrent timer deliveries cannot duplicate jobs or reset an existing retry/backoff.
  // Last success is separate from cached-data checks and signed transaction webhooks.
  const result=await env.DB.prepare(`INSERT OR IGNORE INTO sync_jobs(id,kind,subject,live_balance,due_at)
    SELECT 'refresh:'||c.item_id,'refresh',c.item_id,1,? FROM connections c
    LEFT JOIN app_settings r ON r.key='full_refresh:'||c.item_id
    WHERE c.active=1 AND (r.value IS NULL OR CAST(r.value AS INTEGER)<=?)`)
    .bind(now,now-minutes*60000).run();
  return result.meta.changes;
}
export async function recordFullRefresh(env:Pick<Env,'DB'>,bankID:string,now=Date.now()):Promise<void> {
  await env.DB.prepare(`INSERT INTO app_settings(key,value) VALUES(?,?)
    ON CONFLICT(key) DO UPDATE SET value=excluded.value`).bind('full_refresh:'+bankID,String(now)).run();
}
export async function fullRefreshTimes(env:Pick<Env,'DB'>):Promise<Map<string,string>> {
  const rows=(await env.DB.prepare("SELECT key,value FROM app_settings WHERE key LIKE 'full_refresh:%'").all<{key:string;value:string}>()).results;
  return new Map(rows.filter(r=>Number.isFinite(Number(r.value))&&Number(r.value)>0)
    .map(r=>[r.key.slice('full_refresh:'.length),new Date(Number(r.value)).toISOString()]));
}
