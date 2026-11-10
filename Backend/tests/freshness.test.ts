import { test } from 'node:test';
import assert from 'node:assert/strict';
import { oldestSourceTime } from '../src/freshness.ts';
test('freshness uses the oldest valid source rather than the response clock',()=>{
 assert.equal(oldestSourceTime(['2026-11-10T10:00:00Z','2026-11-09T10:00:00Z']),'2026-11-09T10:00:00Z');
 assert.equal(oldestSourceTime([null,undefined,'invalid']),null);
 assert.equal(oldestSourceTime(['2026-11-10T10:00:00.000Z',null]),'2026-11-10T10:00:00.000Z');
});
