// LEAP BL quality dashboard. Every number comes from the KPI's own tab in the Google Sheet
// (registry sheet_tab), read by sheet.js. Nothing is hard-coded here.
(function () {
  'use strict';

  const CFG = window.DASHBOARD_CONFIG;
  const Sheet = window.KpiSheet;
  const DIR = { lower_is_better: 'lower', higher_is_better: 'higher', neutral: 'neutral' };
  const ANY = '__any__'; // K13's "Any correction" row, derived from base - "0. No Issue"
  const BLUE = '#2A78D6', BLUE_STRONG = '#1C5CAB', SLATE = '#475467', LIGHT = '#86B6EF', ORANGE = '#EB6834';

  const KPIS = (window.KPI_REGISTRY || []).filter(r => r.enabled !== false).map(r => {
    const meta = CFG.kpis[r.id] || {};
    return Object.assign({}, r, meta, {
      name: meta.name || r.name,
      dir: DIR[r.direction] || 'neutral',
      src: CFG.dataSources[r.redash_data_source_id] || 'Redash data source ' + r.redash_data_source_id
    });
  });
  const GROUP_IDS = CFG.groups.map(g => g.id);

  const data = {}; // kpi id -> { status: 'loading' | 'ok' | 'error', error, byDate, lastSynced }
  const state = {
    group: groupFromHash(), mode: 'week', cur: null, ref: null,
    calOpen: null, calMonth: null, info: null, sel: {}, copied: false, loading: false
  };

  // ---------- formatting ----------
  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  }
  function fmtInt(n) { return n == null ? '—' : Math.round(n).toLocaleString('en-US'); }
  function fmtPct(p) { return p == null ? '—' : (p < 0.1 ? p.toFixed(3) : p.toFixed(2)) + '%'; }
  function fmtSigned(n) { return n === 0 ? '±0' : (n > 0 ? '+' : '−') + fmtInt(Math.abs(n)); }
  function trimNum(v) { return String(parseFloat(v.toPrecision(3))); }
  function fmtAxisPct(v) { return trimNum(v) + '%'; }
  function fmtAxisCount(v) { return v >= 1000 ? trimNum(v / 1000) + 'K' : trimNum(v); }

  // ---------- dates (ISO yyyy-mm-dd strings, calendar days) ----------
  const WD = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
  const MON = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  const MONTH_LONG = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
  function toDate(iso) { const p = iso.split('-').map(Number); return new Date(Date.UTC(p[0], p[1] - 1, p[2])); }
  function toIso(dt) { return dt.toISOString().slice(0, 10); }
  function addDays(iso, n) { return toIso(new Date(toDate(iso).getTime() + n * 86400000)); }
  function daysBetween(a, b) { return Math.round((toDate(b) - toDate(a)) / 86400000); }
  function dayLabel(iso) { const d = toDate(iso); return WD[d.getUTCDay()] + ' ' + d.getUTCDate() + ' ' + MON[d.getUTCMonth()]; }
  function tickLabel(iso) { const d = toDate(iso); return WD[d.getUTCDay()] + ' ' + d.getUTCDate(); }
  function rangeLabel(a, b) {
    const da = toDate(a), db = toDate(b);
    return da.getUTCMonth() === db.getUTCMonth()
      ? da.getUTCDate() + '–' + db.getUTCDate() + ' ' + MON[db.getUTCMonth()]
      : da.getUTCDate() + ' ' + MON[da.getUTCMonth()] + ' – ' + db.getUTCDate() + ' ' + MON[db.getUTCMonth()];
  }

  // every report_date found in any KPI tab, oldest first
  function allDates() {
    const set = new Set();
    for (const id in data) if (data[id].status === 'ok') data[id].byDate.forEach((_, iso) => set.add(iso));
    return Array.from(set).sort();
  }

  // the two dates being compared, and the days the charts cover
  function picked() {
    const dates = allDates();
    if (!dates.length) return null;
    const latest = dates[dates.length - 1];
    let cur, ref;
    if (state.mode === 'week') {
      cur = latest; ref = addDays(latest, -7);
    } else {
      cur = dates.indexOf(state.cur) >= 0 ? state.cur : latest;
      ref = dates.indexOf(state.ref) >= 0 ? state.ref : (dates[dates.length - 2] || latest);
    }
    const end = cur > ref ? cur : ref;
    let start = cur < ref ? cur : ref;
    const minStart = addDays(end, -(CFG.minWindowDays - 1));
    if (minStart < start) start = minStart;
    if (daysBetween(start, end) > 119) start = addDays(end, -119);
    const win = [];
    for (let s = start; s <= end; s = addDays(s, 1)) win.push(s);
    return { dates, latest, cur, ref, win };
  }

  // ---------- reading values ----------
  function catLabel(k, key) {
    return key === ANY ? k.categories.anyCorrection.label : String(key).replace(/^\w+\.\s*/, '');
  }
  function headKey(k) { return k.categories.anyCorrection ? ANY : k.categories.headline; }

  // the categories a K07 / K13 tab holds, in the configured order, then any new ones
  function catKeys(k) {
    const seen = new Set();
    const r = data[k.id];
    if (r && r.status === 'ok') r.byDate.forEach(day => day.cats.forEach((_, key) => seen.add(key)));
    const order = k.categories.order || [];
    const keys = order.filter(key => seen.has(key)).concat(Array.from(seen).filter(key => order.indexOf(key) < 0).sort());
    return k.categories.anyCorrection ? [ANY].concat(keys) : keys;
  }

  // { count, base } of a KPI on a date; view = a category key or 'generated' (K03), null = headline
  function point(k, iso, view) {
    const r = data[k.id];
    if (!r || r.status !== 'ok') return null;
    const day = r.byDate.get(iso);
    if (!day) return null;
    if (k.categories) {
      const key = view == null ? headKey(k) : view;
      if (key === ANY) {
        const none = day.cats.get(k.categories.anyCorrection.noIssue);
        return { count: none == null || day.base == null ? null : day.base - none, base: day.base };
      }
      // the query only returns categories that have BLs, so a missing one is 0 that day
      return { count: day.cats.has(key) ? day.cats.get(key) : 0, base: day.base };
    }
    if (view === 'generated') return { count: day.extra[k.generated.column], base: day.base };
    return { count: day.count, base: day.base };
  }
  function pctOf(p) {
    if (!p || p.count == null) return null;
    if (p.base) return p.count / p.base * 100;
    return null;
  }
  function baseLabelOf(k) {
    const r = data[k.id];
    if (!r || r.status !== 'ok') return '';
    let latest = null;
    r.byDate.forEach((day, iso) => { if (!latest || iso > latest.iso) latest = { iso, label: day.baseLabel }; });
    return latest ? latest.label : '';
  }
  function approvedOn(iso) {
    for (const id of CFG.approvedFrom) {
      const k = KPIS.find(x => x.id === id);
      const p = k && point(k, iso);
      if (p && p.base != null) return p.base;
    }
    return null;
  }

  function delta(k, cur, ref) {
    if (cur == null || ref == null) return { cls: 'flat', text: 'No comparison' };
    const d = cur - ref;
    const tone = Math.abs(d) < 0.0005 ? 'flat' : k.dir === 'neutral' ? 'neutral' : (k.dir === 'lower' ? d < 0 : d > 0) ? 'good' : 'bad';
    const word = tone === 'good' ? 'Better' : tone === 'bad' ? 'Worse' : tone === 'neutral' ? (d > 0 ? 'Up' : 'Down') : 'No change';
    return { cls: tone === 'neutral' ? '' : tone, text: (tone === 'flat' ? '→' : d > 0 ? '↑' : '↓') + ' ' + word };
  }

  // ---------- small pieces ----------
  const ICON_INFO = '<svg aria-hidden="true" width="20" height="20" viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"><circle cx="10" cy="10" r="8.2"></circle><path d="M10 9v5"></path><circle cx="10" cy="6.2" r="0.6" fill="currentColor"></circle></svg>';
  function infoBtn(k) {
    return '<button class="info-btn" data-act="info" data-arg="' + esc(k.id) + '" aria-label="How ' + esc(k.id) + ' is calculated: show the query" title="Show query">' + ICON_INFO + '</button>';
  }
  function pill(d, extra) { return '<span class="pill ' + d.cls + (extra ? ' ' + extra : '') + '">' + esc(d.text) + '</span>'; }

  // polylines for a series with gaps: one polyline per run of days that have a value
  function runs(values, xy) {
    const out = [];
    let cur = [];
    values.forEach((v, i) => {
      if (v == null) { if (cur.length) out.push(cur); cur = []; return; }
      cur.push(xy(v, i));
    });
    if (cur.length) out.push(cur);
    return out.map(run => run.map(p => p[0].toFixed(2) + ',' + p[1].toFixed(2)).join(' '));
  }
  function yRange(values) {
    const vs = values.filter(v => v != null);
    if (!vs.length) return null;
    const min = Math.min.apply(null, vs), max = Math.max.apply(null, vs);
    const span = (max - min) || Math.abs(max) * 0.1 || 1;
    return { lo: Math.max(0, min - span * 0.6), hi: max + span * 0.6 };
  }
  function yPct(v, r) { return 100 - (v - r.lo) / (r.hi - r.lo) * 100; }

  function sparkline(values, win, p) {
    const W = 232, H = 40, P = 6, n = values.length;
    const r = yRange(values);
    if (!r) return '<svg class="spark" aria-hidden="true"></svg>';
    const xy = (v, i) => [P + (n > 1 ? i * (W - 2 * P) / (n - 1) : (W - 2 * P) / 2), P + yPct(v, r) / 100 * (H - 2 * P)];
    let s = '<svg class="spark" viewBox="0 0 ' + W + ' ' + H + '" preserveAspectRatio="none" aria-hidden="true">';
    runs(values, xy).forEach(pts => { s += '<polyline points="' + pts + '" fill="none" stroke="' + LIGHT + '" stroke-width="2" stroke-linejoin="round" stroke-linecap="round" vector-effect="non-scaling-stroke"></polyline>'; });
    const dot = (iso, fill, stroke) => {
      const i = win.indexOf(iso);
      if (i < 0 || values[i] == null) return '';
      const c = xy(values[i], i);
      return '<circle cx="' + c[0].toFixed(1) + '" cy="' + c[1].toFixed(1) + '" r="4.5" fill="' + fill + '" stroke="' + stroke + '" stroke-width="2" vector-effect="non-scaling-stroke"></circle>';
    };
    s += dot(p.ref, '#FFFFFF', SLATE) + dot(p.cur, BLUE, '#FFFFFF');
    return s + '</svg>';
  }

  // ---------- header, tabs, date controls ----------
  function header(p) {
    const synced = KPIS.map(k => data[k.id] && data[k.id].lastSynced).filter(Boolean).sort().pop();
    const tabs = CFG.groups.map(g => {
      const n = KPIS.filter(k => k.group === g.id).length;
      return '<button class="tab" role="tab" aria-selected="' + (g.id === state.group) + '" data-act="tab" data-arg="' + g.id + '">' +
        esc(g.label) + (g.id === 'overview' ? '' : '<span class="chip">' + n + '</span>') + '</button>';
    }).join('');
    return '<header class="top"><div class="wrap"><div class="top-row">' +
      '<div><div class="eyebrow">LEAP · Buy-lead quality</div><h1>Daily KPI tracker</h1></div>' +
      '<div class="meta">' +
      (p ? '<span>Data through <strong>' + esc(dayLabel(p.latest)) + ' ' + p.latest.slice(0, 4) + '</strong></span>' : '') +
      (synced ? '<span>Last sync ' + esc(synced) + ' IST</span>' : '') +
      '<a href="https://docs.google.com/spreadsheets/d/' + esc(CFG.sheetId) + '/edit" target="_blank" rel="noopener">' +
      '<svg aria-hidden="true" width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5"><rect x="2.5" y="1.5" width="11" height="13" rx="1.5"></rect><path d="M2.5 6h11M2.5 10h11M7 6v8.5"></path></svg>' +
      esc(CFG.sheetName) + '</a></div></div>' +
      '<nav class="tabs" role="tablist" aria-label="KPI groups">' + tabs + '</nav></div></header>';
  }

  function calendar(p, which) {
    const selected = which === 'cur' ? p.cur : p.ref, other = which === 'cur' ? p.ref : p.cur;
    const month = state.calMonth || selected.slice(0, 7);
    const y = Number(month.slice(0, 4)), m = Number(month.slice(5, 7));
    const first = new Date(Date.UTC(y, m - 1, 1));
    const daysIn = new Date(Date.UTC(y, m, 0)).getUTCDate();
    const has = new Set(p.dates);
    const firstIso = month + '-01', lastIso = month + '-' + String(daysIn).padStart(2, '0');
    const canPrev = p.dates[0] < firstIso, canNext = p.dates[p.dates.length - 1] > lastIso;
    let cells = ['Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa', 'Su'].map(w => '<span class="cal-wd" aria-hidden="true">' + w + '</span>').join('');
    for (let i = 0; i < (first.getUTCDay() + 6) % 7; i++) cells += '<span></span>';
    for (let d = 1; d <= daysIn; d++) {
      const iso = month + '-' + String(d).padStart(2, '0');
      const ok = has.has(iso);
      const look = iso === selected ? (which === 'cur' ? 'is-cur' : 'is-ref') : iso === other ? (which === 'cur' ? 'is-ref' : 'is-cur') : '';
      cells += '<button class="cal-day ' + (ok ? look : '') + '" data-act="cal-pick" data-arg="' + iso + '"' + (ok ? '' : ' disabled') +
        ' aria-pressed="' + (iso === selected) + '" aria-label="' + esc(ok ? dayLabel(iso) : dayLabel(iso) + ': no data') + '">' + d + '</button>';
    }
    return '<div class="cal" role="dialog" aria-label="' + (which === 'cur' ? 'Pick the date' : 'Pick the date to compare with') + '">' +
      '<div class="cal-head"><button class="cal-nav" data-act="cal-month" data-arg="-1" aria-label="Previous month"' + (canPrev ? '' : ' disabled') + '>‹</button>' +
      '<strong>' + MONTH_LONG[m - 1] + ' ' + y + '</strong>' +
      '<button class="cal-nav" data-act="cal-month" data-arg="1" aria-label="Next month"' + (canNext ? '' : ' disabled') + '>›</button></div>' +
      '<div class="cal-title">' + (which === 'cur' ? 'Date' : 'Compare with') + '</div>' +
      '<div class="cal-grid">' + cells + '</div></div>';
  }

  function controls(p) {
    const isWeek = state.mode === 'week';
    let left = '<div class="seg" role="group" aria-label="Date view">' +
      '<button data-act="mode" data-arg="week" aria-pressed="' + isWeek + '">Same day last week</button>' +
      '<button data-act="mode" data-arg="compare" aria-pressed="' + !isWeek + '">Compare dates</button></div>';
    if (p && isWeek) {
      left += '<span class="week-note"><svg aria-hidden="true" width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5"><rect x="2" y="3" width="12" height="11" rx="1.5"></rect><path d="M2 6.5h12M5.5 1.5v3M10.5 1.5v3"></path></svg>' +
        '<strong>' + esc(dayLabel(p.cur)) + '</strong> vs <strong>' + esc(dayLabel(p.ref)) + '</strong> · same day last week</span>';
    } else if (p) {
      const btn = (which, iso, dot) => '<div class="picker"><button class="btn" data-act="cal-toggle" data-arg="' + which + '" aria-haspopup="dialog" aria-expanded="' + (state.calOpen === which) + '"' +
        ' aria-label="' + (which === 'cur' ? 'Date: ' : 'Compared with: ') + esc(dayLabel(iso)) + '. Pick another date">' +
        '<span class="' + dot + '" aria-hidden="true"></span>' + esc(dayLabel(iso)) +
        '<svg aria-hidden="true" width="12" height="12" viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M3 4.5l3 3 3-3"></path></svg></button>' +
        (state.calOpen === which ? calendar(p, which) : '') + '</div>';
      left += '<div class="pickers">' + btn('cur', p.cur, 'dot-cur') + '<span>vs</span>' + btn('ref', p.ref, 'dot-ref') +
        '<button class="btn square" data-act="swap" aria-label="Swap the two dates" title="Swap dates"><svg aria-hidden="true" width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M2.5 5.5h10l-2.5-2.5M13.5 10.5h-10l2.5 2.5"></path></svg></button></div>';
    }
    const right = '<button class="btn" data-act="refresh"' + (state.loading ? ' disabled' : '') + '>' +
      '<svg aria-hidden="true" width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"><path d="M13.5 8a5.5 5.5 0 1 1-1.6-3.9M13.5 2.5v3h-3"></path></svg>' +
      (state.loading ? 'Loading…' : 'Reload sheet') + '</button>';
    return '<div class="wrap controls"><div class="controls-left">' + left + '</div>' + right + '</div>' +
      (state.calOpen ? '<button class="cal-backdrop" data-act="cal-close" aria-label="Close calendar"></button>' : '');
  }

  // ---------- problems with tabs ----------
  function problems() {
    const bad = KPIS.filter(k => data[k.id] && data[k.id].status === 'error');
    if (!bad.length) return '';
    return '<div class="banner warn" role="status"><strong>' + bad.length + ' of ' + KPIS.length + ' KPI tabs could not be read.</strong> Their cards show why.' +
      '<ul>' + bad.map(k => '<li>' + esc(k.id) + ' (' + esc(k.sheet_tab) + '): ' + esc(data[k.id].error) + '</li>').join('') + '</ul></div>';
  }

  // ---------- overview ----------
  function hero(p) {
    const vals = p.win.map(approvedOn);
    const cur = approvedOn(p.cur), ref = approvedOn(p.ref);
    const known = vals.filter(v => v != null);
    const total = known.reduce((s, v) => s + v, 0);
    const diff = cur != null && ref != null ? cur - ref : null;
    const HW = 280, HH = 56, n = vals.length;
    const r = yRange(vals);
    const xy = (v, i) => [(i + 0.5) * HW / n, 5 + yPct(v, r) / 100 * (HH - 10)];
    let svg = '';
    if (r) {
      runs(vals, xy).forEach(pts => { svg += '<polyline points="' + pts + '" fill="none" stroke="' + BLUE + '" stroke-width="2" stroke-linejoin="round" stroke-linecap="round"></polyline>'; });
      const dot = (iso, fill, stroke, rad) => {
        const i = p.win.indexOf(iso);
        if (i < 0 || vals[i] == null) return '';
        const c = xy(vals[i], i);
        return '<circle cx="' + c[0].toFixed(1) + '" cy="' + c[1].toFixed(1) + '" r="' + rad + '" fill="' + fill + '" stroke="' + stroke + '" stroke-width="2"></circle>';
      };
      svg += dot(p.ref, '#FFFFFF', SLATE, 5) + dot(p.cur, BLUE_STRONG, '#FFFFFF', 5.5);
    }
    const step = Math.ceil(n / 10);
    const ticks = p.win.map((iso, i) => {
      const mark = iso === p.cur ? 'tick-cur' : iso === p.ref ? 'tick-ref' : '';
      const show = mark || (n - 1 - i) % step === 0;
      return '<span class="' + mark + '" style="width:' + (HW / n).toFixed(2) + 'px">' + (show ? toDate(iso).getUTCDate() : '') + '</span>';
    }).join('');
    return '<section class="card-surface hero" aria-label="Approved BLs">' +
      '<div><div class="hero-label">Approved BLs · ' + esc(dayLabel(p.cur)) + '</div>' +
      '<div class="hero-line"><span class="hero-value num">' + fmtInt(cur) + '</span>' +
      (diff != null ? '<span class="pill hero-pill">' + fmtSigned(diff) + ' (' + (diff >= 0 ? '+' : '−') + Math.abs(diff / ref * 100).toFixed(1) + '%)</span>' : '') +
      '<span class="small">vs ' + esc(dayLabel(p.ref)) + ' (' + fmtInt(ref) + ')</span></div>' +
      '<div class="small">The base for every % on this dashboard, except K06 (Indian BLs), K07 (auto-approved BLs), K09 and K10 (BLs whose MCAT asks for quantity / specs).</div></div>' +
      '<div class="hero-side">' +
      '<div class="kv"><span>Total, ' + esc(rangeLabel(p.win[0], p.win[n - 1])) + '</span><span class="num">' + fmtInt(known.length ? total : null) + '</span></div>' +
      '<div class="kv"><span>Daily average</span><span class="num">' + fmtInt(known.length ? total / known.length : null) + '</span></div>' +
      '<div role="img" aria-label="Approved BLs per day, ' + esc(rangeLabel(p.win[0], p.win[n - 1])) + ': ' + esc(vals.map(fmtInt).join(', ')) + '">' +
      '<svg aria-hidden="true" width="' + HW + '" height="' + HH + '" viewBox="0 0 ' + HW + ' ' + HH + '" style="display:block;overflow:visible">' + svg + '</svg>' +
      '<div class="hero-ticks">' + ticks + '</div></div></div></section>';
  }

  function baseText(k, base) {
    return (k.categories ? k.categories.headWord + ', of ' : 'of ') + fmtInt(base) + ' ' + (k.baseWord || 'approved') + ' BLs';
  }

  function card(k, p) {
    const r = data[k.id] || { status: 'loading' };
    const foot = '<div class="kcard-foot"><span>' + esc(k.id) + '</span>' +
      (k.group ? '<button class="ghost" data-act="tab" data-arg="' + esc(k.group) + '">Details →</button>' : '') + '</div>';
    const head = '<div class="kcard-head"><h3>' + esc(k.name) + '</h3>' + infoBtn(k) + '</div>';
    if (r.status !== 'ok') {
      const msg = r.status === 'loading' ? 'Loading tab <strong>' + esc(k.sheet_tab) + '</strong>…' : esc(r.error);
      return '<article class="card-surface kcard">' + head + '<div class="nodata">' + msg + '</div>' + foot + '</article>';
    }
    const pc = point(k, p.cur), pr = point(k, p.ref);
    const cur = pctOf(pc), ref = pctOf(pr);
    const vals = p.win.map(iso => pctOf(point(k, iso)));
    let body;
    if (!pc) {
      const last = Array.from(r.byDate.keys()).sort().pop();
      body = '<div class="nodata">No row for <strong>' + esc(dayLabel(p.cur)) + '</strong> in tab ' + esc(k.sheet_tab) + '.' +
        (last ? ' Latest row: ' + esc(dayLabel(last)) + '.' : ' The tab has no rows yet.') + '</div>';
    } else {
      body = '<div><div class="kcard-value"><span class="big num">' + fmtInt(pc.count) + '</span><span class="pct num">' + fmtPct(cur) + '</span></div>' +
        '<span class="base">' + esc(baseText(k, pc.base)) + '</span></div>' +
        '<div class="kcard-delta">' + pill(delta(k, cur, ref)) + '<span>' + (pr ? 'vs ' + fmtPct(ref) + ' on ' + esc(dayLabel(p.ref)) : 'no row for ' + esc(dayLabel(p.ref))) + '</span></div>';
    }
    return '<article class="card-surface kcard">' + head + body + sparkline(vals, p.win, p) + foot + '</article>';
  }

  // ---------- detail panels ----------
  function lineChart(o) {
    // o: { win, cur, ref, series: [{ color, values }], axis, multi, caps, tips(i) -> [[label, value]] }
    const n = o.win.length;
    const r = yRange(o.series.reduce((all, s) => all.concat(s.values), []));
    if (!r) return '<div class="nodata">No rows in this date range.</div>';
    const xy = (v, i) => [(i + 0.5) / n * 100, yPct(v, r)];
    let lines = '';
    o.series.slice().reverse().forEach(s => runs(s.values, xy).forEach(pts => {
      lines += '<polyline points="' + pts + '" fill="none" stroke="' + s.color + '" stroke-width="2" vector-effect="non-scaling-stroke" stroke-linejoin="round" stroke-linecap="round"></polyline>';
    }));
    const step = Math.ceil(n / 12);
    let cols = '', ticks = '';
    o.win.forEach((iso, i) => {
      const m = iso === o.cur ? 'cur' : iso === o.ref ? 'ref' : '';
      const band = m === 'cur' ? (o.multi ? 'rgba(42,120,214,0.10)' : 'rgba(42,120,214,0.05)') : m === 'ref' ? (o.multi ? 'rgba(71,84,103,0.08)' : 'rgba(71,84,103,0.04)') : 'transparent';
      let dots = '';
      o.series.forEach(s => {
        const v = s.values[i];
        if (v == null) return;
        let size = m ? 10 : 7, fill = s.color, ring = '#FFFFFF';
        if (!o.multi && m) { size = 12; fill = m === 'cur' ? BLUE_STRONG : '#FFFFFF'; ring = m === 'cur' ? '#FFFFFF' : SLATE; }
        dots += '<span class="pt" style="top:' + yPct(v, r).toFixed(2) + '%;width:' + size + 'px;height:' + size + 'px;margin:-' + size / 2 + 'px 0 0 -' + size / 2 + 'px;background:' + fill + ';border-color:' + ring + '"></span>';
      });
      const capV = o.caps ? o.caps[i] : null;
      const cap = !o.multi && m && capV != null ? '<span class="cap num" style="top:' + yPct(o.series[0].values[i], r).toFixed(2) + '%">' + esc(o.capFmt(capV)) + '</span>' : '';
      const tipPos = i === 0 ? 'left:0' : i === n - 1 ? 'right:0' : 'left:50%;transform:translateX(-50%)';
      const tip = '<div class="tip" style="' + tipPos + '"><b>' + esc(dayLabel(iso)) + '</b>' +
        o.tips(i).map(t => '<div><span>' + esc(t[0]) + '</span><span class="num">' + esc(t[1]) + '</span></div>').join('') + '</div>';
      cols += '<div class="grp"><div class="hoverband" style="background:' + band + '"></div>' + dots + cap + tip + '</div>';
      const show = m || (n - 1 - i) % step === 0;
      ticks += '<span class="' + (m ? 'tick-' + m : '') + '">' + (show ? esc(tickLabel(iso)) : '') + '</span>';
    });
    const grid = 'grid-template-columns:repeat(' + n + ',minmax(0,1fr))';
    return '<div class="plot-row"><div class="yaxis num" aria-hidden="true"><span>' + o.axis(r.hi) + '</span><span>' + o.axis((r.hi + r.lo) / 2) + '</span><span>' + o.axis(r.lo) + '</span></div>' +
      '<div class="plot"><div class="mid" aria-hidden="true"></div><svg viewBox="0 0 100 100" preserveAspectRatio="none" aria-hidden="true">' + lines + '</svg>' +
      '<div class="cols" style="' + grid + '">' + cols + '</div></div></div>' +
      '<div class="xaxis" aria-hidden="true"><div class="pad"></div><div class="ticks" style="' + grid + '">' + ticks + '</div></div>';
  }

  function panel(k, p) {
    const r = data[k.id] || { status: 'loading' };
    const head = '<div class="panel-head"><div class="ids"><span class="tag">' + esc(k.id) + '</span><h3>' + esc(k.name) + '</h3><p class="def">' + esc(k.def || '') + '</p></div>' + infoBtn(k) + '</div>';
    if (r.status !== 'ok') {
      return '<section class="card-surface panel">' + head + '<div class="nodata">' + (r.status === 'loading' ? 'Loading tab ' + esc(k.sheet_tab) + '…' : esc(r.error)) + '</div></section>';
    }
    const countHead = k.countHead || (k.categories && k.categories.headWord) || 'BLs';
    const baseHead = k.baseHead || 'Approved BLs';
    const pctHead = '% of ' + (k.baseWord || 'approved');
    const pc = point(k, p.cur), pr = point(k, p.ref);
    const cur = pctOf(pc), ref = pctOf(pr);
    const d = delta(k, cur, ref);
    const winPts = p.win.map(iso => point(k, iso));
    const known = winPts.filter(x => x && x.count != null && x.base);
    const avgPct = known.length ? known.reduce((s, x) => s + x.count / x.base * 100, 0) / known.length : null;
    const avgCount = known.length ? known.reduce((s, x) => s + x.count, 0) / known.length : null;
    const range = rangeLabel(p.win[0], p.win[p.win.length - 1]);
    const stat = (label, value, sub, pillHtml) => '<div class="stat"><span class="label">' + esc(label) + '</span><span class="value num">' + value + '</span>' + (pillHtml || '') + (sub ? '<span class="sub">' + esc(sub) + '</span>' : '') + '</div>';
    let stats = stat(countHead + ' · ' + dayLabel(p.cur), fmtInt(pc && pc.count), dayLabel(p.ref) + ': ' + fmtInt(pr && pr.count) + (pc && pr && pc.count != null && pr.count != null ? ' (' + fmtSigned(pc.count - pr.count) + ')' : '')) +
      stat(pctHead + ' BLs', fmtPct(cur), dayLabel(p.ref) + ': ' + fmtPct(ref), pill(d)) +
      stat(baseHead + ' · ' + dayLabel(p.cur), fmtInt(pc && pc.base), 'Base for the %');
    if (k.generated) {
      const g = point(k, p.cur, 'generated');
      stats += stat(k.generated.head, fmtInt(g && g.count), k.generated.note);
    }
    stats += stat('Daily average, ' + range, fmtPct(avgPct), avgCount == null ? '' : fmtInt(avgCount) + ' BLs a day');

    // chart: K03 plots generated vs approved counts; K07 / K13 the picked category; others their daily %
    let chartTitle, legend, chartHtml;
    const marks = '<span><span class="' + (k.generated ? 'band-cur' : 'dot-cur') + '"></span>' + esc(dayLabel(p.cur)) + '</span>' +
      (p.ref !== p.cur ? '<span><span class="' + (k.generated ? 'band-ref' : 'dot-ref') + '"></span>' + esc(dayLabel(p.ref)) + '</span>' : '');
    if (k.generated) {
      const gen = p.win.map(iso => { const x = point(k, iso, 'generated'); return x ? x.count : null; });
      const app = winPts.map(x => (x ? x.count : null));
      chartTitle = 'Photo BLs per day: generated vs approved';
      legend = '<span><span class="swatch" style="background:' + ORANGE + '"></span>Generated</span><span><span class="swatch" style="background:' + BLUE + '"></span>Approved</span>' + marks;
      chartHtml = lineChart({ win: p.win, cur: p.cur, ref: p.ref, multi: true, axis: fmtAxisCount,
        series: [{ color: ORANGE, values: gen }, { color: BLUE, values: app }],
        tips: i => [['Generated', fmtInt(gen[i])], ['Approved', fmtInt(app[i])], ['% of approved BLs', fmtPct(pctOf(winPts[i]))]] });
    } else {
      const keys = k.categories ? catKeys(k) : null;
      const view = keys ? (keys.indexOf(state.sel[k.id]) >= 0 ? state.sel[k.id] : headKey(k)) : null;
      const pts = keys ? p.win.map(iso => point(k, iso, view)) : winPts;
      const vals = pts.map(pctOf);
      const viewHead = keys ? catLabel(k, view) : countHead;
      chartTitle = pctHead + ' BLs, daily' + (keys ? ' · ' + viewHead : '');
      legend = marks;
      chartHtml = lineChart({ win: p.win, cur: p.cur, ref: p.ref, multi: false, axis: fmtAxisPct,
        series: [{ color: BLUE, values: vals }], caps: vals, capFmt: fmtPct,
        tips: i => [[viewHead, fmtInt(pts[i] && pts[i].count)], [pctHead, fmtPct(vals[i])], [baseHead, fmtInt(pts[i] && pts[i].base)]] });
    }

    let side;
    if (k.categories) {
      const keys = catKeys(k);
      const view = keys.indexOf(state.sel[k.id]) >= 0 ? state.sel[k.id] : headKey(k);
      const cols = 'grid-template-columns:minmax(176px,1.6fr) repeat(3,minmax(84px,1fr)) minmax(104px,1fr)';
      const rows = keys.map(key => {
        const a = point(k, p.cur, key), b = point(k, p.ref, key);
        const ca = pctOf(a), cb = pctOf(b);
        return '<button class="tr cat-row" style="' + cols + '" data-act="cat" data-arg="' + esc(k.id + '|' + key) + '" aria-pressed="' + (key === view) + '">' +
          '<span class="cat-label" style="font-weight:' + (key === headKey(k) ? 600 : 500) + '">' + esc(catLabel(k, key)) + '</span>' +
          '<span class="num">' + fmtInt(a && a.count) + '</span><span class="num" style="font-weight:600">' + fmtPct(ca) + '</span>' +
          '<span class="num" style="color:#475467">' + fmtPct(cb) + '</span><span>' + pill(delta(k, ca, cb)) + '</span></button>';
      }).join('');
      side = '<div class="chart-head"><h4>By ' + esc(k.categories.head.toLowerCase()) + ' · ' + esc(dayLabel(p.cur)) + '</h4><span class="small" style="font-size:12px">Pick a row to plot it</span></div>' +
        '<div class="tbl-wrap"><div class="tbl" role="group" aria-label="' + esc(k.name) + ' by ' + esc(k.categories.head.toLowerCase()) + '" style="min-width:560px">' +
        '<div class="tr th" style="' + cols + '"><span>' + esc(k.categories.head) + '</span><span>BLs · ' + esc(tickLabel(p.cur)) + '</span><span>% · ' + esc(tickLabel(p.cur)) + '</span><span>% · ' + esc(tickLabel(p.ref)) + '</span><span>Change</span></div>' +
        (rows || '<div class="nodata" style="padding:12px">No rows yet.</div>') + '</div></div>' +
        (k.categories.note ? '<p class="table-note">' + esc(k.categories.note) + '</p>' : '');
    } else {
      const nCols = k.generated ? 4 : 3;
      const cols = 'grid-template-columns:minmax(136px,1.3fr) repeat(' + nCols + ',minmax(96px,1fr))';
      const rows = p.win.slice().reverse().map(iso => {
        const x = point(k, iso);
        const m = iso === p.cur ? 'dot-cur' : iso === p.ref ? 'dot-ref' : '';
        const g = k.generated ? point(k, iso, 'generated') : null;
        return '<div class="tr' + (m ? ' marked' : '') + '" role="row" style="' + cols + '"><span role="cell">' + esc(dayLabel(iso)) + (m ? '<span class="' + m + '" aria-hidden="true"></span>' : '') + '</span>' +
          '<span role="cell" class="num" style="font-weight:500">' + fmtInt(x && x.count) + '</span>' +
          '<span role="cell" class="num" style="color:#475467">' + fmtInt(x && x.base) + '</span>' +
          '<span role="cell" class="num" style="font-weight:600">' + fmtPct(pctOf(x)) + '</span>' +
          (k.generated ? '<span role="cell" class="num" style="font-weight:500">' + fmtInt(g && g.count) + '</span>' : '') + '</div>';
      }).join('');
      side = '<h4>Daily values</h4><div class="tbl-wrap"><div class="tbl" role="table" aria-label="' + esc(k.name) + ', daily values" style="min-width:' + (136 + nCols * 100) + 'px">' +
        '<div class="tr th" role="row" style="' + cols + '"><span role="columnheader">Date</span><span role="columnheader">' + esc(countHead) + '</span><span role="columnheader">' + esc(baseHead) + '</span><span role="columnheader">' + esc(pctHead) + '</span>' +
        (k.generated ? '<span role="columnheader">' + esc(k.generated.head) + '</span>' : '') + '</div>' + rows + '</div></div>';
    }

    return '<section class="card-surface panel">' + head + '<div class="stats">' + stats + '</div>' +
      '<div class="panel-body"><div class="chart-col"><div class="chart-head"><h4>' + esc(chartTitle) + '</h4><div class="legend">' + legend + '</div></div>' + chartHtml + '</div>' +
      '<div class="table-col">' + side + '</div></div></section>';
  }

  // ---------- SQL dialog ----------
  function infoDialog() {
    const k = KPIS.find(x => x.id === state.info);
    if (!k) return '';
    const dirText = k.dir === 'lower' ? 'Lower is better' : k.dir === 'higher' ? 'Higher is better' : 'Context only (no better direction)';
    const meta = [
      ['Data source', k.src], ['Sheet tab', k.sheet_tab], ['Redash query', k.redash_query_id ? '#' + k.redash_query_id : '—'],
      ['Parameters', 'None · always the previous day (IST date − 1)'], ['Base for the %', baseLabelOf(k) || 'Approved BLs'], ['Direction', dirText]
    ];
    const copyLabel = state.copied === true ? 'Copied' : state.copied === 'fail' ? 'Copy blocked: select the text' : 'Copy SQL';
    return '<div class="overlay" data-act="info-close"><div class="dialog" role="dialog" aria-modal="true" aria-labelledby="sql-title">' +
      '<div class="dialog-head"><div><span class="tag">' + esc(k.id) + ' · How it is calculated</span><h2 id="sql-title">' + esc(k.name) + '</h2><p>' + esc(k.def || '') + '</p></div>' +
      '<button class="close-btn" data-act="info-close" aria-label="Close"><svg aria-hidden="true" width="18" height="18" viewBox="0 0 18 18" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"><path d="M4 4l10 10M14 4L4 14"></path></svg></button></div>' +
      '<div class="dialog-meta">' + meta.map(m => '<div><span>' + esc(m[0]) + '</span><span>' + esc(m[1]) + '</span></div>').join('') + '</div>' +
      '<div class="dialog-sql"><div class="dialog-sql-head"><span>SQL · <code>' + esc(k.sql_file) + '</code></span>' +
      '<button class="btn" data-act="copy">' + esc(copyLabel) + '</button></div><pre class="sql">' + esc(k.sql || '') + '</pre></div></div></div>';
  }

  // ---------- page ----------
  function body(p) {
    const banner = problems();
    if (!p) {
      if (state.loading) return '<div class="nodata">Reading ' + KPIS.length + ' KPI tabs from ' + esc(CFG.sheetName) + '…</div>';
      return banner + '<div class="banner err">No KPI rows found in ' + esc(CFG.sheetName) + '. The KPI tabs fill when the n8n workflow runs (9 AM IST).</div>';
    }
    if (state.group === 'overview') {
      return banner + hero(p) + '<div class="cards">' + KPIS.map(k => card(k, p)).join('') + '</div>';
    }
    const g = CFG.groups.find(x => x.id === state.group);
    return banner + '<div class="group-head"><h2>' + esc(g.title || g.label) + '</h2><p>' + esc(g.intro || '') + '</p></div>' +
      KPIS.filter(k => k.group === state.group).map(k => panel(k, p)).join('');
  }

  function render() {
    const active = document.activeElement;
    const focusKey = active && active.dataset && active.dataset.act ? active.dataset.act + '|' + (active.dataset.arg || '') : null;
    const p = picked();
    document.getElementById('app').innerHTML = header(p) + controls(p) + '<main class="wrap">' + body(p) + '</main>' +
      '<footer class="wrap"><span>Every % is over all BLs approved that day, except K06, K07, K09 and K10, which name their base. Green / red follow each KPI\'s better direction; grey = no better direction.</span>' +
      '<span>Source: ' + esc(CFG.sheetName) + ' (Google Sheet), one tab per KPI, filled daily by n8n from Redash.</span></footer>' + infoDialog();
    if (focusKey) {
      const parts = focusKey.split('|');
      const el = Array.from(document.querySelectorAll('[data-act="' + parts[0] + '"]')).find(x => (x.dataset.arg || '') === parts.slice(1).join('|'));
      if (el) el.focus();
    }
  }

  // ---------- loading ----------
  async function loadAll() {
    state.loading = true;
    KPIS.forEach(k => { if (!data[k.id] || data[k.id].status !== 'ok') data[k.id] = { status: 'loading' }; });
    render();
    await Promise.all(KPIS.map(k => Sheet.loadKpi(CFG.sheetId, k).then(
      res => { data[k.id] = { status: 'ok', byDate: res.byDate, lastSynced: res.lastSynced }; },
      err => { data[k.id] = { status: 'error', error: err instanceof Sheet.SheetError ? err.message : 'Could not read this tab (' + err.message + ').' }; }
    ).then(render)));
    state.loading = false;
    render();
  }

  // ---------- events ----------
  function groupFromHash() {
    const h = location.hash.replace('#', '');
    return GROUP_IDS.indexOf(h) >= 0 ? h : 'overview';
  }
  window.addEventListener('hashchange', () => { state.group = groupFromHash(); render(); });

  let copyTimer = null;
  function flashCopied(v) {
    clearTimeout(copyTimer);
    state.copied = v; render();
    copyTimer = setTimeout(() => { state.copied = false; render(); }, 1800);
  }

  document.addEventListener('click', e => {
    const el = e.target.closest('[data-act]');
    if (!el) return;
    const act = el.dataset.act, arg = el.dataset.arg;
    // clicks inside the dialog shouldn't reach the overlay's close handler
    if (act === 'info-close' && el.classList.contains('overlay') && e.target !== el) return;
    const p = picked();
    switch (act) {
      case 'tab':
        state.group = arg;
        history.replaceState(null, '', arg === 'overview' ? location.pathname + location.search : '#' + arg);
        window.scrollTo(0, 0);
        break;
      case 'mode':
        state.mode = arg; state.calOpen = null;
        if (arg === 'compare' && p && !state.cur) { state.cur = p.cur; state.ref = p.dates.indexOf(p.ref) >= 0 ? p.ref : null; }
        break;
      case 'cal-toggle':
        state.calOpen = state.calOpen === arg ? null : arg;
        state.calMonth = p ? (arg === 'cur' ? p.cur : p.ref).slice(0, 7) : null;
        break;
      case 'cal-close': state.calOpen = null; break;
      case 'cal-month': {
        const y = Number(state.calMonth.slice(0, 4)), m = Number(state.calMonth.slice(5, 7)) - 1 + Number(arg);
        const d = new Date(Date.UTC(y, m, 1));
        state.calMonth = d.toISOString().slice(0, 7);
        break;
      }
      case 'cal-pick':
        if (state.calOpen === 'cur') state.cur = arg; else state.ref = arg;
        if (p && state.calOpen === 'cur' && !state.ref) state.ref = p.ref;
        if (p && state.calOpen === 'ref' && !state.cur) state.cur = p.cur;
        state.calOpen = null;
        break;
      case 'swap': if (p) { state.cur = p.ref; state.ref = p.cur; } break;
      case 'info': state.info = arg; state.copied = false; break;
      case 'info-close': state.info = null; break;
      case 'copy': {
        const k = KPIS.find(x => x.id === state.info);
        const text = k ? k.sql || '' : '';
        if (navigator.clipboard && navigator.clipboard.writeText) {
          navigator.clipboard.writeText(text).then(() => flashCopied(true), () => flashCopied('fail'));
        } else flashCopied('fail');
        return;
      }
      case 'cat': {
        const i = arg.indexOf('|');
        state.sel[arg.slice(0, i)] = arg.slice(i + 1);
        break;
      }
      case 'refresh': if (!state.loading) loadAll(); return;
      default: return;
    }
    render();
  });

  document.addEventListener('keydown', e => {
    if (e.key !== 'Escape') return;
    if (state.info) { state.info = null; render(); } else if (state.calOpen) { state.calOpen = null; render(); }
  });

  loadAll();
})();
