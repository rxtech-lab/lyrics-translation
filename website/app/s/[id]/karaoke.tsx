"use client";
import PlayerIcon from './player-icon';
import {memo, useEffect, useMemo, useRef, useState, type ReactNode} from 'react';
import {createPortal} from 'react-dom';
import type {Document} from '@/lib/document';
type Word = NonNullable<Document['lines'][number]['originalTiming']>[number];
export function resolve(words: Word[]) {
  let previous: number | null = null;
  return words.map((word, index) => {
    if (word.start == null && word.end == null) { previous = null; return null; }
    let start = word.start ?? previous ?? Math.max(0, (word.end ?? 0) - .4);
    if (word.start == null && word.end != null) start = Math.min(start, word.end);
    const next = words.slice(index + 1).find(w => w.start != null || w.end != null);
    const nextTime = next ? next.start ?? (start + next.end!) / 2 : null;
    const end = Math.max(start, word.end ?? (nextTime == null ? start + .5 : Math.min(nextTime, start + 1.5)));
    previous = end;
    return {start, end};
  });
}
export default function Karaoke({open, onClose, lines, getTime, onSeek, title, artist, children}: {
  open: boolean; onClose: () => void; lines: Document['lines']; getTime: () => number; onSeek: (time: number) => void; title?: string; artist?: string; children: ReactNode;
}) {
  const dialog = useRef<HTMLDialogElement>(null);
  const stage = useRef<HTMLDivElement>(null);
  const [present, setPresent] = useState(false);
  const [mounted, setMounted] = useState(false);
  const [translation, setTranslation] = useState(false);
  const [offset, setOffset] = useState(0);
  useEffect(() => setMounted(true), []);
  useEffect(() => {
    if (!open) {
      const timer = window.setTimeout(() => { dialog.current?.close(); setPresent(false); }, window.matchMedia('(prefers-reduced-motion: reduce)').matches ? 0 : 240);
      return () => window.clearTimeout(timer);
    }
    setPresent(true);
    dialog.current?.showModal();
    const previous = document.body.style.overflow;
    document.body.style.overflow = 'hidden';
    return () => { document.body.style.overflow = previous; };
  }, [open, mounted]);
  const groups = useMemo(() => {
    const speakers = [...new Set(lines.map(l => l.speaker).filter(Boolean))];
    const items = lines.map((line, index) => {
      const words = (translation ? line.translationTiming : line.originalTiming) ?? [];
      const ranges = resolve(words);
      const timed = ranges.filter(r => r !== null);
      return {line, index, words, ranges, right: !!line.speaker && speakers.indexOf(line.speaker) % 2 === 1,
        start: timed.length ? Math.min(...timed.map(r => r.start)) : Infinity,
        end: timed.length ? Math.max(...timed.map(r => r.end)) : Infinity};
    }).filter(l => Number.isFinite(l.start)).sort((a,b) => a.start - b.start || a.index - b.index);
    const result: {start:number; end:number; items:typeof items}[] = [];
    for (const item of items) {
      const last = result.at(-1);
      if (last && item.start < last.end) { last.items.push(item); last.end = Math.max(last.end, item.end); }
      else result.push({start:item.start, end:item.end, items:[item]});
    }
    result.forEach(g => g.items.sort((a,b) => a.index-b.index));
    return result;
  }, [lines, translation]);
  const [focus, setFocus] = useState(0);
  const seekRef = useRef(onSeek);
  seekRef.current = onSeek;
  const flow = useRef<HTMLDivElement>(null);
  const manual = useRef({delta: 0, timer: 0});
  const offsetRef = useRef(0);
  offsetRef.current = offset;
  const resetScroll = () => {
    window.clearTimeout(manual.current.timer);
    manual.current.delta = 0;
    flow.current?.classList.remove('is-manual');
    flow.current?.style.setProperty('--scroll', '0px');
  };
  useEffect(() => {
    if (!open || !stage.current) return;
    // Cache nodes once, keeping frame updates out of React reconciliation.
    const rows = groups.flatMap(group => group.items).map(item => ({
      item,
      node: stage.current!.querySelector<HTMLElement>(`[data-line="${item.index}"]`)!,
      words: Array.from(stage.current!.querySelectorAll<HTMLElement>(`[data-line="${item.index}"] .karaoke-word`)),
      fills: [] as HTMLElement[],
      progress: item.words.map(() => -1),
      state: '',
    }));
    rows.forEach(row => { row.fills = row.words.map(word => word.firstElementChild as HTMLElement); });
    let frame = 0;
    let previousTime = -1;
    let previousFocus = -1;
    const draw = () => {
      const time = getTime();
      if (time !== previousTime) {
        previousTime = time;
        const next = Math.max(0, groups.findLastIndex(g => g.start <= time + .25));
        if (next !== previousFocus) { previousFocus = next; setFocus(next); }
        for (const row of rows) {
          const {item, node, words, fills, progress} = row;
          const state = time >= item.end ? 'past' : time >= item.start ? 'current' : '';
          if (state !== row.state) {
            row.state = state;
            node.classList.toggle('current', state === 'current');
            node.classList.toggle('past', state === 'past');
          }
          // Only lines near the playhead can change word progress.
          if (time < item.start - .1 && progress[0] === 0) continue;
          if (time > item.end + .1 && progress[progress.length - 1] === 1) continue;
          for (let index = 0; index < item.ranges.length; index++) {
            const range = item.ranges[index];
            const value = range ? Math.max(0, Math.min(1, range.end > range.start
              ? (time - range.start) / (range.end - range.start) : time >= range.start ? 1 : 0)) : 0;
            if (Math.abs(value - progress[index]) < .002 && value !== 0 && value !== 1) continue;
            if (value === progress[index]) continue;
            progress[index] = value;
            words[index].style.transform = `translate3d(0,${-2 * value * value * (3 - 2 * value)}px,0)`;
            fills[index].style.clipPath = `inset(0 ${(1 - value) * 100}% 0 0)`;
          }
        }
      }
      frame = requestAnimationFrame(draw);
    };
    frame = requestAnimationFrame(draw);
    return () => cancelAnimationFrame(frame);
  }, [open, groups, getTime]);
  useEffect(() => {
    if (!open || !stage.current) return;
    const measure = () => {
      const element = stage.current?.querySelector<HTMLElement>(`[data-group="${focus}"]`);
      if (element) setOffset(element.offsetTop);
    };
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(stage.current);
    return () => observer.disconnect();
  }, [open, focus, groups]);
  // Manual scrolling: shift the whole flow by a user offset, then return to the
  // playhead after a short idle period.
  useEffect(() => {
    const element = stage.current;
    if (!open || !element) return;
    const state = manual.current;
    const scrollBy = (amount: number) => {
      const node = flow.current;
      if (!node) return;
      const height = node.scrollHeight;
      const min = -offsetRef.current - element.clientHeight * .3;
      const max = height - offsetRef.current - element.clientHeight * .3;
      state.delta = Math.max(min, Math.min(max, state.delta + amount));
      node.classList.add('is-manual');
      node.style.setProperty('--scroll', `${-state.delta}px`);
      window.clearTimeout(state.timer);
      state.timer = window.setTimeout(() => {
        node.classList.remove('is-manual');
        state.delta = 0;
        node.style.setProperty('--scroll', '0px');
      }, 3000);
    };
    const onWheel = (event: WheelEvent) => {
      event.preventDefault();
      scrollBy(event.deltaMode === 1 ? event.deltaY * 32 : event.deltaY);
    };
    let lastY: number | null = null;
    const onTouchStart = (event: TouchEvent) => { lastY = event.touches[0]?.clientY ?? null; };
    const onTouchMove = (event: TouchEvent) => {
      const y = event.touches[0]?.clientY;
      if (lastY == null || y == null) return;
      event.preventDefault();
      scrollBy(lastY - y);
      lastY = y;
    };
    const onTouchEnd = () => { lastY = null; };
    element.addEventListener('wheel', onWheel, {passive: false});
    element.addEventListener('touchstart', onTouchStart, {passive: true});
    element.addEventListener('touchmove', onTouchMove, {passive: false});
    element.addEventListener('touchend', onTouchEnd);
    return () => {
      element.removeEventListener('wheel', onWheel);
      element.removeEventListener('touchstart', onTouchStart);
      element.removeEventListener('touchmove', onTouchMove);
      element.removeEventListener('touchend', onTouchEnd);
      window.clearTimeout(state.timer);
    };
  }, [open]);
  const handleSeek = useMemo(() => (time: number) => { resetScroll(); seekRef.current(time); }, []);
  return <>{!present && children}{mounted && createPortal(<dialog ref={dialog} className={`karaoke-dialog ${open ? "is-open" : "is-closing"}`} onCancel={event => { event.preventDefault(); onClose(); }} aria-label="Fullscreen lyrics">
    <div className="karaoke-heading"><div><strong>{title || 'Linked song'}</strong><small>{artist}</small></div><div className="karaoke-options"><button onClick={() => setTranslation(!translation)}>{translation ? 'Translation' : 'Original'}</button><button onClick={onClose} aria-label="Close fullscreen lyrics"><PlayerIcon name="close"/></button></div></div>
    <div className="karaoke-stage" ref={stage}>
      {!groups.length ? <div className="karaoke-empty"><h2>No word timings yet</h2><p>Time the {translation ? 'translated' : 'original'} lyrics in the Mac app and publish again.</p></div> : <div className="karaoke-flow" ref={flow}><KaraokeFlow groups={groups} focus={focus} offset={offset} translation={translation} onSeek={handleSeek}/></div>}
    </div>
    {present && children}
  </dialog>, document.body)}</>;
}

