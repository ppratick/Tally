export class BodyLimitError extends Error {}

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
