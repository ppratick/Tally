import { build } from 'esbuild';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
const backend = dirname(dirname(fileURLToPath(import.meta.url)));
const temporary = mkdtempSync(join(tmpdir(), 'tally-worker-test-'));
try {
  const outfile = join(temporary, 'worker-test.mjs');
  await build({ entryPoints: [join(backend, 'tests/worker.integration.ts')], outfile, bundle: true, platform: 'node', format: 'esm', logLevel: 'silent' });
  const result = spawnSync(process.execPath, [outfile], { cwd: backend, stdio: 'inherit' });
  process.exitCode = result.status ?? 1;
} finally { rmSync(temporary, { recursive: true, force: true }); }
