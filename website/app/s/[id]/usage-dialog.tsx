'use client';
import {useRef} from 'react';
import type {Document} from '@/lib/document';
import {formatNumber} from '@/lib/format-number';
import UsageReport from './usage-report';

export default function UsageDialog({count, summary}: {count: number; summary?: Document['usageSummary']}) {
  const dialog = useRef<HTMLDialogElement>(null);
  return <>
    <button type="button" aria-haspopup="dialog" onClick={() => dialog.current?.showModal()} title={count.toLocaleString('en-US') + ' tokens'}>
      {formatNumber(count)} tokens
    </button>
    <dialog ref={dialog} className="usage-dialog" aria-labelledby="usage-title" onClick={event => {
      if (event.target === event.currentTarget) {
        const bounds = event.currentTarget.getBoundingClientRect();
        if (event.clientX < bounds.left || event.clientX > bounds.right || event.clientY < bounds.top || event.clientY > bounds.bottom) dialog.current?.close();
      }
    }}>
      <header><h2 id="usage-title">Token usage</h2><button type="button" autoFocus onClick={() => dialog.current?.close()}>Done</button></header>
      <UsageReport summary={summary}/>
    </dialog>
  </>;
}
