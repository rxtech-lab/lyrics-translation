import type {Document} from '@/lib/document';
import {formatNumber} from '@/lib/format-number';

export default function UsageReport({summary = []}: {summary?: Document['usageSummary']}) {
  const total = summary.reduce((sum, row) => sum + row.tokens, 0);
  const complete = summary.length > 0 && summary.every(row => row.costUSD != null);
  const cost = (value: number) => new Intl.NumberFormat('en-US', {style: 'currency', currency: 'USD', minimumFractionDigits: 2, maximumFractionDigits: 4}).format(value);
  return <div className="usage-report">
    <dl><dt>Total tokens</dt><dd>{formatNumber(total)}</dd>
      <dt>Estimated cost</dt><dd>{complete ? cost(summary.reduce((sum, row) => sum + (row.costUSD ?? 0), 0)) : 'Unavailable'}</dd></dl>
    {summary.length ? <table className="usage-summary"><thead><tr><th>Agent</th><th>Tokens</th><th>Cost (USD)</th></tr></thead>
      <tbody>{summary.map(row => <tr key={row.agent}><th scope="row">{row.agent}</th><td>{formatNumber(row.tokens)}</td><td>{row.costUSD == null ? 'Unavailable' : cost(row.costUSD)}</td></tr>)}</tbody></table> : <p>No usage recorded.</p>}
    <p>Creator-reported estimates. Missing prices are shown as unavailable.</p>
  </div>;
}
