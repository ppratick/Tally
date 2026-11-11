import { encrypt, decrypt, type Bank, type Env } from './plaid';
import type { Snapshot, BalanceObservation } from './model';
interface ConnectionRow { item_id:string; institution_id:string; token_encrypted:string|null; active:number }
export type ConnectionMetadata = Pick<Bank,'item_id'|'institution_id'|'active'>;
const historyDayFormatters=new Map([['America/New_York',new Intl.DateTimeFormat('en-CA',{timeZone:'America/New_York'})]]);
// Initialize the default formatter once at Worker startup instead of rebuilding ICU state inside every refresh.
historyDayFormatters.get('America/New_York')!.format(new Date(0));
export async function initializeConnections(env:Env):Promise<void> {
  if(await env.DB.prepare("SELECT value FROM app_settings WHERE key='connections_initialized'").first())return;
  const seeds=JSON.parse(env.PLAID_ITEMS||'[]') as Bank[];
  for(const bank of seeds) {
    await env.DB.prepare('INSERT OR IGNORE INTO connections(item_id,institution_id,token_encrypted,created_at) VALUES(?,?,?,?)')
      .bind(bank.item_id,bank.institution_id,await encrypt(env,bank.access_token),new Date().toISOString()).run();
  }
  await env.DB.prepare("INSERT OR IGNORE INTO app_settings(key,value) VALUES('connections_initialized','1')").run();
}
// Read-only dashboards and metadata checks never need to fetch or decrypt credentials.
export async function connectionMetadata(env:Env,includeArchived=false):Promise<ConnectionMetadata[]> {
  await initializeConnections(env);
  const rows=await env.DB.prepare('SELECT item_id,institution_id,active FROM connections'+(includeArchived?'':' WHERE active=1'))
    .all<{item_id:string;institution_id:string;active:number}>();
  return rows.results.map(row=>({...row,active:row.active===1}));
}
export async function bankByID(env:Env,id:string):Promise<Bank|undefined> {
  await initializeConnections(env);
  const row=await env.DB.prepare('SELECT item_id,institution_id,token_encrypted,active FROM connections WHERE item_id=? AND active=1')
    .bind(id).first<ConnectionRow>();
  return row?{item_id:row.item_id,institution_id:row.institution_id,active:true,
    access_token:row.token_encrypted?await decrypt<string>(env,row.token_encrypted):''}:undefined;
}
export async function load(env:Env,id:string,includeTransactions=true):Promise<Snapshot> {
  const row=await env.DB.prepare('SELECT data FROM snapshots WHERE id=?').bind(id).first<{data:string}>();
  const state:Snapshot={accounts:[],transactions:[],bank:'Bank',...(row?JSON.parse(row.data):{})};
  if(state.transactionsExternal&&includeTransactions){const rows=await env.DB.prepare('SELECT data FROM transactions WHERE bank_id=?').bind(id).all<{data:string}>();state.transactions=rows.results.map(r=>JSON.parse(r.data));}
  return state;
}
export async function saveConnection(env:Env,bank:Omit<Bank,'active'>):Promise<void> {
  await env.DB.prepare('INSERT INTO connections(item_id,institution_id,token_encrypted,created_at,active) VALUES(?,?,?,?,1) ON CONFLICT(item_id) DO UPDATE SET token_encrypted=excluded.token_encrypted,active=1,disconnected_at=NULL')
    .bind(bank.item_id,bank.institution_id,await encrypt(env,bank.access_token),new Date().toISOString()).run();
}
export function pendingAmount(state:Snapshot,accountID:string,currency:string):number {
  if(state.transactionsExternal&&state.transactions.length===0&&state.pendingTotals)return state.pendingTotals[accountID]||0;
  const replaced=new Set(state.transactions.filter(t=>!t.pending).map(t=>t.pendingID).filter(Boolean));
  const amounts=state.transactions.filter(t=>t.pending&&!replaced.has(t.id)&&t.accountID===accountID&&t.currency===currency).map(t=>Math.round(t.amount*100));
  return amounts.reduce((s,x)=>s+x,0)/100;
}
export function historyStatements(env:Env,bank:Bank,state:Snapshot,lease:string):D1PreparedStatement[] {
  const observed=state.checkedAt||new Date().toISOString();
  const zone=env.HISTORY_TIME_ZONE||'America/New_York';
  let formatter=historyDayFormatters.get(zone);
  if(!formatter){formatter=new Intl.DateTimeFormat('en-CA',{timeZone:zone});historyDayFormatters.set(zone,formatter);}
  const day=formatter.format(new Date(observed));
  return state.accounts.filter(a=>!a.archived).map(account=>env.DB.prepare(`INSERT INTO balance_history(account_id,day,bank_id,observed_at,current,available,pending,currency)
    SELECT ?,?,?,?,?,?,?,? WHERE EXISTS(SELECT 1 FROM connections WHERE item_id=? AND active=1) AND EXISTS(SELECT 1 FROM snapshots WHERE id=? AND lease=?)
    ON CONFLICT(account_id,day) DO UPDATE SET observed_at=excluded.observed_at,current=excluded.current,available=excluded.available,pending=excluded.pending,currency=excluded.currency`)
    .bind(account.id,day,bank.item_id,observed,account.current,account.available,pendingAmount(state,account.id,account.currency),account.currency,bank.item_id,bank.item_id,lease));
}
export async function history(env:Env) {
  const rows=await env.DB.prepare('SELECT account_id AS accountID,day,observed_at AS observedAt,current,available,pending,currency FROM balance_history ORDER BY day,account_id').all<BalanceObservation>();
  return rows.results;
}

export function transactionStatements(env:Env,bank:Bank,entries:Snapshot['transactions'],removed:string[],lease:string):D1PreparedStatement[] {
  const statements:D1PreparedStatement[]=[],deletions:D1PreparedStatement[]=[];
  for(let index=0;index<entries.length;index+=500) {
    statements.push(env.DB.prepare(`INSERT INTO transactions(id,bank_id,account_id,data)
      SELECT json_extract(value,'$.id'),?,json_extract(value,'$.accountID'),value FROM json_each(?)
      WHERE EXISTS(SELECT 1 FROM snapshots WHERE id=? AND lease=?) AND EXISTS(SELECT 1 FROM connections WHERE item_id=? AND active=1)
      ON CONFLICT(id) DO UPDATE SET data=excluded.data,account_id=excluded.account_id`)
      .bind(bank.item_id,JSON.stringify(entries.slice(index,index+500)),bank.item_id,lease,bank.item_id));
  }
  for(let index=0;index<removed.length;index+=500) {
    deletions.push(env.DB.prepare('DELETE FROM transactions WHERE bank_id=? AND id IN(SELECT value FROM json_each(?)) AND EXISTS(SELECT 1 FROM snapshots WHERE id=? AND lease=?)')
      .bind(bank.item_id,JSON.stringify(removed.slice(index,index+500)),bank.item_id,lease));
  }
  return [...deletions,...statements];
}

export async function accountMappings(env:Env,bankID:string):Promise<Map<string,string>> {
  const rows=await env.DB.prepare('SELECT source_id,canonical_id FROM account_mappings WHERE bank_id=?').bind(bankID).all<{source_id:string;canonical_id:string}>();
  return new Map(rows.results.map(r=>[r.source_id,r.canonical_id]));
}
