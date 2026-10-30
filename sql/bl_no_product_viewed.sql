-- Approved BLs whose buyer saw no product (lead-level list)
-- Data source : IM-Lakehouse (BigQuery, Redash data_source_id = 41)
-- Params      : {{ start_date }}, {{ end_date }}  (Redash "Date" params, inclusive)
-- Grain       : one row per approved BL with no row in iil_buyer_products_viewed
--               (the '6. No product viewed' category of sql/k07_viewed_product_match.sql, ~33k BLs/day)
-- Columns     : buyer_glid = the buyer (fk_glusr_usr_id); approved_by_system = auto-approval
--               (eto_ofr_approv_by_orig < 0) vs a LEAP agent
-- Notes       : iil_buyer_products_viewed.partition_date = BL approval date

WITH approved AS (
  SELECT
    DATE(eto_ofr_approv_date_orig)     AS report_date,
    CAST(eto_ofr_display_id AS INT64)  AS bl_id,
    fk_glusr_usr_id                    AS buyer_glid,
    eto_ofr_title                      AS bl_title,
    fk_glcat_mcat_id                   AS bl_mcat_id,
    eto_ofr_glcat_mcat_name            AS bl_mcat_name,
    fk_glcat_cat_id                    AS bl_subcat_id,
    fk_gl_module_id                    AS module,
    fk_gl_country_iso                  AS country_iso,
    eto_ofr_approv_by_orig < 0         AS approved_by_system
  FROM `imbl.eto_ofr_with_expired`
  -- partition_date = post date; approvals land within ~3 days of posting
  WHERE partition_date BETWEEN DATE_SUB(DATE('{{ start_date }}'), INTERVAL 7 DAY) AND DATE('{{ end_date }}')
    AND DATE(eto_ofr_approv_date_orig) BETWEEN DATE('{{ start_date }}') AND DATE('{{ end_date }}')
  QUALIFY ROW_NUMBER() OVER (PARTITION BY eto_ofr_display_id ORDER BY partition_date DESC) = 1
),

viewed AS (
  SELECT DISTINCT CAST(fk_eto_ofr_display_id AS INT64) AS bl_id
  FROM `imbl.iil_buyer_products_viewed`
  WHERE partition_date BETWEEN DATE('{{ start_date }}') AND DATE('{{ end_date }}')
)

SELECT a.*
FROM approved a
LEFT JOIN viewed v USING (bl_id)
WHERE v.bl_id IS NULL
ORDER BY a.report_date, a.bl_id
