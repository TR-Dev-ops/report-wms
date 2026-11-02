/*
 * gate-calc.js — ตรรกะล้วนของหน้า 2 (โมเดลคลังสินค้า) ไม่แตะหน้าจอ → window.GateCalc
 * ทดสอบด้วย tests/gate-calc-tests.html (Edge headless ผ่าน tests/run-tests.ps1 ส่วน C)
 *
 * กติกา (บรีฟหน้า 2 — การตัดสินใจเจ้าของ 2026-10-30):
 *  - รวมจุดขึ้นสินค้าเป็นยอดต่อโกดังตาม site.pointMap (ชื่อจุด WMS -> id อาคาร)
 *  - ตัวเลขหลักของป้าย (total) = กำลังขึ้นสินค้า (loading) เท่านั้น ไม่รวม Plan (เจ้าของเปลี่ยน 2026-11-02)
 *    % = กำลังขึ้น ÷ ความจุ (site.capacity) × 100 · plan ยังรวมไว้ให้ tooltip ดู
 *  - สี: เขียว < warnPct ≤ เหลือง < critPct ≤ แดง ; ไม่มีความจุ หรือเกณฑ์ว่างทั้งคู่ = none (เทา, ไม่เดา)
 *  - จุดที่ไม่อยู่ใน pointMap (หรือชี้ไปอาคารที่ไม่มีในผัง) = unmatched → หน้าจอขึ้นแถบเตือน ห้ามทิ้งเงียบ
 */
