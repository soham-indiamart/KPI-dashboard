-- K10 | Buyer filled spec %
-- Data source : IM-Lakehouse (BigQuery, Redash data_source_id = 41)
-- Params      : none. Always the previous day: approvals on (current IST date - 1), via
--               CURRENT_DATE('Asia/Kolkata'). n8n calls it with no parameters.
-- Grain       : one row (the previous day)
-- Definition  : approved BLs with at least one non-quantity spec answer filled by the buyer, modified on the
--               approval date. Buyer-filled = eto_attribute_source 1-199, 601-650 or
--               204/206/208/209/210/214/220/221/250/991/999/1001
-- Base        : approved BLs whose MCAT has an active non-quantity buyer/seller ISQ and is live
--               (glcat_mcat_delete_status = 0, seo_on_flag = 1) (~98% of approvals)
-- Notes       : eto_attribute partition_date = attribute mod date. Answers filled before the approval day
--               are not counted (~50 BLs/day)

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

spec_mcats AS (
  SELECT DISTINCT s.im_cat_spec_category_id AS mcat_id
  FROM `mesh.im_cat_specification` s
  JOIN `mesh.im_specification_master` m ON s.fk_im_spec_master_id = m.im_spec_master_id
  JOIN `mesh.glcat_mcat` c ON c.glcat_mcat_id = s.im_cat_spec_category_id
  WHERE LOWER(m.im_spec_master_desc) NOT IN ('quantity', 'quantity unit')
    AND s.im_cat_spec_status = 1
    AND m.im_spec_master_buyer_seller IN (0, 1)
    AND c.glcat_mcat_delete_status = 0
    AND c.seo_on_flag = 1
),

buyer_spec AS (
  SELECT DISTINCT CAST(fk_eto_ofr_display_id AS INT64) AS bl_id
  FROM `imbl.eto_attribute`
  -- yesterday ... today
  WHERE partition_date BETWEEN DATE_SUB(CURRENT_DATE('Asia/Kolkata'), INTERVAL 1 DAY) AND CURRENT_DATE('Asia/Kolkata')
    AND DATE(eto_attribute_mod_date) = DATE_SUB(CURRENT_DATE('Asia/Kolkata'), INTERVAL 1 DAY)
    AND LOWER(fk_im_spec_master_desc) NOT IN ('quantity', 'quantity unit')
    AND (eto_attribute_source BETWEEN 1 AND 199
         OR eto_attribute_source BETWEEN 601 AND 650
         OR eto_attribute_source IN (204, 206, 208, 209, 210, 214, 220, 221, 250, 991, 999, 1001))
)

SELECT
  a.report_date,
  'K10'                                                         AS kpi_id,
  'Buyer filled spec BLs'                                       AS kpi_name,
  COUNTIF(b.bl_id IS NOT NULL)                                  AS kpi_count,
  COUNT(*)                                                      AS base_count,
  ROUND(100 * SAFE_DIVIDE(COUNTIF(b.bl_id IS NOT NULL), COUNT(*)), 2) AS kpi_pct,
  'Approved BLs in MCATs with buyer specs'                      AS base_label
FROM approved a
JOIN spec_mcats USING (mcat_id)
LEFT JOIN buyer_spec b USING (bl_id)
GROUP BY a.report_date
ORDER BY a.report_date
