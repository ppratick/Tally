import type { LinkTokenGetResponse, AccountsGetResponse, ItemGetResponse } from 'plaid/legacy';
import { banks, load, saveConnection } from './repository';
import { enqueueJob } from './jobs';
import { mapReplacement } from './relink';
import { plaid, encrypt, decrypt, digest, type Env, type Bank } from './plaid';
type Sync = (env:Env,bank:Bank,live?:boolean)=>Promise<void>;
interface Session { id:string;payload_encrypted:string;expires_at:string;status:string;message:string|null }
interface Payload { token:string;url:string;replacementID?:string }
export async function startSession(env:Env,replacementID?:string) {
  if(replacementID&&!(await banks(env)).some(b=>b.item_id===replacementID))throw new Error('Connection unavailable');
  const pending=await env.DB.prepare("SELECT * FROM link_sessions WHERE status='pending' AND expires_at>? ORDER BY created_at DESC").bind(new Date().toISOString()).all<Session>();
  for(const existing of pending.results){const value=await decrypt<Payload>(env,existing.payload_encrypted);
    if(value.replacementID===replacementID)return {sessionID:existing.id,url:value.url};}
  const result=await plaid<{link_token:string;hosted_link_url:string;expiration:string}>(env,'/link/token/create',{
    user:{client_user_id:'tally-owner'},client_name:'Tally',country_codes:['US'],language:'en',products:['transactions'],additional_consented_products:['liabilities'],
    transactions:{days_requested:730},webhook:env.PUBLIC_URL+'/webhooks/plaid',hosted_link:{...(replacementID?{}:{completion_redirect_uri:'tally://link-complete'}),url_lifetime_seconds:1800}
  });
  const id=crypto.randomUUID();
  const insert=env.DB.prepare('INSERT INTO link_sessions(id,token_hash,payload_encrypted,created_at,expires_at) VALUES(?,?,?,?,?)')
    .bind(id,await digest(result.link_token),await encrypt(env,{token:result.link_token,url:result.hosted_link_url,replacementID}),new Date().toISOString(),result.expiration);
  await env.DB.batch([insert,...(replacementID?[env.DB.prepare('INSERT INTO relink_jobs(session_id,old_bank_id) VALUES(?,?)').bind(id,replacementID)]:[])]);
  return {sessionID:id,url:result.hosted_link_url};
}
async function duplicateCandidate(env:Env,institutionID:string|undefined,accounts:{mask?:string|null;type?:string|null}[],excludeID?:string):Promise<boolean> {
  if(!institutionID || accounts.length===0 || accounts.some(a=>!a.mask))return false;
  const existing=(await banks(env)).filter(b=>b.institution_id===institutionID&&b.item_id!==excludeID);
  for(const bank of existing){const state=await load(env,bank.item_id);
    if(accounts.every(a=>state.accounts.some(old=>old.mask===a.mask&&old.type===a.type)))return true;
  }
  return false;
}
export async function finishSession(env:Env,id:string,sync:Sync) {
  const session=await env.DB.prepare('SELECT * FROM link_sessions WHERE id=?').bind(id).first<Session>();
  if(!session)return {status:'expired',message:'This connection session is unavailable. Start a new connection.'};
  if(session.status!=='pending')return {status:session.status,message:session.message};
  const lock=await env.DB.prepare('UPDATE link_sessions SET lease_until=? WHERE id=? AND lease_until<?').bind(Date.now()+180000,id,Date.now()).run();
  if(!lock.meta.changes)return {status:'pending',message:'Finishing your connection securely…'};
  try {
    const payload=await decrypt<Payload>(env,session.payload_encrypted);
    const details=await plaid<LinkTokenGetResponse>(env,'/link/token/get',{link_token:payload.token});
    let imported=0,duplicates=0;
    for(const attempt of details.link_sessions||[]) {
      for(const result of attempt.results?.item_add_results||[]) {
        if(!result.public_token)continue;
        const hash=await digest(result.public_token);
        const known=await env.DB.prepare('SELECT item_id FROM processed_public_tokens WHERE hash=?').bind(hash).first<{item_id:string}>();
        if(known){imported++;continue;}
        // Detect before exchange. Exchanging a confirmed duplicate lets us remove only the newly-created Item, not the user's existing connection.
        const duplicate=await duplicateCandidate(env,result.institution?.institution_id,result.accounts||[],payload.replacementID);
        const exchanged=await plaid<{access_token:string;item_id:string}>(env,'/item/public_token/exchange',{public_token:result.public_token});
        const alreadyStored=(await banks(env,true)).some(b=>b.item_id===exchanged.item_id);
        if(duplicate&&!alreadyStored) {
          await plaid(env,'/item/remove',{access_token:exchanged.access_token});duplicates++;
        }else {
          const info=await plaid<ItemGetResponse>(env,'/item/get',{access_token:exchanged.access_token});
          const bank={...exchanged,institution_id:info.item.institution_id||result.institution?.institution_id||'unknown',active:true};
          await saveConnection(env,bank);
          if(payload.replacementID){
            await env.DB.prepare("UPDATE relink_jobs SET new_bank_id=?,status='importing' WHERE session_id=?").bind(bank.item_id,id).run();
            const original=(await banks(env)).find(b=>b.item_id===payload.replacementID);
            if(original)try{await mapReplacement(env,original,bank,id);}
            catch{
              await plaid(env,'/item/remove',{access_token:bank.access_token});
              await env.DB.prepare('UPDATE connections SET active=0,token_encrypted=NULL WHERE item_id=?').bind(bank.item_id).run();
              await env.DB.prepare("UPDATE relink_jobs SET status='failed' WHERE session_id=?").bind(id).run();
              await env.DB.prepare("UPDATE link_sessions SET status='failed',message=? WHERE id=?").bind('Choose the same bank and all existing accounts when relinking. Your original connection was kept.',id).run();
              return {status:'failed',message:'Choose the same bank and all existing accounts when relinking. Your original connection was kept.'};
            }
          }
          imported++;
          await sync(env,bank);
        }
        await env.DB.prepare('INSERT OR IGNORE INTO processed_public_tokens(hash,item_id,processed_at) VALUES(?,?,?)').bind(hash,exchanged.item_id,new Date().toISOString()).run();
      }
    }
    if(imported||duplicates) {
      const message=duplicates&&!imported?'Those accounts are already connected. Your existing connection was kept.':'Your accounts are connected.';
      await env.DB.prepare("UPDATE link_sessions SET status='complete',message=? WHERE id=?").bind(message,id).run();
      return {status:'complete',message};
    }
    if(new Date(session.expires_at).getTime()<Date.now()) {
      await env.DB.prepare("UPDATE link_sessions SET status='expired' WHERE id=?").bind(id).run();
      return {status:'expired',message:'This Link session expired. Start again to connect your bank.'};
    }
    return {status:'pending',message:'Finish connecting in Plaid, then check the connection again.'};
  }finally{await env.DB.prepare('UPDATE link_sessions SET lease_until=0 WHERE id=?').bind(id).run();}
}
export async function enqueueLinkByToken(env:Env,token:string) {
  const row=await env.DB.prepare('SELECT id FROM link_sessions WHERE token_hash=?').bind(await digest(token)).first<{id:string}>();
  if(row)await enqueueJob(env,'link',row.id);
}
export async function pendingSessionID(env:Env):Promise<string|null> {
  const row=await env.DB.prepare("SELECT id FROM link_sessions WHERE id NOT IN (SELECT session_id FROM relink_jobs) AND status='pending' AND expires_at>? ORDER BY created_at DESC LIMIT 1").bind(new Date().toISOString()).first<{id:string}>();
  return row?.id||null;
}