(function (root) {
  'use strict';
  var STATUSES = ['ok', 'fetch_error', 'login_failed', 'parse_error'];

  function isCount(v) { return typeof v === 'number' && isFinite(v) && v >= 0 && Math.floor(v) === v; }
  function parseTime(s) { if (typeof s !== 'string' || !s) return null; var t = Date.parse(s); return isNaN(t) ? null : t; }
  /* ค่าตั้งค่าตัวเลข: null / "" / ไม่ใช่ตัวเลข / ติดลบ = ว่าง */
  function optNum(v) {
    if (v === null || v === undefined || v === '') return null;
    var n = typeof v === 'number' ? v : Number(v);
    return isFinite(n) && n >= 0 ? n : null;
  }

  /* ตรวจรูปแบบ tracking.json — คืน { ok, error } */
  function validateTracking(d) {
    if (!d || typeof d !== 'object') return { ok: false, error: 'ไฟล์ข้อมูลไม่ใช่ JSON object' };
    if (d.schemaVersion !== 1) return { ok: false, error: 'schemaVersion ต้องเป็น 1' };
    if (STATUSES.indexOf(d.status) < 0) return { ok: false, error: 'status ไม่รู้จัก: ' + d.status };
    if (d.status === 'parse_error') return { ok: true };
    if (!Array.isArray(d.points) || !d.points.length) return { ok: false, error: 'ยังไม่มีรายการจุดขึ้นสินค้า (points)' };
    var seen = {};
    for (var i = 0; i < d.points.length; i++) {
      var p = d.points[i];
      if (!p || typeof p.name !== 'string' || !p.name) return { ok: false, error: 'จุดที่ ' + (i + 1) + ' ไม่มีชื่อ' };
      if (!isCount(p.plan) || !isCount(p.loading)) return { ok: false, error: 'จุด ' + p.name + ': Plan/กำลังโหลด ไม่ใช่จำนวนเต็ม' };
      if (seen[p.name]) return { ok: false, error: 'จุด ' + p.name + ' ซ้ำ' };
      seen[p.name] = true;
    }
    var w = d.weightIncoming;
    if (w !== null && w !== undefined && (typeof w !== 'object' || !isCount(w.final))) return { ok: false, error: 'weightIncoming.final ไม่ใช่จำนวนเต็ม' };
    if (parseTime(d.lastSuccessAt) === null) return { ok: false, error: 'lastSuccessAt ไม่ใช่เวลา ISO 8601' };
    return { ok: true };
  }

  /* ตรวจไฟล์ผังขั้นต่ำ — คืน { ok, error } */
  function validateSite(s) {
    if (!s || typeof s !== 'object') return { ok: false, error: 'ไฟล์ผังไม่ใช่ JSON object' };
    if (!Array.isArray(s.boundary) || s.boundary.length < 3) return { ok: false, error: 'boundary ต้องมีอย่างน้อย 3 จุด' };
    if (!Array.isArray(s.buildings) || !s.buildings.length) return { ok: false, error: 'ไม่มี buildings' };
    for (var i = 0; i < s.buildings.length; i++) {
      var b = s.buildings[i];
      if (!b || !b.id) return { ok: false, error: 'อาคารลำดับ ' + (i + 1) + ' ไม่มี id' };
      var parts = b.parts || [[b.x, b.y, b.w, b.d]];
      for (var k = 0; k < parts.length; k++) {
        if (!Array.isArray(parts[k]) || parts[k].length !== 4 || parts[k].some(function (n) { return typeof n !== 'number' || !isFinite(n); }))
          return { ok: false, error: 'อาคาร ' + b.id + ': พิกัด x, y, w, d ไม่ครบ' };
      }
      if (typeof b.h !== 'number') return { ok: false, error: 'อาคาร ' + b.id + ': ไม่มีความสูง h' };
    }
    return { ok: true };
  }

  /*
   * รวมจุด -> โกดัง
   * คืน { byBuilding: { id: { plan, loading, total, pts: [point] } }, unmatched: [{ name, plan, loading, reason }] }
   */
  function aggregate(points, site) {
    var map = (site && site.pointMap) || {}, ids = {}, out = { byBuilding: {}, unmatched: [] };
    ((site && site.buildings) || []).forEach(function (b) { ids[b.id] = true; });
    (points || []).forEach(function (p) {
      var bid = Object.prototype.hasOwnProperty.call(map, p.name) ? map[p.name] : null;
      if (!bid) { out.unmatched.push({ name: p.name, plan: p.plan, loading: p.loading, reason: 'nomap' }); return; }
      if (!ids[bid]) { out.unmatched.push({ name: p.name, plan: p.plan, loading: p.loading, reason: 'nobuilding', building: bid }); return; }
      var a = out.byBuilding[bid] || (out.byBuilding[bid] = { plan: 0, loading: 0, total: 0, pts: [] });
      a.plan += p.plan; a.loading += p.loading; a.total += p.loading;   /* ตัวเลขหลัก = กำลังขึ้นเท่านั้น */ a.pts.push(p);
    });
    return out;
  }

  function capacityOf(site, bid) {
    var c = optNum(((site && site.capacity) || {})[bid]);
    return c === null || c === 0 ? null : c;
  }
  function pctOf(total, cap) { return cap ? total / cap * 100 : null; }

  /* none | good | warn | crit */
  function levelFor(total, cap, th) {
    th = th || {};
    var warn = optNum(th.warnPct), crit = optNum(th.critPct);
    if (!cap || (warn === null && crit === null)) return 'none';
    var pct = total / cap * 100;
    if (crit !== null && pct >= crit) return 'crit';
    if (warn !== null && pct >= warn) return 'warn';
    return 'good';
  }
  /* ป้าย W: เกณฑ์เป็นจำนวน (คัน) — ว่างทั้งคู่ = none */
  function weightLevel(final, th) {
    th = th || {};
    var warn = optNum(th.warn), crit = optNum(th.crit);
    if (final === null || final === undefined || (warn === null && crit === null)) return 'none';
    if (crit !== null && final >= crit) return 'crit';
    if (warn !== null && final >= warn) return 'warn';
    return 'good';
  }

  /* ป้าย W (เจ้าของ 2026-11-02): ตัวเลขยังเป็น Weight Final เดี่ยว ๆ แต่ถ้ามี capacity ของอาคาร W (capacity.W ในไฟล์ผัง)
     ใช้เป็นเกณฑ์สีแบบโกดัง (densityThresholds 80/100) · ไม่มีค่า = แบบเดิม (weightThresholds, ว่าง = เทา) */
  function weightBoardLevel(final, site, bid) {
    if (final === null || final === undefined) return 'none';
    var cap = capacityOf(site, bid);
    if (cap) return levelFor(final, cap, (site && site.densityThresholds) || {});
    return weightLevel(final, site && site.weightThresholds);
  }

  /* สถานะการเชื่อมต่อ — กติกาเดียวกับหน้า 1 (calc.js connState) แต่ตรวจรูปแบบ tracking.json */
  function connState(d, nowMs, cfg) {
    if (!d || typeof d !== 'object') return { state: 'parse', ageMin: null, error: 'ไม่มีข้อมูล' };
    var last = parseTime(d.lastSuccessAt);
    var ageMin = last === null ? null : Math.max(0, (nowMs - last) / 60000);
    if (d.status === 'login_failed') return { state: 'login', ageMin: ageMin };
    if (d.status === 'parse_error') return { state: 'parse', ageMin: ageMin };
    /* ดึงพลาดตั้งแต่ครั้งแรก ยังไม่เคยมีข้อมูลสำเร็จ -> "ยังดึงไม่สำเร็จ" (ไม่ใช่ "อ่านข้อมูลไม่ได้") */
    if (d.status === 'fetch_error' && d.schemaVersion === 1 && last === null && (!Array.isArray(d.points) || !d.points.length))
      return { state: 'nodata', ageMin: null };
    var v = validateTracking(d);
    if (!v.ok) return { state: 'parse', ageMin: ageMin, error: v.error };
    var I = cfg.refreshMinutes, g = cfg.staleGraceMinutes;
    var fails = typeof d.consecutiveFailures === 'number' ? d.consecutiveFailures : 0;
    if (fails >= 2 || ageMin > 2 * I + g) return { state: 'stale', ageMin: ageMin };
    if (d.status === 'fetch_error' || fails === 1 || ageMin > I + g) return { state: 'retry', ageMin: ageMin };
    return { state: 'ok', ageMin: ageMin };
  }

  /*
   * P2-D: คำตอบของ server.ps1 GET /api/trucks?wh=<โกดัง> -> สิ่งที่แผงรายการรถต้องแสดง
   * คืน { kind: 'data' | 'empty' | 'error' | 'session' | 'login' | 'unknown', reason, loading, plan, failed, sample }
   *  - data  = มีรถอย่างน้อย 1 คัน หรือดึงไม่ครบบางประตู (ต้องโชว์กลุ่ม + แถบเตือน ห้ามขึ้น "ไม่มีรถ")
   *  - empty = ดึงครบทุกประตูแล้วไม่มีรถเลย
   *  - รูปแบบผิด = error (ไม่เดา)
   */
  function truckView(r) {
    if (!r || typeof r !== 'object' || r.schemaVersion !== 1) return { kind: 'error', reason: 'format' };
    if (r.status === 'session') return { kind: 'session', reason: r.message || '' };
    if (r.status === 'login_failed') return { kind: 'login', reason: r.message || '' };
    if (r.status === 'unknown_wh') return { kind: 'unknown', reason: '' };
    if (r.status !== 'ok' && r.status !== 'partial') return { kind: 'error', reason: r.message || String(r.status) };
    var clean = function (list) {
      return list.filter(function (o) { return o && typeof o === 'object'; }).map(function (o) {
        return { plate: typeof o.plate === 'string' ? o.plate : '', company: typeof o.company === 'string' ? o.company : '' };
      });
    };
    if (r.kind === 'weight') {           /* ป้าย W: กลุ่มเดียว "Weight Final" */
      if (!Array.isArray(r.weight)) return { kind: 'error', reason: 'format' };
      var wr = clean(r.weight);
      return { kind: wr.length ? 'data' : 'empty', reason: '', weight: true, rows: wr, loading: [], plan: [], failed: [], sample: r.mode === 'sample' };
    }
    if (!Array.isArray(r.loading) || !Array.isArray(r.plan)) return { kind: 'error', reason: 'format' };
    var ld = clean(r.loading), pl = clean(r.plan);
    var failed = (Array.isArray(r.failedGates) ? r.failedGates : []).filter(function (s) { return typeof s === 'string' && s; });
    if (r.status === 'partial' && !failed.length) failed = ['?'];
    return { kind: ld.length || pl.length || failed.length ? 'data' : 'empty', reason: '', weight: false, rows: [], loading: ld, plan: pl, failed: failed, sample: r.mode === 'sample' };
  }

  root.GateCalc = {
    optNum: optNum, parseTime: parseTime, validateTracking: validateTracking, validateSite: validateSite,
    aggregate: aggregate, capacityOf: capacityOf, pctOf: pctOf, levelFor: levelFor, weightLevel: weightLevel, connState: connState,
    truckView: truckView, weightBoardLevel: weightBoardLevel
  };
})(typeof window !== 'undefined' ? window : this);
