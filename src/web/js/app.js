/*
 * app.js — หน้าจอ wms-realtime-report
 *  - อ่านค่าตั้งค่าจาก config.json และข้อมูลจากไฟล์ JSON (config.dataFile) ทุก refreshMinutes นาที
 *  - ตัดสินสถานะการเชื่อมต่อจากข้อมูลในไฟล์ + อายุข้อมูล (calc.js -> connState)
 *  - ไม่โหลดอะไรจากอินเทอร์เน็ต
 */
(function () {
  'use strict';
  var C = window.WmsCalc;
  var $ = function (id) { return document.getElementById(id); };
  var pad = C.pad;

  /* ===== ค่าตั้งค่าเริ่มต้น (ใช้เมื่ออ่าน config.json ไม่ได้) — เกณฑ์ทุกตัวว่าง = ไม่ใส่สี ===== */
  var DEFAULTS = {
    dataFile: 'data/latest.json',
    refreshMinutes: 5,
    staleGraceMinutes: 2,
    targetEndTime: '',
    remainingTonsYellow: null, remainingTonsRed: null,
    remainingTrucksYellow: null, remainingTrucksRed: null,
    forecastYellowWithinMinutes: null,
    sampleClock: ''
  };

  var state = {
    cfg: normalizeConfig({}), cfgError: '',
    data: null, pageFetchError: '', lastPageFetch: 0,
    view: null, timer: null
  };

  function normalizeConfig(raw) {
    var c = {};
    Object.keys(DEFAULTS).forEach(function (k) { c[k] = raw[k] !== undefined ? raw[k] : DEFAULTS[k]; });
    var r = C.optNum(c.refreshMinutes);
    c.refreshMinutes = r === null ? 5 : Math.max(1, r);          // brief ข้อ 9.5: ไม่ถี่กว่า 1 นาที
    var g = C.optNum(c.staleGraceMinutes);
    c.staleGraceMinutes = g === null ? 2 : g;
    c.targetMin = C.parseHHMM(c.targetEndTime);
    if (typeof c.dataFile !== 'string' || !c.dataFile) c.dataFile = DEFAULTS.dataFile;
    return c;
  }

  /* ===== รูปแบบตัวเลข / เวลา ===== */
  var nf1 = new Intl.NumberFormat('en-US', { minimumFractionDigits: 1, maximumFractionDigits: 1 });
  var nf0 = new Intl.NumberFormat('en-US', { maximumFractionDigits: 0 });
  var nfMax1 = new Intl.NumberFormat('en-US', { maximumFractionDigits: 1 });
  var t1 = function (kg) { return nf1.format(kg / 1000); };
  var hm = function (min) { return pad(Math.floor(min / 60) % 24) + ':' + pad(min % 60); };
  var hmMs = function (ms) { return hm(C.minutesOfDay(ms)); };
  var dur = function (h) { var m = Math.round(h * 60); return Math.floor(m / 60) + ' ชม. ' + (m % 60) + ' นาที'; };
  var etaText = function (min) { return min >= 1440 ? 'หลัง 24:00' : hm(min); };
  var DAYS = ['อาทิตย์', 'จันทร์', 'อังคาร', 'พุธ', 'พฤหัสบดี', 'ศุกร์', 'เสาร์'];
  var MONTHS = ['ม.ค.', 'ก.พ.', 'มี.ค.', 'เม.ย.', 'พ.ค.', 'มิ.ย.', 'ก.ค.', 'ส.ค.', 'ก.ย.', 'ต.ค.', 'พ.ย.', 'ธ.ค.'];
  function thaiDate(ymd) {
    var m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(ymd || '');
    if (!m) return '—';
    var d = new Date(+m[1], +m[2] - 1, +m[3]);
    return DAYS[d.getDay()] + ' ' + d.getDate() + ' ' + MONTHS[d.getMonth()] + ' ' + (d.getFullYear() + 543);
  }

  /* ===== ไอคอน (SVG วาดเอง) ===== */
  var IC = {
    check: '<svg class="ic" viewBox="0 0 24 24" aria-hidden="true"><path d="M5 12.5l4.5 4.5L19 7.5" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"/></svg>',
    alert: '<svg class="ic" viewBox="0 0 24 24" aria-hidden="true"><path d="M12 3L2 21h20L12 3z" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linejoin="round"/><path d="M12 10v5" stroke="currentColor" stroke-width="2.4" stroke-linecap="round"/><circle cx="12" cy="18" r="1.3" fill="currentColor"/></svg>',
    dash: '<svg class="ic" viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="9" fill="none" stroke="currentColor" stroke-width="2.2"/><path d="M8 12h8" stroke="currentColor" stroke-width="2.4" stroke-linecap="round"/></svg>',
    ok: '<svg class="ic" viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="7" fill="currentColor"/></svg>',
    retry: '<svg class="ic" viewBox="0 0 24 24" aria-hidden="true"><path d="M19 12a7 7 0 1 1-2.05-4.95" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round"/><path d="M19 4v4h-4" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"/></svg>',
    off: '<svg class="ic" viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="9.5" fill="none" stroke="currentColor" stroke-width="2.4"/><path d="M8 8l8 8M16 8l-8 8" stroke="currentColor" stroke-width="2.6" stroke-linecap="round"/></svg>',
    lock: '<svg class="ic" viewBox="0 0 24 24" aria-hidden="true"><rect x="4.5" y="10.5" width="15" height="10" rx="2" fill="none" stroke="currentColor" stroke-width="2.4"/><path d="M8 10.5V7.5a4 4 0 0 1 8 0v3" fill="none" stroke="currentColor" stroke-width="2.4"/></svg>'
  };
  var REM_CHIP = { none: [IC.dash, 'ยังไม่ได้ตั้งเกณฑ์'], good: [IC.check, 'ต่ำกว่าเกณฑ์'], warn: [IC.alert, 'ถึงเกณฑ์เหลือง'], crit: [IC.alert, 'เกินเกณฑ์แดง'] };
  var FC_CHIP = { none: [IC.dash, 'ยังไม่เทียบเป้า'], good: [IC.check, 'ทันเวลาเลิกงาน'], warn: [IC.alert, 'ใกล้เวลาเลิกงาน'], crit: [IC.alert, 'เกินเวลาเลิกงาน'] };
  function chipHtml(def) { return def[0] + '<span>' + def[1] + '</span>'; }

  /* ===== ธีม (จำค่าใน localStorage ; ค่าเริ่มต้นมืด) ===== */
  var THEME_KEY = 'wms-realtime-report.theme';
  function loadTheme() { try { return localStorage.getItem(THEME_KEY) === 'light' ? 'light' : 'dark'; } catch (e) { return 'dark'; } }
  function setTheme(th, save) {
    document.body.setAttribute('data-theme', th);
    $('themeBtn').textContent = th === 'light' ? 'ธีมมืด' : 'ธีมสว่าง';
    $('themeBtn').title = 'สลับเป็น' + (th === 'light' ? 'ธีมมืด' : 'ธีมสว่าง');
    if (save) { try { localStorage.setItem(THEME_KEY, th); } catch (e) { /* เบราว์เซอร์ไม่ให้เก็บ — ใช้ค่าในหน้านี้ต่อไป */ } }
    requestAnimationFrame(drawCharts);
  }

  /* ===== โหมดดูตัวอย่างสถานะ (ปิดเป็นค่าเริ่มต้น เปิดด้วย #preview=retry|stale|login|parse) ===== */
  var PREVIEW_NAMES = { ok: 'ปกติ', retry: 'ดึงพลาด 1 รอบ', stale: 'ข้อมูลเก่า', login: 'ล็อกอินไม่ผ่าน', parse: 'อ่านหน้า WMS ไม่ได้' };
  function previewState() {
    var m = /(?:^|[#&])preview=(\w+)/.exec(location.hash);
    return m && PREVIEW_NAMES[m[1]] ? m[1] : null;
  }

  /* ===== เวลา "ตอนนี้" — ใช้ sampleClock เฉพาะเมื่อไฟล์เป็นข้อมูลตัวอย่าง ข้อมูลจริงใช้นาฬิกาเครื่องเสมอ ===== */
  function nowMs() {
    if (state.data && state.data.source === 'sample') {
      var t = C.parseTime(state.cfg.sampleClock);
      if (t !== null) return t;
    }
    return Date.now();
  }
  function usingSampleClock() {
    return !!(state.data && state.data.source === 'sample' && C.parseTime(state.cfg.sampleClock) !== null);
  }

  /* ===== โหลดไฟล์ ===== */
  function getJson(url) {
    return fetch(url + (url.indexOf('?') < 0 ? '?' : '&') + 't=' + Date.now(), { cache: 'no-store' })
      .then(function (res) { if (!res.ok) throw new Error('HTTP ' + res.status); return res.text(); })
      .then(function (txt) { return JSON.parse(txt.replace(/^﻿/, '')); });
  }

  function load() {
    clearTimeout(state.timer);
    state.lastPageFetch = Date.now();
    return getJson('config.json')
      .then(function (raw) { state.cfg = normalizeConfig(raw || {}); state.cfgError = ''; },
        function (err) { state.cfg = normalizeConfig({}); state.cfgError = 'อ่าน config.json ไม่ได้ (' + err.message + ') ใช้ค่าเริ่มต้น'; })
      .then(function () { return getJson(state.cfg.dataFile); })
      .then(function (d) { state.data = d; state.pageFetchError = ''; },
        function (err) { state.pageFetchError = 'อ่านไฟล์ข้อมูล ' + state.cfg.dataFile + ' ไม่ได้ (' + err.message + ')'; })
      .then(function () {
        render();
        state.timer = setTimeout(load, state.cfg.refreshMinutes * 60000);
      });
  }

  /* ทุก 30 วินาที: ประเมินอายุข้อมูลใหม่ ถ้าข้อมูลเริ่มเก่า ลองอ่านไฟล์ซ้ำก่อนรอบปกติ (ไม่ถี่กว่าทุก 60 วินาที) */
  setInterval(function () {
    if (!state.view) return;
    var v = computeView();
    if (v.conn !== 'ok' && Date.now() - state.lastPageFetch > 60000) { load(); return; }
    renderStatus(v);
  }, 30000);

  /* ===== คำนวณมุมมองทั้งหมดจากข้อมูล + ค่าตั้งค่า ===== */
  function computeView() {
    var cfg = state.cfg, d = state.data, now = nowMs();
    var v = { cfg: cfg, data: d, now: now, usable: false };
    if (!d) { v.conn = state.pageFetchError ? 'nofile' : 'loading'; return withPreview(v); }
    var cs = C.connState(d, now, cfg);
    v.conn = cs.state; v.ageMin = cs.ageMin; v.connError = cs.error || '';
    v.usable = d.status !== 'parse_error' && C.validateData(d).ok;
    if (v.usable) {
      v.rows = d.rows;
      var s = C.summarize(d.rows);
      v.T = s.totals; v.lastIdx = s.lastIdx;
      v.dataMs = C.parseTime(d.lastSuccessAt);
      v.dataMin = C.minutesOfDay(v.dataMs);
      v.curIdx = C.currentRowIndex(v.dataMin);
      v.lastShown = Math.max(v.lastIdx, v.curIdx);
      v.fc = C.forecast(d.rows, v.T, v.dataMin);
      v.wLevel = C.levelByThreshold(v.T.remainingKg / 1000, cfg.remainingTonsYellow, cfg.remainingTonsRed);
      v.tLevel = C.levelByThreshold(v.T.truckRemaining, cfg.remainingTrucksYellow, cfg.remainingTrucksRed);
      v.fcLevel = v.fc.ok ? C.forecastLevel(v.fc.etaMin, cfg.targetMin, cfg.forecastYellowWithinMinutes) : 'none';
    }
    return withPreview(v);
  }
  function withPreview(v) {
    var p = previewState();
    v.preview = p;
    if (p && (v.usable || p === 'parse')) {
      v.conn = p;
      if (p === 'retry') v.ageMin = state.cfg.refreshMinutes * 2;
      if (p === 'stale') v.ageMin = state.cfg.refreshMinutes * 5;
    }
    return v;
  }

  /* ===== วาดทั้งหน้า ===== */
  function render() {
    var v = computeView();
    state.view = v;
    if (v.usable) { renderKpis(v); renderForecast(v); renderTable(v); }
    else clearNumbers();
    renderStatus(v);
    requestAnimationFrame(drawCharts);
  }

  function clearNumbers() {
    ['wTotal', 'wDone', 'wRem', 'wPct', 'tCi', 'tOb', 'tDone', 'tRem', 'tPct', 'fcTime', 'fcLeft', 'fcFormula', 'fcTruck'].forEach(function (id) { $(id).textContent = ''; });
    $('tbody').innerHTML = ''; $('tfoot').innerHTML = '';
    $('chartW').innerHTML = ''; $('chartT').innerHTML = '';
  }

  function thresholdNote(y, r, unit, fmt) {
    y = C.optNum(y); r = C.optNum(r);
    if (y === null && r === null) return 'เกณฑ์สี: ยังไม่ได้ตั้ง (ไม่ใส่สี)';
    var parts = [];
    if (y !== null) parts.push('เหลือง ≥ ' + fmt(y));
    if (r !== null) parts.push('แดง ≥ ' + fmt(r));
    return 'เกณฑ์: ' + parts.join(' · ') + ' ' + unit;
  }

  function renderKpis(v) {
    var T = v.T, cfg = v.cfg;
    $('wTotal').textContent = t1(T.weightKg);
    $('wDone').textContent = t1(T.completeKg);
    $('wRem').textContent = t1(T.remainingKg);
    $('wPct').textContent = nf1.format(T.completePct) + '%';
    $('wBar').style.width = Math.min(100, T.completePct) + '%';
    $('tCi').textContent = nf0.format(T.truckCheckIn);
    $('tOb').textContent = nf0.format(T.truckOutbound);
    $('tDone').textContent = nf0.format(T.truckComplete);
    $('tRem').textContent = nf0.format(T.truckRemaining);
    $('tPct').textContent = nf1.format(T.truckCompletePct) + '%';
    $('tBar').style.width = Math.min(100, T.truckCompletePct) + '%';
    $('wRemTile').setAttribute('data-level', v.wLevel);
    $('tRemTile').setAttribute('data-level', v.tLevel);
    $('wChip').innerHTML = chipHtml(REM_CHIP[v.wLevel]);
    $('tChip').innerHTML = chipHtml(REM_CHIP[v.tLevel]);
    $('thW').textContent = thresholdNote(cfg.remainingTonsYellow, cfg.remainingTonsRed, 'ตัน', function (n) { return nfMax1.format(n); });
    $('thT').textContent = thresholdNote(cfg.remainingTrucksYellow, cfg.remainingTrucksRed, 'คัน', function (n) { return nf0.format(n); });
  }

  function renderForecast(v) {
    var fc = v.fc, T = v.T, cfg = v.cfg;
    $('fcCard').setAttribute('data-level', v.fcLevel);
    $('fcChip').innerHTML = chipHtml(FC_CHIP[v.fcLevel]);
    var timeEl = $('fcTime').parentNode;
    if (fc.ok) {
      var after = fc.etaMin >= 1440;
      $('fcTime').textContent = etaText(fc.etaMin);
      $('fcUnit').hidden = after;
      timeEl.classList.toggle('fc-long', after);
      $('fcLeft').textContent = T.remainingKg > 0 ? 'อีกประมาณ ' + dur(fc.leftH) : 'ไม่มีงานค้างแล้ว';
      $('fcFormula').innerHTML = 'วิธีคิด: ค้าง ' + t1(T.remainingKg) + ' ตัน ÷ อัตราเสร็จเฉลี่ยวันนี้ <b>' + nf1.format(fc.rateTph) +
        ' ตัน/ชม.</b> (เสร็จ ' + t1(T.completeKg) + ' ตัน ใน ' + dur(fc.elapsedH) + ' นับจาก ' + hm(fc.startMin) + ' น. ถึง ' + hm(v.dataMin) + ' น.)';
      $('fcTruck').textContent = fc.truck
        ? 'เทียบ: ถ้าคิดจากรถค้าง ' + nf0.format(T.truckRemaining) + ' คัน (เฉลี่ย ' + nf1.format(fc.truck.ratePerH) + ' คัน/ชม.) จะเสร็จประมาณ ' +
          etaText(fc.truck.etaMin) + (fc.truck.etaMin >= 1440 ? '' : ' น.')
        : '';
    } else {
      $('fcTime').textContent = '--:--';
      $('fcUnit').hidden = true;
      timeEl.classList.remove('fc-long');
      $('fcLeft').textContent = 'ยังคำนวณไม่ได้ (วันนี้ยังไม่มีงานเสร็จ)';
      $('fcFormula').textContent = 'วิธีคิด: ค้าง ÷ อัตราเสร็จเฉลี่ยวันนี้ (นับจากต้นชั่วโมงแรกที่มีงานเสร็จ ถึงเวลาที่ดึงข้อมูล)';
      $('fcTruck').textContent = '';
    }
    if (cfg.targetMin === null) {
      $('fcTarget').innerHTML = 'เวลาเลิกงานเป้า: <b>ยังไม่ได้ตั้ง</b> จึงยังไม่ใส่สี';
    } else {
      var x = C.optNum(cfg.forecastYellowWithinMinutes);
      $('fcTarget').innerHTML = 'เวลาเลิกงานเป้า: <b>' + (cfg.targetMin === 1440 ? '24:00' : hm(cfg.targetMin)) + ' น.</b>' +
        (x !== null ? ' · เหลืองเมื่อเหลือน้อยกว่า ' + nf0.format(x) + ' นาที' : '');
    }
  }

  function renderTable(v) {
    var dash = '–';
    $('tbody').innerHTML = v.rows.map(function (r, i) {
      /* ชั่วโมงที่ยังไม่ถึง และชั่วโมงปัจจุบันที่ยังไม่มีข้อมูล (แถว 0 ทั้งแถว) แสดง "–" ไม่แสดง 0 */
      var fut = i > v.lastShown, cur = i === v.curIdx, noData = i > v.lastIdx;
      var d = function (s) { return noData ? dash : s; };
      return '<tr class="' + (fut ? 'fut' : cur ? 'cur' : '') + '"' + (cur ? ' aria-current="time"' : '') + '>' +
        '<th scope="row">' + r.period.replace('-', '–') + '</th>' +
        '<td>' + d(nf1.format(r.workloadPct)) + '</td>' +
        '<td class="sep">' + d(t1(r.weightKg)) + '</td><td>' + d(t1(r.completeKg)) + '</td><td class="em">' + d(t1(r.remainingKg)) + '</td><td>' + d(nf1.format(r.completePct)) + '</td>' +
        '<td class="sep">' + d(nf0.format(r.truckCheckIn)) + '</td><td>' + d(nf0.format(r.truckOutbound)) + '</td><td>' + d(nf0.format(r.truckComplete)) + '</td><td class="em">' + d(nf0.format(r.truckRemaining)) + '</td><td>' + d(nf1.format(r.truckCompletePct)) + '</td></tr>';
    }).join('');
    var T = v.T;
    $('tfoot').innerHTML = '<tr><th scope="row">รวมทั้งวัน</th><td>100.0</td>' +
      '<td class="sep">' + t1(T.weightKg) + '</td><td>' + t1(T.completeKg) + '</td><td>' + t1(T.remainingKg) + '</td><td>' + nf1.format(T.completePct) + '</td>' +
      '<td class="sep">' + nf0.format(T.truckCheckIn) + '</td><td>' + nf0.format(T.truckOutbound) + '</td><td>' + nf0.format(T.truckComplete) + '</td><td>' + nf0.format(T.truckRemaining) + '</td><td>' + nf1.format(T.truckCompletePct) + '</td></tr>';
  }

  /* ===== แถบบน + แถบ error + ทับหน้า ===== */
  function renderStatus(v) {
    var b = document.body, d = v.data, cfg = v.cfg;
    b.setAttribute('data-conn', v.conn);
    b.setAttribute('data-hide', v.usable ? '0' : '1');
    $('dateTxt').textContent = d ? thaiDate(d.reportDate) : '—';
    $('sampleBadge').hidden = !(d && d.source === 'sample');
    var sim = [];
    if (v.preview) sim.push('จำลองสถานะ: ' + PREVIEW_NAMES[v.preview]);
    if (usingSampleClock()) sim.push('เวลาจำลอง ' + hmMs(v.now) + ' น.');
    $('simBadge').hidden = !sim.length;
    $('simBadge').textContent = sim.join(' · ');
    $('simBadge').title = v.preview ? 'โหมดดูตัวอย่างสถานะ เปิดจากท้าย URL (#preview=...) ลบออกเพื่อกลับสู่สถานะจริง' : 'เวลา "ตอนนี้" มาจาก sampleClock ใน config.json (ใช้กับข้อมูลตัวอย่างเท่านั้น)';

    var dataMs = d ? C.parseTime(d.lastSuccessAt) : null;
    var lastTxt = dataMs !== null ? hmMs(dataMs) + ' น.' : '—';
    var attemptMs = d ? C.parseTime(d.lastAttemptAt) : null;
    var age = v.ageMin !== null && v.ageMin !== undefined ? Math.floor(v.ageMin) : null;
    var fails = d && typeof d.consecutiveFailures === 'number' ? d.consecutiveFailures : 0;
    var I = cfg.refreshMinutes;
    var msg = d && d.message ? ' · รายละเอียด: ' + d.message : '';
    var pageErr = state.pageFetchError ? ' · ' + state.pageFetchError : '';

    var S;
    switch (v.conn) {
      case 'ok':
        S = { pill: 'conn-ok', ic: IC.ok, text: 'เชื่อมต่อ WMS ปกติ', upd: lastTxt,
          sub: 'อัปเดตเองทุก ' + nf0.format(I) + ' นาที · รอบถัดไป ' + hmMs(dataMs + I * 60000) + ' น.' };
        break;
      case 'retry':
        S = { pill: 'conn-retry', ic: IC.retry, text: 'ดึงข้อมูลไม่สำเร็จ 1 รอบ · กำลังลองใหม่', upd: lastTxt,
          sub: 'ผ่านมา ' + age + ' นาที' + (d.status === 'fetch_error' || fails ? ' · รอบล่าสุดดึงไม่สำเร็จ' : ' · ยังไม่ได้ข้อมูลรอบใหม่') };
        break;
      case 'stale':
        S = { pill: 'conn-bad', ic: IC.off, text: 'เชื่อมต่อ WMS ไม่ได้', upd: lastTxt,
          sub: 'ผ่านมา ' + age + ' นาที' + (fails >= 2 ? ' · ดึงไม่สำเร็จติดต่อกัน ' + fails + ' รอบ' : ''),
          bIc: IC.off, bTitle: 'ข้อมูลไม่อัปเดต — ตัวเลขด้านล่างเป็นข้อมูลเก่า ณ ' + lastTxt,
          bDetail: 'ไม่ได้ข้อมูลใหม่จาก WMS มา ' + age + ' นาที โปรแกรมยังลองใหม่ทุก ' + nf0.format(I) + ' นาที · ตรวจว่าเครื่องที่รันโปรแกรมเปิดอยู่และต่อแลนบริษัทได้' + msg,
          ovT: 'ข้อมูลเก่า ณ ' + lastTxt, ovS: 'ไม่ใช่ตัวเลขปัจจุบัน — ห้ามใช้ตัดสินใจจนกว่าแถบแดงจะหายไป' };
        break;
      case 'login':
        S = { pill: 'conn-bad', ic: IC.lock, text: 'ล็อกอิน WMS ไม่ผ่าน', upd: lastTxt,
          sub: 'หยุดดึงข้อมูลตั้งแต่ ' + (attemptMs !== null ? hmMs(attemptMs) + ' น.' : '—'),
          bIc: IC.lock, bTitle: 'ล็อกอิน WMS ไม่ผ่าน — หยุดดึงข้อมูลแล้ว' + (v.usable ? ' ตัวเลขด้านล่างเป็นข้อมูลเก่า ณ ' + lastTxt : ''),
          bDetail: 'โปรแกรมหยุดลองล็อกอินเองเพื่อไม่ให้บัญชีถูกล็อก · ผู้ดูแลต้องตรวจ user/รหัสผ่านบนเครื่องที่รันโปรแกรม แล้วเริ่มโปรแกรมใหม่' + msg,
          ovT: v.usable ? 'ข้อมูลเก่า ณ ' + lastTxt : 'ยังไม่มีข้อมูล', ovS: 'ล็อกอินไม่ผ่าน — ตัวเลขจะไม่อัปเดตจนกว่าผู้ดูแลจะแก้ไข' };
        break;
      case 'nofile':
        S = { pill: 'conn-bad', ic: IC.off, text: 'เปิดไฟล์ข้อมูลไม่ได้', upd: '—', sub: state.pageFetchError,
          bIc: IC.off, bTitle: 'หน้าจออ่านไฟล์ข้อมูลไม่ได้ — ไม่แสดงตัวเลข',
          bDetail: location.protocol === 'file:'
            ? 'หน้านี้ถูกเปิดเป็นไฟล์ตรง ๆ เบราว์เซอร์จึงไม่ยอมให้อ่านไฟล์ข้อมูล · ให้ปิดหน้านี้แล้วดับเบิลคลิก src\\start.cmd แทน'
            : state.pageFetchError + ' · ตรวจว่า start.cmd ยังเปิดอยู่ และมีไฟล์ตามที่ตั้งใน config.json',
          ovT: 'ไม่มีข้อมูลที่เชื่อถือได้ในขณะนี้', ovS: 'เปิดไฟล์ข้อมูลไม่ได้' };
        break;
      case 'loading':
        S = { pill: 'conn-wait', ic: IC.retry, text: 'กำลังโหลด', upd: '—', sub: 'กำลังโหลดข้อมูล…' };
        break;
      default: // parse
        S = { pill: 'conn-bad', ic: IC.alert, text: 'อ่านข้อมูล WMS ไม่ได้', upd: '—',
          sub: (attemptMs !== null ? 'อ่านรอบ ' + hmMs(attemptMs) + ' น. ไม่ได้' : 'ข้อมูลผิดรูปแบบ') + (dataMs !== null ? ' · อ่านได้ครั้งล่าสุด ' + lastTxt : ''),
          bIc: IC.alert, bTitle: 'อ่านหน้ารายงาน WMS ไม่ได้ — ซ่อนตัวเลขทั้งหมดเพื่อป้องกันข้อมูลผิด',
          bDetail: (v.connError ? 'ไฟล์ข้อมูลไม่ตรงรูปแบบ: ' + v.connError : 'ล็อกอินได้ แต่รูปแบบหน้ารายงานไม่ตรงกับที่โปรแกรมรู้จัก (หน้า WMS อาจถูกปรับ)') + ' · แจ้งผู้ดูแลโปรแกรม' + msg,
          ovT: 'ไม่มีข้อมูลที่เชื่อถือได้ในขณะนี้', ovS: 'รูปแบบข้อมูลไม่ตรง — ไม่แสดงตัวเลขจนกว่าจะแก้ไข' };
    }
    var pill = $('connPill');
    pill.className = 'pill ' + S.pill;
    pill.innerHTML = S.ic + '<span></span>';
    pill.lastChild.textContent = S.text;
    $('updTxt').textContent = S.upd;
    $('updSub').textContent = S.sub + (v.conn !== 'nofile' ? pageErr : '') + (state.cfgError ? ' · ' + state.cfgError : '');
    if (S.bTitle) {
      $('bannerIc').innerHTML = S.bIc;
      $('bannerTitle').textContent = S.bTitle;
      $('bannerDetail').textContent = S.bDetail;
      $('ovTitle').textContent = S.ovT;
      $('ovSub').textContent = S.ovS;
    }
  }

  /* ===== กราฟ (SVG วาดเอง) ===== */
  function niceScale(v) {
    if (!(v > 0)) return { max: 1, step: 1 };
    var raw = v / 4, p = Math.pow(10, Math.floor(Math.log10(raw))), n = raw / p;
    var step = (n <= 1 ? 1 : n <= 2 ? 2 : n <= 2.5 ? 2.5 : n <= 5 ? 5 : 10) * p;
    return { max: Math.ceil(v / step) * step, step: step };
  }
  function barPath(x, y, w, h, r) {
    r = Math.max(0, Math.min(r, w / 2, h));
    return 'M' + x + ',' + (y + h) + 'V' + (y + r) + 'Q' + x + ',' + y + ' ' + (x + r) + ',' + y +
      'H' + (x + w - r) + 'Q' + (x + w) + ',' + y + ' ' + (x + w) + ',' + (y + r) + 'V' + (y + h) + 'Z';
  }
  var tip = $('tip');
  function showTip(e, html) {
    tip.innerHTML = html; tip.style.display = 'block';
    var x = e.clientX + 16, y = e.clientY + 16, w = tip.offsetWidth, h = tip.offsetHeight;
    if (x + w > window.innerWidth - 8) x = e.clientX - w - 16;
    if (y + h > window.innerHeight - 8) y = e.clientY - h - 16;
    tip.style.left = Math.max(8, x) + 'px'; tip.style.top = Math.max(8, y) + 'px';
  }
  function hideTip() { tip.style.display = 'none'; }

  var CHARTS = [
    {
      host: 'chartW', aria: 'กราฟน้ำหนักงานเข้าและเสร็จรายชั่วโมง พร้อมเส้นยอดค้างสะสม หน่วยตัน', unit: 'ตัน', fmt: function (x) { return nf1.format(x); },
      bars: [{ cls: 's-in', get: function (r) { return r.weightKg / 1000; } }, { cls: 's-done', get: function (r) { return r.completeKg / 1000; } }],
      line: { label: 'ค้าง', get: function (r) { return r.remainingKg / 1000; } },
      tip: function (r, note) {
        return '<div><b>' + r.period.replace('-', '–') + ' น.</b></div>' + (note ? '<div>' + note + '</div>' :
          '<div><i class="sw bg-in"></i>งานเข้า ' + t1(r.weightKg) + ' ตัน</div><div><i class="sw bg-done"></i>เสร็จ ' + t1(r.completeKg) + ' ตัน</div><div><i class="sw-line bg-rem"></i>ค้างสะสม ' + t1(r.remainingKg) + ' ตัน</div>');
      }
    },
    {
      host: 'chartT', aria: 'กราฟจำนวนรถ Check in, Outbound และเสร็จ รายชั่วโมง หน่วยคัน', unit: 'คัน', fmt: function (x) { return nf0.format(x); },
      bars: [{ cls: 's-ci', get: function (r) { return r.truckCheckIn; } }, { cls: 's-in', get: function (r) { return r.truckOutbound; } }, { cls: 's-done', get: function (r) { return r.truckComplete; } }],
      line: null,
      tip: function (r, note) {
        return '<div><b>' + r.period.replace('-', '–') + ' น.</b></div>' + (note ? '<div>' + note + '</div>' :
          '<div><i class="sw bg-ci"></i>Check in ' + nf0.format(r.truckCheckIn) + ' คัน</div><div><i class="sw bg-in"></i>Outbound ' + nf0.format(r.truckOutbound) + ' คัน</div><div><i class="sw bg-done"></i>เสร็จ ' + nf0.format(r.truckComplete) + ' คัน</div><div>ค้างสะสม ' + nf0.format(r.truckRemaining) + ' คัน</div>');
      }
    }
  ];

  function drawChart(cfg, v) {
    var host = $(cfg.host);
    var rows = v.rows, lastIdx = v.lastIdx, lastShown = v.lastShown, curIdx = v.curIdx;
    var fs = parseFloat(getComputedStyle(document.documentElement).fontSize) || 16;
    var W = host.clientWidth, H = host.clientHeight;
    if (W < 60 || H < 60) return;
    var m = { l: fs * 3.4, r: fs * 0.6, t: fs * 1.7, b: fs * 1.9 };
    var pw = W - m.l - m.r, ph = H - m.t - m.b, n = rows.length, bw = pw / n;
    var vmax = 0;
    rows.forEach(function (r, i) {
      if (i > lastIdx) return;
      cfg.bars.forEach(function (b) { vmax = Math.max(vmax, b.get(r)); });
      if (cfg.line) vmax = Math.max(vmax, cfg.line.get(r));
    });
    var sc = niceScale(vmax * 1.08);
    var y = function (val) { return m.t + ph - (val / sc.max) * ph; };
    var xc = function (i) { return m.l + i * bw + bw / 2; };
    var o = [];
    o.push('<svg width="' + W + '" height="' + H + '" viewBox="0 0 ' + W + ' ' + H + '" role="img" aria-label="' + cfg.aria + '">');
    if (lastShown < n - 1) {
      var fx = m.l + (lastShown + 1) * bw;
      o.push('<rect class="fut-band" x="' + fx + '" y="' + m.t + '" width="' + (m.l + pw - fx) + '" height="' + ph + '"/>');
      if (m.l + pw - fx > fs * 7) o.push('<text class="fut-lbl" x="' + ((fx + m.l + pw) / 2) + '" y="' + (m.t + ph / 2) + '" text-anchor="middle" dominant-baseline="middle">ยังไม่ถึงเวลา</text>');
    }
    if (curIdx >= 0) {
      o.push('<rect class="cur-band" x="' + (m.l + curIdx * bw + 1) + '" y="' + (m.t - fs * 1.4) + '" width="' + (bw - 2) + '" height="' + (ph + fs * 1.4) + '" rx="4"/>');
      o.push('<text class="cur-lbl" x="' + xc(curIdx) + '" y="' + (m.t - fs * 0.45) + '" text-anchor="middle">ตอนนี้</text>');
    }
    for (var k = 0; k * sc.step <= sc.max + 1e-9; k++) {
      var val = k * sc.step, yy = y(val).toFixed(1);
      o.push('<line class="' + (k === 0 ? 'axis' : 'grid') + '" x1="' + m.l + '" x2="' + (m.l + pw) + '" y1="' + yy + '" y2="' + yy + '"/>');
      o.push('<text class="tick" x="' + (m.l - fs * 0.5) + '" y="' + yy + '" text-anchor="end" dominant-baseline="middle">' + nf0.format(val) + '</text>');
    }
    var every = bw >= fs * 2.8 ? 1 : bw >= fs * 1.5 ? 2 : 3;
    rows.forEach(function (r, i) {
      if (i % every) return;
      var h = C.FIRST_HOUR + i;
      var cls = 'xt' + (i > lastShown ? ' fut' : '') + (i === curIdx ? ' cur' : '');
      var lbl = every === 1 ? pad(h) + '-' + pad(h + 1) : pad(h);
      o.push('<text class="' + cls + '" x="' + xc(i) + '" y="' + (m.t + ph + fs * 1.35) + '" text-anchor="middle">' + lbl + '</text>');
    });
    var nb = cfg.bars.length, gw = bw * 0.76, gap = 2, barW = Math.max(1, (gw - gap * (nb - 1)) / nb);
    rows.forEach(function (r, i) {
      if (i > lastIdx) return;
      cfg.bars.forEach(function (b, j) {
        var bv = b.get(r);
        if (!(bv > 0)) return;
        var x = m.l + i * bw + (bw - gw) / 2 + j * (barW + gap), top = y(bv);
        o.push('<path class="' + b.cls + '" d="' + barPath(x, top, barW, m.t + ph - top, Math.min(4, barW / 2)) + '"/>');
      });
    });
    /* เส้นค้างสะสม หยุดที่แถวล่าสุดที่มีข้อมูล ไม่ลากลง 0 */
    if (cfg.line && lastIdx >= 0) {
      var pts = [];
      for (var i = 0; i <= lastIdx; i++) pts.push([xc(i), y(cfg.line.get(rows[i]))]);
      o.push('<polyline class="ln" points="' + pts.map(function (p) { return p[0].toFixed(1) + ',' + p[1].toFixed(1); }).join(' ') + '"/>');
      pts.forEach(function (p) { o.push('<circle class="dot" cx="' + p[0].toFixed(1) + '" cy="' + p[1].toFixed(1) + '" r="' + Math.max(4, fs * 0.3) + '"/>'); });
      var lp = pts[pts.length - 1], txt = cfg.line.label + ' ' + cfg.fmt(cfg.line.get(rows[lastIdx])) + ' ' + cfg.unit;
      var right = lp[0] + fs * 12 < W;
      o.push('<text class="dlabel" x="' + (lp[0] + (right ? fs * 0.8 : -fs * 0.8)) + '" y="' + (lp[1] - fs * 0.7) + '" text-anchor="' + (right ? 'start' : 'end') + '">' + txt + '</text>');
    }
    rows.forEach(function (r, i) {
      o.push('<rect class="hit" data-i="' + i + '" x="' + (m.l + i * bw) + '" y="' + m.t + '" width="' + bw + '" height="' + ph + '"/>');
    });
    o.push('</svg>');
    host.innerHTML = o.join('');
    host.onmousemove = function (e) {
      var t = e.target.closest ? e.target.closest('.hit') : null;
      if (!t) { hideTip(); return; }
      var idx = +t.getAttribute('data-i');
      showTip(e, cfg.tip(rows[idx], idx > lastShown ? 'ยังไม่ถึงเวลา' : idx > lastIdx ? 'ยังไม่มีข้อมูลในชั่วโมงนี้' : ''));
    };
    host.onmouseleave = hideTip;
  }
  function drawCharts() {
    var v = state.view;
    if (!v || !v.usable) return;
    CHARTS.forEach(function (c) { drawChart(c, v); });
  }

  /* ===== ปุ่ม / เหตุการณ์ ===== */
  var rt;
  window.addEventListener('resize', function () { clearTimeout(rt); rt = setTimeout(drawCharts, 120); });
  window.addEventListener('hashchange', render);
  $('themeBtn').addEventListener('click', function () {
    setTheme(document.body.getAttribute('data-theme') === 'light' ? 'dark' : 'light', true);
  });
  $('fsBtn').addEventListener('click', function () {
    if (!document.fullscreenElement) { if (document.documentElement.requestFullscreen) document.documentElement.requestFullscreen(); }
    else if (document.exitFullscreen) document.exitFullscreen();
  });

  setTheme(loadTheme(), false);
  if (location.protocol === 'file:') {
    /* เบราว์เซอร์บล็อกการอ่านไฟล์จาก file:// — แจ้งวิธีเปิดที่ถูกต้องทันที */
    state.pageFetchError = 'หน้านี้ต้องเปิดผ่าน start.cmd';
    render();
  } else {
    load();
  }
})();
