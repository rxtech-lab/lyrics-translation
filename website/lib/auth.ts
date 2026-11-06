import {cookies} from 'next/headers';
import {createRemoteJWKSet,jwtVerify} from 'jose';
export const issuer='https://auth.rxlab.app';
export async function metadata(){const r=await fetch(issuer+'/.well-known/openid-configuration');if(!r.ok)throw Error('Identity service unavailable');return r.json();}
export async function authenticatedProfile(request?:Request, nativeOnly = false){
 const bearer=request?.headers.get('authorization')?.match(/^Bearer (.+)$/)?.[1];
 if(nativeOnly && !bearer) throw Error('Publishing is available only from the LyricStudio app');
 const token=bearer || (await cookies()).get('access_token')?.value;
 if(!token)throw Error('Sign in required');
 const m=await metadata(); const {payload}=await jwtVerify(token,createRemoteJWKSet(new URL(m.jwks_uri)),{issuer,algorithms:['RS256']});
 const allowed=(nativeOnly ? [process.env.RXAUTH_NATIVE_CLIENT_ID] : [process.env.RXAUTH_CLIENT_ID,process.env.RXAUTH_NATIVE_CLIENT_ID]).filter(Boolean);
 if(nativeOnly && (payload.client_id ?? payload.azp) !== process.env.RXAUTH_NATIVE_CLIENT_ID) throw Error('Native app sign-in required');
 if(!payload.sub || !allowed.length || !allowed.some(id=>payload.client_id===id || payload.azp===id || payload.aud===id || Array.isArray(payload.aud)&&payload.aud.includes(id!)))throw Error('Invalid identity');
 return {owner: payload.sub, name: typeof payload.name === 'string' ? payload.name.trim().slice(0, 200) : undefined};
}
export function sameOrigin(r:Request){const origin=r.headers.get('origin');if(!r.headers.get('authorization') && origin!==new URL(process.env.SITE_URL || 'http://localhost:3000').origin)throw Error('Invalid origin');}

export async function identity(request?: Request, nativeOnly = false) { return (await authenticatedProfile(request, nativeOnly)).owner; }
