# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A daily BL (buy-lead) quality tracker for LEAP (IndiaMART's BL approval team), made of SQL, a JSON registry,
an n8n workflow and a static dashboard (`dashboard/`). Nothing in the repo is built, linted or tested. Each `sql/kNN_*.sql` file is a saved
Redash query that always returns the previous IST day. Redash refreshes each query on a schedule;
`n8n/kpi_daily_redash_to_sheet.workflow.json` reads every query's cached CSV result at 9 AM IST and upserts
the rows into that KPI's Google Sheet tab (`sheet_tab`). `dashboard/` reads those tabs in the browser. `README.md` has the
KPI definitions, data notes and validated numbers. Read it before you change a KPI's logic.

## The brief (what the user asked for)

- A daily tracker of LEAP-level BL-quality KPIs, in modular SQL so KPIs are quick to add or remove. 14 KPIs in
  the order of the task list: BLs with no MCAT mapped (K01) · one-word BLs approved (K02) · BLs with photos
  generated / approved / App % (K03) · BLs with 2+ MCATs mapped (K04) · buyer name / company name in title (K05)
  · blank BLs (K06) · other-subcat photos viewed BLs % (K07) · PMCAT mapping % (K08) · qty fill rate % (K09) ·
  buyer filled spec % (K10) · BLs approved after 24 hours of generation % (K11) · BLs with 0 suppliers
  selected (K12) · BL quality agent corrections, all agents, count + % (K13) · absurd qty detected (K14).
- Every KPI needs **both a number and a %**, for **the previous day only** (day - 1).
- n8n fills a sheet with **one tab per KPI**, one node per KPI API, running at **9 AM IST**; if a query fails or
  times out it should be called again. The sheet powers a dashboard: **default view = last 7 days**, plus
  **compare one date with another**. Clean, professional design.
- Dashboard must have an **MCAT tab** showing only MCAT KPIs (no MCAT, 2+ MCATs), and an **(i) button on
  every KPI that shows the query** behind it.
- KPIs are also to be **split into AWM leads** (Approved Without MCAT, see Segments). The AWM definition and
  validation queries exist; the per-KPI split is not built yet.

## Decisions already made (don't relitigate)

