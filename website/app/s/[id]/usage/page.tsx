import UsageReport from '../usage-report';
import Link from 'next/link';
import {notFound} from 'next/navigation';
import {get} from '@/lib/db';
import {documentSchema} from '@/lib/document';

export const dynamic = 'force-dynamic';

export default async function Usage({params}: {params: Promise<{id: string}>}) {
  const {id} = await params;
  const share = await get(id);
  if (!share) notFound();
  const document = documentSchema.parse(JSON.parse(String(share.document)));
  return <main className="page narrow">
    <Link href={`/s/${id}`}>← Back to translation</Link>
    <p className="eyebrow">AGENT USAGE</p>
    <h1>{String(share.title)}</h1>
    <UsageReport summary={document.usageSummary}/>
  </main>;
}
