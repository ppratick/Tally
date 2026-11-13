import { build } from 'esbuild';
import { mkdtempSync, rmSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import assert from 'node:assert/strict';
import { Miniflare, convertV4MiniflareOptions } from 'miniflare';
const backend = dirname(dirname(fileURLToPath(import.meta.url)));
const temporary = mkdtempSync(join(tmpdir(), 'tally-worker-test-'));
try {
  for (const test of ['worker.integration', 'chat.integration', 'payment-tracking.integration']) {
    const outfile = join(temporary, test + '.mjs');
    await build({ entryPoints: [join(backend, 'tests', test + '.ts')], outfile, bundle: true, platform: 'node', format: 'esm', logLevel: 'silent' });
    const result = spawnSync(process.execPath, [outfile], { cwd: backend, stdio: 'inherit' });
    if (result.status !== 0) { process.exitCode = result.status ?? 1; break; }
  }
  if (!process.exitCode) {
    const outfile = join(temporary, 'provider-runtime.mjs');
    await build({ entryPoints: [join(backend, 'tests/provider-runtime.ts')], outfile, bundle: true, platform: 'browser', format: 'esm', logLevel: 'silent' });
    const runtime = new Miniflare(convertV4MiniflareOptions({
      compatibilityDate: '2026-11-09',
      workers: [
        { name: 'test', modules: true, script: readFileSync(outfile, 'utf8'), outboundService: 'provider' },
        { name: 'provider', modules: true, script: `export default { fetch(request) {
          const path = new URL(request.url).pathname;
          if (path === '/success') return Response.json({ok:true});
          if (path === '/redirect') return new Response(null,{status:302,headers:{Location:'https://untrusted.test/capture'}});
          return new Response('Unexpected redirect destination',{status:500});
        }};` },
      ],
    }));
    try {
      const success = await runtime.dispatchFetch('http://test/success');
      assert.equal(success.status, 200);
      assert.equal((await success.json()).status, 200);
      const redirect = await runtime.dispatchFetch('http://test/redirect');
      assert.equal(redirect.status, 502);
      assert.equal((await redirect.json()).error, 'Upstream redirect rejected');
      console.log('Workers runtime passed: provider requests succeed with supported redirect handling; redirects are rejected before credentials can be forwarded.');
    } finally { await runtime.dispose(); }
  }
} finally { rmSync(temporary, { recursive: true, force: true }); }