- **Every % is over all BLs approved on that date** (the user's explicit instruction), not over a KPI-specific
  base. The exceptions, each with its own `base_label`:
  - **K06 (blank BLs) is India-only** (user request): count and base are `fk_gl_country_iso = 'IN'` BLs.
  - **K07 is auto-approved BLs only** (user request, 2026-10-29): BLs whose latest row (after the dedupe) has
    `fk_employee_id = -14`, ~80% of approvals.
  - **K09 / K10 keep the team's fill-rate bases** (2026-10-29): BLs in MCATs that ask for quantity / have
    buyer specs. A fill rate over BLs that were never asked the question would mean little. If the user asks
    for all approved BLs instead, drop the `JOIN qty_mcats` / `JOIN spec_mcats`.
- **Every KPI returns only the previous day and takes no params** (user, 2026-10-29). Previous day =
  `DATE_SUB(CURRENT_DATE('Asia/Kolkata'), INTERVAL 1 DAY)` on BigQuery (partition pruning still works),
  `(now() AT TIME ZONE 'Asia/Kolkata')::date - 1` on Postgres. No KPI can be backfilled as is.
- **Date basis = approval date** (`eto_ofr_approv_date_orig`). K03's `photo_bls_generated` counts by post date.
  **K11 counts by approval date** although the team's original counted by post date: yesterday's posts that
  will take > 24 h aren't approved yet at 9 AM, so a post-date count is always incomplete.
- **K08–K14 are the team's queries** (`~/Downloads/Processed_data - api_query.csv`), reshaped to the output
  contract and the standard approved-BL CTE. Their own logic was kept; K09/K10 still match answers modified on
  the approval day (requiring that misses only ~50 BLs/day).
- **AWM = the leap-go-workers check** (the user supplied the worker code, 2026-10-28): the source product has
  no prime MCAT mapping (see Data traps). Not `pc_item_status_approval = 50` (misses ~245 BLs/day) and not
  `fk_employee_id = -14` (a general auto-approval id on ~80% of all approvals).
- **K07 = auto-approved BLs classified by the best-ranked product the buyer viewed** (user's design,
  2026-10-29). It replaced the "every viewed photo is from another subcat" K07 and its K08/K09 subdivisions;
  those files are gone, and K08/K09 are now PMCAT mapping and qty fill rate.
- **n8n reads cached results; it doesn't drive the queries** (user, 2026-10-29): the user set Redash refresh
  schedules, so branches fetch `results.csv` directly and fan out from the trigger instead of running in series.
- **Open question for the user:** should the other KPIs be India-only too? Ask before extending the filter.

## Running / validating a query

There is no local runner. The KPI files take no params, so run them as they are on their Redash data source;
they return yesterday relative to the current IST date:

- **IM-Lakehouse, data_source_id 41 (BigQuery):** every KPI except K05, plus the AWM and exploration files.
  Table names use backticks; running these on a Postgres source fails with `syntax error at or near "`"`.
- **pg-imblr-prod-live, data_source_id 16 (PostgreSQL, live prod DB):** K05 only (~3.5 s; ~19 s on a cold
  cache). Run **one call at a time**: concurrent calls hit the statement timeout. The DB timezone is
  `Asia/Kolkata` and approval timestamps are IST.
- Other sources seen: 8 = Redshift (access denied), 18 = leap_ml.

From Claude Code, the IndiaMART Redash MCP runs this ad hoc: `redash_query-results_run-sql` with the
data_source_id and the SQL returns a job id; poll it with `redash_job_show`, then read the rows with
`redash_query-results_get`. To check an older date, replace `CURRENT_DATE('Asia/Kolkata')` with
`DATE '<day after>'` in a scratch copy. Don't save or edit queries in Redash without asking (a write action).
`redash_queries_get-query` shows a saved query's SQL, owner (`can_edit`), params and refresh schedule.

All KPIs share the approved-BL base, so `base_count` should agree across KPIs for a date to within a few BLs:
166,933 on 10-28 for every Lakehouse KPI and K05; 174,630 / 174,633 (`SELECT DISTINCT` in K01/K04) / 174,632
(K05) on 10-26. A bigger gap means an `approved` CTE has drifted. Not comparable: K06 (Indian BLs), K07
(auto-approved), K09/K10 (their fill-rate bases).

### Validated daily values (approval dates 2026-10-20 → 26, K01–K06)

| KPI | Tue 20 | Wed 21 | Thu 22 | Fri 23 | Sat 24 | Sun 25 | Mon 26 |
|-----|-------:|-------:|-------:|-------:|-------:|-------:|-------:|
| Approved BLs (base) | 134,686 | 155,308 | 163,313 | 171,945 | 173,406 | 158,329 | 174,630 |
| K01 no MCAT | 6 | 8 | 15 | 12 | 11 | 9 | 37 |
| K02 one-word | 180 | 216 | 202 | 266 | 217 | 201 | 203 |
| K03 photo BLs approved | 16,570 | 18,818 | 20,283 | 20,514 | 21,217 | 19,423 | 21,143 |
| K03 `photo_bls_generated` | 20,356 | 23,689 | 25,504 | 25,437 | 25,615 | 23,096 | 26,503 |
| K04 2+ MCATs | 33,402 | 37,632 | 39,032 | 42,057 | 42,132 | 39,169 | 43,126 |
| K05 name in title | 16 | 28 | 28 | 18 | 21 | 30 | 31 |
| K06 blank BLs (India) | 2,004 | 2,419 | 2,429 | 2,442 | 2,380 | 1,906 | 2,322 |
| K06 base: Indian approved | 129,510 | 150,353 | 158,805 | 166,583 | 169,223 | 153,891 | 169,589 |
| AWM leads | 2,956 | 3,413 | 3,303 | 3,407 | 3,535 | 3,217 | 3,070 |

Sunday (25th) is a low-volume day.

### Validated 2026-10-28 (run 2026-10-29, K07–K14)

| KPI | kpi_count | base_count | kpi_pct |
|-----|----------:|-----------:|--------:|
| K01 no MCAT | 17 | 166,933 | 0.01 |
| K07 Same MCAT / No product viewed (of auto-approved) | 97,527 / 25,375 | 133,369 | 73.13 / 19.03 |
| K08 PMCAT mapped | 22,512 | 166,933 | 13.49 |
| K09 qty filled | 110,636 | 136,775 | 80.89 |
| K10 buyer filled spec | 135,475 | 163,929 | 82.64 |
| K11 approved > 24 h | 1,997 | 166,933 | 1.20 |
| K12 0 suppliers | 3 | 166,933 | 0.00 |
| K13 Spec Mismatch / Buyer Description / One Word Title / Other / Absurd Qty / Selling Intent / PII / No Issue | 45,160 / 9,907 / 2,697 / 1,876 / 1,389 / 13 / 3 / 109,821 | 166,933 | 27.05 / 5.93 / 1.62 / 1.12 / 0.83 / 0.01 / 0.00 / 65.79 |
| K14 absurd qty | 1,389 | 166,933 | 0.83 |

## Output contract

Every KPI query returns rows with exactly these columns, in this order: `report_date, kpi_id, kpi_name,
kpi_count, base_count, kpi_pct, base_label`. `kpi_pct` = `ROUND(100 * kpi_count / base_count, 2)`;
`base_label` is `'Approved BLs'` unless the base differs (K06, K07, K09, K10; see README). Extra columns can
only go after these, and each one must also be listed in that KPI's `extra_columns` in `kpi_registry.json`
(K03: `photo_bls_generated`; K07, K13: `category`). K07 and K13 return several rows per day (one per
category); every other KPI returns one. Registry `direction`: `higher_is_better` for K03, K09, K10; `neutral`
for the breakdowns K07, K13; `lower_is_better` for the rest.

## Shared query structure (BigQuery KPIs)

All the Lakehouse queries are built the same way. Keep new ones consistent with them:

1. An `approved` CTE on `imbl.eto_ofr_with_expired`. Its `partition_date` is the **post** date, so it scans
   `yesterday - 7 … yesterday` and keeps `DATE(eto_ofr_approv_date_orig) = yesterday`. One row per BL, via
   `QUALIFY ROW_NUMBER() OVER (PARTITION BY eto_ofr_display_id ORDER BY partition_date DESC) = 1` or
   `SELECT DISTINCT` (K01/K04). Filters on BL columns that can change (K07's `fk_employee_id`) go after the
   dedupe, so the latest row decides.
2. Side tables, partitioned by event date: `eto_ofr_mapping` + `_expired` and `eto_attribute` (K06) scan
   `yesterday - 7 … yesterday + 3`; tables written on the approval day scan just that day (K09 attributes and
   K13/K14 audit log: yesterday; K10 attributes and K12 supplier mapping: yesterday … today). Aggregate them
   per `bl_id`.
3. `LEFT JOIN` the side tables onto `approved` (an inner `JOIN` only to restrict the base, as K09/K10 do),
   then `GROUP BY report_date` with `COUNTIF` / `SAFE_DIVIDE`.

Join on `CAST(... AS INT64)` display ids. In this schema, BL ids are `eto_ofr_display_id` /
`fk_eto_ofr_display_id` / `fk_eto_ofr_id`.

## Schema notes (Lakehouse unless stated)

- `imbl.eto_ofr_with_expired`: live + expired BLs, ~134k–175k approved a day. `partition_date` = post date.
  `eto_ofr_approv_by_orig` < 0 = system auto-approval (~95%), > 0 = a LEAP agent (~8.9k/day).
  `fk_employee_id`: -14 on ~79% of approvals; -30 / -76 are the other system approvers (~15%); ~0.9% of the
  -14 BLs were first approved by an agent. `eto_ofr_modrefid` = source product display id for every
  `eto_ofr_modref_type`; on app BLs (`modref_type` NULL) `eto_ofr_modref_dispname` is blank.
- `imbl.eto_ofr_temp_del`: rejected / deleted BLs, **no partition column** (filter on
  `DATE(eto_ofr_postdate_orig)`). Used only for K03's generated count.
- `imbl.eto_ofr_mapping` / `_expired`: BL → MCAT rows, `partition_date` = mapping date.
- `imbl.eto_attribute`: BL ISQ answers, `partition_date` = attribute mod date (~= approval date: rewritten when
  the BL is approved). Quantity = `fk_im_spec_master_desc = 'Quantity'`; priorities 1000 (order value) and 1100
  (req. type) are system-derived, not buyer specs; `eto_attribute_source` tells buyer-filled answers apart (K10).
- `imbl.eto_lead_supplier_mapping`: BL → selected suppliers (1–300 rows per BL); `partition_date` =
  `DATE(mapping_date)` = the approval date. Only ~3 approved BLs/day have no row (K12).
- `leapml.leap_blml_agent_audit_log`: one row per correction by the BL quality agent (`fk_eto_ofr_id`,
  `issue_flag_id` 1–7, attribute before/after); `partition_date` = `DATE(offer_approve_date)` = approval date.
  ~60k BLs/day have at least one row.
- `imbl.iil_buyer_products_viewed`: `partition_date` = the BL's approval date. Its `fk_glcat_cat_id` /
  `fk_glcat_mcat_id` are the **viewed product's** (match the BL's subcat in only ~76% of rows, MCAT ~55%).
- `mesh.glcat_mcat`: MCAT master; `glcat_mcat_is_generic = 1` = PMCAT (K08), `glcat_mcat_delete_status`,
  `seo_on_flag`. `mesh.im_cat_specification` + `mesh.im_specification_master` = which ISQs each MCAT asks
  (`im_cat_spec_status = 1` active, `im_spec_master_buyer_seller` 0/1).
- `mesh.pc_item`: products. `pc_item_status_approval = 50` is the Decision Engine's AWM code, not the AWM
  rule used here. `pc_item_glcat_mcat_id_list` is stale on AWM products (non-empty with no mapping row), so
  don't use it. `mesh.pc_item_to_glcat_mcat` = product → MCAT (`item_mapping_isprime = -1` = prime);
  `mesh.glcat_cat_to_mcat` = cat → MCAT. Scanning these is costly (~10–20 GB per query).
- Postgres (ds 16): `weberp.eto_ofr` / `weberp.eto_ofr_expired` are views with indexes on
  `date(eto_ofr_approv_date_orig)`; filters must use that exact expression. `weberp.glusr_usr` is too slow,
  `public.glusr_usr` is permission denied. `eto_ofr_s_organization`, `eto_ofr_companyname` are the buyer's company.
- Field meanings and the `user_identifier_flag` (UIF) pool codes (MUST / DNC / INTENT) are in the user's
  `~/Downloads/LEAP Tables and Files - Dir_query_free.csv` and `~/Downloads/Flags used in LEAP 2 - UIF.csv`.
  `dir_query_catid` / `fk_glcat_cat_id` = "lead is mapped in which category".

## Data traps (already investigated, don't reintroduce)

- Photo = `eto_ofr_attachment_is_exist = 1`. Don't use `imbl.eto_ofr_attachment`: it loses rows once a BL
  expires, which breaks history. ~850 approved BLs/day have the flag at 0 but something in `eto_ofr_original_image`
  / `eto_ofr_small_image` / `eto_ofr_image_path1`. Only ~80 of those are real images (a URL or a `data7/...`
  path, so they contain `/`); ~775 are the placeholders `'1'` or `'[object Object]'` and have no image. Check
  image columns with `STRPOS(col, '/') > 0`, never "not blank" (see `sql/k07_viewed_product_match.sql`).
  K03/K06 use the flag alone.
- `eto_ofr_qty` / `eto_ofr_spec` are empty on every BL. Spec and quantity come from `imbl.eto_attribute`.
- `fk_glcat_mcat_id` on the BL is almost never empty, so MCAT counts come from the mapping tables.
- In `imbl.iil_buyer_products_viewed`, the cat/mcat columns describe the *viewed product*, not the BL.
- Filtering approvals with `partition_date >= start_date` undercounts, because `partition_date` is the post
  date (one-word BLs on 10-26: 133 instead of 175 for India). `partition_date <= end_date` with no lower bound
  is right but scans all history. Always look back 7 days. The team's original K08–K14 had both.
- K05 (Postgres): buyer names are masked in the Lakehouse, which is why this KPI runs on the live DB. Filter
  with `date(eto_ofr_approv_date_orig)` so the expression index is used, and don't join `glusr_usr` (it
  pushes the query to ~90 s/day and it times out).
