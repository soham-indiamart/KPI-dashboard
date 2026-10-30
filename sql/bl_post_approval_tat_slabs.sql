-- BL post -> approval TAT slabs, day-wise by POST DATE (IST), last 30 days, counts + % of that day's approved BLs
-- Data source : IM-Lakehouse (BigQuery, Redash data_source_id = 41)
-- Params      : none (last 30 post dates up to yesterday, IST)
-- Grain       : one row per post date
-- Definition  : TAT = eto_ofr_approv_date_orig - eto_ofr_postdate_orig, for BLs approved so far
-- Base        : BLs posted that day and approved so far (one row per BL)
-- Notes       : the most recent 1-2 post dates are incomplete (BLs still awaiting approval)

WITH base AS (
  SELECT
    DATE(eto_ofr_postdate_orig) AS post_date,
    TIMESTAMP_DIFF(CAST(eto_ofr_approv_date_orig AS TIMESTAMP),
                   CAST(eto_ofr_postdate_orig AS TIMESTAMP), SECOND) / 60.0 AS diff_min
  FROM `imbl.eto_ofr_with_expired`
  -- partition_date = post date
  WHERE partition_date BETWEEN DATE_SUB(CURRENT_DATE('Asia/Kolkata'), INTERVAL 30 DAY)
                           AND DATE_SUB(CURRENT_DATE('Asia/Kolkata'), INTERVAL 1 DAY)
    AND DATE(eto_ofr_postdate_orig) BETWEEN DATE_SUB(CURRENT_DATE('Asia/Kolkata'), INTERVAL 30 DAY)
                                        AND DATE_SUB(CURRENT_DATE('Asia/Kolkata'), INTERVAL 1 DAY)
    AND eto_ofr_approv_date_orig IS NOT NULL
    AND eto_ofr_approv_date_orig >= eto_ofr_postdate_orig
  QUALIFY ROW_NUMBER() OVER (PARTITION BY eto_ofr_display_id ORDER BY partition_date DESC) = 1
)

SELECT
  post_date,
  COUNT(*)                                                        AS total_approved,
  COUNTIF(diff_min < 15)                                          AS min_0_15,
  COUNTIF(diff_min >= 15 AND diff_min < 30)                       AS min_15_30,
  COUNTIF(diff_min >= 30 AND diff_min < 60)                       AS min_30_60,
  COUNTIF(diff_min >= 60 AND diff_min < 240)                      AS hr_1_4,
  COUNTIF(diff_min >= 240 AND diff_min < 720)                     AS hr_4_12,
  COUNTIF(diff_min >= 720 AND diff_min < 1440)                    AS hr_12_24,
  COUNTIF(diff_min >= 1440 AND diff_min < 2160)                   AS hr_24_36,
  COUNTIF(diff_min >= 2160)                                       AS hr_36_plus,
  ROUND(100 * COUNTIF(diff_min < 15) / COUNT(*), 1)                          AS min_0_15_pct,
  ROUND(100 * COUNTIF(diff_min >= 15 AND diff_min < 30) / COUNT(*), 1)       AS min_15_30_pct,
  ROUND(100 * COUNTIF(diff_min >= 30 AND diff_min < 60) / COUNT(*), 1)       AS min_30_60_pct,
  ROUND(100 * COUNTIF(diff_min >= 60 AND diff_min < 240) / COUNT(*), 1)      AS hr_1_4_pct,
  ROUND(100 * COUNTIF(diff_min >= 240 AND diff_min < 720) / COUNT(*), 1)     AS hr_4_12_pct,
  ROUND(100 * COUNTIF(diff_min >= 720 AND diff_min < 1440) / COUNT(*), 1)    AS hr_12_24_pct,
  ROUND(100 * COUNTIF(diff_min >= 1440 AND diff_min < 2160) / COUNT(*), 1)   AS hr_24_36_pct,
  ROUND(100 * COUNTIF(diff_min >= 2160) / COUNT(*), 1)                       AS hr_36_plus_pct
FROM base
GROUP BY post_date
ORDER BY post_date DESC
