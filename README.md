# KPI-dashboard

Daily LEAP BL-quality tracker. Each KPI is one self-contained SQL file that runs in Redash, always returns
the previous day (IST) and the same 7 columns, so n8n can write it to that KPI's sheet tab and the
dashboard can read every tab the same way.

## Output contract (every KPI)

| column       | type   | meaning                                                  |
|--------------|--------|----------------------------------------------------------|
| `report_date`| date   | approval date (always yesterday, IST)                    |
| `kpi_id`     | string | `K01` … `K14`                                            |
| `kpi_name`   | string | display name                                             |
| `kpi_count`  | int    | BLs approved on the date that hit the KPI                |
| `base_count` | int    | **all BLs approved on the date**, except K06 (Indian BLs), K07 (auto-approved BLs), K09 (BLs in MCATs that ask for quantity) and K10 (BLs in MCATs with buyer specs) |
| `kpi_pct`    | float  | `100 * kpi_count / base_count`, 2 decimals               |
| `base_label` | string | names the base: `Approved BLs`, or K06 `Approved BLs (India)`, K07 `Auto-approved BLs`, K09 `Approved BLs in MCATs with a Quantity ISQ`, K10 `Approved BLs in MCATs with buyer specs` |

A KPI may add extra trailing columns (listed under `extra_columns` in `kpi_registry.json`):
K03 → `photo_bls_generated`; K07 and K13 → `category` (they return one row per category per day).

No parameters: every query computes yesterday itself (`DATE_SUB(CURRENT_DATE('Asia/Kolkata'), INTERVAL 1 DAY)`
on BigQuery, `(now() AT TIME ZONE 'Asia/Kolkata')::date - 1` on Postgres), so a run on the 26th returns the 25th.
The flip side: no KPI can be backfilled for an older date as is.

## KPIs

| ID  | KPI                                   | Source (Redash DS)        | Redash query | Validated                       |
|-----|---------------------------------------|---------------------------|--------------|---------------------------------|
| K01 | BLs with no MCAT mapped               | IM-Lakehouse (41)         | 49596 | 6–37/day, ~0.01% (10-20 → 26)            |
| K02 | One-word BLs approved                 | IM-Lakehouse (41)         | 43446 | 180–266/day, ~0.13%                      |
| K03 | BLs with photos: generated / approved / % of approved | IM-Lakehouse (41) | 43226 | 16.6–21.2k approved/day, ~12%; 20–25k generated |
| K04 | BLs with 2+ MCATs mapped              | IM-Lakehouse (41)         | 24260 | 33–43k/day, ~24.5%                       |
| K05 | Buyer / company name in title         | pg-imblr-prod-live (16)   | 24118 | 16–31/day, ~0.02%                        |
| K06 | Blank BLs (no spec/desc/qty/photo), India only | IM-Lakehouse (41) | 23071 | 1.9–2.4k/day, 1.24–1.61% of Indian approved |
| K07 | Auto-approved BLs by best-ranked viewed product (one row per category) | IM-Lakehouse (41) | 23053 | 10-28: Same MCAT 73.1%, Others 2.3%, no product viewed 19.0% of auto-approved |
| K08 | PMCAT mapping %                       | IM-Lakehouse (41)         | 49707* | 10-28: 22,512 of 166,933, 13.49%        |
| K09 | Qty fill rate %                       | IM-Lakehouse (41)         | 49671* | 10-28: 110,636 of 136,775, 80.89%       |
| K10 | Buyer filled spec %                   | IM-Lakehouse (41)         | 49699* | 10-28: 135,475 of 163,929, 82.64%       |
| K11 | BLs approved > 24 h after generation  | IM-Lakehouse (41)         | 49667* | 10-28: 1,997 of 166,933, 1.20%          |
| K12 | BLs with 0 suppliers selected         | IM-Lakehouse (41)         | 49708* | 10-28: 3 of 166,933                     |
| K13 | BL quality agent corrections, by issue (one row per issue) | IM-Lakehouse (41) | 49709* | 10-28: Spec Mismatch 27.05%, Buyer Description 5.93%, One Word Title 1.62%, No Issue 65.79% |
| K14 | Absurd quantity detected              | IM-Lakehouse (41)         | 49710* | 10-28: 1,389 of 166,933, 0.83%          |

