-- K03 | BLs with photos: Generated, Approved & Approval %
-- Data source : IM-Lakehouse (BigQuery, Redash data_source_id = 41)
-- Params      : none. Always the previous day: approvals on (current IST date - 1), via
--               CURRENT_DATE('Asia/Kolkata'). n8n calls it with no parameters.
-- Grain       : one row (the previous day)
-- Definition  : kpi_count            = BLs approved on the date that have a photo/attachment
--               base_count           = all BLs approved on the date
--               kpi_pct              = kpi_count / base_count
--               photo_bls_generated  = BLs with a photo POSTED on the date (live + expired + deleted/rejected)
-- Photo       : eto_ofr_attachment_is_exist = 1 (BL-level flag). imbl.eto_ofr_attachment is not used
--               because it drops rows once a BL expires (~3-4 days), which would break history / date compare.

WITH approved AS (
  SELECT
    CAST(eto_ofr_display_id AS INT64)            AS bl_id,
    DATE(eto_ofr_approv_date_orig)               AS report_date,
    COALESCE(eto_ofr_attachment_is_exist, 0) = 1 AS has_photo
  FROM `imbl.eto_ofr_with_expired`
  -- partition_date = post date: yesterday - 7 days ... yesterday
  WHERE partition_date BETWEEN DATE_SUB(CURRENT_DATE('Asia/Kolkata'), INTERVAL 8 DAY) AND DATE_SUB(CURRENT_DATE('Asia/Kolkata'), INTERVAL 1 DAY)
    AND DATE(eto_ofr_approv_date_orig) = DATE_SUB(CURRENT_DATE('Asia/Kolkata'), INTERVAL 1 DAY)
  QUALIFY ROW_NUMBER() OVER (PARTITION BY eto_ofr_display_id ORDER BY partition_date DESC) = 1
),

generated AS (
  SELECT
    CAST(eto_ofr_display_id AS INT64)            AS bl_id,
    DATE(eto_ofr_postdate_orig)                  AS report_date,
    COALESCE(eto_ofr_attachment_is_exist, 0) = 1 AS has_photo
  FROM `imbl.eto_ofr_with_expired`
  WHERE partition_date = DATE_SUB(CURRENT_DATE('Asia/Kolkata'), INTERVAL 1 DAY)
    AND DATE(eto_ofr_postdate_orig) = DATE_SUB(CURRENT_DATE('Asia/Kolkata'), INTERVAL 1 DAY)
  UNION ALL
  -- rejected / deleted BLs (not in with_expired)
  SELECT
    CAST(eto_ofr_display_id AS INT64),
    DATE(eto_ofr_postdate_orig),
    COALESCE(eto_ofr_attachment_is_exist, 0) = 1
  FROM `imbl.eto_ofr_temp_del`
  WHERE DATE(eto_ofr_postdate_orig) = DATE_SUB(CURRENT_DATE('Asia/Kolkata'), INTERVAL 1 DAY)
),

generated_daily AS (
  SELECT report_date, COUNT(DISTINCT IF(has_photo, bl_id, NULL)) AS photo_bls_generated
  FROM generated
  GROUP BY report_date
),

approved_daily AS (
  SELECT report_date, COUNTIF(has_photo) AS photo_bls_approved, COUNT(*) AS approved_bls
  FROM approved
  GROUP BY report_date
)

SELECT
  a.report_date,
  'K03'                                                                   AS kpi_id,
  'BLs with photos approved'                                              AS kpi_name,
  a.photo_bls_approved                                                    AS kpi_count,
  a.approved_bls                                                          AS base_count,
  ROUND(100 * SAFE_DIVIDE(a.photo_bls_approved, a.approved_bls), 2)       AS kpi_pct,
  'Approved BLs'                                                          AS base_label,
  COALESCE(g.photo_bls_generated, 0)                                      AS photo_bls_generated
FROM approved_daily a
LEFT JOIN generated_daily g USING (report_date)
ORDER BY a.report_date
