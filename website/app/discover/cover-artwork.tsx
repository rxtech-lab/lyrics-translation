"use client";

import {useState} from 'react';

export default function CoverArtwork({src}: {src?: string | null}) {
  const [failedSource, setFailedSource] = useState<string>();
  const url = src?.replaceAll('{w}', '600').replaceAll('{h}', '600');
  return <div className="discover-art" aria-hidden="true">
    {url && failedSource !== url ? <img src={url} alt="" loading="lazy" decoding="async" onError={() => setFailedSource(url)} /> : <><span>♫</span><div className="discover-art-lines">≋ ≋ ≋</div></>}
  </div>;
}
