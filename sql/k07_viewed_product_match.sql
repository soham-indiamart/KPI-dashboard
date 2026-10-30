-- K07 | Auto-approved BLs classified by the best-ranked product the buyer viewed
-- Data source : IM-Lakehouse (BigQuery, Redash data_source_id = 41)
-- Params      : none. Always the previous day: approvals on (current IST date - 1), via
--               CURRENT_DATE('Asia/Kolkata'). n8n calls it with no parameters.
-- Grain       : one row per category for the previous day; upsert on report_date + category
-- Population  : auto-approved BLs only: BLs approved on the date whose latest row has fk_employee_id = -14
--               (~79% of approvals; filtered after the dedupe so the latest row decides). BLs approved by
--               the other system approvers (-30, -76) or by a LEAP agent are not included.
-- Method      : rank each BL's viewed products (iil_buyer_products_viewed) by activity_type_id, lowest first,
--               and classify the BL by its rank-1 product:
--                 1-4   -> 1. Same MCAT
--                 5-8   -> 2. Same PMCAT
--                 9-12  -> 3. Same subcat
--                 13-16 -> 4. Same group
--                 >16   -> 5. Others, split (exclusive, checked in this order):
--                            5a. no MCAT  : source product is AWM, Approved Without MCAT: no prime MCAT
--                                           mapping, the same check as leap-go-workers (models.FetchMcatName):
--                                           no pc_item_to_glcat_mcat row with item_mapping_isprime = -1 whose
--                                           MCAT exists in glcat_mcat and glcat_cat_to_mcat
--                            5b. no image : the BL the buyer posted has no image: eto_ofr_attachment_is_exist = 0
--                                           and no image path (a value containing '/') in the image columns;
--                                           the placeholders '1' / '[object Object]' don't count as images
--                            5c. rest
--               BLs with no viewed product -> 6. No product viewed (lead list: sql/bl_no_product_viewed.sql),
--               so the categories add up to base_count.
-- Columns     : KPI output contract. kpi_count = BLs in the category, base_count = auto-approved BLs on the
--               date, kpi_pct = kpi_count / base_count; category (extra column) = the row's class
-- Notes       : only odd activity ids occur (1, 3 ... 21). iil partition_date = BL approval date.
--               mesh.pc_item and the mapping tables are current snapshots, so 5a can drift slightly.

WITH approved_all AS (
  SELECT
    CAST(eto_ofr_display_id AS INT64)  AS bl_id,
    DATE(eto_ofr_approv_date_orig)     AS report_date,
    eto_ofr_modrefid                   AS product_display_id,
    fk_employee_id,
    COALESCE(eto_ofr_attachment_is_exist, 0) > 0
      OR STRPOS(COALESCE(eto_ofr_original_image, ''), '/') > 0
      OR STRPOS(COALESCE(eto_ofr_small_image, ''), '/') > 0
      OR STRPOS(COALESCE(eto_ofr_image_path1, ''), '/') > 0 AS has_image
  FROM `imbl.eto_ofr_with_expired`
  -- partition_date = post date: yesterday - 7 days ... yesterday
  WHERE partition_date BETWEEN DATE_SUB(CURRENT_DATE('Asia/Kolkata'), INTERVAL 8 DAY) AND DATE_SUB(CURRENT_DATE('Asia/Kolkata'), INTERVAL 1 DAY)
    AND DATE(eto_ofr_approv_date_orig) = DATE_SUB(CURRENT_DATE('Asia/Kolkata'), INTERVAL 1 DAY)
  QUALIFY ROW_NUMBER() OVER (PARTITION BY eto_ofr_display_id ORDER BY partition_date DESC) = 1
),

-- filter after the dedupe so the BL's latest row decides
approved AS (
  SELECT * EXCEPT (fk_employee_id)
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
  WHERE partition_date = DATE_SUB(CURRENT_DATE('Asia/Kolkata'), INTERVAL 1 DAY)
),

top_product AS (
  SELECT bl_id, activity_type_id
  FROM ranked
  WHERE product_rank = 1
),

products AS (
  -- source products of the approved BLs; pc_item is a current snapshot
  SELECT DISTINCT pc_item_display_id, pc_item_id
  FROM `mesh.pc_item`
  WHERE pc_item_display_id IN (SELECT product_display_id FROM approved WHERE product_display_id IS NOT NULL)
),

prime_mapped AS (
  -- leap-go-workers models.FetchMcatName: prime mapping (item_mapping_isprime = -1) to an MCAT that
  -- exists in glcat_mcat and has a glcat_cat_to_mcat row
  SELECT DISTINCT fk_pc_item_id
  FROM `mesh.pc_item_to_glcat_mcat`
  WHERE fk_pc_item_id IN (SELECT pc_item_id FROM products)
    AND item_mapping_isprime = -1
    AND fk_glcat_mcat_id > 0
    AND fk_glcat_mcat_id IN (SELECT glcat_mcat_id FROM `mesh.glcat_mcat`)
    AND fk_glcat_mcat_id IN (SELECT fk_glcat_mcat_id FROM `mesh.glcat_cat_to_mcat`)
),

awm_products AS (
  -- AWM = source product with no such row (prodMcatId <= 0 in the worker)
  SELECT pr.pc_item_display_id
  FROM products pr
  LEFT JOIN prime_mapped m ON m.fk_pc_item_id = pr.pc_item_id
  GROUP BY 1
  HAVING COUNT(m.fk_pc_item_id) = 0
),

labelled AS (
  SELECT
    a.report_date,
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
),

base AS (
  SELECT report_date, COUNT(*) AS approved_bls
  FROM approved
  GROUP BY 1
)

SELECT
  l.report_date,
  'K07'                                                 AS kpi_id,
  'Auto-approved BLs by best-ranked viewed product'     AS kpi_name,
  COUNT(*)                                              AS kpi_count,
  b.approved_bls                                        AS base_count,
  ROUND(100 * SAFE_DIVIDE(COUNT(*), b.approved_bls), 2) AS kpi_pct,
  'Auto-approved BLs'                                   AS base_label,
  l.category
FROM labelled l
JOIN base b USING (report_date)
GROUP BY l.report_date, l.category, b.approved_bls
ORDER BY l.report_date, l.category