- AWM is the leap-go-workers check (`models.FetchMcatName`): the source product has no prime MCAT mapping
  (`item_mapping_isprime = -1`, MCAT present in `glcat_mcat` and `glcat_cat_to_mcat`). It is *not*
  `pc_item_status_approval = 50`. The same `products` / `prime_mapped` / `awm_products` CTEs are copied into
  every file that uses AWM, so change them everywhere together. `pc_item` and the mapping tables are current
  snapshots, so counts for older dates drift slightly.
- Redash CSVs (`results.csv`) write dates as `dd/MM/yy` (`28/10/26`), not ISO. The n8n Check node parses that.
- A Redash query with params returns the cache of whatever params ran last from `results.csv`, or
  `{"message": "No cached result found for this query."}`. Queries n8n reads must have no params and a refresh
  schedule.

## Segments: AWM

AWM lead = approved BL whose source product (`eto_ofr_modrefid` = `mesh.pc_item.pc_item_display_id`) has no
prime MCAT mapping, per the leap-go-workers check (see Data traps). `sql/awm_leads.sql` lists the leads for
spot checks (compare `bl_title` with `product_name`; `product_mcat_rows` > 0 = mapped but no valid prime, 95
of 3,070 on 10-26). `sql/awm_leads_daily.sql` gives the daily count and %. BLs whose product is no longer in
`pc_item` (~900/day) and BLs with no `eto_ofr_modrefid` (~24.6k/day) are not counted as AWM.
These files use `kpi_id = 'AWM'` and date-range params, are not in the registry, and n8n doesn't run them.

