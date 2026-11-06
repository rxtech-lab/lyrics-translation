"use client";

import Link from 'next/link';
import AuthNavigation from './auth-navigation';
import {useEffect, useState} from 'react';

export default function SiteHeader({signedIn}: {signedIn: boolean}) {
  const [compact, setCompact] = useState(false);

  useEffect(() => {
    // Separate thresholds prevent the shrinking header from toggling itself
    // as the browser adjusts the page's scroll position.
    const update = () => setCompact(previous => previous ? window.scrollY > 16 : window.scrollY > 96);
    update();
    window.addEventListener('scroll', update, {passive: true});
    return () => window.removeEventListener('scroll', update);
  }, []);

  return <header className={`site-header${compact ? ' is-compact' : ''}`}>
    <Link className="brand" href="/"><img src="/icon.png" alt=""/>LyricStudio</Link>
    <nav aria-label="Main navigation"><Link href="/discover">Discover</Link><a href="https://update.lyrics.rxlab.app/LyricStudio.dmg">Download for Mac</a><AuthNavigation signedIn={signedIn}/></nav>
  </header>;
}
