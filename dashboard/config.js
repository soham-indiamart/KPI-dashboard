// Dashboard settings. Which tab each KPI reads comes from kpi_registry.json (sheet_tab) via registry.js;
// this file only holds the sheet id and how each KPI is shown.
window.DASHBOARD_CONFIG = {
  sheetId: '1AAPtHbdl4Z1UjBYoznOxSYxaw6u-hStMWrKDgpb0eH0',
  sheetName: 'Daily_Audits_BL_Quality',

  // the "Approved BLs" headline uses base_count from the first of these tabs that has the date
  approvedFrom: ['K11', 'K08', 'K12', 'K14', 'K03'],
  // charts show at least this many days, ending on the later of the two compared dates
  minWindowDays: 8,

  dataSources: {
    41: 'IM-Lakehouse (BigQuery) · Redash data source 41',
    16: 'pg-imblr-prod-live (PostgreSQL) · Redash data source 16'
  },

  groups: [
    { id: 'overview', label: 'Overview' },
    { id: 'mcat', label: 'MCAT', title: 'MCAT mapping', intro: 'How approved BLs map to MCATs. Lower is better for all three.' },
    { id: 'photos', label: 'Photos', title: 'BLs with photos', intro: 'Photo BLs generated and approved each day, and their share of all approved BLs. Higher is better.' },
    { id: 'content', label: 'Title & content', title: 'Title and content quality', intro: 'Thin or misleading BLs that still got approved. Lower is better for all three.' },
    { id: 'specs', label: 'Specs & quantity', title: 'Specs and quantity', intro: 'Quantity and buyer-spec fill rates (higher is better), each over BLs whose MCAT asks the question, and absurd quantities the agent flagged (lower is better).' },
    { id: 'approval', label: 'Approval & suppliers', title: 'Approval time and suppliers', intro: 'Slow approvals and approved BLs that reached no supplier. Lower is better for both.' },
    { id: 'viewed', label: 'Viewed products', title: 'Auto-approved BLs by viewed product', intro: 'Which product the buyer viewed closest to the BL, for auto-approved BLs. Pick a category to plot it.' },
    { id: 'agent', label: 'Agent corrections', title: 'BL quality agent corrections', intro: 'What the BL quality agent corrected on approved BLs. Pick an issue to plot it.' }
  ],

  // group = dashboard tab; baseWord names the % base on cards ("of N <baseWord> BLs")
  kpis: {
    K01: { group: 'mcat', name: 'BLs with no MCAT mapped',
      def: 'Approved BLs that have no MCAT in the BL-to-MCAT mapping (eto_ofr_mapping + eto_ofr_mapping_expired).' },
    K02: { group: 'content', name: 'One-word BLs approved',
      def: 'Approved BLs whose title is a single word, e.g. "Crackers" or "Vermicompost".' },
    K03: { group: 'photos', name: 'BLs with photos approved', countHead: 'Photo BLs approved',
      def: 'Approved BLs that carry a photo. Generated = BLs with a photo posted that day, including ones later rejected or deleted.',
      generated: { column: 'photo_bls_generated', head: 'Photo BLs generated', note: 'Posted that day, incl. rejected' } },
    K04: { group: 'mcat', name: 'BLs with 2+ MCATs mapped',
      def: 'Approved BLs mapped to two or more distinct MCATs.' },
    K05: { group: 'content', name: 'Buyer / company name in title',
      def: 'Approved BLs whose title contains the buyer\'s name or company name. Heuristic match on the live BL database.' },
    K06: { group: 'content', name: 'Blank BLs (India)', baseWord: 'Indian approved', baseHead: 'Indian approved BLs',
      def: 'Indian approved BLs (fk_gl_country_iso = IN) with no spec, no description, no quantity and no photo. The % is over Indian approved BLs.' },
    K07: { group: 'viewed', name: 'Auto-approved BLs by viewed product', baseWord: 'auto-approved', baseHead: 'Auto-approved BLs',
      def: 'Auto-approved BLs (latest row fk_employee_id = −14), grouped by the best-ranked product the buyer viewed: same MCAT, PMCAT, subcat or group, others (split into no MCAT / no image / rest), or no product viewed. Categories add up to the base.',
      categories: {
        head: 'Category', headline: '1. Same MCAT', headWord: 'Same MCAT',
        order: ['1. Same MCAT', '2. Same PMCAT', '3. Same subcat', '4. Same group', '5a. Others: no MCAT (AWM)',
          '5b. Others: no image', '5c. Others: rest', '6. No product viewed'],
        note: 'Every auto-approved BL is in exactly one category, so they add up to the base.'
      } },
    K08: { group: 'mcat', name: 'BLs mapped to a PMCAT',
      def: 'Approved BLs whose MCAT is a PMCAT, i.e. a generic MCAT (glcat_mcat_is_generic = 1).' },
    K09: { group: 'specs', name: 'Qty fill rate', countHead: 'Qty filled BLs', baseWord: 'qty-asking', baseHead: 'BLs in qty MCATs',
      def: 'BLs with a Quantity answer saved on the approval day, over approved BLs whose MCAT asks for Quantity (an active Quantity ISQ).' },
    K10: { group: 'specs', name: 'Buyer filled spec', countHead: 'Buyer spec BLs', baseWord: 'spec-asking', baseHead: 'BLs in spec MCATs',
      def: 'BLs with at least one non-quantity spec filled by the buyer, over approved BLs whose MCAT has active buyer specs and is live.' },
    K11: { group: 'approval', name: 'Approved more than 24 h after posting',
      def: 'BLs approved on the date more than 24 hours after they were posted. Counted by approval date, so the previous day is complete at 9 AM.' },
    K12: { group: 'approval', name: 'BLs with 0 suppliers selected',
      def: 'Approved BLs with no row in eto_lead_supplier_mapping: the BL reached no supplier.' },
    K13: { group: 'agent', name: 'BL quality agent corrections',
      def: 'Approved BLs the BL quality agent corrected (leap_blml_agent_audit_log), by issue. A BL with several issues counts in each, so the issues add up to more than "Any correction".',
      categories: {
        head: 'Issue', headWord: 'With a correction',
        // "Any correction" is not a sheet row: base_count - the "0. No Issue" row
        anyCorrection: { label: 'Any correction', noIssue: '0. No Issue' },
        order: ['1. Spec Mismatch', '6. Buyer Description', '2. One Word Title', '7. Other', '3. Absurd Quantity',
          '5. Selling Intent', '4. PII Issue', '0. No Issue'],
        note: 'Any correction = approved BLs − No Issue. A BL with several issues counts in each, so the issues add up to more than Any correction.'
      } },
    K14: { group: 'specs', name: 'Absurd quantity detected',
      def: 'Approved BLs the BL quality agent flagged for an absurd quantity (issue_flag_id = 3); the same BLs as K13\'s Absurd Quantity row.' }
  }
};
