import type { Entry } from './model';

// A full replacement import is authoritative for its covered dates. Keep older saved history,
// without fuzzy merchant/amount deduplication that would erase legitimate identical purchases.
export function mergeReplacementHistory(previous:Entry[],replacement:Entry[]):Entry[] {
  const oldest=new Map<string,string>();
  for(const t of replacement.filter(t=>!t.pending)) {
    if(!oldest.has(t.accountID)||t.date<oldest.get(t.accountID)!)oldest.set(t.accountID,t.date);
  }
  const ids=new Set(replacement.map(t=>t.id));
  return [...previous.filter(t=>!t.pending&&!ids.has(t.id)&&(!oldest.has(t.accountID)||t.date<oldest.get(t.accountID)!)),...replacement];
}
