import {redirectToRelation} from '../../../_music/resolve';
export async function GET(request: Request, {params}: {params: Promise<{id: string}>}) { return redirectToRelation(request, (await params).id, 'artist'); }
