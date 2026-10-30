-- K13 | BL quality agent corrections (all agents), by issue
-- Data source : IM-Lakehouse (BigQuery, Redash data_source_id = 41)
-- Params      : none. Always the previous day: approvals on (current IST date - 1), via
--               CURRENT_DATE('Asia/Kolkata'). n8n calls it with no parameters.
-- Grain       : one row per issue for the previous day; upsert on report_date + category
-- Definition  : approved BLs with a correction in leapml.leap_blml_agent_audit_log, by issue_flag_id:
--               1 Spec Mismatch, 2 One Word Title, 3 Absurd Quantity, 4 PII Issue, 5 Selling Intent,
--               6 Buyer Description, 7 / anything else Other. BLs with no audit row are 0. No Issue.
-- Base        : all BLs approved on the date
-- Columns     : KPI output contract + category (the issue). A BL with several issues is counted in each of
--               them, so the issue rows add up to more than base_count
-- Notes       : audit log partition_date = DATE(offer_approve_date) = the BL's approval date

WITH approved AS (
  SELECT
    CAST(eto_ofr_display_id AS INT64)  AS bl_id,
    DATE(eto_ofr_approv_date_orig)     AS report_date
  FROM `imbl.eto_ofr_with_expired`
  -- partition_date = post date: yesterday - 7 days ... yesterday
  WHERE partition_date BETWEEN DATE_SUB(CURRENT_DATE('Asia/Kolkata'), INTERVAL 8 DAY) AND DATE_SUB(CURRENT_DATE('Asia/Kolkata'), INTERVAL 1 DAY)
    AND DATE(eto_ofr_approv_date_orig) = DATE_SUB(CURRENT_DATE('Asia/Kolkata'), INTERVAL 1 DAY)
  QUALIFY ROW_NUMBER() OVER (PARTITION BY eto_ofr_display_id ORDER BY partition_date DESC) = 1
),

issues AS (
  SELECT DISTINCT
    CAST(fk_eto_ofr_id AS INT64)  AS bl_id,
    CAST(issue_flag_id AS INT64)  AS issue_flag_id
  FROM `leapml.leap_blml_agent_audit_log`
  WHERE partition_date = DATE_SUB(CURRENT_DATE('Asia/Kolkata'), INTERVAL 1 DAY)
    AND DATE(offer_approve_date) = DATE_SUB(CURRENT_DATE('Asia/Kolkata'), INTERVAL 1 DAY)
),

labelled AS (
  SELECT
    a.report_date,
    a.bl_id,
    CASE COALESCE(i.issue_flag_id, 0)
      WHEN 0 THEN '0. No Issue'
      WHEN 1 THEN '1. Spec Mismatch'
      WHEN 2 THEN '2. One Word Title'
      WHEN 3 THEN '3. Absurd Quantity'
      WHEN 4 THEN '4. PII Issue'
      WHEN 5 THEN '5. Selling Intent'
      WHEN 6 THEN '6. Buyer Description'
      ELSE '7. Other'
    END AS category
  FROM approved a
  LEFT JOIN issues i USING (bl_id)
),

base AS (
  SELECT report_date, COUNT(*) AS approved_bls
  FROM approved
  GROUP BY 1
)

SELECT
  l.report_date,
  'K13'                                                         AS kpi_id,
  'BL quality agent corrections'                                AS kpi_name,
  COUNT(DISTINCT l.bl_id)                                       AS kpi_count,
  b.approved_bls                                                AS base_count,
  ROUND(100 * SAFE_DIVIDE(COUNT(DISTINCT l.bl_id), b.approved_bls), 2) AS kpi_pct,
  'Approved BLs'                                                AS base_label,
  l.category
FROM labelled l
JOIN base b USING (report_date)
GROUP BY l.report_date, l.category, b.approved_bls
ORDER BY l.report_date, l.category
