-- K08 | PMCAT mapping %
-- Data source : IM-Lakehouse (BigQuery, Redash data_source_id = 41)
-- Params      : none. Always the previous day: approvals on (current IST date - 1), via
--               CURRENT_DATE('Asia/Kolkata'). n8n calls it with no parameters.
-- Grain       : one row (the previous day)
-- Definition  : approved BLs whose MCAT (fk_glcat_mcat_id on the BL) is a PMCAT, i.e. a generic MCAT
--               (mesh.glcat_mcat.glcat_mcat_is_generic = 1)
-- Base        : all BLs approved on the date

WITH approved AS (
  SELECT
    CAST(eto_ofr_display_id AS INT64)  AS bl_id,
    DATE(eto_ofr_approv_date_orig)     AS report_date,
    fk_glcat_mcat_id                   AS mcat_id
  FROM `imbl.eto_ofr_with_expired`
  -- partition_date = post date: yesterday - 7 days ... yesterday
  WHERE partition_date BETWEEN DATE_SUB(CURRENT_DATE('Asia/Kolkata'), INTERVAL 8 DAY) AND DATE_SUB(CURRENT_DATE('Asia/Kolkata'), INTERVAL 1 DAY)
    AND DATE(eto_ofr_approv_date_orig) = DATE_SUB(CURRENT_DATE('Asia/Kolkata'), INTERVAL 1 DAY)
  QUALIFY ROW_NUMBER() OVER (PARTITION BY eto_ofr_display_id ORDER BY partition_date DESC) = 1
),

pmcats AS (
  SELECT glcat_mcat_id
  FROM `mesh.glcat_mcat`
  WHERE glcat_mcat_is_generic = 1
)

SELECT
  a.report_date,
  'K08'                                                         AS kpi_id,
  'BLs mapped to a PMCAT'                                       AS kpi_name,
  COUNTIF(p.glcat_mcat_id IS NOT NULL)                          AS kpi_count,
  COUNT(*)                                                      AS base_count,
  ROUND(100 * SAFE_DIVIDE(COUNTIF(p.glcat_mcat_id IS NOT NULL), COUNT(*)), 2) AS kpi_pct,
  'Approved BLs'                                                AS base_label
FROM approved a
LEFT JOIN pmcats p ON p.glcat_mcat_id = a.mcat_id
GROUP BY a.report_date
ORDER BY a.report_date
