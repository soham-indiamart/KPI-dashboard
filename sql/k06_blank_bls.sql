-- K06 | Blank BLs approved (no Spec, no Description, no Quantity, no Photo)
-- Data source : IM-Lakehouse (BigQuery, Redash data_source_id = 41)
-- Params      : none. Always the previous day: approvals on (current IST date - 1), via
--               CURRENT_DATE('Asia/Kolkata'). n8n calls it with no parameters.
-- Grain       : one row (the previous day)
-- Definition  : approved BL with ALL of the following missing
--                 Spec        -> no eto_attribute row other than Quantity / Quantity Unit
--                                and the system-derived ones (priority 1000 order value, 1100 req. type)
--                 Description -> eto_ofr_desc blank
--                 Quantity    -> no non-blank, non-zero "Quantity" attribute
--                 Photo       -> eto_ofr_attachment_is_exist = 0 (BL-level flag; the attachment
--                                table loses rows once a BL expires, so it can't be used for history)
-- Scope       : Indian BLs only (fk_gl_country_iso = 'IN', ~97% of approvals)
-- Base        : Indian BLs approved on the date (base_label 'Approved BLs (India)')

WITH approved AS (
  SELECT
    CAST(eto_ofr_display_id AS INT64)          AS bl_id,
    DATE(eto_ofr_approv_date_orig)             AS report_date,
    NULLIF(TRIM(eto_ofr_desc), '') IS NOT NULL AS has_desc,
    COALESCE(eto_ofr_attachment_is_exist, 0) = 1 AS has_photo
  FROM `imbl.eto_ofr_with_expired`
  -- partition_date = post date: yesterday - 7 days ... yesterday
  WHERE partition_date BETWEEN DATE_SUB(CURRENT_DATE('Asia/Kolkata'), INTERVAL 8 DAY) AND DATE_SUB(CURRENT_DATE('Asia/Kolkata'), INTERVAL 1 DAY)
    AND DATE(eto_ofr_approv_date_orig) = DATE_SUB(CURRENT_DATE('Asia/Kolkata'), INTERVAL 1 DAY)
    AND fk_gl_country_iso = 'IN'
  QUALIFY ROW_NUMBER() OVER (PARTITION BY eto_ofr_display_id ORDER BY partition_date DESC) = 1
),

attr AS (
  SELECT
    CAST(fk_eto_ofr_display_id AS INT64) AS bl_id,
    LOGICAL_OR(LOWER(TRIM(fk_im_spec_master_desc)) = 'quantity'
               AND NULLIF(TRIM(fk_im_spec_options_desc), '') IS NOT NULL
               AND TRIM(fk_im_spec_options_desc) NOT IN ('0', '0.0'))                      AS has_qty,
    LOGICAL_OR(LOWER(TRIM(fk_im_spec_master_desc)) NOT IN ('quantity', 'quantity unit')
               AND COALESCE(CAST(im_cat_spec_priority AS INT64), 0) NOT IN (1000, 1100)
               AND NULLIF(TRIM(fk_im_spec_options_desc), '') IS NOT NULL)                  AS has_spec
  FROM `imbl.eto_attribute`
  -- yesterday - 7 days ... yesterday + 3 days
  WHERE partition_date BETWEEN DATE_SUB(CURRENT_DATE('Asia/Kolkata'), INTERVAL 8 DAY) AND DATE_ADD(CURRENT_DATE('Asia/Kolkata'), INTERVAL 2 DAY)
  GROUP BY bl_id
),

flags AS (
  SELECT
    a.report_date,
    NOT COALESCE(t.has_spec, FALSE)
      AND NOT a.has_desc
      AND NOT COALESCE(t.has_qty, FALSE)
      AND NOT a.has_photo AS is_blank
  FROM approved a
  LEFT JOIN attr t USING (bl_id)
)

SELECT
  report_date,
  'K06'                                                         AS kpi_id,
  'Blank BLs (no spec/desc/qty/photo), India'                   AS kpi_name,
  COUNTIF(is_blank)                                             AS kpi_count,
  COUNT(*)                                                      AS base_count,
  ROUND(100 * SAFE_DIVIDE(COUNTIF(is_blank), COUNT(*)), 2)      AS kpi_pct,
  'Approved BLs (India)'                                        AS base_label
FROM flags
GROUP BY report_date
ORDER BY report_date
