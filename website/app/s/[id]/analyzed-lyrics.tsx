'use client';
import {Fragment,useEffect,useState,type CSSProperties} from 'react';
import type {Document} from '@/lib/document';

type Line=Document['lines'][number];
type Rhyme=NonNullable<Line['rhymes']>[number];
const storageKey='lyricstudio.analysis-popover';
type Focus={line:number;rhyme:number|null};

const palette=['#5b9dff','#f2b55f','#7fd6a4','#e58fd0','#8fd3f2','#f28b82','#c3a6ff','#d7e07a'];
const normalize=(word:string)=>word.toLowerCase().replace(/[’‘]/g,"'").replace(/^[^\p{L}\p{N}]+|[^\p{L}\p{N}]+$/gu,'');
/** "me / busy" → {"me","busy"}; multi-word phrases contribute every word. */
const rhymeWords=(r:Rhyme)=>new Set(r.words.split(/[\/,;|]/).flatMap(part=>part.trim().split(/\s+/)).map(normalize).filter(Boolean));
const colorFor=(sound:string)=>{let h=0;for(const c of sound)h=(h*31+c.charCodeAt(0))>>>0;return palette[h%palette.length];};

export default function AnalyzedLyrics({lines,highlighted}:{lines:Document['lines'];highlighted:number[]}) {
 const [focus,setFocus]=useState<Focus|null>(null),[enabled,setEnabled]=useState(true);
 useEffect(()=>{try{if(localStorage.getItem(storageKey)==='off')setEnabled(false);}catch{}},[]);
 const toggle=(on:boolean)=>{setEnabled(on);if(!on)setFocus(null);try{localStorage.setItem(storageKey,on?'on':'off');}catch{}};
 const hasAnalysis=lines.some(l=>(l.syllables||0)>0||!!l.stress||(l.rhymes?.length||0)>0);
 const marked=new Set(highlighted);

 // Words to colour in each line for the hovered line (and, if hovering one row, just that rhyme).
 const highlights=new Map<number,Map<string,string>>();
 if(focus){
  const source=lines[focus.line]?.rhymes||[];
  source.forEach((r,ri)=>{
   if(focus.rhyme!=null&&focus.rhyme!==ri)return;
   const words=rhymeWords(r),color=colorFor(r.sound);
   for(const target of [focus.line,...r.relatedLines.map(n=>n-1)]){
    if(!lines[target])continue;
    const map=highlights.get(target)??new Map<string,string>();
    words.forEach(w=>{if(!map.has(w))map.set(w,color);});
    highlights.set(target,map);
   }
  });
 }
 const related=new Set(focus?(lines[focus.line]?.rhymes||[]).filter((_,ri)=>focus.rhyme==null||focus.rhyme===ri).flatMap(r=>r.relatedLines.map(n=>n-1)).filter(n=>n!==focus.line):[]);

 return <>{hasAnalysis&&<div className="analysis-toggle-bar">
  <label className="analysis-toggle">
   <input type="checkbox" role="switch" checked={enabled} onChange={e=>toggle(e.target.checked)}/>
   <span className="analysis-switch" aria-hidden="true"/>
   <span>Rhythm &amp; rhyme on hover</span>
  </label>
 </div>}
 <div className={`lyrics${enabled?'':' analysis-off'}`}>{lines.map((l,i)=>{
  const rhymes=l.rhymes||[],stress=(l.stress||'').replace(/[^01]/g,''),syllables=l.syllables||stress.length;
  const analyzed=enabled&&(syllables>0||rhymes.length>0),words=highlights.get(i);
  return <article key={i} id={`line-${i+1}`}
   className={`translation-line${analyzed?' has-analysis':''}${related.has(i)?' is-rhyme-partner':''}${focus?.line===i?' is-analysis-open':''}`}
   style={marked.has(i+1)?{background:'#fff0b3',color:'#222',borderRadius:12,boxShadow:'inset 4px 0 #d4a017'}:undefined}
   tabIndex={analyzed?0:undefined}
   aria-describedby={analyzed?`analysis-${i+1}`:undefined}
   onMouseEnter={analyzed?()=>setFocus({line:i,rhyme:null}):undefined}
   onMouseLeave={analyzed?()=>setFocus(f=>f?.line===i?null:f):undefined}
   onFocus={analyzed?()=>setFocus(f=>f?.line===i?f:{line:i,rhyme:null}):undefined}
   onBlur={analyzed?e=>{if(!e.currentTarget.contains(e.relatedTarget as Node))setFocus(f=>f?.line===i?null:f);}:undefined}>
   <div className="line-context">
    <span className="line-number">{String(i+1).padStart(2,'0')}</span>
    {(l.speaker||l.section)&&<small>{[l.section,l.speaker].filter(Boolean).join(' · ')}</small>}
    {analyzed&&<span className="analysis-hint" aria-hidden="true">{syllables>0&&`${syllables} syl`}{syllables>0&&rhymes.length>0&&' · '}{rhymes.length>0&&`${rhymes.length} rhyme${rhymes.length===1?'':'s'}`}</span>}
   </div>
   <p className="original"><Words text={l.original} colors={words}/></p>
   <p className="translation">{l.translated}</p>
   {analyzed&&<div className="line-analysis" id={`analysis-${i+1}`} role="group" aria-label="Rhythm and rhyme analysis">
    <button type="button" className="analysis-unpin" onClick={e=>{
     e.stopPropagation();
     const article=e.currentTarget.closest('article');
     if(article?.contains(document.activeElement))(document.activeElement as HTMLElement)?.blur();
     setFocus(null);
    }}>Unpin</button>
    {syllables>0&&<section className="analysis-card meter-card">
     <div className="analysis-card-head"><span><MeterIcon/>Estimated meter</span><span className="analysis-count"><strong>{syllables}</strong> {syllables===1?'syllable':'syllables'}</span></div>
     {stress?<>
      <div className="meter-bars" role="img" aria-label={`Stress pattern ${stress}`}>{[...stress].map((beat,b)=><div key={b} className="meter-beat"><i className={beat==='1'?'is-stressed':''}/><span>{b+1}</span></div>)}</div>
      <div className="meter-legend"><span><i className="is-stressed"/>Stressed</span><span><i/>Unstressed</span></div>
     </>:<p className="analysis-empty">No stress pattern yet.</p>}
    </section>}
    {rhymes.length>0&&<section className="analysis-card rhyme-card">
     <div className="analysis-card-head"><span><LinkIcon/>Original rhymes</span><span className="analysis-count">{rhymes.length}</span></div>
     <ul>{rhymes.map((r,ri)=><li key={ri} style={{'--rhyme':colorFor(r.sound)} as CSSProperties}
      className={focus?.line===i&&focus.rhyme===ri?'is-active':''}
      onMouseEnter={()=>setFocus({line:i,rhyme:ri})} onMouseLeave={()=>setFocus({line:i,rhyme:null})}>
      <code>{r.sound}</code><span className="rhyme-words">{r.words}</span>
      <span className="rhyme-lines">{r.relatedLines.filter(n=>n!==i+1&&lines[n-1]).map(n=><a key={n} href={`#line-${n}`} onFocus={()=>setFocus({line:i,rhyme:ri})}>L{n}</a>)}</span>
     </li>)}</ul>
    </section>}
   </div>}
  </article>;
 })}</div></>;
}

function Words({text,colors}:{text:string;colors?:Map<string,string>}) {
 if(!colors?.size)return <>{text}</>;
 return <>{text.split(/(\s+)/).map((part,k)=>{
  const color=/\s/.test(part)?undefined:colors.get(normalize(part));
  return color?<mark key={k} className="rhyme-mark" style={{'--rhyme':color} as CSSProperties}>{part}</mark>:<Fragment key={k}>{part}</Fragment>;
 })}</>;
}
const MeterIcon=()=><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" aria-hidden="true"><path d="M3 10v4M7 7v10M11 4v16M15 8v8M19 10v4"/></svg>;
const LinkIcon=()=><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true"><path d="M10 13a5 5 0 0 0 7.5.5l3-3a5 5 0 0 0-7-7l-1.7 1.7"/><path d="M14 11a5 5 0 0 0-7.5-.5l-3 3a5 5 0 0 0 7 7l1.7-1.7"/></svg>;
