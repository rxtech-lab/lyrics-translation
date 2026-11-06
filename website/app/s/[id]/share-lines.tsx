'use client';
import {useEffect,useLayoutEffect,useRef,useState} from 'react';
import {lyricArtwork, lyricFilename} from '@/lib/lyric-artwork';
import type {Document} from '@/lib/document';
export default function ShareLines({lines,title,target}:{target:string;lines:Document['lines'];title:string}) {
 const dialog=useRef<HTMLDialogElement>(null),[selected,setSelected]=useState<number[]>([]),[status,setStatus]=useState('');
 const anchor=useRef<HTMLSpanElement>(null),[floating,setFloating]=useState(false);
 const trigger=useRef<HTMLButtonElement>(null),label=useRef<HTMLSpanElement>(null),previousRect=useRef<DOMRect|null>(null);
 const floatingRef=useRef(false),movement=useRef<Animation[]>([]);
 // Magic move: fly the real button from its old box to the new one without scaling its contents.
 useLayoutEffect(()=>{
  const button=trigger.current,from=previousRect.current;
  previousRect.current=null;
  if(!button||!from||window.matchMedia('(prefers-reduced-motion: reduce)').matches)return;
  const to=button.getBoundingClientRect();
  // The floating button is pinned bottom-right, the inline one top-left; offset from the pinned corner so the size change doesn't drift.
  const dx=floating?from.right-to.right:from.left-to.left,dy=floating?from.bottom-to.bottom:from.top-to.top;
  const radius=getComputedStyle(button).borderRadius;
  const easing='cubic-bezier(.32, .72, 0, 1)';
  movement.current=[button.animate([
   {transform:`translate(${dx}px, ${dy}px)`,width:`${from.width}px`,height:`${from.height}px`,borderRadius:floating?'10px':`${from.height/2}px`},
   {transform:'translate(0, 0)',width:`${to.width}px`,height:`${to.height}px`,borderRadius:radius}
  ],{duration:650,easing})];
  const icon=button.querySelector('svg');
  if(icon)movement.current.push(icon.animate([{transform:'rotate(-14deg) scale(.82)'},{transform:'none'}],{duration:650,easing}));
  if(!floating&&label.current)movement.current.push(label.current.animate([{opacity:0,transform:'translateX(-6px)'},{opacity:1,transform:'none'}],{duration:320,delay:260,easing:'ease-out',fill:'backwards'}));
  return ()=>{movement.current.forEach(a=>a.cancel());movement.current=[];};
 },[floating]);
 // Keep the floating button vertically centred on the player, whatever height it wraps to.
 useEffect(()=>{
  if(!floating)return;
  const player=document.querySelector<HTMLElement>('.translation-page .floating-player:not(.karaoke-dialog .floating-player)');
  if(!player)return;
  const sync=()=>document.documentElement.style.setProperty('--player-height',`${player.offsetHeight}px`);
  const observer=new ResizeObserver(sync);observer.observe(player);
  return ()=>observer.disconnect();
 },[floating]);
 useEffect(()=>{
  const node=anchor.current;if(!node)return;
  const observer=new IntersectionObserver(([entry])=>{
   const next=!entry.isIntersecting && entry.boundingClientRect.top<=110;
   if(next===floatingRef.current)return;
   const player=document.querySelector<HTMLElement>('.translation-page .floating-player:not(.karaoke-dialog .floating-player)');
   if(player)document.documentElement.style.setProperty('--player-height',`${player.offsetHeight}px`);
   movement.current.forEach(a=>a.cancel());movement.current=[];
   previousRect.current=trigger.current?.getBoundingClientRect()??null;
   floatingRef.current=next;
   setFloating(next);
  },{rootMargin:'-110px 0px 0px 0px'});
  observer.observe(node);
  return ()=>observer.disconnect();
 },[]);
 async function download(){
  setStatus('Preparing PNG…');
  try {
   const blob=await lyricArtwork(title,target,selected.slice().sort((a,b)=>a-b).map(i=>lines[i]));
   const url=URL.createObjectURL(blob),a=document.createElement('a');a.href=url;a.download=lyricFilename(title);a.click();setTimeout(()=>URL.revokeObjectURL(url),30000);setStatus('PNG download started.');
  }catch(e){setStatus(e instanceof Error?e.message:'Sharing failed.');}
 }
 async function copy(){try{const url=new URL(location.href);url.searchParams.set('lines',selected.slice().sort((a,b)=>a-b).map(i=>i+1).join(','));await navigator.clipboard.writeText(url.toString());setStatus('Link copied.');}catch{setStatus('Could not copy the link.');}}
 return <><span ref={anchor} className="share-lines-anchor"><button ref={trigger} className={`share-lines-trigger${floating?' is-floating':''}`} aria-label="Share lyric lines" title="Share lyric lines" aria-haspopup="dialog" onClick={()=>dialog.current?.showModal()}><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true"><path d="M12 16V3m-5 5 5-5 5 5M5 13v7a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1v-7"/></svg><span ref={label} className="share-lines-label">Share lyric lines</span></button></span><dialog ref={dialog} className="share-lines-dialog" aria-labelledby="share-lines-title"><div className="share-lines-header"><div><h2 id="share-lines-title">Share lyric lines</h2><p>Select the lines to include in your image or link.</p></div><button aria-label="Close share lyric lines" onClick={()=>dialog.current?.close()}>Close</button></div><div className="share-lines-list">{lines.map((l,i)=><label key={i} className={`share-line-option${selected.includes(i)?' is-selected':''}`}><input type="checkbox" checked={selected.includes(i)} onChange={e=>setSelected(e.target.checked?[...selected,i]:selected.filter(n=>n!==i))}/><span className="share-line-number">{i+1}</span><span className="share-line-text"><span>{l.original}</span>{l.translated&&<span className="share-line-translation">{l.translated}</span>}</span></label>)}</div><div className="share-lines-footer"><span>{selected.length} selected</span><div><button disabled={!selected.length} onClick={copy}>Copy highlighted link</button><button className="primary" disabled={!selected.length} onClick={download}>Save PNG</button></div></div>{status&&<div role="status" className="share-lines-status">{status}<button onClick={()=>setStatus('')}>Dismiss</button></div>}</dialog></>;
}
