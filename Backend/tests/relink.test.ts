import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mergeReplacementHistory } from '../src/relink-model.ts';
import type { Entry } from '../src/model.ts';
const entry=(id:string,date:string,accountID='credit',pending=false):Entry=>({id,date,accountID,pending,merchant:'Cafe',amount:10,currency:'USD',category:'FOOD_AND_DRINK',pendingID:null});
test('replacement uses complete new coverage without double-counting overlap or erasing identical new purchases',()=>{
  const old=[entry('old-one','2026-09-01'),entry('old-two','2026-09-01'),entry('saved-older','2024-01-01'),entry('old-pending','2026-11-10','credit',true)];
  const recent=[entry('new-one','2026-09-01'),entry('new-two','2026-09-01'),entry('new-pending','2026-11-10','credit',true)];
  const merged=mergeReplacementHistory(old,recent);
  assert.deepEqual(merged.map(t=>t.id),['saved-older','new-one','new-two','new-pending']);
  assert.deepEqual(mergeReplacementHistory(merged,recent),merged);
});
test('replacement cutoffs are per account; missing history never erases saved posted records',()=>{
  const old=[entry('first','2026-05-01'),entry('second','2026-10-01','checking')];
  const fresh=[entry('fresh','2026-01-01')];
  assert.deepEqual(mergeReplacementHistory(old,fresh).map(t=>t.id),['second','fresh']);
  assert.deepEqual(mergeReplacementHistory(old,[]),old);
});
