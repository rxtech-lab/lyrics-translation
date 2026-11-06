'use client';

import {useEffect} from 'react';
import {useRouter} from 'next/navigation';

export default function AuthNavigation({signedIn}: {signedIn: boolean}) {
  const router = useRouter();

  useEffect(() => {
    // Sign-in can finish in another tab; revalidate the server session on return.
    const refresh = () => {
      if (document.visibilityState === 'visible') router.refresh();
    };
    window.addEventListener('focus', refresh);
    document.addEventListener('visibilitychange', refresh);
    return () => {
      window.removeEventListener('focus', refresh);
      document.removeEventListener('visibilitychange', refresh);
    };
  }, [router]);

  return signedIn
    ? <span className="pill" role="status">Signed in ✓</span>
    : <a href="/api/auth/login" className="pill">Sign in to like ↗</a>;
}
