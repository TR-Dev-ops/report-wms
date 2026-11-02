/*
 * page2.js — หน้า 2 "โมเดลคลังสินค้า" ของ wms-realtime-report
 *  - วาด 3 มิติ / 2D ด้วย <canvas> 2D + projection ที่เขียนเอง (ไม่มีไลบรารี ไม่โหลดอะไรจากอินเทอร์เน็ต)
 *    โค้ดวาดยกมาจาก design/page2-mockup.html ที่เจ้าของยืนยันแล้ว (ตัดแผงดูตัวอย่าง/เครื่องมืออ่านพิกัดออก)
 *  - ผัง: data/site.local.json (ผังจริง ไม่ขึ้น repo) ถ้าไม่มี -> data/site.sample.json + ป้าย "ผังตัวอย่าง"
 *  - ตัวเลข: config.trackingFile (ค่าเริ่มต้น: โหมดข้อมูลจริง data/tracking.json / โหมดตัวอย่าง data/tracking.sample.json)
 *  - ตรรกะรวมโกดัง/สี/สถานะอยู่ใน gate-calc.js
 *  - P2-D: คลิกป้ายโกดัง -> แผงรายการรถ (server.ps1 GET api/trucks) ดึงเฉพาะตอนคลิก/กดรีเฟรช
 *    รายการเก็บในหน่วยความจำของแผงเท่านั้น (ไม่ลง localStorage/ไฟล์) และล้างทิ้งเมื่อปิด
 */
