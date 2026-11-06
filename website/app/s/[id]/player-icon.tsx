type IconName = 'back' | 'forward' | 'expand' | 'collapse' | 'music' | 'close';
export default function PlayerIcon({name}: {name: IconName}) {
  const rewind = name === 'back' || name === 'forward';
  return <svg className="player-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true" focusable="false">
    {rewind ? <>
      <g transform={name === 'forward' ? 'translate(24 0) scale(-1 1)' : undefined}><path d="M5 7a8 8 0 1 1-1 9M5 3v4h4"/></g>
      <g strokeWidth="1.4"><path d="M8 11l1.5-1v6M8 16h3"/><rect x="13" y="10" width="3.5" height="6" rx="1.75"/></g>
    </> : name === 'expand' ? <path d="M9 4H4v5m11-5h5v5M4 15v5h5m11-5v5h-5"/>
      : name === 'collapse' ? <path d="M4 9h5V4m6 0v5h5M9 20v-5H4m16 0h-5v5"/>
      : name === 'close' ? <path d="m6 6 12 12M6 18 18 6"/>
      : <><path d="M9 18V5l11-2v13M9 9l11-2"/><ellipse cx="6" cy="18" rx="3" ry="2"/><ellipse cx="17" cy="16" rx="3" ry="2"/></>}
  </svg>;
}
