-- K14 | Absurd quantity detected
-- Data source : IM-Lakehouse (BigQuery, Redash data_source_id = 41)
-- Params      : none. Always the previous day: approvals on (current IST date - 1), via
--               CURRENT_DATE('Asia/Kolkata'). n8n calls it with no parameters.
-- Grain       : one row (the previous day)
-- Definition  : approved BLs that the BL quality agent flagged for absurd quantity
--               (leapml.leap_blml_agent_audit_log.issue_flag_id = 3); the same BLs as K13's
--               '3. Absurd Quantity' row
-- Base        : all BLs approved on the date
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

absurd AS (
  SELECT DISTINCT CAST(fk_eto_ofr_id AS INT64) AS bl_id
  FROM `leapml.leap_blml_agent_audit_log`
  WHERE partition_date = DATE_SUB(CURRENT_DATE('Asia/Kolkata'), INTERVAL 1 DAY)
    AND DATE(offer_approve_date) = DATE_SUB(CURRENT_DATE('Asia/Kolkata'), INTERVAL 1 DAY)
    AND issue_flag_id = 3
)

SELECT
  a.report_date,
  'K14'                                                         AS kpi_id,
  'Absurd quantity detected'                                    AS kpi_name,
  COUNTIF(x.bl_id IS NOT NULL)                                  AS kpi_count,
  COUNT(*)                                                      AS base_count,
  ROUND(100 * SAFE_DIVIDE(COUNTIF(x.bl_id IS NOT NULL), COUNT(*)), 2) AS kpi_pct,
  'Approved BLs'                                                AS base_label
FROM approved a
LEFT JOIN absurd x USING (bl_id)
GROUP BY a.report_date
ORDER BY a.report_date
