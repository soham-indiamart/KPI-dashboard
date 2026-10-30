-- K01 | BLs with no MCAT mapped
-- Data source : IM-Lakehouse (BigQuery, Redash data_source_id = 41)
-- Params      : none. Always the previous day: approvals on (current IST date - 1), via
--               CURRENT_DATE('Asia/Kolkata'). n8n calls it with no parameters.
-- Grain       : one row (the previous day)
-- Definition  : approved BLs that have zero MCATs in eto_ofr_mapping (+ _expired)
-- Base        : all BLs approved on the date

WITH approved AS (
  SELECT DISTINCT
    CAST(eto_ofr_display_id AS INT64)  AS bl_id,
    DATE(eto_ofr_approv_date_orig)     AS report_date
  FROM `imbl.eto_ofr_with_expired`
  -- partition_date = post date: yesterday - 7 days ... yesterday
  WHERE partition_date BETWEEN DATE_SUB(CURRENT_DATE('Asia/Kolkata'), INTERVAL 8 DAY) AND DATE_SUB(CURRENT_DATE('Asia/Kolkata'), INTERVAL 1 DAY)
    AND DATE(eto_ofr_approv_date_orig) = DATE_SUB(CURRENT_DATE('Asia/Kolkata'), INTERVAL 1 DAY)
),

mcat_map AS (
  -- partition_date = mapping date
  SELECT CAST(fk_eto_ofr_id AS INT64) AS bl_id, fk_glcat_mcat_id
  FROM `imbl.eto_ofr_mapping`
  WHERE partition_date BETWEEN DATE_SUB(CURRENT_DATE('Asia/Kolkata'), INTERVAL 8 DAY) AND DATE_ADD(CURRENT_DATE('Asia/Kolkata'), INTERVAL 2 DAY)
  UNION ALL
  SELECT CAST(fk_eto_ofr_id AS INT64), fk_glcat_mcat_id
  FROM `imbl.eto_ofr_mapping_expired`
  WHERE partition_date BETWEEN DATE_SUB(CURRENT_DATE('Asia/Kolkata'), INTERVAL 8 DAY) AND DATE_ADD(CURRENT_DATE('Asia/Kolkata'), INTERVAL 2 DAY)
),

mcat_cnt AS (
  SELECT bl_id, COUNT(DISTINCT fk_glcat_mcat_id) AS mcats
  FROM mcat_map
  WHERE COALESCE(fk_glcat_mcat_id, 0) > 0
  GROUP BY bl_id
)

SELECT
  a.report_date,
  'K01'                                                         AS kpi_id,
  'BLs with no MCAT mapped'                                     AS kpi_name,
  COUNTIF(COALESCE(m.mcats, 0) = 0)                             AS kpi_count,
  COUNT(*)                                                      AS base_count,
  ROUND(100 * SAFE_DIVIDE(COUNTIF(COALESCE(m.mcats, 0) = 0), COUNT(*)), 2) AS kpi_pct,
  'Approved BLs'                                                AS base_label
FROM approved a
LEFT JOIN mcat_cnt m USING (bl_id)
GROUP BY a.report_date
ORDER BY a.report_date
