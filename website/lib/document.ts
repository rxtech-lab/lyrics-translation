import {z} from 'zod';
const wordSchema=z.object({text:z.string().max(10000),space:z.boolean(),start:z.number().finite().nonnegative().nullable().optional(),end:z.number().finite().nonnegative().nullable().optional()});
const rhymeSchema=z.object({words:z.string().max(1000),sound:z.string().max(200),relatedLines:z.array(z.number().int().positive()).max(2000)});
const legacyDocumentSchema=z.object({target:z.string().max(100),lines:z.array(z.object({original:z.string().max(10000),translated:z.string().max(10000),speaker:z.string().max(200).nullable().optional(),section:z.string().max(200).nullable().optional(),originalTiming:z.array(wordSchema).max(10000).nullable().optional(),translationTiming:z.array(wordSchema).max(10000).nullable().optional(),syllables:z.number().int().nonnegative().max(1000).optional(),stress:z.string().max(1000).optional(),rhymes:z.array(rhymeSchema).max(100).optional()})).min(1).max(2000),appleMusic:z.object({id:z.string().regex(/^\d+$/),title:z.string().max(300),artist:z.string().max(300),album:z.string().max(1000).nullable().optional(),artworkURL:z.string().max(2000).url().refine(value=>{const u=new URL(value);return u.protocol==='https:' && (u.hostname==='mzstatic.com' || u.hostname.endsWith('.mzstatic.com'))}).nullable().optional(),duration:z.number().finite().nonnegative().nullable().optional(),url:z.string().max(2000).url().refine(value=>{const u=new URL(value);return u.protocol==='https:' && u.hostname==='music.apple.com'}).nullable().optional()}).nullable().optional(),usageLog:z.array(z.object({title:z.string().max(1000).optional(),date:z.string().max(100).optional(),records:z.array(z.object({agent:z.string().max(500).optional(),provider:z.string().max(500).optional(),model:z.string().max(500).optional(),step:z.string().max(2000).optional(),date:z.string().max(100).optional(),reportedCostUSD:z.number().finite().nonnegative().nullable().optional(),input:z.number().int().nonnegative().max(1e10),output:z.number().int().nonnegative().max(1e10),cacheRead:z.number().int().nonnegative().max(1e10).optional(),cacheWrite:z.number().int().nonnegative().max(1e10).optional()})).max(10000)})).max(1000).optional()});

export const usageSummarySchema = z.array(z.object({
  agent: z.string().max(500),
  tokens: z.number().int().nonnegative(),
  costUSD: z.number().finite().nonnegative().nullable(),
})).max(1000);
export const documentSchema = legacyDocumentSchema.extend({usageSummary: usageSummarySchema.optional()}).transform(({usageLog, usageSummary, ...document}) => {
  const agents = new Map<string, {agent: string; tokens: number; costUSD: number | null}>();
  for (const record of (usageLog ?? []).flatMap(session => session.records)) {
    const name = record.agent || 'Other';
    const prior = agents.get(name);
    agents.set(name, {agent: name, tokens: (prior?.tokens ?? 0) + record.input + record.output,
      costUSD: record.reportedCostUSD == null || (prior && prior.costUSD == null) ? null : (prior?.costUSD ?? 0) + record.reportedCostUSD});
  }
  return {...document, usageSummary: usageSummary ?? [...agents.values()]};
});
export type Document = z.infer<typeof documentSchema>;
export function tokens(d: Document) { return (d.usageSummary ?? []).reduce((sum, row) => sum + row.tokens, 0); }
