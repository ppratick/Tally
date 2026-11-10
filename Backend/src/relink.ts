import type { AccountsGetResponse } from 'plaid/legacy';
import { banks, load } from './repository';
import { plaid, PlaidError, type Env, type Bank } from './plaid';
export interface RelinkJob { session_id:string;old_bank_id:string;new_bank_id:string|null;status:string }
export async function relinkJobs(env:Env):Promise<RelinkJob[]> {
  return (await env.DB.prepare('SELECT * FROM relink_jobs').all<RelinkJob>()).results;
}
export async function mapReplacement(env:Env,oldBank:Bank,newBank:Bank,sessionID:string):Promise<void> {
  if(oldBank.institution_id!==newBank.institution_id)throw new Error('Choose the same bank when replacing a connection');
  const old=await load(env,oldBank.item_id,false);
  const response=await plaid<AccountsGetResponse>(env,'/accounts/get',{access_token:newBank.access_token});
  const shared=response.accounts.filter(a=>['credit','depository'].includes(a.type));
  const expected=old.accounts.filter(a=>!a.archived);
  // Require every currently-shared account so no existing balance disappears on replacement.
  if(!expected.every(a=>a.mask&&shared.some(n=>n.mask===a.mask&&n.type===a.type)))throw new Error('Select all existing accounts when relinking');
  const statements=shared.flatMap(a=>{
    const matches=expected.filter(o=>o.mask===a.mask&&o.type===a.type);
    if(matches.length!==1)return [];
    return [env.DB.prepare('INSERT OR REPLACE INTO account_mappings(bank_id,source_id,canonical_id) VALUES(?,?,?)')
      .bind(newBank.item_id,a.account_id,matches[0].id)];
  });
  await env.DB.batch([...statements,env.DB.prepare("UPDATE relink_jobs SET new_bank_id=?,status='importing' WHERE session_id=?").bind(newBank.item_id,sessionID)]);
}
export async function finalizeRelink(env:Env,newID:string):Promise<void> {
  const job=await env.DB.prepare("SELECT * FROM relink_jobs WHERE new_bank_id=? AND status='importing'").bind(newID).first<RelinkJob>();
  if(!job)return;
  const current=await load(env,newID,false);
  if(!current.importComplete||current.error)return;
  const old=(await banks(env)).find(b=>b.item_id===job.old_bank_id);
  if(old)try{await plaid(env,'/item/remove',{access_token:old.access_token});}
  catch(e){if(!(e instanceof PlaidError&&e.code==='ITEM_NOT_FOUND'))throw e;}
  await env.DB.batch([
    env.DB.prepare('UPDATE connections SET active=0,token_encrypted=NULL,disconnected_at=? WHERE item_id=?').bind(new Date().toISOString(),job.old_bank_id),
    env.DB.prepare("UPDATE relink_jobs SET status='complete' WHERE session_id=?").bind(job.session_id)
  ]);
}
