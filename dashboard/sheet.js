// Reads one KPI's sheet tab through the Sheets query endpoint (gviz). The sheet is shared by link, so the
// browser can read it with no login or API key.
//
// Trap: gviz answers a tab name that doesn't exist with the FIRST sheet of the file instead of an error.
// So a tab only counts if its header row has the KPI output contract and its rows carry this KPI's id.
window.KpiSheet = (function () {
  'use strict';

  const CONTRACT = ['report_date', 'kpi_id', 'kpi_name', 'kpi_count', 'base_count', 'kpi_pct', 'base_label'];

  class SheetError extends Error {}

  async function fetchTable(sheetId, tab) {
    const url = 'https://docs.google.com/spreadsheets/d/' + encodeURIComponent(sheetId) +
      '/gviz/tq?tqx=out:json&headers=1&sheet=' + encodeURIComponent(tab);
    let res;
    try {
      res = await fetch(url, { cache: 'no-store' });
    } catch (err) {
      // opened as a file, the page has no origin and the browser blocks every request to the sheet
      if (location.protocol === 'file:') {
        throw new SheetError('The page was opened as a file, so the browser blocks the sheet. Serve the dashboard ' +
          'folder over http (e.g. python3 -m http.server 8000) and open http://localhost:8000.');
      }
      // a sheet that isn't shared by link answers with a sign-in page, which the browser blocks
      throw new SheetError('Could not reach the sheet. Check that it is still shared with "anyone with the link".');
    }
    if (!res.ok) throw new SheetError('The sheet answered HTTP ' + res.status + '.');
    const text = await res.text();
    const start = text.indexOf('{'), end = text.lastIndexOf('}');
    if (start < 0 || end < start) throw new SheetError('The sheet did not return data. Is it shared with "anyone with the link"?');
    const json = JSON.parse(text.slice(start, end + 1));
    if (json.status === 'error') {
      throw new SheetError((json.errors || []).map(e => e.detailed_message || e.message).join('; ') || 'The sheet returned an error.');
    }
    return json.table;
  }

  function cellValue(c) {
    if (!c) return null;
    return c.v != null ? c.v : (c.f != null ? c.f : null);
  }

  function pad(n) { return String(n).padStart(2, '0'); }

  // dates arrive as gviz "Date(2026,9,26)" (month from 0) when the cell is a date, else as text
  function toIsoDate(v) {
    if (v == null || v === '') return null;
    const s = String(v).trim();
    let m = s.match(/^Date\((\d+),(\d+),(\d+)/);
    if (m) return m[1] + '-' + pad(Number(m[2]) + 1) + '-' + pad(m[3]);
    m = s.match(/^(\d{4})-(\d{2})-(\d{2})/);
    if (m) return m[1] + '-' + m[2] + '-' + m[3];
    m = s.match(/^(\d{1,2})\/(\d{1,2})\/(\d{2}|\d{4})$/); // Redash CSV style dd/MM/yy
    if (m) return (m[3].length === 2 ? '20' + m[3] : m[3]) + '-' + pad(m[2]) + '-' + pad(m[1]);
    return null;
  }

  function toTimestamp(v) {
    if (v == null || v === '') return null;
    const s = String(v).trim();
    const m = s.match(/^Date\((\d+),(\d+),(\d+)(?:,(\d+),(\d+)(?:,(\d+))?)?/);
    if (m) return m[1] + '-' + pad(Number(m[2]) + 1) + '-' + pad(m[3]) + ' ' + pad(m[4] || 0) + ':' + pad(m[5] || 0);
    return s.slice(0, 16);
  }

  function toNumber(v) {
    if (v == null || v === '') return null;
    if (typeof v === 'number') return v;
    const n = Number(String(v).replace(/,/g, '').trim());
    return Number.isFinite(n) ? n : null;
  }

  // -> { byDate: Map(iso -> day), lastSynced, rowCount }
  //    day = { count, base, pct, baseLabel, extra: {column: number}, cats: Map(category -> count) }
  async function loadKpi(sheetId, kpi) {
    const table = await fetchTable(sheetId, kpi.sheet_tab);
    const labels = table.cols.map(c => String(c.label || '').trim());
    const missing = CONTRACT.filter(c => labels.indexOf(c) < 0);
    if (missing.length) {
      throw new SheetError('Tab "' + kpi.sheet_tab + '" is missing from the sheet, or its first row is not the KPI header. n8n creates it on its first run.');
    }
    const col = name => labels.indexOf(name);
    const catCol = col('category');
    const extraCols = (kpi.extra_columns || []).filter(c => c !== 'category' && col(c) >= 0);

    const byDate = new Map();
    let lastSynced = null, rowCount = 0, otherId = null;
    for (const r of table.rows) {
      const get = name => (col(name) < 0 ? null : cellValue(r.c[col(name)]));
      const id = String(get('kpi_id') || '').trim();
      if (!id) continue;
      if (id !== kpi.id) { otherId = otherId || id; continue; }
      const iso = toIsoDate(get('report_date'));
      if (!iso) continue;
      rowCount++;
      const day = byDate.get(iso) || { count: null, base: null, pct: null, baseLabel: '', extra: {}, cats: new Map() };
      day.base = toNumber(get('base_count'));
      day.baseLabel = String(get('base_label') || '');
      if (catCol >= 0) {
        const cat = String(get('category') || '').trim();
        if (cat) day.cats.set(cat, toNumber(get('kpi_count')));
      } else {
        day.count = toNumber(get('kpi_count'));
        day.pct = toNumber(get('kpi_pct'));
        for (const c of extraCols) day.extra[c] = toNumber(get(c));
      }
      byDate.set(iso, day);
      const synced = toTimestamp(get('synced_at'));
      if (synced && (!lastSynced || synced > lastSynced)) lastSynced = synced;
    }
    if (!rowCount && otherId) {
      throw new SheetError('Tab "' + kpi.sheet_tab + '" holds rows for ' + otherId + ', not ' + kpi.id + '.');
    }
    return { byDate, lastSynced, rowCount };
  }

  return { loadKpi, SheetError };
})();
