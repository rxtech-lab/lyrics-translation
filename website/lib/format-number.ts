const compact = new Intl.NumberFormat('en-US', {notation: 'compact', maximumFractionDigits: 1});
export function formatNumber(value: number) {
  return compact.format(value);
}
