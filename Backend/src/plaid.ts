export interface Bank { item_id: string; access_token: string; institution_id: string; active: boolean }
export interface Env {
  DB: D1Database; PLAID_CLIENT_ID: string; PLAID_SECRET: string; PLAID_ENV: string;
  PLAID_ITEMS: string; APP_TOKEN: string; TOKEN_ENCRYPTION_KEY: string;
  WIDGET_TOKEN: string; PUBLIC_URL: string; HISTORY_TIME_ZONE?: string;
}
export class PlaidError extends Error {
  constructor(public code: string, public requestID?: string) { super(code); }
}
export async function plaid<T>(env: Env, route: string, body: object): Promise<T> {
  if (!['production','sandbox'].includes(env.PLAID_ENV)) throw new Error('Invalid environment');
  for (let attempt=0; attempt<3; attempt++) {
    const response = await fetch(`https://${env.PLAID_ENV}.plaid.com${route}`, {
      method:'POST', headers:{'Content-Type':'application/json','Plaid-Version':'2020-09-14'},
      body:JSON.stringify({client_id:env.PLAID_CLIENT_ID,secret:env.PLAID_SECRET,...body}),signal:AbortSignal.timeout(60000)
    });
    const result=await response.json() as T & {error_code?:string;request_id?:string};
    if(response.ok)return result;
    if(response.status===429 && attempt<2){await new Promise(r=>setTimeout(r,500*2**attempt));continue;}
    throw new PlaidError(result.error_code||'BANK_UNAVAILABLE',result.request_id);
  }
  throw new Error('Bank unavailable');
}
function bytes64(s:string):Uint8Array { return Uint8Array.from(atob(s),c=>c.charCodeAt(0)); }
function base64(bytes:Uint8Array):string { return btoa(String.fromCharCode(...bytes)); }
async function encryptionKey(env:Env):Promise<CryptoKey> {
  const bytes=bytes64(env.TOKEN_ENCRYPTION_KEY);
  if(bytes.length!==32)throw new Error('Encryption unavailable');
  return crypto.subtle.importKey('raw',bytes as BufferSource,{name:'AES-GCM'},false,['encrypt','decrypt']);
}
export async function encrypt(env:Env,value:unknown):Promise<string> {
  const iv=crypto.getRandomValues(new Uint8Array(12));
  const ciphertext=await crypto.subtle.encrypt({name:'AES-GCM',iv},await encryptionKey(env),new TextEncoder().encode(JSON.stringify(value)));
  return base64(iv)+'.'+base64(new Uint8Array(ciphertext));
}
export async function decrypt<T>(env:Env,value:string):Promise<T> {
  const [iv,body]=value.split('.');
  const clear=await crypto.subtle.decrypt({name:'AES-GCM',iv:bytes64(iv) as BufferSource},await encryptionKey(env),bytes64(body) as BufferSource);
  return JSON.parse(new TextDecoder().decode(clear));
}
export async function digest(value:string):Promise<string> {
  const bytes=await crypto.subtle.digest('SHA-256',new TextEncoder().encode(value));
  return [...new Uint8Array(bytes)].map(x=>x.toString(16).padStart(2,'0')).join('');
}
export async function matchesBearer(request:Request,token:string):Promise<boolean> {
  if(!token || token.length<32)return false;
  const a=await digest(request.headers.get('Authorization')||'');const b=await digest(`Bearer ${token}`);
  let diff=0;for(let i=0;i<a.length;i++)diff|=a.charCodeAt(i)^b.charCodeAt(i);return diff===0;
}
