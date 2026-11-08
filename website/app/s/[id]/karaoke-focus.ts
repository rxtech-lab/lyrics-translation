// Items are in display order (start time, then original lyric index), as on macOS.
export function focusLine(items: readonly {start: number; end: number}[], time: number): number {
  const current = items.findIndex(item => item.start <= time + .5 && time < item.end);
  if (current >= 0) return current;
  return Math.max(0, items.findLastIndex(item => item.start <= time + .5));
}
