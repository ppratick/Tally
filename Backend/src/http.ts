export class BodyLimitError extends Error {}

// Workers supports 'manual', but rejects 'error' before sending any request.
// Inspect the original response so credentials never reach a redirect destination.
export async function fetchWithoutRedirects(url:string,init:RequestInit):Promise<Response> {
  const response=await fetch(url,{...init,redirect:'manual'});
  if(response.status>=300&&response.status<400) {
    await response.body?.cancel();
    throw new Error('Upstream redirect rejected');
  }
  return response;
}

// Bound actual streamed bytes too: Content-Length may be absent or untrustworthy.
export async function readText(request:Request,maxBytes:number):Promise<string> {
  if(Number(request.headers.get('Content-Length')||0)>maxBytes)throw new BodyLimitError('Too large');
  const reader=request.body?.getReader();
  if(!reader)return '';
  const decoder=new TextDecoder(),parts:string[]=[];
  let size=0;
  while(true) {
    const {done,value}=await reader.read();
    if(done)break;
    size+=value.byteLength;
    if(size>maxBytes){await reader.cancel().catch(()=>{});throw new BodyLimitError('Too large');}
    parts.push(decoder.decode(value,{stream:true}));
  }
  parts.push(decoder.decode());
  return parts.join('');
}
