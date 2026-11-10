export function oldestSourceTime(values:(string|null|undefined)[]):string|null {
  const valid=values.filter((value):value is string=>!!value&&Number.isFinite(Date.parse(value)));
  return valid.length?valid.reduce((a,b)=>Date.parse(a)<=Date.parse(b)?a:b):null;
}