(function () {
  'use strict';
  var G = window.GateCalc;
  var $ = function (id) { return document.getElementById(id); };
  var pad = function (n) { return (n < 10 ? '0' : '') + n; };

  /* ===== ค่าตั้งค่า (config.json ร่วมกับหน้า 1) ===== */
  function normalizeConfig(raw) {
    var r = G.optNum(raw.refreshMinutes), g = G.optNum(raw.staleGraceMinutes);
    var dataFile = typeof raw.dataFile === 'string' && raw.dataFile ? raw.dataFile : 'data/latest.json';
    var tf = typeof raw.trackingFile === 'string' && raw.trackingFile ? raw.trackingFile
      : (/latest\.json$/.test(dataFile) ? 'data/tracking.json' : 'data/tracking.sample.json');
    return { refreshMinutes: r === null ? 5 : Math.max(1, r), staleGraceMinutes: g === null ? 2 : g,
      sampleClock: raw.sampleClock || '', trackingFile: tf };
  }
  var state = { cfg: normalizeConfig({}), cfgError: '', site: null, siteSample: false, siteError: '',
    data: null, pageFetchError: '', lastPageFetch: 0, timer: null, view: null };

  function getJson(url) {
    return fetch(url + (url.indexOf('?') < 0 ? '?' : '&') + 't=' + Date.now(), { cache: 'no-store' })
      .then(function (res) { if (!res.ok) { var e = new Error('HTTP ' + res.status); e.status = res.status; throw e; } return res.text(); })
      .then(function (txt) { return JSON.parse(txt.replace(/^﻿/, '')); });
  }

  /* ผัง: local ก่อน (มีแต่ผิดรูปแบบ = แจ้ง error ไม่สลับไปผังตัวอย่างเงียบ ๆ) ; ไม่มีไฟล์ (404) -> sample */
  function loadSite() {
    return getJson('data/site.local.json').then(function (s) { return { site: s, sample: false }; }, function (err) {
      if (err.status === 404) return getJson('data/site.sample.json').then(function (s) { return { site: s, sample: true }; });
      throw new Error('ไฟล์ผัง data/site.local.json อ่านไม่ได้ (' + err.message + ')');
    }).then(function (r) {
      var v = G.validateSite(r.site);
      if (!v.ok) throw new Error('ไฟล์ผัง ' + (r.sample ? 'site.sample.json' : 'site.local.json') + ' ผิดรูปแบบ: ' + v.error);
      return r;
    });
  }

  function load() {
    clearTimeout(state.timer);
    state.lastPageFetch = Date.now();
    return getJson('config.json')
      .then(function (raw) { state.cfg = normalizeConfig(raw || {}); state.cfgError = ''; },
        function (err) { state.cfg = normalizeConfig({}); state.cfgError = 'อ่าน config.json ไม่ได้ (' + err.message + ') ใช้ค่าเริ่มต้น'; })
      .then(loadSite)
      .then(function (r) {
        var changed = JSON.stringify(r.site) !== JSON.stringify(state.site);
        state.site = r.site; state.siteSample = r.sample; state.siteError = '';
        if (changed) buildScene();
      }, function (err) { state.siteError = err.message; })
      .then(function () { return getJson(state.cfg.trackingFile); })
      .then(function (d) { state.data = d; state.pageFetchError = ''; },
        function (err) { state.pageFetchError = 'อ่านไฟล์ข้อมูล ' + state.cfg.trackingFile + ' ไม่ได้ (' + err.message + ')'; })
      .then(function () {
        render();
        /* ตรวจหน้าจอ (QA): #open=<id โกดัง> เปิดแผงรายการรถครั้งเดียวตอนเปิดหน้า — เฉพาะโหมดตัวอย่าง (ไม่เรียก WMS)
           โหมดข้อมูลจริงไม่เปิดเอง: ดึง WMS ได้เฉพาะเมื่อมีคนคลิกป้าย/กดรีเฟรช */
        if (!state.hashOpened) {
          state.hashOpened = true;
          var ho = hashParam('open');
          if (ho && state.data && state.data.source === 'sample' && state.view && state.view.usable && state.view.agg.byBuilding[ho]) openPanel(ho);
        }
        state.timer = setTimeout(load, state.cfg.refreshMinutes * 60000);
      });
  }
  setInterval(function () {
    if (!state.view) return;
    var v = computeView();
    if (v.conn !== 'ok' && Date.now() - state.lastPageFetch > 60000) { load(); return; }
    renderStatus(v);
  }, 30000);

  /* ===== เวลา "ตอนนี้" (sampleClock ใช้เฉพาะข้อมูลตัวอย่าง เหมือนหน้า 1) ===== */
  function usingSampleClock() { return !!(state.data && state.data.source === 'sample' && G.parseTime(state.cfg.sampleClock) !== null); }
  function nowMs() { return usingSampleClock() ? G.parseTime(state.cfg.sampleClock) : Date.now(); }
  var hmMs = function (ms) { var d = new Date(ms); return pad(d.getHours()) + ':' + pad(d.getMinutes()); };

  var PREVIEW_NAMES = { ok: 'ปกติ', retry: 'ดึงพลาด 1 รอบ', stale: 'ข้อมูลเก่า', login: 'ล็อกอินไม่ผ่าน', parse: 'อ่านหน้า WMS ไม่ได้' };
  function hashParam(k) { var m = new RegExp('(?:^|[#&])' + k + '=([\\w-]+)').exec(location.hash); return m ? m[1] : null; }
  function previewState() { var p = hashParam('preview'); return p && PREVIEW_NAMES[p] ? p : null; }

  /* ===== มุมมองข้อมูล ===== */
  function computeView() {
    var cfg = state.cfg, d = state.data, now = nowMs();
    var v = { cfg: cfg, data: d, now: now, usable: false, agg: { byBuilding: {}, unmatched: [] } };
    if (!d) v.conn = state.pageFetchError ? 'nofile' : 'loading';
    else {
      var cs = G.connState(d, now, cfg);
      v.conn = cs.state; v.ageMin = cs.ageMin; v.connError = cs.error || '';
      v.usable = d.status !== 'parse_error' && G.validateTracking(d).ok;
    }
    var p = previewState();
    v.preview = p;
    if (p && (v.usable || p === 'parse')) {
      v.conn = p;
      if (p === 'retry') v.ageMin = cfg.refreshMinutes * 2;
      if (p === 'stale') v.ageMin = cfg.refreshMinutes * 5;
      if (p === 'parse') v.usable = false;
    }
    if (v.usable && state.site) v.agg = G.aggregate(d.points, state.site);
    v.dim = v.conn === 'stale' || v.conn === 'login';        // ตัวเลขเก่า: วาดจางและไม่ใส่สี
    return v;
  }

  /* ===== ไอคอน (เหมือนหน้า 1) ===== */
  var IC = {
    ok: '<svg class="ic" viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="7" fill="currentColor"/></svg>',
    retry: '<svg class="ic" viewBox="0 0 24 24" aria-hidden="true"><path d="M19 12a7 7 0 1 1-2.05-4.95" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round"/><path d="M19 4v4h-4" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"/></svg>',
    off: '<svg class="ic" viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="9.5" fill="none" stroke="currentColor" stroke-width="2.4"/><path d="M8 8l8 8M16 8l-8 8" stroke="currentColor" stroke-width="2.6" stroke-linecap="round"/></svg>',
    lock: '<svg class="ic" viewBox="0 0 24 24" aria-hidden="true"><rect x="4.5" y="10.5" width="15" height="10" rx="2" fill="none" stroke="currentColor" stroke-width="2.4"/><path d="M8 10.5V7.5a4 4 0 0 1 8 0v3" fill="none" stroke="currentColor" stroke-width="2.4"/></svg>',
    alert: '<svg class="ic" viewBox="0 0 24 24" aria-hidden="true"><path d="M12 3L2 21h20L12 3z" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linejoin="round"/><path d="M12 10v5" stroke="currentColor" stroke-width="2.4" stroke-linecap="round"/><circle cx="12" cy="18" r="1.3" fill="currentColor"/></svg>'
  };

  function render() {
    var v = computeView();
    state.view = v;
    renderStatus(v);
    renderSide();
    renderUnmatched(v);
    $('vpErr').hidden = !state.siteError;
    $('vpErr').textContent = state.siteError ? state.siteError + ' — แก้ไฟล์ผังตาม README ข้อ 10 แล้วกด F5' : '';
    req();
  }

  function renderStatus(v) {
    var b = document.body, d = v.data, cfg = v.cfg;
    b.setAttribute('data-conn', v.conn);
    $('sampleBadge').hidden = !(d && d.source === 'sample');
    $('siteBadge').hidden = !(state.site && state.siteSample);
    var sim = [];
    if (v.preview) sim.push('จำลองสถานะ: ' + PREVIEW_NAMES[v.preview]);
    if (usingSampleClock()) sim.push('เวลาจำลอง ' + hmMs(v.now) + ' น.');
    $('simBadge').hidden = !sim.length; $('simBadge').textContent = sim.join(' · ');

    var dataMs = d ? G.parseTime(d.lastSuccessAt) : null, lastTxt = dataMs !== null ? hmMs(dataMs) + ' น.' : '—';
    var attemptMs = d ? G.parseTime(d.lastAttemptAt) : null;
    var age = v.ageMin !== null && v.ageMin !== undefined ? Math.floor(v.ageMin) : null;
    var fails = d && typeof d.consecutiveFailures === 'number' ? d.consecutiveFailures : 0;
    var I = cfg.refreshMinutes, msg = d && d.message ? ' · รายละเอียด: ' + d.message : '';
    var S;
    switch (v.conn) {
      case 'ok':
        S = { pill: 'conn-ok', ic: IC.ok, text: 'เชื่อมต่อ WMS ปกติ', upd: lastTxt, sub: 'อัปเดตเองทุก ' + I + ' นาที · รอบถัดไป ' + hmMs(dataMs + I * 60000) + ' น.' };
        break;
      case 'retry':
        S = { pill: 'conn-retry', ic: IC.retry, text: 'ดึงข้อมูลไม่สำเร็จ 1 รอบ · กำลังลองใหม่', upd: lastTxt,
          sub: 'ผ่านมา ' + age + ' นาที' + (d.status === 'fetch_error' || fails ? ' · รอบล่าสุดดึงไม่สำเร็จ' : ' · ยังไม่ได้ข้อมูลรอบใหม่') };
        break;
      case 'stale':
        S = { pill: 'conn-bad', ic: IC.off, text: 'เชื่อมต่อ WMS ไม่ได้', upd: lastTxt,
          sub: 'ผ่านมา ' + age + ' นาที' + (fails >= 2 ? ' · ดึงไม่สำเร็จติดต่อกัน ' + fails + ' รอบ' : ''),
          bIc: IC.off, bTitle: 'ข้อมูลไม่อัปเดต — ตัวเลขบนโมเดลเป็นข้อมูลเก่า ณ ' + lastTxt,
          bDetail: 'ไม่ได้ข้อมูลใหม่จากหน้า Gate Tracking มา ' + age + ' นาที โปรแกรมยังลองใหม่ทุก ' + I + ' นาที · ตรวจว่าเครื่องที่รันโปรแกรมเปิดอยู่และต่อแลนบริษัทได้' + msg,
          ovT: 'ข้อมูลเก่า ณ ' + lastTxt, ovS: 'ไม่ใช่ตัวเลขปัจจุบัน — ห้ามใช้ตัดสินใจจนกว่าแถบแดงจะหายไป' };
        break;
      case 'login':
        S = { pill: 'conn-bad', ic: IC.lock, text: 'ล็อกอิน WMS ไม่ผ่าน', upd: lastTxt,
          sub: 'หยุดดึงข้อมูลตั้งแต่ ' + (attemptMs !== null ? hmMs(attemptMs) + ' น.' : '—'),
          bIc: IC.lock, bTitle: 'ล็อกอิน WMS ไม่ผ่าน — หยุดดึงข้อมูลแล้ว' + (v.usable ? ' ตัวเลขบนโมเดลเป็นข้อมูลเก่า ณ ' + lastTxt : ''),
          bDetail: 'โปรแกรมหยุดลองล็อกอินเองเพื่อไม่ให้บัญชีถูกล็อก · ผู้ดูแลต้องตรวจ user/รหัสผ่านบนเครื่องที่รันโปรแกรม แล้วเริ่มโปรแกรมใหม่' + msg,
          ovT: v.usable ? 'ข้อมูลเก่า ณ ' + lastTxt : 'ยังไม่มีข้อมูล', ovS: 'ล็อกอินไม่ผ่าน — ตัวเลขจะไม่อัปเดตจนกว่าผู้ดูแลจะแก้ไข' };
        break;
      case 'nofile':
        S = { pill: 'conn-bad', ic: IC.off, text: 'เปิดไฟล์ข้อมูลไม่ได้', upd: '—', sub: state.pageFetchError,
          bIc: IC.off, bTitle: 'หน้าจออ่านไฟล์ข้อมูลไม่ได้ — ไม่แสดงตัวเลข',
          bDetail: location.protocol === 'file:'
            ? 'หน้านี้ถูกเปิดเป็นไฟล์ตรง ๆ เบราว์เซอร์จึงไม่ยอมให้อ่านไฟล์ข้อมูล · ให้ปิดหน้านี้แล้วดับเบิลคลิก src\\start.cmd แทน'
            : state.pageFetchError + ' · ถ้าเพิ่งเปิดโหมดข้อมูลจริง รอตัวดึงทำงานรอบแรก (ไม่เกิน 1 นาที) · ตรวจว่า start-live.cmd ยังเปิดอยู่',
          ovT: 'ไม่มีข้อมูลที่เชื่อถือได้ในขณะนี้', ovS: 'เปิดไฟล์ข้อมูลไม่ได้' };
        break;
      case 'nodata':   /* ดึงพลาดตั้งแต่ครั้งแรก ยังไม่เคยมีตัวเลข */
        S = { pill: 'conn-bad', ic: IC.off, text: 'ดึงข้อมูลจาก WMS ไม่สำเร็จ', upd: '—',
          sub: (attemptMs !== null ? 'ลองล่าสุด ' + hmMs(attemptMs) + ' น.' : '') + (fails ? ' · ไม่สำเร็จติดต่อกัน ' + fails + ' รอบ' : ''),
          bIc: IC.off, bTitle: 'ยังดึงหน้า Gate Tracking จาก WMS ไม่สำเร็จ — ยังไม่มีตัวเลขให้แสดง',
          bDetail: 'โปรแกรมลองใหม่ทุก ' + I + ' นาที · ตรวจว่าเครื่องที่รันโปรแกรมเปิดอยู่และต่อแลนบริษัทได้' + msg,
          ovT: 'ยังไม่มีข้อมูล', ovS: 'ดึงข้อมูลไม่สำเร็จ — กำลังลองใหม่' };
        break;
      case 'loading':
        S = { pill: 'conn-wait', ic: IC.retry, text: 'กำลังโหลด', upd: '—', sub: 'กำลังโหลดข้อมูล…' };
        break;
      default: // parse
        S = { pill: 'conn-bad', ic: IC.alert, text: 'อ่านข้อมูล WMS ไม่ได้', upd: '—',
          sub: (attemptMs !== null ? 'อ่านรอบ ' + hmMs(attemptMs) + ' น. ไม่ได้' : 'ข้อมูลผิดรูปแบบ') + (dataMs !== null ? ' · อ่านได้ครั้งล่าสุด ' + lastTxt : ''),
          bIc: IC.alert, bTitle: 'อ่านหน้า Gate Tracking ของ WMS ไม่ได้ — ซ่อนตัวเลขทั้งหมดเพื่อป้องกันข้อมูลผิด',
          bDetail: (v.connError ? 'ไฟล์ข้อมูลไม่ตรงรูปแบบ: ' + v.connError : 'รูปแบบหน้า Gate Tracking ไม่ตรงกับที่โปรแกรมรู้จัก (หน้า WMS อาจถูกปรับ)') + ' · แจ้งผู้ดูแลโปรแกรม' + msg,
          ovT: 'ไม่มีข้อมูลที่เชื่อถือได้ในขณะนี้', ovS: 'รูปแบบข้อมูลไม่ตรง — ไม่แสดงตัวเลขจนกว่าจะแก้ไข' };
    }
    var pill = $('connPill');
    pill.className = 'pill ' + S.pill;
    pill.innerHTML = S.ic + '<span></span>';
    pill.lastChild.textContent = S.text;
    $('updTxt').textContent = S.upd;
    $('updSub').textContent = S.sub + (v.conn !== 'nofile' && state.pageFetchError ? ' · ' + state.pageFetchError : '') + (state.cfgError ? ' · ' + state.cfgError : '');
    if (S.bTitle) {
      $('bannerIc').innerHTML = S.bIc; $('bannerTitle').textContent = S.bTitle; $('bannerDetail').textContent = S.bDetail;
      $('ovTitle').textContent = S.ovT; $('ovSub').textContent = S.ovS;
    }
  }

  function renderSide() {
    var th = (state.site && state.site.densityThresholds) || {}, w = G.optNum(th.warnPct), c = G.optNum(th.critPct);
    var f = function (n) { return n === null ? '–' : n + '%'; };
    $('lvGood').innerHTML = '<b>เขียว</b> — ' + (w !== null ? 'ต่ำกว่า ' + f(w) : c !== null ? 'ต่ำกว่า ' + f(c) : 'ยังไม่ได้ตั้งเกณฑ์') + ' ของความจุ';
    $('lvWarn').innerHTML = '<b>เหลือง</b> — ' + (w !== null ? f(w) + (c !== null ? ' ถึงต่ำกว่า ' + f(c) : ' ขึ้นไป') : 'ยังไม่ได้ตั้งเกณฑ์');
    $('lvCrit').innerHTML = '<b>แดง</b> — ' + (c !== null ? f(c) + ' ขึ้นไป (เต็ม/เกิน)' : 'ยังไม่ได้ตั้งเกณฑ์');
    $('thBox').textContent = state.site
      ? 'ความจุและเกณฑ์ ' + f(w) + ' / ' + f(c) + ' อ่านจาก' + (state.siteSample ? 'ผังตัวอย่าง (สมมติ)' : 'ไฟล์ผัง site.local.json') + (w === null && c === null ? ' — เกณฑ์ยังว่าง ทุกโกดังเป็นสีเทา' : '')
      : '';
    var note = state.siteSample ? 'ผังตัวอย่าง (สมมติ) — ยังไม่ได้วางไฟล์ผังจริง data/site.local.json'
      : 'ตำแหน่ง/สัดส่วนอ่านจากผังจริง · ความสูงอาคารเป็นค่าสมมติ · ชื่ออาคารตามเจ้าของ';
    $('vpNote').textContent = note;
  }

  function renderUnmatched(v) {
    var u = $('unm'), list = v.usable ? v.agg.unmatched : [];
    if (!list.length) { u.classList.remove('on'); u.textContent = ''; return; }
    u.textContent = 'พบจุดที่ยังไม่จับคู่กับโกดัง: ' + list.map(function (p) {
      return p.name + ' (Plan ' + p.plan + ' · โหลด ' + p.loading + (p.reason === 'nobuilding' ? ' · ไม่มีอาคาร ' + p.building + ' ในผัง' : '') + ')';
    }).join(', ') + ' — เพิ่มใน pointMap ของไฟล์ผัง (README ข้อ 10)';
    u.classList.add('on');
  }

  /* =====================================================================
   * โมเดล (ยกมาจาก mockup ที่เจ้าของยืนยัน)
   * ===================================================================== */
  var PAL = {
    dark: { ground: '#262624', border: '#4c7a43', lawn: '#2d3a2a', canal: '#1f4f78', pond: '#1f4f78', road: '#3a3a36', park: '#30302d',
      sport: '#36583a', field: '#4a5232', roof: '#b9b8b1', roofU: '#86857f', office: '#93a3b0', ridge: '#77766f',
      edge: 'rgba(0,0,0,.45)', sideK: [0.78, 0.55, 0.68, 0.62], hl: '#ffffff', ink: '#f0efec', ink2: '#c3c2b7',
      cardBg: '#1a1a19', cardLine: '#6a6964', noneStroke: '#c3c2b7', unkFill: '#232321', unkStroke: '#c3c2b7', unkInk: '#f0efec',
      areaInk: 'rgba(240,239,236,.5)', sel: '#3987e5' },
    light: { ground: '#dddcd6', border: '#7fa86d', lawn: '#c9d8bb', canal: '#93c1e3', pond: '#93c1e3', road: '#c8c7c0', park: '#d2d1cb',
      sport: '#9cc48c', field: '#b8bc8f', roof: '#ffffff', roofU: '#e9e8e3', office: '#dde6ee', ridge: '#a9a8a1',
      edge: 'rgba(0,0,0,.28)', sideK: [0.87, 0.70, 0.80, 0.76], hl: '#0b0b0b', ink: '#0b0b0b', ink2: '#52514e',
      cardBg: '#fcfcfb', cardLine: '#a9a8a1', noneStroke: '#52514e', unkFill: '#fcfcfb', unkStroke: '#52514e', unkInk: '#0b0b0b',
      areaInk: 'rgba(11,11,11,.5)', sel: '#2a78d6' }
  };
  var LV = { good: { c: '#0ca30c', ink: '#fff', sym: '✓' }, warn: { c: '#fab219', ink: '#0b0b0b', sym: '!' }, crit: { c: '#d03b3b', ink: '#fff', sym: '!!' } };
  var LV_TEXT = { good: 'เขียว: ยังไม่ถึงเกณฑ์เหลือง', warn: 'เหลือง: ถึงเกณฑ์เหลือง', crit: 'แดง: ถึงเกณฑ์แดง' };
  var FONT = '"Leelawadee UI","Segoe UI","Noto Sans Thai",Tahoma,sans-serif';

  var V = { mode: '3d', yaw: -0.18, pitch: 0.95, dist: 4000, tx: 1230, tz: 700, fov: 0.75, offX: 0, offY: 0, s2: 1, cx2: 1230, cz2: 700 };
  var STD = { yaw: -0.18, pitch: 0.95 };
  var cv = $('cv'), ctx = cv.getContext('2d'), vp = $('vp');
  var W = 0, H = 0, DPR = 1, REM = 16, C = PAL.dark, CAM = null, hits = [], gHits = [], DETAIL = false, hoverId = null, hoverCard = null;
  /* P2-D แผงรายการรถ: wh = id โกดังที่เปิดอยู่ (null = ปิด) */
  var TP = { wh: null, seq: 0, ctrl: null, view: null, fetchedAt: 0, loading: false, timers: [] };
  var L = null, B = [], BM = {};

  function buildScene() {
    L = state.site;
    B = L.buildings.map(function (b) {
      var parts = b.parts || [[b.x, b.y, b.w, b.d]];
      var mnx = 1e9, mnz = 1e9, mxx = -1e9, mxz = -1e9;
      parts.forEach(function (p) { mnx = Math.min(mnx, p[0]); mnz = Math.min(mnz, p[1]); mxx = Math.max(mxx, p[0] + p[2]); mxz = Math.max(mxz, p[1] + p[3]); });
      return { id: b.id, label: b.label || '', name: b.name || b.label || b.id, fac: b.style === 'fac', noLabel: !!b.noLabel,
        ownerText: b.ownerText || '', note: b.note || '', was: b.was || '', board: b.board || '', boardAt: b.boardAt || null, lo: b.labelOffset || null,
        type: b.type, h: b.h, parts: parts, la: b.labelAt || [(mnx + mxx) / 2, (mnz + mxz) / 2], bb: [mnx, mnz, mxx, mxz] };
    });
    BM = {}; B.forEach(function (b) { BM[b.id] = b; });
    if (W) fitStandard();
  }

  function camera() {
    var cp = Math.cos(V.pitch), sp = Math.sin(V.pitch), cy = Math.cos(V.yaw), sy = Math.sin(V.yaw);
    return { p: [V.tx + V.dist * cp * sy, V.dist * sp, V.tz + V.dist * cp * cy],
      f: [-cp * sy, -sp, -cp * cy], r: [cy, 0, -sy], u: [-sy * sp, cp, -cy * sp],
      foc: (H / 2) / Math.tan(V.fov / 2), sp: sp, sy: sy, cy: cy };
  }
  function P(x, y, z) {
    if (V.mode === '2d') return [W / 2 + (x - V.cx2) * V.s2, H / 2 + (z - V.cz2) * V.s2, 0];
    var c = CAM, dx = x - c.p[0], dy = y - c.p[1], dz = z - c.p[2];
    var zv = dx * c.f[0] + dy * c.f[1] + dz * c.f[2]; if (zv < 20) zv = 20;
    return [W / 2 + V.offX + c.foc * (dx * c.r[0] + dz * c.r[2]) / zv,
            H / 2 + V.offY - c.foc * (dx * c.u[0] + dy * c.u[1] + dz * c.u[2]) / zv, zv];
  }

  function worldPts() {
    var pts = L.boundary.map(function (q) { return [q[0], 0, q[1]]; });
    B.forEach(function (b) { b.parts.forEach(function (p) { pts.push([p[0], b.h, p[1]], [p[0] + p[2], b.h, p[1] + p[3]]); }); });
    return pts;
  }
  function scrBox(pts) {
    var a = 1e9, b = 1e9, c = -1e9, d = -1e9;
    pts.forEach(function (q) { var s = P(q[0], q[1], q[2]); a = Math.min(a, s[0]); b = Math.min(b, s[1]); c = Math.max(c, s[0]); d = Math.max(d, s[1]); });
    return [a, b, c, d];
  }
  /* มุมมองมาตรฐาน: พอดีจอ เว้นที่หัว/ปุ่ม */
  function fitStandard(mode) {
    if (mode) V.mode = mode;
    if (!L || !W) { syncUI(); return; }
    var pts = worldPts(), padX = REM * 1.2, top = REM * 6, bot = REM * 5;
    var availW = Math.max(50, W - 2 * padX), availH = Math.max(50, H - top - bot);
    var mnx = 1e9, mnz = 1e9, mxx = -1e9, mxz = -1e9;
    pts.forEach(function (q) { mnx = Math.min(mnx, q[0]); mxx = Math.max(mxx, q[0]); mnz = Math.min(mnz, q[2]); mxz = Math.max(mxz, q[2]); });
    if (V.mode === '2d') {
      V.s2 = Math.min(availW / (mxx - mnx), availH / (mxz - mnz));
      V.cx2 = (mnx + mxx) / 2; V.cz2 = (mnz + mxz) / 2 - ((top - bot) / 2) / V.s2;
    } else {
      V.yaw = STD.yaw; V.pitch = STD.pitch; V.tx = (mnx + mxx) / 2; V.tz = (mnz + mxz) / 2; V.offX = 0; V.offY = 0;
      V.dist = Math.max(mxx - mnx, mxz - mnz) * 1.6;
      for (var i = 0; i < 10; i++) {
        CAM = camera(); var bb = scrBox(pts);
        V.dist *= Math.max((bb[2] - bb[0]) / availW, (bb[3] - bb[1]) / availH);
      }
      CAM = camera(); var b2 = scrBox(pts);
      V.offX = W / 2 - (b2[0] + b2[2]) / 2; V.offY = (top + H - bot) / 2 - (b2[1] + b2[3]) / 2;
    }
    syncUI(); req();
  }

  function shade(hex, k) {
    var n = parseInt(hex.slice(1), 16);
    return 'rgb(' + Math.round(((n >> 16) & 255) * k) + ',' + Math.round(((n >> 8) & 255) * k) + ',' + Math.round((n & 255) * k) + ')';
  }
  function hexA(hex, a) { var n = parseInt(hex.slice(1), 16); return 'rgba(' + ((n >> 16) & 255) + ',' + ((n >> 8) & 255) + ',' + (n & 255) + ',' + a + ')'; }
  function path(pts) { ctx.beginPath(); pts.forEach(function (s, i) { if (i) ctx.lineTo(s[0], s[1]); else ctx.moveTo(s[0], s[1]); }); ctx.closePath(); }
  function poly(pts, fill, stroke, lw) { path(pts); if (fill) { ctx.fillStyle = fill; ctx.fill(); } if (stroke) { ctx.strokeStyle = stroke; ctx.lineWidth = lw || 1; ctx.stroke(); } }
  function rectPts(r, y) { y = y || 0; return [P(r[0], y, r[1]), P(r[0] + r[2], y, r[1]), P(r[0] + r[2], y, r[1] + r[3]), P(r[0], y, r[1] + r[3])]; }
  function ellPts(e, n) { var o = []; for (var i = 0; i < n; i++) { var a = i / n * Math.PI * 2; o.push(P(e[0] + Math.cos(a) * e[2], 0, e[1] + Math.sin(a) * e[3])); } return o; }
  function rr(x, y, w, h, r) { ctx.beginPath(); ctx.moveTo(x + r, y); ctx.arcTo(x + w, y, x + w, y + h, r); ctx.arcTo(x + w, y + h, x, y + h, r); ctx.arcTo(x, y + h, x, y, r); ctx.arcTo(x, y, x + w, y, r); ctx.closePath(); }
  function text(t, x, y, size, color, weight, align) {
    ctx.font = (weight || '400') + ' ' + size + 'px ' + FONT; ctx.fillStyle = color;
    ctx.textAlign = align || 'left'; ctx.textBaseline = 'middle'; ctx.fillText(t, x, y);
  }
  function esc(s) { return String(s).replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; }); }

  var need = false;
  function req() { if (!need) { need = true; requestAnimationFrame(draw); } }   /* วาดใหม่เฉพาะตอนมีการเปลี่ยน */

  function draw() {
    need = false;
    if (!L || !W) return;
    C = PAL[document.body.getAttribute('data-theme') === 'light' ? 'light' : 'dark'];
    if (V.mode === '3d') CAM = camera();
    ctx.setTransform(DPR, 0, 0, DPR, 0, 0); ctx.clearRect(0, 0, W, H);
    hits = []; gHits = [];
    ctx.lineJoin = 'round';
    var span = Math.max(L.boundary.reduce(function (m, q) { return Math.max(m, q[0]); }, 0), 1);
    var q1 = P(span * 0.5, 0, 0), q2 = P(span * 0.5 + 100, 0, 0);
    DETAIL = Math.hypot(q2[0] - q1[0], q2[1] - q1[1]) / 100 >= 1.0;

    poly(L.boundary.map(function (q) { return P(q[0], 0, q[1]); }), C.ground, C.border, Math.max(3, REM * 0.35));
    var areas = L.areas || [];
    areas.forEach(function (a) {
      var pts = a.ellipse ? ellPts(a.ellipse, 28) : rectPts(a.rect);
      poly(pts, C[a.type] || C.park, null);
      if (a.type === 'park') { ctx.strokeStyle = C.edge; ctx.lineWidth = 1; path(pts); ctx.stroke(); }
    });
    areas.forEach(function (a) {
      if (!a.label || a.style === 'fac') return;
      var c = a.labelAt ? P(a.labelAt[0], 0, a.labelAt[1])          /* labelAt = ย้ายป้ายพื้นที่ (กันทับป้ายอื่น) */
        : a.ellipse ? P(a.ellipse[0], 0, a.ellipse[1]) : P(a.rect[0] + a.rect[2] / 2, 0, a.rect[1] + a.rect[3] / 2);
      text(a.label, c[0], c[1], REM * 0.78, C.areaInk, '400', 'center');
    });
    var v = state.view || { agg: { byBuilding: {} }, usable: false };
    drawBuildings();
    drawLabels(v);
    if (v.usable) drawCards(v);
    drawWeight(v);
  }

  function drawBuildings() {
    var items = [];
    B.forEach(function (b) { b.parts.forEach(function (p) { items.push({ b: b, x0: p[0], z0: p[1], x1: p[0] + p[2], z1: p[1] + p[3] }); }); });
    if (V.mode === '3d') {
      var c = CAM.p;
      items.forEach(function (it) { var cx = (it.x0 + it.x1) / 2, cz = (it.z0 + it.z1) / 2; it.k = (cx - c[0]) * (cx - c[0]) + (cz - c[2]) * (cz - c[2]); });
      items.sort(function (A, Bx) {   /* ไกล -> ใกล้ (กล่องวางชิดพื้นไม่ทับกัน: แยกแกนก่อน แล้วค่อยระยะ) */
        var x = c[0], z = c[2];
        if (A.x1 <= Bx.x0) { if (x >= Bx.x0) return -1; if (x <= A.x1) return 1; }
        if (Bx.x1 <= A.x0) { if (x >= A.x0) return 1; if (x <= Bx.x1) return -1; }
        if (A.z1 <= Bx.z0) { if (z >= Bx.z0) return -1; if (z <= A.z1) return 1; }
        if (Bx.z1 <= A.z0) { if (z >= A.z0) return 1; if (z <= Bx.z1) return -1; }
        return Bx.k - A.k;
      });
    }
    items.forEach(drawBox);
  }
  function drawBox(it) {
    var b = it.b, h = b.h, x0 = it.x0, x1 = it.x1, z0 = it.z0, z1 = it.z1;
    var base = b.type === 'office' ? C.office : ((b.fac || b.noLabel) ? C.roofU : C.roof);
    var hov = hoverId === b.id, sel = TP.wh === b.id;
    if (V.mode === '3d') {
      var c = CAM.p, k = C.sideK, faces = [];
      if (c[2] > z1) faces.push([[x0, 0, z1], [x1, 0, z1], [x1, h, z1], [x0, h, z1], k[0]]);
      if (c[2] < z0) faces.push([[x1, 0, z0], [x0, 0, z0], [x0, h, z0], [x1, h, z0], k[1]]);
      if (c[0] > x1) faces.push([[x1, 0, z1], [x1, 0, z0], [x1, h, z0], [x1, h, z1], k[2]]);
      if (c[0] < x0) faces.push([[x0, 0, z0], [x0, 0, z1], [x0, h, z1], [x0, h, z0], k[3]]);
      faces.forEach(function (f) {
        var pts = f.slice(0, 4).map(function (q) { return P(q[0], q[1], q[2]); });
        poly(pts, shade(base, f[4]), C.edge, 1); hits.push({ pts: pts, b: b });
      });
    }
    var top = rectPts([x0, z0, x1 - x0, z1 - z0], h);
    poly(top, base, sel ? C.sel : hov ? C.hl : C.edge, sel ? 3 : hov ? 2.5 : 1); hits.push({ pts: top, b: b });
    var w = x1 - x0, d = z1 - z0, a, e;      /* สันหลังคา */
    if (w >= d) { a = P(x0 + w * 0.04, h, z0 + d / 2); e = P(x1 - w * 0.04, h, z0 + d / 2); }
    else { a = P(x0 + w / 2, h, z0 + d * 0.04); e = P(x0 + w / 2, h, z1 - d * 0.04); }
    ctx.beginPath(); ctx.moveTo(a[0], a[1]); ctx.lineTo(e[0], e[1]);
    ctx.strokeStyle = C.ridge; ctx.lineWidth = Math.max(1.5, REM * 0.22); ctx.lineCap = 'round'; ctx.stroke();
  }

  function pillLabel(t, cx, cy) {
    var fs = REM * 0.78; ctx.font = '700 ' + fs + 'px ' + FONT;
    var pw = ctx.measureText(t).width + REM * 0.9, ph = REM * 1.45;
    rr(cx - pw / 2, cy - ph / 2, pw, ph, ph / 2);
    ctx.fillStyle = C.unkFill; ctx.fill(); ctx.strokeStyle = C.unkStroke; ctx.lineWidth = 1.5; ctx.stroke();
    text(t, cx, cy + 1, fs, C.unkInk, '700', 'center');
  }
  function drawLabels(v) {
    (L.areas || []).forEach(function (a) {      /* พื้นที่ที่มีชื่อแบบอาคาร (style "fac") */
      if (a.style !== 'fac' || !a.label || !a.rect) return;
      var s = P(a.rect[0] + a.rect[2] / 2, 0, a.rect[1] + a.rect[3] / 2);
      pillLabel(a.label, s[0], s[1]);
    });
    var agg = v.usable ? v.agg.byBuilding : {};
    B.forEach(function (b) {
      if (b.noLabel || !b.label) return;
      if (b.board) return;                 /* อาคาร W: ชื่ออยู่บนป้ายสถานะ */
      if (agg[b.id]) return;               /* โกดังที่มีจุด: ชื่ออยู่หัวป้ายยอดรวม */
      var s = P(b.la[0], b.h + 1, b.la[1]);
      if (b.lo) {                          /* เลื่อนป้ายออก (rem บนจอ) + เส้นชี้ กันป้ายซ้อน */
        var a0 = s[0], a1 = s[1]; s = [a0 + b.lo[0] * REM, a1 + b.lo[1] * REM];
        ctx.beginPath(); ctx.moveTo(a0, a1); ctx.lineTo(s[0], s[1]); ctx.strokeStyle = C.unkStroke; ctx.lineWidth = 1.5; ctx.stroke();
        ctx.beginPath(); ctx.arc(a0, a1, REM * 0.2, 0, Math.PI * 2); ctx.fillStyle = C.unkStroke; ctx.fill();
      }
      if (!b.fac) {
        var r = REM * 1.15;
        ctx.beginPath(); ctx.arc(s[0], s[1], r, 0, Math.PI * 2);
        ctx.fillStyle = '#eb6834'; ctx.fill(); ctx.strokeStyle = '#ffffff'; ctx.lineWidth = 2; ctx.stroke();
        text(b.label, s[0], s[1] + 1, REM * (b.label.length > 1 ? 0.92 : 1.1), '#ffffff', '700', 'center');
      } else pillLabel(b.label, s[0], s[1]);
    });
  }

  /* ป้ายยอดรวมต่อโกดัง: บนหลังคา ไม่มีเสา */
  function drawCards(v) {
    var placeAll = L.cardPlacement || {}, th = L.densityThresholds || {};
    Object.keys(v.agg.byBuilding).forEach(function (bid) {
      var b = BM[bid]; if (!b) return;
      var a = v.agg.byBuilding[bid], total = a.total, cap = G.capacityOf(L, bid);
      var lvl = v.dim ? 'none' : G.levelFor(total, cap, th), lv = LV[lvl];
      var pl = placeAll[bid] || {}, at = pl.cardAt || b.la, s = P(at[0], b.h + 1, at[1]);
      if (pl.cardOffset) s = [s[0] + pl.cardOffset[0] * REM, s[1] + pl.cardOffset[1] * REM];
      var label = b.label || b.id;
      var big = total + '/' + (cap === null ? '–' : cap), small = 'Plan ' + a.plan + ' · โหลด ' + a.loading;
      var fsB = REM * (DETAIL ? 1.3 : 1.15), fsS = REM * 0.68, fsL = REM * (label.length > 2 ? 0.62 : 0.78);
      ctx.font = '700 ' + fsB + 'px ' + FONT; var bw = ctx.measureText(big).width;
      ctx.font = '400 ' + fsS + 'px ' + FONT; var sw = DETAIL ? ctx.measureText(small).width : 0;
      ctx.font = '700 ' + fsL + 'px ' + FONT; var lw = ctx.measureText(label).width;
      var bd = REM * (DETAIL ? 1.6 : 1.35), badgeW = Math.max(bd, lw + REM * 0.6);
      var symW = lv ? REM * (lv.sym.length > 1 ? 1.25 : 0.95) : 0;
      var cw = REM * 0.25 + badgeW + REM * 0.35 + Math.max(bw, sw) + (lv ? REM * 0.3 + symW : 0) + REM * 0.4, ch = REM * (DETAIL ? 2.6 : 1.75);
      var x = s[0] - cw / 2, y = s[1] - ch / 2;
      var selC = TP.wh === bid, hovC = hoverCard === bid;
      ctx.save(); if ((total === 0 && !selC && !hovC) || v.dim) ctx.globalAlpha = v.dim ? 0.45 : 0.6;
      rr(x, y, cw, ch, REM * 0.45); ctx.fillStyle = C.cardBg; ctx.fill();
      if (lv) { ctx.fillStyle = hexA(lv.c, 0.18); ctx.fill(); }
      ctx.strokeStyle = lv ? lv.c : C.cardLine; ctx.lineWidth = lv ? 3 : 1.5; ctx.stroke();
      var bx = x + REM * 0.25, by = y + ch / 2;
      rr(bx, by - bd / 2, badgeW, bd, bd / 2); ctx.fillStyle = '#eb6834'; ctx.fill(); ctx.strokeStyle = '#ffffff'; ctx.lineWidth = 1.5; ctx.stroke();
      text(label, bx + badgeW / 2, by + 1, fsL, '#ffffff', '700', 'center');
      var tx = bx + badgeW + REM * 0.35;
      if (DETAIL) { text(big, tx, y + REM * 1.0, fsB, C.ink, '700'); text(small, tx, y + REM * 2.0, fsS, C.ink2, '400'); }
      else text(big, tx, by + 1, fsB, C.ink, '700');
      if (lv) {
        var px = x + cw - REM * 0.4 - symW, ph = REM * 0.95;
        rr(px, by - ph / 2, symW, ph, ph / 2); ctx.fillStyle = lv.c; ctx.fill();
        text(lv.sym, px + symW / 2, by + 1, REM * 0.66, lv.ink, '700', 'center');
      }
      ctx.restore();
      if (selC || hovC) {                  /* P2-D: วงแหวนฟ้า (ชี้ = บาง, เปิดแผงอยู่ = หนา + ลูกศรชี้ไปทางแผง) */
        ctx.save(); rr(x - 3, y - 3, cw + 6, ch + 6, REM * 0.6); ctx.strokeStyle = C.sel; ctx.lineWidth = selC ? 4 : 3; ctx.stroke();
        if (selC) text('▸', x + cw + REM * 0.6, y + ch / 2, REM * 1.1, C.sel, '700', 'center');
        ctx.restore();
      }
      var pct = G.pctOf(total, cap);
      var rows = a.pts.map(function (p) { return esc(p.name) + (p.zone && p.zone !== p.name ? ' (การ์ด ' + esc(p.zone) + ')' : '') + ' — Plan ' + p.plan + ' · โหลด ' + p.loading; }).join('<br>');
      var lvTxt = v.dim ? 'ข้อมูลเก่า — ไม่ใส่สี' : lvl === 'none' ? (cap ? 'สีเทา: ยังไม่ได้ตั้งเกณฑ์ %' : 'สีเทา: ยังไม่มีความจุ') : LV_TEXT[lvl];
      gHits.push({ x: x, y: y, w: cw, h: ch, bid: bid, html: '<b>' + esc(b.name) + '</b><div>กำลังขึ้น ' + total + ' คัน / ความจุ ' + (cap === null ? 'ยังไม่ได้ตั้ง' : cap + ' คัน') +
        (pct !== null ? ' (' + Math.round(pct) + '%)' : '') + '</div><div class="m">Plan ' + a.plan + ' (ไม่นับในตัวเลขป้าย)</div><div>' + lvTxt + '</div>' +
        '<div class="m">จุดใน WMS:<br>' + rows + '</div><div class="act">คลิกเพื่อดูทะเบียนรถ</div>' });
    });
  }

  /* ป้ายสถานะ Weight ที่อาคาร W — แสดงเฉพาะ Weight Final กึ่งกลาง (เจ้าของ 2026-10-30) */
  function drawWeight(v) {
    B.forEach(function (b) {
      if (b.board !== 'weight') return;
      var wi = v.usable && v.data ? v.data.weightIncoming : null;
      var fin = wi && typeof wi.final === 'number' ? wi.final : null;
      var lvl = v.dim ? 'none' : G.weightLevel(fin, L.weightThresholds), lv = LV[lvl];
      var base = P(b.la[0], b.h, b.la[1]), ba = b.boardAt || b.la, c0 = P(ba[0], 0, ba[1]);
      var w = REM * 9.2, h = REM * 3.5, x = c0[0] - w / 2, y = c0[1] - h / 2;
      ctx.beginPath(); ctx.moveTo(base[0], base[1]); ctx.lineTo(c0[0], c0[1]); ctx.strokeStyle = C.ink; ctx.lineWidth = 2; ctx.stroke();
      ctx.beginPath(); ctx.arc(base[0], base[1], REM * 0.3, 0, Math.PI * 2); ctx.fillStyle = lv ? lv.c : C.noneStroke; ctx.fill();
      ctx.save(); if (v.dim) ctx.globalAlpha = 0.45;
      rr(x, y, w, h, REM * 0.45); ctx.fillStyle = C.cardBg; ctx.fill();
      if (lv) { ctx.fillStyle = hexA(lv.c, 0.18); ctx.fill(); }
      ctx.strokeStyle = lv ? lv.c : C.cardLine; ctx.lineWidth = lv ? 3 : 1.5; ctx.stroke();
      var cr = REM * 0.5, ccx = x + REM * 0.35 + cr, ccy = y + REM * 0.65;
      ctx.beginPath(); ctx.arc(ccx, ccy, cr, 0, Math.PI * 2); ctx.fillStyle = '#eb6834'; ctx.fill();
      text(b.label || 'W', ccx, ccy + 1, REM * 0.62, '#ffffff', '700', 'center');
      text('Weight Incoming', ccx + cr + REM * 0.3, ccy, REM * 0.75, C.ink, '700');
      if (lv) {
        var pw = REM * (lv.sym.length > 1 ? 1.25 : 0.95), ph = REM * 0.9, px = x + w - pw - REM * 0.3, py = y + REM * 0.2;
        rr(px, py, pw, ph, ph / 2); ctx.fillStyle = lv.c; ctx.fill();
        text(lv.sym, px + pw / 2, py + ph / 2 + 1, REM * 0.62, lv.ink, '700', 'center');
      }
      text(fin === null ? '–' : String(fin), x + w / 2, y + REM * 1.95, REM * 1.5, C.ink, '700', 'center');
      text('Weight Final', x + w / 2, y + REM * 2.95, REM * 0.65, C.ink, '700', 'center');
      ctx.restore();
      gHits.push({ x: x, y: y, w: w, h: h, html: '<b>อาคาร W · Weight Incoming</b><div>Weight Final ' + (fin === null ? '–' : fin) + '</div>' +
        '<div>' + (lvl === 'none' ? (v.dim ? 'ข้อมูลเก่า — ไม่ใส่สี' : 'ยังไม่ได้ตั้งเกณฑ์ (สีเทา)') : LV_TEXT[lvl]) + '</div>' });
    });
  }

  /* ===== hover / tooltip ===== */
  function inPoly(x, y, pts) {
    var ins = false;
    for (var i = 0, j = pts.length - 1; i < pts.length; j = i++) {
      var xi = pts[i][0], yi = pts[i][1], xj = pts[j][0], yj = pts[j][1];
      if (((yi > y) !== (yj > y)) && (x < (xj - xi) * (y - yi) / (yj - yi) + xi)) ins = !ins;
    }
    return ins;
  }
  var tip = $('tip');
  /* ป้ายที่จุด (x, y) บน canvas — ป้ายยอดรวมโกดังมี bid (คลิกได้), ป้าย W ไม่มี bid */
  function cardAt(x, y) {
    for (var i = gHits.length - 1; i >= 0; i--) {
      var g = gHits[i];
      if (x >= g.x && x <= g.x + g.w && y >= g.y && y <= g.y + g.h) return g;
    }
    return null;
  }
  function hover(e) {
    var r = cv.getBoundingClientRect(), x = e.clientX - r.left, y = e.clientY - r.top, html = '', id = null, i;
    var gh = cardAt(x, y), hc = gh && gh.bid ? gh.bid : null;
    if (gh) html = gh.html;
    cv.style.cursor = hc ? 'pointer' : '';
    if (hc !== hoverCard) { hoverCard = hc; req(); }
    if (!html) for (i = hits.length - 1; i >= 0; i--) {
      if (inPoly(x, y, hits[i].pts)) {
        var b = hits[i].b, v = state.view, has = v && v.usable && v.agg.byBuilding[b.id];
        var capB = G.capacityOf(L, b.id); id = b.id;
        html = '<b>' + esc(b.name) + '</b>' +
          (capB !== null && !has ? '<div>ความจุ ' + capB + ' คัน · ยังไม่มีจุดขึ้นสินค้าใน WMS</div>' : '') +
          (b.note ? '<div class="m">' + esc(b.note) + '</div>' : '') +
          (b.ownerText ? '<div class="m">เจ้าของเขียนว่า "' + esc(b.ownerText) + '"</div>' : '');
        break;
      }
    }
    if (id !== hoverId) { hoverId = id; req(); }
    if (html) {
      tip.innerHTML = html; tip.style.display = 'block';
      var tx = e.clientX + 14, ty = e.clientY + 14;
      if (tx + tip.offsetWidth > innerWidth - 8) tx = e.clientX - tip.offsetWidth - 14;
      if (ty + tip.offsetHeight > innerHeight - 8) ty = e.clientY - tip.offsetHeight - 14;
      tip.style.left = tx + 'px'; tip.style.top = ty + 'px';
    } else tip.style.display = 'none';
  }

  /* ===== เมาส์ / นิ้ว ===== */
  function rotBy(dx, dy) { V.yaw -= dx * 0.006; V.pitch = Math.min(1.5, Math.max(0.28, V.pitch + dy * 0.004)); }
  function panBy(dx, dy) {
    if (V.mode === '2d') { V.cx2 -= dx / V.s2; V.cz2 -= dy / V.s2; return; }
    var c = CAM || camera(), k = V.dist / c.foc;
    V.tx -= c.r[0] * dx * k; V.tz -= c.r[2] * dx * k;
    var s = Math.max(c.sp, 0.3);
    V.tx += -c.sy * dy * k / s; V.tz += -c.cy * dy * k / s;
  }
  function zoomAt(mx, my, f) {
    if (V.mode === '2d') {
      var wx = V.cx2 + (mx - W / 2) / V.s2, wz = V.cz2 + (my - H / 2) / V.s2;
      V.s2 = Math.min(8, Math.max(0.05, V.s2 / f));
      V.cx2 = wx - (mx - W / 2) / V.s2; V.cz2 = wz - (my - H / 2) / V.s2;
    } else V.dist = Math.min(20000, Math.max(250, V.dist * f));
  }
  var ptrs = new Map(), drag = null, pinch = null;
  function pos(e) { var r = cv.getBoundingClientRect(); return { x: e.clientX - r.left, y: e.clientY - r.top }; }
  function pinchState() { var a = Array.from(ptrs.values()); return { d: Math.hypot(a[0].x - a[1].x, a[0].y - a[1].y) || 1, mx: (a[0].x + a[1].x) / 2, my: (a[0].y + a[1].y) / 2 }; }
  /* คลิก = ปล่อยนิ้ว/เมาส์ปุ่มซ้ายโดยขยับไม่เกิน 6px (ลากหมุน / ซูม / 2 นิ้ว ไม่นับ) */
  var tap = null;
  cv.addEventListener('pointerdown', function (e) {
    cv.setPointerCapture(e.pointerId); ptrs.set(e.pointerId, pos(e));
    drag = { btn: e.button, shift: e.shiftKey }; cv.classList.add('dragging'); cv.style.cursor = ''; touched();
    var p0 = pos(e);
    tap = ptrs.size === 1 && e.button === 0 ? { id: e.pointerId, x: p0.x, y: p0.y } : null;
    if (ptrs.size === 2) pinch = pinchState();
  });
  cv.addEventListener('pointermove', function (e) {
    var p = ptrs.get(e.pointerId);
    if (!p) { if (e.pointerType === 'mouse') hover(e); return; }
    var q = pos(e), dx = q.x - p.x, dy = q.y - p.y; p.x = q.x; p.y = q.y;
    if (tap && (tap.id !== e.pointerId || Math.hypot(q.x - tap.x, q.y - tap.y) > 6)) tap = null;
    if (ptrs.size === 1) {
      var pan = V.mode === '2d' || drag.btn === 2 || drag.btn === 1 || drag.shift || e.shiftKey;
      if (pan) panBy(dx, dy); else rotBy(dx, dy);
    } else if (ptrs.size === 2 && pinch) {
      var n = pinchState();
      zoomAt(n.mx, n.my, pinch.d / n.d); panBy(n.mx - pinch.mx, n.my - pinch.my); pinch = n;
    }
    tip.style.display = 'none'; touched(); req();
  });
  function end(e) {
    var wasTap = e.type === 'pointerup' && tap && tap.id === e.pointerId && ptrs.size === 1;
    ptrs.delete(e.pointerId); pinch = ptrs.size === 2 ? pinchState() : null;
    if (!ptrs.size) cv.classList.remove('dragging');
    tap = null;
    if (wasTap) {
      var q = pos(e), g = cardAt(q.x, q.y);
      if (g && g.bid) openPanel(g.bid);
      else if (TP.wh) closePanel();            /* คลิกที่ว่างบนโมเดล (ไม่โดนป้าย และไม่ได้ลาก) = ปิดแผง */
      if (e.pointerType === 'mouse') hover(e);
    }
  }
  cv.addEventListener('pointerup', end); cv.addEventListener('pointercancel', end);
  cv.addEventListener('pointerleave', function () {
    if (!ptrs.size) { tip.style.display = 'none'; cv.style.cursor = ''; if (hoverId || hoverCard) { hoverId = null; hoverCard = null; req(); } }
  });
  cv.addEventListener('contextmenu', function (e) { e.preventDefault(); });
  cv.addEventListener('wheel', function (e) { e.preventDefault(); var q = pos(e); zoomAt(q.x, q.y, Math.exp(e.deltaY * 0.0012)); touched(); req(); }, { passive: false });

  /* ทีวี: ไม่มีใครแตะ 60 วินาที -> กลับมุมมองมาตรฐานเอง (ไม่หมุนเอง ตัวเลขนิ่ง) */
  var idleT = null;
  function touched() { clearTimeout(idleT); if (innerWidth >= 1200) idleT = setTimeout(function () { fitStandard('3d'); }, 60000); }

  /* ===== ปุ่ม ===== */
  $('stdBtn').onclick = function () { fitStandard('3d'); };
  $('m3d').onclick = function () { fitStandard('3d'); touched(); };
  $('m2d').onclick = function () { fitStandard('2d'); touched(); };
  $('zIn').onclick = function () { zoomAt(W / 2, H / 2, 1 / 1.25); touched(); req(); };
  $('zOut').onclick = function () { zoomAt(W / 2, H / 2, 1.25); touched(); req(); };
  $('rL').onclick = function () { V.yaw += 0.35; touched(); req(); };
  $('rR').onclick = function () { V.yaw -= 0.35; touched(); req(); };
  function syncUI() {
    $('m3d').setAttribute('aria-pressed', V.mode === '3d'); $('m2d').setAttribute('aria-pressed', V.mode === '2d');
    Array.prototype.forEach.call(document.querySelectorAll('.rot'), function (b) { b.style.display = V.mode === '3d' ? '' : 'none'; });
    $('vpTitle').textContent = V.mode === '3d' ? 'โมเดลคลังสินค้า 3 มิติ' : 'ผังคลังสินค้า 2D (มองจากด้านบน)';
    $('hint').innerHTML = V.mode === '3d'
      ? 'ลากเพื่อหมุน · คลิกขวา / Shift+ลาก / 2 นิ้ว เพื่อเลื่อน<br>ล้อเมาส์ / ถ่างนิ้ว เพื่อซูม<br>คลิกป้ายโกดังเพื่อดูทะเบียนรถ'
      : 'ลากเพื่อเลื่อน · ล้อเมาส์ / ถ่างนิ้ว เพื่อซูม<br>คลิกป้ายโกดังเพื่อดูทะเบียนรถ';
  }

  /* =====================================================================
   * P2-D แผงรายการรถ (design/page2-design.md ข้อ 12 — เจ้าของยืนยัน 2026-11-02)
   *  - ดึงเฉพาะตอนคลิกป้าย / กดรีเฟรช / ลองอีกครั้ง — ไม่ดึงตามรอบ 5 นาที ไม่ดึงล่วงหน้า
   *  - กำลังดึงอยู่ -> ไม่ยิงซ้ำ ; เปลี่ยนโกดัง/ปิดแผง -> ยกเลิก และทิ้งผลที่มาทีหลัง
   *  - ไม่มีใครแตะจอครบ 60 วินาที -> ปิดแผงเอง (ไม่ให้ทีวีค้างรายการเก่า)
   * ===================================================================== */
  /* server.ps1 กรณีแย่สุด: ไม่เริ่มคำขอใหม่หลัง 20 วินาที + คำขอสุดท้ายที่มีล็อกอินใหม่ 1 ครั้ง (≤4 × 10 วินาที) = 60 วินาที -> ตัดที่ 65 */
  var TRUCK_TIMEOUT_MS = 65000;
  var pop = $('pop'), popBody = $('popBody'), panelIdle = null;
  var hmsMs = function (ms) { var d = new Date(ms); return pad(d.getHours()) + ':' + pad(d.getMinutes()) + ':' + pad(d.getSeconds()); };
  function gatesOf(bid) {
    var map = (state.site && state.site.pointMap) || {}, out = [];
    Object.keys(map).forEach(function (k) { if (map[k] === bid) out.push(k); });
    return out;
  }
  function whName(bid) { var b = BM[bid]; return b ? (b.label || b.id) : bid; }
  function clearTimers() { TP.timers.forEach(clearTimeout); TP.timers = []; }
  function setBusy(on) { TP.loading = on; $('refBtn').disabled = on; $('refBtn').classList.toggle('spin', on); }

  function openPanel(bid) {
    tip.style.display = 'none';
    if (TP.wh === bid) { panelTouched(); $('popTitle').focus({ preventScroll: true }); return; }   /* โกดังเดิม: ไม่ดึงซ้ำ (มีปุ่มรีเฟรช) */
    cancelLoad();
    TP.wh = bid; TP.view = null; TP.fetchedAt = 0;
    var nm = whName(bid);
    $('popTag').textContent = nm;
    $('popTitle').textContent = 'โกดัง ' + nm;
    $('popSub').textContent = 'ประตูใน WMS: ' + (gatesOf(bid).join(', ') || '–');
    pop.hidden = false;
    $('popTitle').focus({ preventScroll: true });
    panelTouched();
    req();
    loadTrucks(false);
  }
  function cancelLoad() {
    clearTimers(); TP.seq++;
    if (TP.ctrl) { try { TP.ctrl.abort(); } catch (e) { /* ignore */ } TP.ctrl = null; }
    setBusy(false);
  }
  function closePanel() {
    if (!TP.wh) return;
    cancelLoad(); clearTimeout(panelIdle);
    TP.wh = null; TP.view = null; TP.fetchedAt = 0;
    popBody.innerHTML = ''; popBody.classList.remove('dim');             /* ล้างรายการทิ้ง ไม่เก็บไว้ */
    $('popBars').innerHTML = ''; $('popSum').innerHTML = ''; $('popTime').textContent = '';
    pop.hidden = true;
    req();
  }

  function loadTrucks(isRefresh) {
    if (!TP.wh || TP.loading) return;                                    /* กำลังดึงอยู่ -> ไม่ยิงซ้ำ */
    clearTimers();
    var my = ++TP.seq, wh = TP.wh, keep = isRefresh && TP.view && (TP.view.kind === 'data' || TP.view.kind === 'empty');
    setBusy(true);
    if (keep) { popBody.classList.add('dim'); $('popTime').textContent = 'กำลังดึงใหม่… (รายการด้านล่างคือชุดเดิม)'; $('popTime').className = 'pop-time'; }
    else renderLoading(false);
    TP.timers.push(setTimeout(function () { if (my === TP.seq && !keep) renderLoading(true); }, 3000));
    var ctrl = window.AbortController ? new AbortController() : null, timedOut = false;
    TP.ctrl = ctrl;
    TP.timers.push(setTimeout(function () { timedOut = true; if (ctrl) ctrl.abort(); }, TRUCK_TIMEOUT_MS));
    fetch('api/trucks?wh=' + encodeURIComponent(wh) + '&t=' + Date.now(), { cache: 'no-store', headers: { 'X-WMS-Report': '1' }, signal: ctrl ? ctrl.signal : undefined })
      .then(function (res) {
        return res.text().then(function (txt) { var j = null; try { j = JSON.parse(txt); } catch (e) { /* ไม่ใช่ JSON */ } return { status: res.status, json: j }; });
      })
      .then(function (r) {
        if (my !== TP.seq) return;                                        /* ปิดแผง/เปลี่ยนโกดังไปแล้ว: ทิ้ง */
        finishLoad();
        var v = r.json ? G.truckView(r.json) : { kind: 'error', reason: 'http' + r.status };
        TP.view = v;
        if (v.kind === 'data' || v.kind === 'empty') { TP.fetchedAt = Date.now(); renderTrucks(v); }
        else renderTruckError(v.kind, v.reason);
      }, function () {
        if (my !== TP.seq) return;
        finishLoad();
        TP.view = { kind: 'error' };
        renderTruckError('error', timedOut ? 'timeout' : 'local');
      });
  }
  function finishLoad() { clearTimers(); TP.ctrl = null; setBusy(false); popBody.classList.remove('dim'); $('popBars').innerHTML = ''; }

  function sumChips(a, b) { return '<div class="chip ld"><b>' + a + '</b>กำลังขึ้น</div><div class="chip pl"><b>' + b + '</b>Plan</div>'; }
  function secHead(label, color, n) {
    return '<div class="sec-h"><span class="sdot" style="background:' + color + '"></span>' + label + (n === null ? '' : ' <span class="n">' + n + ' คัน</span>') + '</div>';
  }
  function renderLoading(slow) {
    $('popTime').textContent = 'กำลังดึงข้อมูลจาก WMS…'; $('popTime').className = 'pop-time';
    $('popBars').innerHTML = ''; $('popSum').innerHTML = sumChips('–', '–');
    popBody.innerHTML = '<div class="loader"><span class="ring"></span><span>กำลังดึงรายการรถ ' + gatesOf(TP.wh).length + ' ประตู…' +
      (slow ? '<br><span class="slow">ช้ากว่าปกติ ยังรออยู่ (ตัดที่ ' + Math.round(TRUCK_TIMEOUT_MS / 1000) + ' วินาที)</span>' : '') + '</span></div>' +
      secHead('กำลังขึ้น', 'var(--s-ci)', null) + '<div class="skel"></div><div class="skel" style="width:70%"></div>' +
      secHead('Plan', 'var(--muted)', null) + '<div class="skel"></div><div class="skel" style="width:80%"></div><div class="skel" style="width:60%"></div>';
  }
  function rowsHtml(list, emptyTxt) {
    if (!list.length) return '<div class="sec-empty">' + emptyTxt + '</div>';
    return '<div class="cols"><span>External ID (ทะเบียน)</span><span>Company Name</span></div><ul class="rows">' +
      list.map(function (r) {
        return '<li><span class="plate">' + (r.plate ? esc(r.plate) : '–') + '</span><span class="co" title="' + esc(r.company) + '">' + (r.company ? esc(r.company) : '–') + '</span></li>';
      }).join('') + '</ul>';
  }
  function renderTrucks(v) {
    $('popSum').innerHTML = sumChips(v.loading.length, v.plan.length);
    var bars = '';
    if (v.sample) bars += '<div class="samplebar">ข้อมูลตัวอย่าง — ทะเบียน/บริษัทสมมติ ไม่ได้ดึงจาก WMS</div>';
    if (v.failed.length) bars += '<div class="warnbar">ดึงไม่ครบ: ประตู ' + esc(v.failed.join(', ')) + ' ไม่สำเร็จ — รายการด้านล่างอาจขาด กดรีเฟรชเพื่อลองใหม่</div>';
    $('popBars').innerHTML = bars;
    if (v.kind === 'empty') {
      popBody.innerHTML = '<div class="state emp"><span class="ico">✓</span><div class="big">ตอนนี้ไม่มีรถที่โกดัง ' + esc(whName(TP.wh)) + '</div>' +
        '<div class="m">ไม่มีรถกำลังขึ้น และไม่มีรถ Plan</div></div>';
    } else {
      popBody.innerHTML = secHead('กำลังขึ้น', 'var(--s-ci)', v.loading.length) + rowsHtml(v.loading, 'ไม่มีรถกำลังขึ้น') +
        secHead('Plan', 'var(--muted)', v.plan.length) + rowsHtml(v.plan, 'ไม่มีรถ Plan');
    }
    popBody.scrollTop = 0;
    truckTick();
  }
  function renderTruckError(kind, reason) {
    $('popSum').innerHTML = '';
    $('popTime').textContent = 'ดึงไม่สำเร็จเมื่อ ' + hmsMs(Date.now()); $('popTime').className = 'pop-time';
    var d = state.data, last = d ? G.parseTime(d.lastSuccessAt) : null;
    var round = last !== null ? '<br>ตัวเลขบนป้ายโกดังยังเป็นของรอบ ' + hmMs(last) + ' น.' : '';
    var big, m, retry = true;
    if (kind === 'session') {
      big = 'เซสชัน WMS หมดอายุ';
      m = 'ล็อกอิน WMS ใหม่แล้ว แต่ WMS ยังไม่ให้ดึงรายการ ลองอีกครั้งในอีกสักครู่<br>ถ้ายังไม่ได้ ให้แจ้งผู้ดูแลระบบ';
    } else if (kind === 'login') {
      big = 'ล็อกอิน WMS ไม่ผ่าน'; retry = false;
      m = reason === 'env_missing' ? 'ไม่พบไฟล์ .env หรือค่าใน .env ไม่ครบ — ผู้ดูแลต้องตั้งค่าบนเครื่องที่รันโปรแกรม'
        : 'โปรแกรมหยุดลองล็อกอินเองเพื่อไม่ให้บัญชีถูกล็อก<br>ผู้ดูแลต้องตรวจ user/รหัสผ่านใน .env แล้วเปิด start-live.cmd ใหม่';
    } else if (kind === 'unknown') {
      big = 'ไม่พบประตูของโกดังนี้'; retry = false;
      m = 'โกดังนี้ไม่มีจุดใน pointMap ของไฟล์ผัง (README ข้อ 10.2)';
    } else {
      big = 'ดึงรายการรถไม่สำเร็จ';
      m = reason === 'timeout' ? 'WMS ไม่ตอบภายใน ' + Math.round(TRUCK_TIMEOUT_MS / 1000) + ' วินาที'
        : reason === 'local' ? 'ติดต่อโปรแกรมบนเครื่องนี้ไม่ได้ — ตรวจว่าหน้าต่างดำ (start.cmd / start-live.cmd) ยังเปิดอยู่'
        : reason === 'no_gate_ids' ? 'ยังไม่รู้รหัสประตูใน WMS (gateId) — ปิดแล้วเปิด start-live.cmd ใหม่ แล้วรอตัวดึงทำงาน 1 รอบ'
        : 'เชื่อมต่อ WMS ไม่ได้ หรือ WMS ตอบกลับผิดพลาด';
      m += round;
    }
    popBody.innerHTML = '<div class="state err"><span class="ico">!</span><div class="big">' + big + '</div><div class="m">' + m + '</div>' +
      (retry ? '<button class="btn" id="retryBtn" type="button" style="margin-top:.4rem">ลองอีกครั้ง</button>' : '') + '</div>';
    if (retry) $('retryBtn').onclick = function () { loadTrucks(false); };
  }
  function truckTick() {
    var v = TP.view;
    if (!TP.wh || !v || TP.loading || !(v.kind === 'data' || v.kind === 'empty') || !TP.fetchedAt) return;
    var age = (Date.now() - TP.fetchedAt) / 1000, el = $('popTime');
    var rel = age < 60 ? 'เมื่อสักครู่' : Math.floor(age / 60) + ' นาทีที่แล้ว';
    var when = (v.sample ? 'สร้างข้อมูลตัวอย่างเมื่อ ' : 'ดึงจาก WMS เมื่อ ') + hmsMs(TP.fetchedAt) + ' (' + rel + ')';
    if (age >= 300) { el.textContent = when + ' — ข้อมูลเก่า กดรีเฟรช'; el.className = 'pop-time stale'; }
    else { el.textContent = when; el.className = 'pop-time'; }
  }
  setInterval(truckTick, 15000);

  $('closeBtn').onclick = closePanel;
  $('refBtn').onclick = function () { loadTrucks(true); };
  document.addEventListener('keydown', function (e) { if (e.key === 'Escape' && TP.wh) closePanel(); });
  /* ไม่มีใครแตะจอครบ 60 วินาที -> ปิดแผงเอง */
  function panelTouched() { clearTimeout(panelIdle); if (TP.wh) panelIdle = setTimeout(closePanel, 60000); }
  ['pointerdown', 'pointermove', 'wheel', 'keydown', 'touchstart'].forEach(function (ev) {
    document.addEventListener(ev, function () { if (TP.wh) panelTouched(); }, { capture: true, passive: true });
  });

  /* ===== ธีม (key เดียวกับหน้า 1 จึงจำค่าร่วมกัน) ===== */
  var THEME_KEY = 'wms-realtime-report.theme';
  function loadTheme() { try { return localStorage.getItem(THEME_KEY) === 'light' ? 'light' : 'dark'; } catch (e) { return 'dark'; } }
  function setTheme(th, save) {
    document.body.setAttribute('data-theme', th);
    $('themeBtn').textContent = th === 'light' ? 'ธีมมืด' : 'ธีมสว่าง';
    $('themeBtn').title = 'สลับเป็น' + (th === 'light' ? 'ธีมมืด' : 'ธีมสว่าง');
    if (save) { try { localStorage.setItem(THEME_KEY, th); } catch (e) { /* ใช้ค่าในหน้านี้ต่อไป */ } }
    req();
  }
  $('themeBtn').addEventListener('click', function () { setTheme(document.body.getAttribute('data-theme') === 'light' ? 'dark' : 'light', true); });
  $('fsBtn').addEventListener('click', function () {
    if (!document.fullscreenElement) { if (document.documentElement.requestFullscreen) document.documentElement.requestFullscreen(); }
    else if (document.exitFullscreen) document.exitFullscreen();
  });
  window.addEventListener('hashchange', render);

  /* ===== ขนาดจอ ===== */
  function resize() {
    W = vp.clientWidth; H = vp.clientHeight; DPR = Math.min(window.devicePixelRatio || 1, 2);
    REM = parseFloat(getComputedStyle(document.documentElement).fontSize) || 16;
    cv.width = Math.round(W * DPR); cv.height = Math.round(H * DPR);
    fitStandard();
  }

  var hv = hashParam('view');
  V.mode = hv === '2d' || (hv !== '3d' && innerWidth < 900) ? '2d' : '3d';     /* มือถือเริ่มที่ 2D */
  setTheme(hashParam('theme') === 'light' || hashParam('theme') === 'dark' ? hashParam('theme') : loadTheme(), false);
  if (window.ResizeObserver) new ResizeObserver(resize).observe(vp); else window.addEventListener('resize', resize);
  resize(); touched();
  if (location.protocol === 'file:') { state.pageFetchError = 'หน้านี้ต้องเปิดผ่าน start.cmd'; state.siteError = 'หน้านี้ต้องเปิดผ่าน start.cmd (เบราว์เซอร์ไม่ให้อ่านไฟล์ผังจาก file://)'; render(); }
  else load();
})();