Proposed next step (not built, waiting on the user's validation of the AWM list): add a `segment` column
(AWM / Non-AWM) to each KPI, two rows per day per KPI, each segment's % over that segment's approved count.

Other non-KPI files in `sql/` are one-off explorations with date-range params: `bl_no_product_viewed.sql`
(lead list for K07's no-product-viewed category), `bl_viewed_product_5c_auto_approved.sql` (offer ids of K07's
5c), `bl_viewed_product_match_auto_approved.sql` (K07 over a period), `iil_activity_type_groups.sql`.

Related saved Redash queries (read-only, others' work): 42899 "Decision Engine Stats" (`AWM_by_code` =
`product_approval_status = 50`), 47991 "Audit AWM Data", 42163 "AWM ENQs" (Redshift).

## Adding / changing a KPI

1. Add `sql/kNN_<slug>.sql` with the same header comment block as the other files (data source, params,
   grain, definition, base) and the output contract above, returning the previous day with no params.
2. Validate it on Redash (it runs as is), then the user saves it in Redash with a refresh schedule and gives
   its CSV results URL (`/api/queries/{id}/results.csv?api_key=…`).
3. Add an entry to `kpi_registry.json` (`id`, `name`, `sheet_tab`, `sql_file`, `redash_data_source_id`,
   `redash_query_id`, `direction`, `date_window`, `enabled`, plus `extra_columns` if needed).
4. Add a `(id, label, query id, API key, sheet tab)` row to `KPIS` in `n8n/build_workflow.py` and run
   `python3 n8n/build_workflow.py n8n/kpi_daily_redash_to_sheet.workflow.json`; the user re-imports it.
5. Update the KPI table and the "Definitions and data notes" section in `README.md`.
6. Dashboard: add its display entry (`group`, `name`, `def`, base words) to `kpis` in `dashboard/config.js`
   and run `python3 dashboard/build_registry.py`. Rerun that script whenever a `sql/` file changes too, so the
   (i) dialog shows the current SQL.

To retire a KPI, set `"enabled": false` rather than deleting it, so its sheet history stays.

## n8n workflow

`n8n/kpi_daily_redash_to_sheet.workflow.json`, generated by `n8n/build_workflow.py` (edit the script, not the
JSON; node ids are regenerated each run). Both contain the Redash query API keys: keep `n8n/` out of git.
First, once per run: **Read sheet tabs** (`GET` Sheets API) → **Plan sheet tabs** (Code: missing KPI tabs + header
rows) → **Any tab missing?** → **Add missing tabs** (`addSheet`) → **Write header rows** (`values:batchUpdate`, row 1
of every KPI tab) → fan-out. These HTTP nodes use the Google Sheets OAuth2 credential (predefined credential type);
headers come from `header()` in the script (contract + `EXTRA_COLUMNS` + `row_key, synced_at`), so add a KPI's
extra columns there too. Per KPI: **Fetch CSV** (`GET results.csv`, 5 tries) → **Parse CSV** → **Check** (Code: yesterday's rows pass with
`row_key` + `synced_at`; a failed fetch, no rows or an older day returns a retry request until round 3, then
throws to its unconnected error output) → **Retry?** (IF) → **Write** (Google Sheets `appendOrUpdate` on
`row_key`) or **Re-run query** (`POST …/results?api_key=…`, `{"max_age": 0}`) → **Wait 2 min** → back to Fetch.
`row_key` = `report_date`, or `report_date|category` for K07/K13. `SHEET_ID` in the script is the target sheet. n8n runs fan-out branches one after another, top to bottom, so K01–K07 go first.
The user may want true parallel runs later: the option offered is a main workflow that calls a per-KPI worker
workflow with "wait for completion" off.

K08–K14 point at the team's saved queries 49707, 49671, 49699, 49667, 49708, 49709, 49710, owned by a colleague
(`can_edit: false`). Since 2026-10-30 they hold the repo SQL (Redash `query_hash` = the repo file's) with no
parameters. Their API URLs match the user's `~/Downloads/Processed_data - api_query (1).csv` (KPI → results.csv
URL with api_key → original SQL → converted SQL), so the CSV needs nothing further unless an id or key changes.
To check a saved query against the repo without reading it by eye: Redash `query_hash` = md5 of the SQL with
`/* */` comments and all whitespace removed.

## Sheet and dashboard

- **Sheet:** n8n writes to "Daily_Audits_BL_Quality" (id `1AAPtHbdl4Z1UjBYoznOxSYxaw6u-hStMWrKDgpb0eH0`, owned by
  a colleague, shared with the user for editing; it also holds other audit data in `Sheet1`, so only touch the
  KPI tabs). One tab per `sheet_tab`; the workflow's sheet-setup step creates missing tabs and writes their
  header rows (the Google Sheets node itself doesn't create tabs). The n8n credential is a Google Sheets
  OAuth2 credential from the user's own OAuth client; its secret lives only in n8n. An earlier, empty sheet
  ("KPI-dashboard-list", `1IqH5dIzE5CWShxW31VjM7CnBGzCnpvRsFEws_3oAegI`) is no longer used.
- **Dashboard (`dashboard/`):** static HTML/JS, no build, no server code, no credentials. Run it with
  `python3 -m http.server 8000 -d dashboard` and open http://localhost:8000 (any static host works).
  - Data comes only from the sheet: `sheet.js` reads each KPI's own tab (`sheet_tab` from the registry) through
    the gviz endpoint `docs.google.com/spreadsheets/d/<id>/gviz/tq?tqx=out:json&headers=1&sheet=<tab>`. This
    works because the sheet is shared "anyone with the link"; if that sharing is turned off, every tab fails
    and the page says so (the fix would be the Sheets API with an API key or Google sign-in).
  - Trap: gviz answers an unknown tab name with the *first* sheet (Sheet1, audit data), not an error. A tab
    only counts if row 1 holds the contract columns and its rows carry the KPI's `kpi_id`; never drop that check.
  - Dates, windows and states come from the data: latest `report_date` across tabs, "same day last week" =
    latest − 7, charts cover ≥ 8 days (`minWindowDays`); a missing tab or a missing day shows on its card.
    The Approved-BLs headline is `base_count` from the first of `approvedFrom` (K11, K08, …) with that date.
  - `registry.js` is generated by `dashboard/build_registry.py` (registry + SQL text); `config.js` holds the
    sheet id, tab groups and display text; `app.js` renders; `styles.css` follows the design.
  - AWM isn't in the sheet, so the frontend has no AWM card.
- **Dashboard design:** a claude.ai Design artifact, https://claude.ai/artifact/RpJRNyMfYai5WYk8Bzb9Eq
  (one interactive artboard, `project/Main.dc.html` + `project/canvas.json`). To change it, `read` the
  artifact with the Artifact tool and publish back to that URL; the local copy from the session that made it
  was in a temporary scratchpad and is gone.
  - Tabs: Overview (approved-BL headline + one compact card per KPI, K01–K14 in order, + an AWM card),
    MCAT = K01/K04/K08, Photos = K03, Title & content = K02/K05/K06, Specs & quantity = K09/K10/K14,
    Approval & suppliers = K11/K12, Viewed products = K07, Agent corrections = K13.
  - K07 / K13 panels: headline = first category row (K07 "Same MCAT"; K13 "Any correction" = approved −
    "0. No Issue", not a sheet row), plus a category table (date vs compared date); clicking a row plots it.
  - Default view "Same day last week" (latest day vs the same weekday 7 days earlier: Mon 26 Oct vs Mon 19 Oct);
    "Compare dates" shows two date buttons, each opening a small October calendar pop-up. Data covers 19–26 Oct.
  - User's design rules (2026-10-30): line charts only (no bars); no "pp" (changes show as Better / Worse next to
    the other day's value); never label dates "A" / "B"; no segment switch; no K07 breakdown boxes.
  - Every card and panel has an (i) button showing the KPI's SQL, data source, sheet tab and params, with a
    Copy SQL button. The SQL is a pasted copy of each `sql/` file (K01–K14; AWM keeps its own), and the
    numbers are hard-coded Redash results for 19–26 Oct (K07–K14 run 2026-10-30 as date-range copies of the
    repo logic). It's the visual reference; `dashboard/` is the real frontend.

## Open items

- Get the repo SQL into queries 49707, 49671, 49699, 49667, 49708, 49709, 49710 (or new queries) with refresh
  schedules, so n8n's K08–K14 branches pass.
- First n8n run against "Daily_Audits_BL_Quality" (it creates the 14 KPI tabs). Until then `dashboard/` shows
  "tab missing" on every card (checked 2026-10-30: the sheet had no KPI tabs yet).
- India-only scope for the other KPIs? (K06 already is.)
- AWM / Non-AWM split of every KPI, after the user validates `sql/awm_leads.sql`.
- Does leap-go-workers call `FetchMcatName` when `modrefid` is empty? If so, BLs with no source product
  (~24.6k/day) are AWM too, and the AWM CTEs need to count them.
- The Redash refresh schedules on K01–K07 are set to every 60 seconds; check that's intended (K05 hits the
  live Postgres DB each time).
- Nothing has been committed beyond the initial commit; commit only when asked.
