-- Offer ids in category 5c ("Others: rest") of sql/bl_viewed_product_match_auto_approved.sql (lead-level list)
-- Data source : IM-Lakehouse (BigQuery, Redash data_source_id = 41)
-- Params      : {{ start_date }}, {{ end_date }}  (Redash "Date" params, inclusive approval dates)
-- Grain       : one row per BL (offer id only)
-- Population  : BLs approved in the period whose latest row has fk_employee_id = -14, whose best-ranked viewed
--               product has activity_type_id > 16, whose source product is not AWM, and that have an image

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
  SELECT * EXCEPT (fk_employee_id)
  FROM approved_all
  WHERE fk_employee_id = -14
),

top_product AS (
  SELECT
    CAST(fk_eto_ofr_display_id AS INT64) AS bl_id,
    activity_type_id                     AS top_activity_type_id
  FROM `imbl.iil_buyer_products_viewed`
  -- iil partition_date = BL approval date
  WHERE partition_date BETWEEN DATE('{{ start_date }}') AND DATE('{{ end_date }}')
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY fk_eto_ofr_display_id
    ORDER BY activity_type_id ASC NULLS LAST, fk_pc_item_display_id
  ) = 1
),

awm_products AS (
  SELECT DISTINCT pc_item_display_id
  FROM `mesh.pc_item`
  WHERE pc_item_status_approval = 50
    AND pc_item_display_id IN (SELECT product_display_id FROM approved WHERE product_display_id IS NOT NULL)
)

SELECT a.bl_id AS offer_id
FROM approved a
JOIN top_product t USING (bl_id)
LEFT JOIN awm_products w ON w.pc_item_display_id = a.product_display_id
WHERE t.top_activity_type_id > 16
  AND w.pc_item_display_id IS NULL
  AND a.has_image
ORDER BY a.bl_id
