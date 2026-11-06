"use client";
import UsageDialog from './usage-dialog';
import PlayerIcon from './player-icon';
import Karaoke from './karaoke';
import type {ReactNode} from 'react';
import type {Document} from '@/lib/document';
import Script from 'next/script';
import {useCallback, useEffect, useRef, useState} from 'react';

type Music = {
  authorize: () => Promise<string>;
  isAuthorized: boolean;
  setQueue: (q: {song: string}) => Promise<unknown>;
  play: () => Promise<unknown>;
  pause: () => void;
  seekToTime: (time: number) => Promise<void>;
  currentPlaybackTime: number;
  currentPlaybackDuration: number;
  isPlaying: boolean;
};
declare global { interface Window { MusicKit: {configure: (c: unknown) => Promise<Music>; getInstance: () => Music} } }
const seconds = (value: number) => Number.isFinite(value) ? Math.max(0, value) : 0;
const clock = (value: number) => `${Math.floor(value / 60)}:${String(Math.floor(value % 60)).padStart(2, '0')}`;

export default function Player({id, song, title, artist, lines, initialStarred, initialStars, tokenCount, usageSummary, children}: {children?: ReactNode; initialStarred:boolean; initialStars:number; tokenCount:number; usageSummary?:Document['usageSummary']; lines: Document["lines"]; id: string; song?: string; title?: string; artist?: string}) {
  const [needsSignIn, setNeedsSignIn] = useState(false);
  const [starred, setStarred] = useState(initialStarred);
  const [stars, setStars] = useState(initialStars);
  const [savingStar, setSavingStar] = useState(false);
  const starLock = useRef(false);
  const [expanded, setExpanded] = useState(false);
  const music = useRef<Music | null>(null);
  const queued = useRef<string | null>(null);
  const locked = useRef(false);
  const [status, setStatus] = useState('');
  const [ready, setReady] = useState(false);
  const [busy, setBusy] = useState(false);
  const [playing, setPlaying] = useState(false);
  const [position, setPosition] = useState(0);
  const [duration, setDuration] = useState(0);
  const [scrub, setScrub] = useState<number | null>(null);

  useEffect(() => {
    const timer = window.setInterval(() => {
      if (!music.current || queued.current !== song) return;
      setPosition(seconds(music.current.currentPlaybackTime));
      setDuration(seconds(music.current.currentPlaybackDuration));
      setPlaying(music.current.isPlaying);
    }, 250);
    return () => window.clearInterval(timer);
  }, [song]);

  // MusicKit only advances currentPlaybackTime in coarse steps, so interpolate with
  // the frame clock between updates to keep word animation at display refresh rate.
  const clockState = useRef({raw: -1, at: 0, value: 0});
  const getPlaybackTime = useCallback(() => {
    const player = music.current;
    if (queued.current !== song || !player) return 0;
    const raw = seconds(player.currentPlaybackTime);
    const now = performance.now();
    const state = clockState.current;
    if (!player.isPlaying) {
      state.raw = raw; state.at = now;
      // Hold the interpolated value on pause unless the player was seeked.
      if (Math.abs(state.value - raw) > 1) state.value = raw;
      return state.value;
    }
    if (raw !== state.raw) { state.raw = raw; state.at = now; }
    let estimate = raw + Math.min(1.5, (now - state.at) / 1000);
    // Never step backwards by a small amount when the coarse value catches up.
    if (estimate < state.value && state.value - estimate < .4) estimate = state.value;
    state.value = estimate;
    return estimate;
  }, [song]);

  async function toggle() {
    if (!song || locked.current) return;
    locked.current = true;
    setBusy(true);
    try {
      if (!music.current) {
        setStatus('Connecting to Apple Music…');
        const response = await fetch('/api/music-token');
        if (!response.ok) throw Error('Apple Music is not configured yet');
        const {token} = await response.json();
        music.current = await window.MusicKit.configure({developerToken: token, app: {name: 'LyricStudio', build: '1'}});
      }
      const player = music.current;
      if (!player.isAuthorized) await player.authorize();
      if (queued.current !== song) {
        await player.setQueue({song});
        queued.current = song;
      }
      if (player.isPlaying) player.pause();
      else await player.play();
      setPlaying(player.isPlaying);
      setStatus('');
    } catch (error) {
      setStatus(error instanceof Error ? error.message : 'Playback failed');
    } finally { locked.current = false; setBusy(false); }
  }

  async function seek(value: number) {
    if (!music.current || !duration || locked.current) return;
    locked.current = true;
    setBusy(true);
    try {
      const target = Math.max(0, Math.min(duration, value));
      await music.current.seekToTime(target);
      setPosition(target);
    } catch { setStatus('Could not seek. Please try again.'); }
    finally { setScrub(null); locked.current = false; setBusy(false); }
  }

  return <>
    {song && <Script src="https://js-cdn.music.apple.com/musickit/v3/musickit.js" onReady={() => setReady(true)} onError={() => setStatus('Apple Music could not load. Please reload to try again.')} />}
    <div className="translation-actions"><button className={`star-button ${starred ? 'is-starred' : ''}`} aria-pressed={starred} aria-busy={savingStar} disabled={savingStar || starred} onClick={async () => {
      if (starLock.current || starred) return;
      starLock.current = true;
      setSavingStar(true);
      setStatus('Saving star…');
      try {
        const response = await fetch(`/api/shares/${id}/star`, {method: 'POST'});
        if (response.status === 401) { setStatus('Sign in in a new tab, then try starring again.'); setNeedsSignIn(true); return; }
        if (!response.ok) throw Error(await response.text());
        const result = await response.json();
        setNeedsSignIn(false);
        setStarred(result.starred);
        setStars(result.stars);
        setStatus('Star saved');
      } catch { setStatus('Could not save star. Please try again.'); }
      finally { starLock.current = false; setSavingStar(false); }
    }}><svg viewBox="0 0 24 24" aria-hidden="true"><path d="m12 3 2.8 5.7 6.3.9-4.6 4.5 1.1 6.3-5.6-3-5.6 3 1.1-6.3L2.9 9.6l6.3-.9Z"/></svg>{savingStar ? 'Saving…' : starred ? 'Starred' : 'Star translation'}<span className="star-count" aria-live="polite">{stars}</span></button><UsageDialog count={tokenCount} summary={usageSummary}/>{children}<span className="translation-actions-note">Made with LyricStudio</span></div>
    {song && <Karaoke open={expanded} onClose={() => setExpanded(false)} lines={lines} getTime={getPlaybackTime} onSeek={seek} title={title} artist={artist}><section className="floating-player" aria-label="Apple Music player" aria-busy={busy}>
      <div className="player-top">
        <div className="player-art" aria-hidden="true"><PlayerIcon name="music"/></div>
        <div className="floating-player-song"><span className="eyebrow">APPLE MUSIC</span><strong>{title || 'Linked song'}</strong>{artist && <small>{artist}</small>}</div>
        <div className="player-controls">
          <button className="expand-control" aria-label={expanded ? "Close fullscreen lyrics" : "Open fullscreen lyrics"} onClick={() => setExpanded(!expanded)}><PlayerIcon name={expanded ? "collapse" : "expand"}/></button>
          <button className="skip-control" aria-label="Back 10 seconds" title="Back 10 seconds" disabled={!duration || busy} onClick={() => void seek(position - 10)}><PlayerIcon name="back"/></button>
          <button className="play-control" aria-label={playing ? 'Pause' : 'Play'} disabled={!ready || busy} onClick={() => void toggle()}>
            {busy ? <span className="player-spinner"/> : <svg viewBox="0 0 24 24" aria-hidden="true">{playing ? <path d="M6 4h4v16H6zm8 0h4v16h-4z"/> : <path d="M7 3v18l15-9z"/>}</svg>}
          </button>
          <button className="skip-control" aria-label="Forward 10 seconds" title="Forward 10 seconds" disabled={!duration || busy} onClick={() => void seek(position + 10)}><PlayerIcon name="forward"/></button>
        </div>
      </div>
      <div className="player-progress">
        <time>{clock(scrub ?? position)}</time>
        <input type="range" aria-label="Playback position" aria-valuetext={`${clock(scrub ?? position)} of ${clock(duration)}`} min={0} max={duration || 1} step={0.1} value={Math.min(scrub ?? position, duration || 1)} disabled={!duration || busy}
          onChange={event => setScrub(Number(event.target.value))}
          onPointerUp={event => void seek(Number(event.currentTarget.value))}
          onPointerCancel={() => setScrub(null)}
          onKeyUp={event => { if (['ArrowLeft','ArrowRight','ArrowUp','ArrowDown','Home','End','PageUp','PageDown'].includes(event.key)) void seek(Number(event.currentTarget.value)); }}
          onBlur={event => { if (scrub !== null) void seek(Number(event.currentTarget.value)); }} />
        <time>{duration ? clock(duration) : '–:––'}</time>
      </div>
    </section></Karaoke>}
    {status && <div className={song ? 'status player-status' : 'status'} role="status">{status} {needsSignIn && <a href="/api/auth/login" target="_blank" rel="noopener noreferrer">Sign in ↗</a>} <button className="status-dismiss" onClick={() => setStatus('')}>Dismiss</button></div>}
  </>;
}
