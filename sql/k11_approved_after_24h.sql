-- K11 | BLs approved more than 24 hours after generation %
-- Data source : IM-Lakehouse (BigQuery, Redash data_source_id = 41)
-- Params      : none. Always the previous day: approvals on (current IST date - 1), via
--               CURRENT_DATE('Asia/Kolkata'). n8n calls it with no parameters.
-- Grain       : one row (the previous day)
-- Definition  : approved BLs whose approval (eto_ofr_approv_date_orig) came more than 24 hours after posting
--               (eto_ofr_postdate_orig)
-- Base        : all BLs approved on the date
-- Notes       : counted by approval date, not post date: BLs posted yesterday that will take > 24 hours are
--               not approved yet when n8n runs at 9 AM, so a post-date count would always be incomplete

WITH approved AS (
  SELECT
    CAST(eto_ofr_display_id AS INT64)  AS bl_id,
    DATE(eto_ofr_approv_date_orig)     AS report_date,
    TIMESTAMP_DIFF(CAST(eto_ofr_approv_date_orig AS TIMESTAMP),
                   CAST(eto_ofr_postdate_orig AS TIMESTAMP), SECOND) > 86400 AS after_24h
  FROM `imbl.eto_ofr_with_expired`
  -- partition_date = post date: yesterday - 7 days ... yesterday
  WHERE partition_date BETWEEN DATE_SUB(CURRENT_DATE('Asia/Kolkata'), INTERVAL 8 DAY) AND DATE_SUB(CURRENT_DATE('Asia/Kolkata'), INTERVAL 1 DAY)
    AND DATE(eto_ofr_approv_date_orig) = DATE_SUB(CURRENT_DATE('Asia/Kolkata'), INTERVAL 1 DAY)
  QUALIFY ROW_NUMBER() OVER (PARTITION BY eto_ofr_display_id ORDER BY partition_date DESC) = 1
)

SELECT
  report_date,
  'K11'                                                         AS kpi_id,
  'BLs approved after 24 hours'                                 AS kpi_name,
  COUNTIF(after_24h)                                            AS kpi_count,
  COUNT(*)                                                      AS base_count,
  ROUND(100 * SAFE_DIVIDE(COUNTIF(after_24h), COUNT(*)), 2)     AS kpi_pct,
  'Approved BLs'                                                AS base_label
FROM approved
GROUP BY report_date
ORDER BY report_date
