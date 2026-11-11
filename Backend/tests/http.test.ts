import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readText, BodyLimitError } from '../src/http.ts';

test('streamed body size is bounded by bytes, including requests without Content-Length',async()=>{
  const request=new Request('https://example.com',{method:'POST',body:'é'.repeat(8)});
  await assert.rejects(readText(request,10),BodyLimitError);
});
test('body decoder preserves UTF-8 characters split across chunks',async()=>{
  const bytes=new TextEncoder().encode('a💵éz');
  const stream=new ReadableStream({start(controller){for(const byte of bytes)controller.enqueue(new Uint8Array([byte]));controller.close();}});
  const request=new Request('https://example.com',{method:'POST',body:stream,duplex:'half'} as RequestInit);
  assert.equal(await readText(request,bytes.length),'a💵éz');
});
test('oversized advertised lengths are rejected before consuming the stream',async()=>{
  const request=new Request('https://example.com',{method:'POST',headers:{'Content-Length':'1000'},body:'small'});
  await assert.rejects(readText(request,100),BodyLimitError);
  assert.equal(request.bodyUsed,false);
});
