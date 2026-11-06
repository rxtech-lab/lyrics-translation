// Replace public call logs with compact agent totals. Unknown prices stay null.
export default {
  id: '004-usage-summary',
  statements: [`UPDATE shares SET document = json_remove(json_set(document, '$.usageSummary', json(COALESCE((
    SELECT json_group_array(json_object('agent', agent, 'tokens', tokens, 'costUSD', cost))
    FROM (
      SELECT COALESCE(json_extract(record.value, '$.agent'), 'Other') agent,
        SUM(json_extract(record.value, '$.input') + json_extract(record.value, '$.output')) tokens,
        CASE WHEN COUNT(json_extract(record.value, '$.reportedCostUSD')) = COUNT(*)
          THEN SUM(json_extract(record.value, '$.reportedCostUSD')) ELSE NULL END cost
      FROM json_each(shares.document, '$.usageLog') session,
        json_each(session.value, '$.records') record
      GROUP BY COALESCE(json_extract(record.value, '$.agent'), 'Other')
    )
  ), '[]'))), '$.usageLog') WHERE json_type(document, '$.usageLog') = 'array'
    AND json_type(document, '$.usageSummary') IS NULL`,
    `UPDATE shares SET document=json_remove(document, '$.usageLog') WHERE json_type(document, '$.usageSummary') = 'array' AND json_type(document, '$.usageLog') IS NOT NULL`],
};