type Group = {start:number; end:number; items:{line: Document['lines'][number]; index:number; words:Word[]; right:boolean; start:number}[]};
// Memoized so the parent's frequent re-renders (playback position polling) don't
// reconcile every lyric word.
const KaraokeFlow = memo(function KaraokeFlow({groups, focus, offset, translation, onSeek}: {groups: Group[]; focus: number; offset: number; translation: boolean; onSeek: (time: number) => void}) {
  return <>{groups.map((group, index) => <div key={index} data-group={index} className="karaoke-group" style={{transform:`translate3d(0,${-offset}px,0)`, transitionDelay:`${Math.min(.3, Math.max(0,index-focus)*.05)}s`}}>{group.items.map(item =>
    <button key={item.index} data-line={item.index} className={`karaoke-line ${item.right ? 'right' : ''}`} onClick={() => onSeek(Math.max(0,item.start-.25))}>
      <small>{[item.line.section,item.line.speaker].filter(Boolean).join(' · ')}</small>
      <div>{item.words.map((word,i) => <span key={i} className="karaoke-word">{word.text}<span aria-hidden="true" style={{clipPath:'inset(0 100% 0 0)'}}>{word.text}</span>{word.space ? '\u00a0' : ''}</span>)}</div>
      <p>{translation ? item.line.original : item.line.translated}</p>
    </button>)}</div>)}</>;
});
