import { build } from 'esbuild';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
const backend = dirname(dirname(fileURLToPath(import.meta.url)));
const temporary = mkdtempSync(join(tmpdir(), 'tally-worker-test-'));
try {
  for (const test of ['worker.integration', 'chat.integration']) {
    const outfile = join(temporary, test + '.mjs');
    await build({ entryPoints: [join(backend, 'tests', test + '.ts')], outfile, bundle: true, platform: 'node', format: 'esm', logLevel: 'silent' });
    const result = spawnSync(process.execPath, [outfile], { cwd: backend, stdio: 'inherit' });
    if (result.status !== 0) { process.exitCode = result.status ?? 1; break; }
  }
} finally { rmSync(temporary, { recursive: true, force: true }); }
