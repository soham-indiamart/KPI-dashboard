-- K09 | Qty fill rate %
-- Data source : IM-Lakehouse (BigQuery, Redash data_source_id = 41)
-- Params      : none. Always the previous day: approvals on (current IST date - 1), via
--               CURRENT_DATE('Asia/Kolkata'). n8n calls it with no parameters.
-- Grain       : one row (the previous day)
-- Definition  : approved BLs with a Quantity answer in imbl.eto_attribute (fk_im_spec_master_desc =
--               'Quantity'), modified on the approval date
-- Base        : approved BLs whose MCAT asks for Quantity: an active Quantity ISQ (im_cat_specification
--               status 1, buyer/seller spec 0/1) on an MCAT that is not deleted (~82% of approvals)
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

qty_mcats AS (
  SELECT DISTINCT s.im_cat_spec_category_id AS mcat_id
  FROM `mesh.im_cat_specification` s
  JOIN `mesh.im_specification_master` m ON s.fk_im_spec_master_id = m.im_spec_master_id
  JOIN `mesh.glcat_mcat` c ON s.im_cat_spec_category_id = c.glcat_mcat_id
  WHERE s.im_cat_spec_status = 1
    AND m.im_spec_master_buyer_seller IN (0, 1)
    AND m.im_spec_master_desc = 'Quantity'
    AND c.glcat_mcat_delete_status = 0
),

qty AS (
  SELECT CAST(fk_eto_ofr_display_id AS INT64) AS bl_id
  FROM `imbl.eto_attribute`
  WHERE partition_date = DATE_SUB(CURRENT_DATE('Asia/Kolkata'), INTERVAL 1 DAY)
    AND DATE(eto_attribute_mod_date) = DATE_SUB(CURRENT_DATE('Asia/Kolkata'), INTERVAL 1 DAY)
    AND fk_im_spec_master_desc = 'Quantity'
  GROUP BY 1
  HAVING MAX(fk_im_spec_options_desc) IS NOT NULL
)

SELECT
  a.report_date,
  'K09'                                                         AS kpi_id,
  'Qty filled BLs'                                              AS kpi_name,
  COUNTIF(q.bl_id IS NOT NULL)                                  AS kpi_count,
  COUNT(*)                                                      AS base_count,
  ROUND(100 * SAFE_DIVIDE(COUNTIF(q.bl_id IS NOT NULL), COUNT(*)), 2) AS kpi_pct,
  'Approved BLs in MCATs with a Quantity ISQ'                   AS base_label
FROM approved a
JOIN qty_mcats USING (mcat_id)
LEFT JOIN qty q USING (bl_id)
GROUP BY a.report_date
ORDER BY a.report_date
