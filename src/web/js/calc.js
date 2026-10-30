/*
 * calc.js — ตรรกะคำนวณล้วน ๆ (ไม่แตะหน้าจอ) ของ wms-realtime-report
 * ใช้ได้ทั้งในเบราว์เซอร์ (window.WmsCalc) — แยกไว้เพื่อให้ตรวจสูตรได้ง่าย
 *
 * กติกาหลัก (brief.md ข้อ 3, design.md ข้อ 3 และ 5):
 *  - ยอดค้าง ณ ตอนนี้ = Remaining ของแถวล่าสุดที่มีข้อมูล (ห้ามใช้แถว 0 ของชั่วโมงที่ยังไม่ถึง)
 *  - คาดการณ์ = ยอดค้าง ÷ อัตราเสร็จเฉลี่ย โดยอัตรานับจากต้นชั่วโมงแรกที่มีงานเสร็จ ถึงเวลาที่ดึงข้อมูล
 *  - เกณฑ์ที่ว่าง = ไม่ใส่สี
 */
(function (root) {
  'use strict';

  var FIRST_HOUR = 7;      // แถวแรก 07:01-08:00
  var ROW_COUNT = 17;      // 07:01-08:00 ... 23:01-24:00
  var NUM_FIELDS = ['workloadPct', 'weightKg', 'completeKg', 'remainingKg', 'completePct',
    'truckCheckIn', 'truckOutbound', 'truckComplete', 'truckRemaining', 'truckCompletePct'];
  var ACTIVITY_FIELDS = ['weightKg', 'completeKg', 'remainingKg',
    'truckCheckIn', 'truckOutbound', 'truckComplete', 'truckRemaining'];
  var STATUSES = ['ok', 'fetch_error', 'login_failed', 'parse_error'];

  function isNum(v) { return typeof v === 'number' && isFinite(v); }

  function parseTime(s) {
    if (typeof s !== 'string' || !s) return null;
    var t = Date.parse(s);
    return isNaN(t) ? null : t;
  }

  /* "HH:MM" -> นาทีนับจากเที่ยงคืน (รับ 00:00-24:00) ; ว่าง/ผิดรูปแบบ -> null */
  function parseHHMM(s) {
    if (typeof s !== 'string') return null;
    var m = /^\s*(\d{1,2}):(\d{2})\s*$/.exec(s);
    if (!m) return null;
    var h = +m[1], mi = +m[2];
    if (mi > 59 || h > 24 || (h === 24 && mi > 0)) return null;
    return h * 60 + mi;
  }

  /* ค่าตัวเลขในไฟล์ตั้งค่า: null / "" / ไม่ใช่ตัวเลข / ติดลบ = ว่าง */
  function optNum(v) {
    if (v === null || v === undefined || v === '') return null;
    var n = typeof v === 'number' ? v : Number(v);
    return isFinite(n) && n >= 0 ? n : null;
  }

  function minutesOfDay(ms) {
    var d = new Date(ms);
    return d.getHours() * 60 + d.getMinutes();
  }

  /* ตรวจรูปแบบไฟล์ข้อมูล — คืน { ok, error } */
  function validateData(d) {
    if (!d || typeof d !== 'object') return { ok: false, error: 'ไฟล์ข้อมูลไม่ใช่ JSON object' };
    if (d.schemaVersion !== 1) return { ok: false, error: 'schemaVersion ต้องเป็น 1' };
    if (STATUSES.indexOf(d.status) < 0) return { ok: false, error: 'status ไม่รู้จัก: ' + d.status };
    if (d.status === 'parse_error') return { ok: true };            // ไม่ต้องมีแถว
    if (!Array.isArray(d.rows) || d.rows.length !== ROW_COUNT) {
      return { ok: false, error: 'rows ต้องมี ' + ROW_COUNT + ' แถว' };
    }
    for (var i = 0; i < ROW_COUNT; i++) {
      var r = d.rows[i], h = FIRST_HOUR + i;
      var want = pad(h) + ':01-' + pad(h + 1) + ':00';
      if (!r || r.period !== want) return { ok: false, error: 'แถวที่ ' + (i + 1) + ' ต้องเป็นช่วง ' + want };
      for (var j = 0; j < NUM_FIELDS.length; j++) {
        if (!isNum(r[NUM_FIELDS[j]])) return { ok: false, error: 'แถว ' + want + ' ช่อง ' + NUM_FIELDS[j] + ' ไม่ใช่ตัวเลข' };
      }
    }
    if (parseTime(d.lastSuccessAt) === null) return { ok: false, error: 'lastSuccessAt ไม่ใช่เวลา ISO 8601' };
    return { ok: true };
  }

  function hasData(r) {
    for (var i = 0; i < ACTIVITY_FIELDS.length; i++) if (r[ACTIVITY_FIELDS[i]] !== 0) return true;
    return false;
  }

  /* ผลรวมทั้งวัน — ค้าง = แถวล่าสุดที่มีข้อมูล */
  function summarize(rows) {
    var lastIdx = -1;
    var T = { weightKg: 0, completeKg: 0, truckCheckIn: 0, truckOutbound: 0, truckComplete: 0 };
    rows.forEach(function (r, i) {
      if (hasData(r)) lastIdx = i;
      T.weightKg += r.weightKg; T.completeKg += r.completeKg;
      T.truckCheckIn += r.truckCheckIn; T.truckOutbound += r.truckOutbound; T.truckComplete += r.truckComplete;
    });
    T.remainingKg = lastIdx >= 0 ? rows[lastIdx].remainingKg : 0;
    T.truckRemaining = lastIdx >= 0 ? rows[lastIdx].truckRemaining : 0;
    T.completePct = T.weightKg > 0 ? T.completeKg / T.weightKg * 100 : 0;
    T.truckCompletePct = T.truckOutbound > 0 ? T.truckComplete / T.truckOutbound * 100 : 0;
    return { lastIdx: lastIdx, totals: T };
  }

  /* แถวของชั่วโมงที่เวลา dataMin ตกอยู่ (16:55 -> 16:01-17:00) ; นอกช่วง -> -1 */
  function currentRowIndex(dataMin) {
    if (dataMin === null || dataMin === undefined) return -1;
    var idx = Math.floor((dataMin - 1) / 60) - FIRST_HOUR;
    return idx >= 0 && idx < ROW_COUNT ? idx : -1;
  }

  /*
   * คาดการณ์เวลาเคลียร์งาน — 2 แบบเท่ากัน (เจ้าของตัดสินใจ 2026-10-30: ยังไม่เลือกแบบหลัก เก็บข้อมูลไว้ฟันธงภายหลัง)
   *   startMin  = ต้นชั่วโมงของแถวแรกที่มีงานเสร็จ (completeKg > 0 หรือ truckComplete > 0)  (แถว 09:01-10:00 -> 09:00)
   *   elapsedH  = (dataMin - startMin) / 60
   *   แบบน้ำหนัก: rate = เสร็จรวม (ตัน) ÷ elapsedH ; leftH = ค้าง ณ ตอนนี้ (ตัน) ÷ rate
   *   แบบรถ    : rate = รถเสร็จรวม (คัน) ÷ elapsedH ; leftH = รถค้าง ณ ตอนนี้ (คัน) ÷ rate
   *   etaMin    = dataMin + round(leftH × 60)      (>= 1440 = หลัง 24:00)
   *   judge     = แบบที่ etaMin ช้ากว่า (ใช้ตัดสินสีเทียบเวลาเลิกงานเป้า กันประมาทเกิน) ; เท่ากัน = 'both'
   *   ตัน/คัน   = เสร็จ (ตัน) ÷ รถเสร็จ  และ  ค้าง (ตัน) ÷ รถค้าง  (หารศูนย์ = null)
   * คาดการณ์เฉพาะงานที่เช็คอินแล้ว ไม่รวมรถที่จะเข้ามาเพิ่ม
   */
  function forecast(rows, totals, dataMin) {
    var firstIdx = -1;
    for (var i = 0; i < rows.length; i++) { if (rows[i].completeKg > 0 || rows[i].truckComplete > 0) { firstIdx = i; break; } }
    var res = {
      ok: false, reason: '', startMin: null, elapsedH: null, weight: null, truck: null, judge: null, judgeEtaMin: null,
      tonsPerTruckDone: totals.truckComplete > 0 ? (totals.completeKg / 1000) / totals.truckComplete : null,
      tonsPerTruckLeft: totals.truckRemaining > 0 ? (totals.remainingKg / 1000) / totals.truckRemaining : null
    };
    if (firstIdx < 0) { res.reason = 'no-complete'; return res; }
    res.startMin = (FIRST_HOUR + firstIdx) * 60;
    res.elapsedH = (dataMin - res.startMin) / 60;
    if (!(res.elapsedH > 0)) { res.reason = 'no-elapsed'; return res; }
    function one(done, left) {
      if (!(done > 0)) return null;
      var rate = done / res.elapsedH;
      var leftH = left > 0 ? left / rate : 0;
      return { ratePerH: rate, leftH: leftH, etaMin: dataMin + Math.round(leftH * 60) };
    }
    res.weight = one(totals.completeKg / 1000, totals.remainingKg / 1000);
    res.truck = one(totals.truckComplete, totals.truckRemaining);
    if (!res.weight && !res.truck) { res.reason = 'no-complete'; return res; }
    res.ok = true;
    if (res.weight && res.truck) {
      res.judge = res.weight.etaMin > res.truck.etaMin ? 'weight' : res.truck.etaMin > res.weight.etaMin ? 'truck' : 'both';
    } else res.judge = res.weight ? 'weight' : 'truck';
    res.judgeEtaMin = res.judge === 'truck' ? res.truck.etaMin : res.weight.etaMin;
    return res;
  }

  /* สีของการ์ด "ค้าง": none (ไม่ได้ตั้งเกณฑ์) / good / warn / crit */
  function levelByThreshold(value, yellow, red) {
    yellow = optNum(yellow); red = optNum(red);
    if (yellow === null && red === null) return 'none';
    if (red !== null && value >= red) return 'crit';
    if (yellow !== null && value >= yellow) return 'warn';
    return 'good';
  }

  /* สีของการ์ดคาดการณ์: เกินเป้า = crit ; เหลือเวลาก่อนเป้าน้อยกว่า X นาที = warn ; อื่น ๆ = good */
  function forecastLevel(etaMin, targetMin, warnWithinMin) {
    if (etaMin === null || etaMin === undefined || targetMin === null) return 'none';
    if (etaMin > targetMin) return 'crit';
    var x = optNum(warnWithinMin);
    if (x !== null && targetMin - etaMin < x) return 'warn';
    return 'good';
  }

  /*
   * สถานะการเชื่อมต่อ ตัดสินจากไฟล์ข้อมูล + อายุข้อมูล
   *   I = refreshMinutes, g = staleGraceMinutes
   *   login_failed -> 'login' ; parse_error หรือไฟล์ผิดรูปแบบ -> 'parse'
   *   consecutiveFailures >= 2 หรือ อายุ > 2I + g -> 'stale'
   *   fetch_error / consecutiveFailures = 1 / อายุ > I + g -> 'retry'
   *   อื่น ๆ -> 'ok'
   */
  function connState(data, nowMs, cfg) {
    if (!data || typeof data !== 'object') return { state: 'parse', ageMin: null, error: 'ไม่มีข้อมูล' };
    var last = parseTime(data.lastSuccessAt);
    var ageMin = last === null ? null : Math.max(0, (nowMs - last) / 60000);
    if (data.status === 'login_failed') return { state: 'login', ageMin: ageMin };
    if (data.status === 'parse_error') return { state: 'parse', ageMin: ageMin };
    var v = validateData(data);
    if (!v.ok) return { state: 'parse', ageMin: ageMin, error: v.error };
    var I = cfg.refreshMinutes, g = cfg.staleGraceMinutes;
    var fails = isNum(data.consecutiveFailures) ? data.consecutiveFailures : 0;
    if (fails >= 2 || ageMin > 2 * I + g) return { state: 'stale', ageMin: ageMin };
    if (data.status === 'fetch_error' || fails === 1 || ageMin > I + g) return { state: 'retry', ageMin: ageMin };
    return { state: 'ok', ageMin: ageMin };
  }

  function pad(n) { return (n < 10 ? '0' : '') + n; }

  root.WmsCalc = {
    FIRST_HOUR: FIRST_HOUR, ROW_COUNT: ROW_COUNT,
    parseTime: parseTime, parseHHMM: parseHHMM, optNum: optNum, minutesOfDay: minutesOfDay,
    validateData: validateData, hasData: hasData, summarize: summarize, currentRowIndex: currentRowIndex,
    forecast: forecast, levelByThreshold: levelByThreshold, forecastLevel: forecastLevel, connState: connState,
    pad: pad
  };
})(typeof window !== 'undefined' ? window : this);
