export interface Account {
  id: string; bankID: string; bank: string; name: string; mask: string; type: string;
  current: number | null; available: number | null; limit: number | null; currency: string; archived?:boolean; logo?:string|null;
}
export interface Entry {
  id: string; accountID: string; merchant: string; amount: number; currency: string;
  date: string; pending: boolean; category: string; pendingID: string | null;
}
export interface Snapshot {
  cursor?: string; accounts: Account[]; transactions: Entry[]; bank: string;
  checkedAt?: string; bankUpdatedAt?: string | null; balanceUpdatedAt?: string | null;
  error?: string | null; importComplete?: boolean; metadataLoaded?:boolean; logo?:string|null; transactionsExternal?:boolean; pendingTotals?:Record<string,number>;
}
// Apply a complete pagination batch. Pending removals and posted additions may arrive on different pages.
export function applyChanges(previous: Entry[], added: Entry[], modified: Entry[], removed: string[]): Entry[] {
  const entries = new Map(previous.map(t => [t.id, t]));
  for (const id of removed) entries.delete(id);
  for (const entry of [...added, ...modified]) entries.set(entry.id, entry);
  return [...entries.values()].sort((a,b) => b.date.localeCompare(a.date) || a.id.localeCompare(b.id));
}
