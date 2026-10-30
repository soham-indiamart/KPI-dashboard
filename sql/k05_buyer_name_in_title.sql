-- K05 | Buyer name / company name in BL title
-- Data source : pg-imblr-prod-live (PostgreSQL, Redash data_source_id = 16)
--               (buyer names are masked in the Lakehouse, so this KPI reads the live BL DB)
-- Params      : none. Always the previous day: approvals on (current IST date - 1). The DB runs in
--               Asia/Kolkata and approval timestamps are IST; the explicit AT TIME ZONE keeps it right
--               if a session timezone ever differs. n8n calls it with no parameters.
-- Grain       : one row (the previous day)
-- Definition  : approved BL whose title (whole-word match, case/punctuation-insensitive) contains
--   NAME    -> buyer first name (>= 3 chars, not part of the MCAT name) AND one of
--                - buyer last name also in title          e.g. "Prashant Kumar Singh"
--                - a "from / via / by" marker              e.g. "Enquiry for Photo Frame From Najeeb Via ..."
--                - title is just 1-2 words (i.e. the name) e.g. "Nutankumari"
--   COMPANY -> buyer company core (legal/generic words removed, >= 4 chars, not part of the MCAT name)
--              AND (core has 2+ words OR the whole title is the company)
--              single-word cores are skipped on purpose: they are mostly brands ("Mahindra", "Lenovo")
-- Base        : all BLs approved on the date
-- Name source : eto_ofr_s_sendername / eto_ofr_s_organization / eto_ofr_companyname (all buyer-side).
--               glusr_usr is not joined: the view lookup costs ~90 s/day and hits the statement timeout.
-- Perf        : filters use date(eto_ofr_approv_date_orig) so the expression indexes are hit (~10 s/day)

WITH approved AS (
  SELECT eto_ofr_display_id, date(eto_ofr_approv_date_orig) AS report_date, eto_ofr_title,
         eto_ofr_glcat_mcat_name, eto_ofr_s_sendername, eto_ofr_s_organization, eto_ofr_companyname
  FROM weberp.eto_ofr
  WHERE date(eto_ofr_approv_date_orig) = (now() AT TIME ZONE 'Asia/Kolkata')::date - 1
  UNION ALL
  SELECT eto_ofr_display_id, date(eto_ofr_approv_date_orig), eto_ofr_title,
         eto_ofr_glcat_mcat_name, eto_ofr_s_sendername, eto_ofr_s_organization, eto_ofr_companyname
  FROM weberp.eto_ofr_expired
  WHERE date(eto_ofr_approv_date_orig) = (now() AT TIME ZONE 'Asia/Kolkata')::date - 1
),

dedup AS (
  SELECT DISTINCT ON (eto_ofr_display_id) *
  FROM approved
  ORDER BY eto_ofr_display_id, report_date DESC
),

norm AS (
  -- lower-case, alphanumeric-only, single-spaced; padding with ' ' makes position() a whole-word match
  SELECT
    report_date,
    ' ' || trim(regexp_replace(lower(coalesce(eto_ofr_title, '')), '[^a-z0-9]+', ' ', 'g')) || ' '           AS t,
    ' ' || trim(regexp_replace(lower(coalesce(eto_ofr_glcat_mcat_name, '')), '[^a-z0-9]+', ' ', 'g')) || ' ' AS mcat,
    trim(regexp_replace(lower(coalesce(eto_ofr_s_sendername, '')), '[^a-z0-9]+', ' ', 'g'))                  AS sender,
    trim(regexp_replace(
      regexp_replace(lower(coalesce(nullif(trim(eto_ofr_s_organization), ''), eto_ofr_companyname, '')), '[^a-z0-9]+', ' ', 'g'),
      '\m(m s|ms|pvt|private|ltd|limited|llp|inc|co|company|corp|corporation|and|the|of|enterprises?|industries|industry|traders?|trading|solutions?|services?|international|india|indian|group|agency|agencies|exports?|imports?|works|stores?|mart|sons|brothers|bros)\M',
      ' ', 'g'))                                                                                             AS company_raw
  FROM dedup
),

parts AS (
  SELECT
    report_date, t, mcat,
    split_part(sender, ' ', 1)                                        AS first_name,
    CASE WHEN sender LIKE '% %' THEN regexp_replace(sender, '^.* ', '') ELSE '' END AS last_name,
    trim(regexp_replace(company_raw, '\s+', ' ', 'g'))                AS company_core,
    array_length(regexp_split_to_array(trim(t), ' '), 1)              AS title_words
  FROM norm
),

flags AS (
  SELECT
    report_date,
    (
      length(first_name) >= 3
      AND position(' ' || first_name || ' ' IN t) > 0
      AND position(' ' || first_name || ' ' IN mcat) = 0
      AND (
        (length(last_name) >= 3 AND last_name <> first_name AND position(' ' || last_name || ' ' IN t) > 0)
        OR t ~ '\m(from|via|by)\M'
        OR title_words <= 2
      )
    ) AS name_hit,
    (
      length(company_core) >= 4
      AND position(' ' || company_core || ' ' IN t) > 0
      AND position(' ' || company_core || ' ' IN mcat) = 0
      AND (company_core LIKE '% %' OR trim(t) = company_core)
    ) AS company_hit
  FROM parts
)

SELECT
  report_date,
  'K05'                                                                AS kpi_id,
  'Buyer / company name in title'                                      AS kpi_name,
  COUNT(*) FILTER (WHERE name_hit OR company_hit)                      AS kpi_count,
  COUNT(*)                                                             AS base_count,
  ROUND(100.0 * COUNT(*) FILTER (WHERE name_hit OR company_hit) / NULLIF(COUNT(*), 0), 2) AS kpi_pct,
  'Approved BLs'                                                       AS base_label
FROM flags
GROUP BY report_date
ORDER BY report_date
