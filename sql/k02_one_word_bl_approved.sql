-- K02 | One-word BLs approved
-- Data source : IM-Lakehouse (BigQuery, Redash data_source_id = 41)
-- Params      : none. Always the previous day: approvals on (current IST date - 1), via
--               CURRENT_DATE('Asia/Kolkata'). n8n calls it with no parameters.
-- Grain       : one row (the previous day)
-- Definition  : approved BLs whose trimmed title has no whitespace (e.g. "Cement", "PVC-Pipe")
-- Base        : all BLs approved on the date

WITH approved AS (
  SELECT
    CAST(eto_ofr_display_id AS INT64)  AS bl_id,
    DATE(eto_ofr_approv_date_orig)     AS report_date,
    TRIM(eto_ofr_title)                AS title
  FROM `imbl.eto_ofr_with_expired`
  WHERE partition_date BETWEEN DATE_SUB(CURRENT_DATE('Asia/Kolkata'), INTERVAL 8 DAY) AND DATE_SUB(CURRENT_DATE('Asia/Kolkata'), INTERVAL 1 DAY)
    AND DATE(eto_ofr_approv_date_orig) = DATE_SUB(CURRENT_DATE('Asia/Kolkata'), INTERVAL 1 DAY)
  QUALIFY ROW_NUMBER() OVER (PARTITION BY eto_ofr_display_id ORDER BY partition_date DESC) = 1
)

SELECT
  report_date,
  'K02'                                                         AS kpi_id,
  'One-word BLs approved'                                       AS kpi_name,
  COUNTIF(REGEXP_CONTAINS(title, r'^\S+$'))                     AS kpi_count,
  COUNT(*)                                                      AS base_count,
  ROUND(100 * SAFE_DIVIDE(COUNTIF(REGEXP_CONTAINS(title, r'^\S+$')), COUNT(*)), 2) AS kpi_pct,
  'Approved BLs'                                                AS base_label
FROM approved
GROUP BY report_date
ORDER BY report_date
