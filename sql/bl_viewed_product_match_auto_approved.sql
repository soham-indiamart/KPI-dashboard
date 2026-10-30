-- Auto-approved BLs (fk_employee_id = -14) classified by the best-ranked product the buyer viewed
-- Data source : IM-Lakehouse (BigQuery, Redash data_source_id = 41)
-- Params      : {{ start_date }}, {{ end_date }}  (Redash "Date" params, inclusive approval dates)
-- Grain       : one row per category for the whole period
-- Population  : BLs approved in the period whose latest row has fk_employee_id = -14 (~79% of approvals).
--               Of these, ~0.9% were first approved by an agent (eto_ofr_approv_by_orig > 0). The other
--               system approvers (-30, -76: ~15% of approvals) are not included.
-- Method      : same as sql/k07_viewed_product_match.sql: rank each BL's viewed products by activity_type_id,
--               lowest first, and classify the BL by its rank-1 product:
--                 1-4 Same MCAT | 5-8 Same PMCAT | 9-12 Same subcat | 13-16 Same group
--                 >16 Others: 5a no MCAT (source product AWM, pc_item_status_approval = 50),
--                             5b no image (the BL has no image; placeholders '1' / '[object Object]' don't count),
--                             5c rest
--                 no viewed product -> 6. No product viewed
-- Columns     : bls = BLs in the category; auto_approved_bls = all -14 BLs in the period;
--               bls_pct = bls / auto_approved_bls

WITH approved_all AS (
  SELECT
    CAST(eto_ofr_display_id AS INT64)  AS bl_id,
    eto_ofr_modrefid                   AS product_display_id,
    fk_employee_id,
    COALESCE(eto_ofr_attachment_is_exist, 0) > 0
      OR STRPOS(COALESCE(eto_ofr_original_image, ''), '/') > 0
      OR STRPOS(COALESCE(eto_ofr_small_image, ''), '/') > 0
      OR STRPOS(COALESCE(eto_ofr_image_path1, ''), '/') > 0 AS has_image
  FROM `imbl.eto_ofr_with_expired`
  -- partition_date = post date; approvals land within ~3 days of posting
  WHERE partition_date BETWEEN DATE_SUB(DATE('{{ start_date }}'), INTERVAL 7 DAY) AND DATE('{{ end_date }}')
    AND DATE(eto_ofr_approv_date_orig) BETWEEN DATE('{{ start_date }}') AND DATE('{{ end_date }}')
  QUALIFY ROW_NUMBER() OVER (PARTITION BY eto_ofr_display_id ORDER BY partition_date DESC) = 1
),

-- filter after the dedupe so the BL's latest row decides
approved AS (
  SELECT bl_id, product_display_id, has_image
  FROM approved_all
  WHERE fk_employee_id = -14
),

ranked AS (
  SELECT
    CAST(fk_eto_ofr_display_id AS INT64) AS bl_id,
    activity_type_id,
    ROW_NUMBER() OVER (
      PARTITION BY fk_eto_ofr_display_id
      ORDER BY activity_type_id ASC NULLS LAST, fk_pc_item_display_id
    ) AS product_rank
  FROM `imbl.iil_buyer_products_viewed`
  -- iil partition_date = BL approval date
  WHERE partition_date BETWEEN DATE('{{ start_date }}') AND DATE('{{ end_date }}')
),

top_product AS (
  SELECT bl_id, activity_type_id
  FROM ranked
  WHERE product_rank = 1
),

awm_products AS (
  SELECT DISTINCT pc_item_display_id
  FROM `mesh.pc_item`
  WHERE pc_item_status_approval = 50
    AND pc_item_display_id IN (SELECT product_display_id FROM approved WHERE product_display_id IS NOT NULL)
),

labelled AS (
  SELECT
    CASE
      WHEN t.bl_id IS NULL                      THEN '6. No product viewed'
      WHEN t.activity_type_id BETWEEN 1 AND 4   THEN '1. Same MCAT'
      WHEN t.activity_type_id BETWEEN 5 AND 8   THEN '2. Same PMCAT'
      WHEN t.activity_type_id BETWEEN 9 AND 12  THEN '3. Same subcat'
      WHEN t.activity_type_id BETWEEN 13 AND 16 THEN '4. Same group'
      WHEN t.activity_type_id > 16 THEN
        CASE
          WHEN w.pc_item_display_id IS NOT NULL THEN '5a. Others: no MCAT (AWM)'
          WHEN NOT a.has_image                  THEN '5b. Others: no image'
          ELSE '5c. Others: rest'
        END
      ELSE '7. Unknown activity'
    END AS category
  FROM approved a
  LEFT JOIN top_product t USING (bl_id)
  LEFT JOIN awm_products w ON w.pc_item_display_id = a.product_display_id
)

SELECT
  DATE('{{ start_date }}')                                      AS period_start,
  DATE('{{ end_date }}')                                        AS period_end,
  category,
  COUNT(*)                                                      AS bls,
  SUM(COUNT(*)) OVER ()                                         AS auto_approved_bls,
  ROUND(100 * SAFE_DIVIDE(COUNT(*), SUM(COUNT(*)) OVER ()), 2)  AS bls_pct
FROM labelled
GROUP BY category
ORDER BY category
