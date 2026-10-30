-- iil_buyer_products_viewed grouped by activity type (exploratory, not a KPI yet)
-- Data source : IM-Lakehouse (BigQuery, Redash data_source_id = 41)
-- Params      : {{ start_date }}, {{ end_date }}  (Redash "Date" params, inclusive)
-- Grain       : one row per approval date x activity group
-- Groups      : activity_type_id 1-4, 5-8, 9-12, 13-16, >16. Only odd ids occur (1, 3, 5 ... 21), so the
--               first four groups hold two ids each and >16 holds 17, 19, 21 (and any higher id added later).
-- Columns     : bls = distinct BLs with at least one view in the group
--               (a BL can sit in several groups, so group bls add up to more than the BLs with any view);
--               bls_pct = bls / all BLs approved on the date
-- Notes       : iil_buyer_products_viewed.partition_date = BL approval date

WITH views AS (
  SELECT
    partition_date                        AS report_date,
    CAST(fk_eto_ofr_display_id AS INT64)  AS bl_id,
    CASE
      WHEN activity_type_id BETWEEN 1 AND 4   THEN '1-4'
      WHEN activity_type_id BETWEEN 5 AND 8   THEN '5-8'
      WHEN activity_type_id BETWEEN 9 AND 12  THEN '9-12'
      WHEN activity_type_id BETWEEN 13 AND 16 THEN '13-16'
      WHEN activity_type_id > 16              THEN '>16'
      ELSE 'Unknown'
    END                                   AS activity_group
  FROM `imbl.iil_buyer_products_viewed`
  WHERE partition_date BETWEEN DATE('{{ start_date }}') AND DATE('{{ end_date }}')
),

approved AS (
  SELECT DATE(eto_ofr_approv_date_orig) AS report_date, COUNT(DISTINCT eto_ofr_display_id) AS approved_bls
  FROM `imbl.eto_ofr_with_expired`
  -- partition_date = post date; approvals land within ~3 days of posting
  WHERE partition_date BETWEEN DATE_SUB(DATE('{{ start_date }}'), INTERVAL 7 DAY) AND DATE('{{ end_date }}')
    AND DATE(eto_ofr_approv_date_orig) BETWEEN DATE('{{ start_date }}') AND DATE('{{ end_date }}')
  GROUP BY 1
),

grouped AS (
  SELECT report_date, activity_group, COUNT(DISTINCT bl_id) AS bls
  FROM views
  GROUP BY 1, 2
)

SELECT
  g.report_date,
  g.activity_group,
  g.bls,
  a.approved_bls,
  ROUND(100 * SAFE_DIVIDE(g.bls, a.approved_bls), 2) AS bls_pct
FROM grouped g
JOIN approved a USING (report_date)
ORDER BY
  g.report_date,
  CASE g.activity_group
    WHEN '1-4' THEN 1 WHEN '5-8' THEN 2 WHEN '9-12' THEN 3 WHEN '13-16' THEN 4
    WHEN '>16' THEN 5 ELSE 6
  END
