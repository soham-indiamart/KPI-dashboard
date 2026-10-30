-- K12 | BLs with 0 suppliers selected
-- Data source : IM-Lakehouse (BigQuery, Redash data_source_id = 41)
-- Params      : none. Always the previous day: approvals on (current IST date - 1), via
--               CURRENT_DATE('Asia/Kolkata'). n8n calls it with no parameters.
-- Grain       : one row (the previous day)
-- Definition  : approved BLs with no row in imbl.eto_lead_supplier_mapping
-- Base        : all BLs approved on the date
-- Notes       : suppliers are mapped on the approval day (eto_lead_supplier_mapping.partition_date =
--               mapping date = approval date for every BL checked on 10-28), so the mapping scan covers
--               yesterday and today only

WITH approved AS (
  SELECT
    CAST(eto_ofr_display_id AS INT64)  AS bl_id,
    DATE(eto_ofr_approv_date_orig)     AS report_date
  FROM `imbl.eto_ofr_with_expired`
  -- partition_date = post date: yesterday - 7 days ... yesterday
  WHERE partition_date BETWEEN DATE_SUB(CURRENT_DATE('Asia/Kolkata'), INTERVAL 8 DAY) AND DATE_SUB(CURRENT_DATE('Asia/Kolkata'), INTERVAL 1 DAY)
    AND DATE(eto_ofr_approv_date_orig) = DATE_SUB(CURRENT_DATE('Asia/Kolkata'), INTERVAL 1 DAY)
  QUALIFY ROW_NUMBER() OVER (PARTITION BY eto_ofr_display_id ORDER BY partition_date DESC) = 1
),

mapped AS (
  SELECT DISTINCT fk_eto_ofr_display_id AS bl_id
  FROM `imbl.eto_lead_supplier_mapping`
  -- yesterday ... today
  WHERE partition_date BETWEEN DATE_SUB(CURRENT_DATE('Asia/Kolkata'), INTERVAL 1 DAY) AND CURRENT_DATE('Asia/Kolkata')
)

SELECT
  a.report_date,
  'K12'                                                         AS kpi_id,
  'BLs with 0 suppliers selected'                               AS kpi_name,
  COUNTIF(m.bl_id IS NULL)                                      AS kpi_count,
  COUNT(*)                                                      AS base_count,
  ROUND(100 * SAFE_DIVIDE(COUNTIF(m.bl_id IS NULL), COUNT(*)), 2) AS kpi_pct,
  'Approved BLs'                                                AS base_label
FROM approved a
LEFT JOIN mapped m USING (bl_id)
GROUP BY a.report_date
ORDER BY a.report_date