\* Owned by a colleague. Since 2026-10-30 they hold the repo SQL (`sql/k08…k14`, checked against Redash's
query hash) with no parameters, and their cached results are for the previous day (K08 for 10-29: 22,400 of
168,230, 13.32%). The 10-28 numbers above come from running the repo files.

Every percentage is over **all BLs approved on that date** (134k–175k/day; 166,933 on 10-28), except:
K06 is India-only (`fk_gl_country_iso = 'IN'`, ~97% of approvals); K07 covers auto-approved BLs only
(`fk_employee_id = -14` on the BL's latest row, ~80%); K09 and K10 are fill rates, so their base is the BLs
whose MCAT asks the question (quantity: ~82% of approvals; buyer specs: ~98%).

### Definitions and data notes

- **Approved BL** = `imbl.eto_ofr_with_expired` row with `eto_ofr_approv_date_orig` on the date
  (`partition_date` there is the post date; approvals land within ~3 days, so queries look back 7 days).
- **K01/K04** count distinct MCATs in `eto_ofr_mapping` + `eto_ofr_mapping_expired` (`partition_date` = mapping date).
  `fk_glcat_mcat_id` on the BL itself is almost never empty, so it is not a useful signal.
- **K03** `kpi_count` = photo BLs approved on the date, `kpi_pct` = share of all approved BLs that day.
  `photo_bls_generated` = photo BLs posted on the date across `eto_ofr_with_expired` ∪ `eto_ofr_temp_del`
  (rejected/deleted). Photo = `eto_ofr_attachment_is_exist = 1`. `imbl.eto_ofr_attachment` is *not* used
  because it drops rows once a BL expires (~3–4 days), which would break history and date compare.
- **K06** spec/qty come from `imbl.eto_attribute` (BL ISQ answers): quantity = `fk_im_spec_master_desc = 'Quantity'`;
  spec = any other answered attribute except system-derived priorities 1000 (order value) and 1100 (req. type).
  `eto_ofr_qty` / `eto_ofr_spec` columns are empty on all BLs and are ignored. India only: `fk_gl_country_iso = 'IN'`
  on `eto_ofr_with_expired`. Foreign BLs are ~3% of approvals but ~18% of blank BLs (515 of 2,837 on 10-26).
  Validated 2026-10-29: 2,373 of 161,995 Indian BLs for 10-28.
- **K07** covers auto-approved BLs only: the BL's latest row (after the dedupe) has `fk_employee_id = -14`.
  BLs approved by the other system approvers (-30, -76) or by a LEAP agent are left out. It ranks each BL's
  viewed products in `imbl.iil_buyer_products_viewed` (`partition_date` = approval date) by
  `activity_type_id`, lowest first, and puts the BL in the category of its rank-1 product: 1–4 Same MCAT,
  5–8 Same PMCAT, 9–12 Same subcat, 13–16 Same group, >16 Others, split into 5a no MCAT (AWM, see Segments),
  5b no image (no `/` path in the BL's image columns and the flag at 0; the placeholders `'1'` /
  `'[object Object]'` don't count as images), 5c rest. BLs with no viewed product are 6. No product viewed, so
  the categories add up to the auto-approved base. 2026-10-28, of 133,369 auto-approved: Same MCAT 97,527
  (73.1%), PMCAT 2,573, subcat 4,022, group 840, 5a 1,150, 5b 1,697, 5c 185, no product viewed 25,375 (19.0%).
- **K05** is heuristic and runs on live Postgres because buyer names are masked in the Lakehouse.
  It filters on `date(eto_ofr_approv_date_orig)` to hit the expression index (~3.5 s; ~19 s on a cold
  cache). Validated 2026-10-29: 20 of 166,933 for 10-28.
  Name hits are high-precision; ~30% of company hits are buyers whose company is named after a vehicle/brand
  model (e.g. "Tata Indica Ev2"). `glusr_usr` is not joined (≈90 s/day → statement timeout).
- **K08–K14** are the team's queries (`Processed_data - api_query.csv`), reshaped to this contract and to the
  previous day. Each one now uses the standard approved-BL CTE (7-day post-date lookback + dedupe). The originals
  filtered with `partition_date <= end_date` (scans all history) or `partition_date >= start_date` (misses BLs
  posted before the start date).
- **K08** PMCAT = the BL's MCAT is generic (`mesh.glcat_mcat.glcat_mcat_is_generic = 1`).
- **K09** quantity filled = a `Quantity` answer in `imbl.eto_attribute` modified on the approval day. Base = BLs
  whose MCAT has an active Quantity ISQ (`mesh.im_cat_specification` status 1, buyer/seller spec 0/1, MCAT not
  deleted). Answers filled before the approval day are missed, but that is only ~50 BLs/day.
- **K10** buyer-filled spec = a non-quantity answer modified on the approval day with a buyer source
  (`eto_attribute_source` 1–199, 601–650 or 204/206/208/209/210/214/220/221/250/991/999/1001). Base = BLs whose
  MCAT is live (`seo_on_flag = 1`, not deleted) and has an active non-quantity buyer/seller ISQ.
- **K11** counts by **approval** date: approved on the date more than 24 hours after `eto_ofr_postdate_orig`.
  The original counted by post date, which can't work for a previous-day report: yesterday's posts that will
  take more than 24 hours are not approved yet at 9 AM.
- **K12** = approved BLs with no row in `imbl.eto_lead_supplier_mapping`. Suppliers are mapped on the approval
  day (`partition_date` = mapping date = approval date for every BL checked on 10-28), so it scans yesterday and
  today only; the original scanned the whole mapping table.
- **K13** joins `leapml.leap_blml_agent_audit_log` (`partition_date` = `DATE(offer_approve_date)` = approval date)
  and returns one row per issue: 0 No Issue (no audit row), 1 Spec Mismatch, 2 One Word Title, 3 Absurd Quantity,
  4 PII Issue, 5 Selling Intent, 6 Buyer Description, 7 Other. A BL with several issues is in each of their rows.
  2026-10-28: No Issue 109,821, Spec Mismatch 45,160, Buyer Description 9,907, One Word Title 2,697, Other 1,876,
  Absurd Quantity 1,389, Selling Intent 13, PII 3.
- **K14** = BLs with `issue_flag_id = 3` in the audit log; the same BLs as K13's Absurd Quantity row.

## Segments

**AWM leads** (Approved Without MCAT): approved BLs whose source product (`eto_ofr_modrefid` =
`mesh.pc_item.pc_item_display_id`) has no prime MCAT mapping. This is the same check as leap-go-workers
(`models.FetchMcatName` → `prodMcatId <= 0`): no `mesh.pc_item_to_glcat_mcat` row with `item_mapping_isprime = -1`
whose MCAT exists in `mesh.glcat_mcat` and has a `mesh.glcat_cat_to_mcat` row. Validated 2026-10-20 → 26:
3.0–3.5k/day, 1.76–2.20% of approved. It replaced the earlier `pc_item_status_approval = 50` rule: on 10-26 the
two agree on 2,825 BLs, and the worker rule adds 245 more (products without a valid prime mapping that are not
status 50). `pc_item` and the mapping tables are current snapshots, so older dates can drift. BLs whose product
is no longer in `pc_item` (893 on 10-26) can't be checked and are not counted, nor are BLs with no `eto_ofr_modrefid`.

- `sql/awm_leads.sql`: lead-level list for spot checks (BL title / MCAT, module, product name, seller, mapping rows)
- `sql/awm_leads_daily.sql`: daily count + % of approved, same output contract as the KPIs

## Adding / removing a KPI

1. Add `sql/kNN_<slug>.sql` that honours the output contract and returns the previous day (no params).
2. Save it in Redash on its data source with a refresh schedule, and copy its CSV results URL (query API key).
3. Add an entry to `kpi_registry.json` (`sheet_tab`, `redash_data_source_id`, `redash_query_id`, `direction`,
   `enabled`, plus `extra_columns` if it returns several rows per day).
4. Add a row to `KPIS` in `n8n/build_workflow.py`, rerun it, and re-import the workflow in n8n.
5. Add the KPI's display entry to `dashboard/config.js` and run `python3 dashboard/build_registry.py`.

Removing = set `"enabled": false` in the registry (keeps the tab's history) and drop its row from `KPIS`.

## n8n workflow

`n8n/kpi_daily_redash_to_sheet.workflow.json` (built by `n8n/build_workflow.py`; both contain the Redash query
API keys, so keep them out of git). It writes to the Google Sheet "Daily_Audits_BL_Quality"
(`1AAPtHbdl4Z1UjBYoznOxSYxaw6u-hStMWrKDgpb0eH0`), one tab per KPI (`sheet_tab` in the registry). Import it in n8n
and pick a Google Sheets OAuth2 credential in the 3 sheet-setup HTTP nodes and the 14 Write nodes.

- Runs daily at 9:00 AM IST (plus a manual trigger).
- **Sheet setup**, once per run: reads the sheet's tab names (Google Sheets API), adds any missing KPI tab and
  (re)writes row 1 of every KPI tab: the contract columns, the KPI's extra columns, `row_key`, `synced_at`.
  Other tabs in the sheet are never touched. Then it fans out to one branch per KPI.
- Each branch reads its query's **cached** result: `GET /api/queries/{id}/results.csv?api_key=…`. The Redash
  refresh schedule on each query keeps that cache current; the flow sends no parameters.
- **Check** accepts only rows whose `report_date` is yesterday (Redash writes dates as `dd/MM/yy` in CSVs, e.g.
  `28/10/26`), adds `row_key` (date, or date|category) and `synced_at`, and stores numbers as numbers.
- Retries: the fetch tries 5 times. If it still fails, returns no rows or an older day, the branch asks Redash
  to re-run the query (`POST …/results`, `max_age: 0`), waits 2 minutes and fetches again, up to 3 rounds. After
  that the branch stops at its Check node and the other KPIs carry on.
- **Write** upserts on `row_key` into the KPI's tab, so re-running a day overwrites it instead of duplicating.
- n8n runs the branches one after another, not at the same time, so a branch that is retrying delays the
  branches after it (it doesn't stop them).

## Dashboard

`dashboard/` is the frontend: plain HTML, CSS and JavaScript, with no build step, no backend and no keys.
Every number comes from the Google Sheet. Each KPI reads only its own tab (`sheet_tab` in the registry).

```sh
python3 dashboard/build_registry.py          # after changing kpi_registry.json or any sql/ file
python3 -m http.server 8000 -d dashboard     # then open http://localhost:8000
```

- **Reading the sheet:** the browser reads each tab from Google's sheet query endpoint (gviz). That needs the
  sheet to stay shared as "anyone with the link".
- **Bad tabs:** a tab counts only if its first row has the KPI columns and its rows carry that KPI's id.
  This matters because gviz returns the first sheet when a tab name doesn't exist. A missing tab, or a day
  with no row, is reported on that KPI's card; it never borrows another tab's numbers.
- **Views:** the default is the latest day vs the same weekday a week earlier. "Compare dates" picks any two
  days that have data. K07 and K13 show a category table; click a row to plot it.
- **The (i) dialog:** shows each KPI's SQL from `sql/`, its data source, sheet tab and Redash query.
- **Files:** `config.js` (sheet id, tab groups, KPI display text), `registry.js` (generated), `sheet.js`
  (reading and validating tabs), `app.js` (views), `styles.css`.
