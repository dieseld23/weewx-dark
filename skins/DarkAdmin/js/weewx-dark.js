/*
 * DarkAdmin — WeeWX behaviour layer
 *
 * Four jobs:
 *   1. Draw the charts from the JSON that CheetahGenerator emits into data/.
 *   2. Keep the current readings moving. data/live.json is rewritten on every
 *      packet from the sensor, and the elements marked data-live follow it.
 *   3. Keep the rest of the page current. Once WeeWX has generated the page
 *      again, its new highs, lows, tables and chart data are taken over in
 *      place, without a reload.
 *   4. Say so when the radio has gone quiet, and show Weather Underground's
 *      copy of the readings (data/wu.json) until it is back.
 *
 * 2 and 4 need bin/user/darkadminlive.py on the WeeWX side. Without it those
 * two files never appear, and the page shows what the report printed.
 *
 * Deliberately dependency-free beyond Chart.js, and deliberately NOT a
 * Cheetah template — WeeWX would interpolate every `$` in here.
 */
(function () {
  'use strict';

  /* ----------------------------------------------------------------------
   * Palette
   *
   * Pulled from the CSS custom properties rather than hard-coded, so the
   * charts follow css/local.css if its palette is retuned.
   * -------------------------------------------------------------------- */

  var css = getComputedStyle(document.documentElement);

  function cssVar(name, fallback) {
    var v = css.getPropertyValue(name);
    return v && v.trim() ? v.trim() : fallback;
  }

  var COLORS = {
    blue: cssVar('--da-blue', '#2a9fd6'),
    green: cssVar('--da-green', '#77b300'),
    orange: cssVar('--da-orange', '#ff8800'),
    purple: cssVar('--da-purple', '#9933cc'),
    red: cssVar('--da-red', '#cc0000')
  };

  var TEXT = cssVar('--da-text', '#c9ced5');
  var MUTED = cssVar('--da-muted', '#adb5bd');
  var GRID = 'rgba(255, 255, 255, 0.07)';
  var SURFACE = cssVar('--da-surface-2', '#1c2027');
  var BORDER = cssVar('--da-border-strong', 'rgba(255,255,255,0.15)');

  /* Translucent fill for area charts, from a #rrggbb accent. */
  function fade(hex, alpha) {
    var m = /^#?([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$/i.exec(hex);
    if (!m) return 'rgba(42, 159, 214, ' + alpha + ')';
    return 'rgba(' + parseInt(m[1], 16) + ',' + parseInt(m[2], 16) + ',' +
      parseInt(m[3], 16) + ',' + alpha + ')';
  }

  /* ----------------------------------------------------------------------
   * Settings and state
   *
   * The page carries its own settings, on the banner's placeholder: when its
   * newest archive record was written, and the three intervals from
   * skin.conf's [Extras].
   * -------------------------------------------------------------------- */

  var host = document.getElementById('staleness');

  function setting(name, fallback) {
    var v = host ? parseInt(host.getAttribute(name), 10) : NaN;
    return isNaN(v) ? fallback : v;
  }

  var OUTAGE_AFTER = setting('data-outage-after', 600);       /* seconds */
  var LIVE_EVERY = setting('data-live-every', 5);
  var REFRESH_EVERY = setting('data-refresh-every', 30);

  /* Weather Underground stands in only while its observation is recent, and
     only when that observation is clearly later than the radio's last. The
     second matters when the sensor itself stops: Weather Underground then
     stops within the same minute, and has nothing to add. */
  var BACKUP_MAX_AGE = 1200;
  var BACKUP_LEAD = 120;

  var REQUEST_TIMEOUT = 10000;                    /* milliseconds */

  var reportTime = setting('data-obs-time', 0);   /* newest record on this page */
  var live = null;                                /* data/live.json, as last read */
  var backup = null;                              /* data/wu.json, as last read */

  /* Every time here was stamped by the server, so ages are measured against
     the server's clock: a phone that is ten minutes out would otherwise show
     an outage that is not happening, or hide one that is. */
  var skew = 0;                                   /* server clock minus ours, s */

  /* Whether the last request got an answer of any kind. When none does, old
     readings say nothing about the station: it is this device that is cut off. */
  var reachable = true;

  function now() {
    return Math.floor(Date.now() / 1000) + skew;
  }

  /* Resolves with { data, stamp }, or rejects: not there, not readable, or no
     answer in time. An unanswered request must not stall the polling that
     waits for it. */
  function request(src, cache, kind) {
    return new Promise(function (resolve, reject) {
      var ctl = window.AbortController ? new AbortController() : null;
      var answered = false;
      var stamp = '';
      var timer = setTimeout(function () {
        if (!answered) reachable = false;
        if (ctl) ctl.abort();
        reject(new Error(src + ': no answer'));
      }, REQUEST_TIMEOUT);

      fetch(src, { cache: cache, signal: ctl ? ctl.signal : undefined }).then(function (r) {
        answered = reachable = true;
        /* Only from an answer the browser cannot have had in store. */
        if (cache === 'no-store') {
          var served = Date.parse(r.headers.get('Date') || '');
          if (!isNaN(served)) skew = Math.round((served - Date.now()) / 1000);
        }
        if (!r.ok) throw new Error(src + ': HTTP ' + r.status);
        stamp = (r.headers.get('Last-Modified') || '') + (r.headers.get('ETag') || '');
        return kind === 'json' ? r.json() : r.text();
      }).then(function (data) {
        clearTimeout(timer);
        resolve({ data: data, stamp: stamp });
      }, function (err) {
        clearTimeout(timer);
        if (!answered) reachable = false;
        reject(err);
      });
    });
  }

  /* A number through a format such as "%.0f" or "%.1f dB", which is how
     WeeWX itself writes them. Null when the format has no "%.Nf" in it. */
  function printf(format, value) {
    var m = typeof format === 'string' ? /%\.(\d+)f/.exec(format) : null;
    if (!m || typeof value !== 'number') return null;
    var places = parseInt(m[1], 10);
    var digits = value.toFixed(places);
    /* An exact half goes away from zero in toFixed and to the even digit in
       Python, which prints the pages: 60.5 is "61" here and "60" there. A
       number is such a half only if this many halves of it is odd. */
    var halves = Math.abs(value) * Math.pow(2, places + 1);
    if (halves % 2 === 1) {
      var below = Math.floor(halves * Math.pow(5, places) / 2);
      if (below % 2 === 0) {
        digits = (value < 0 ? '-' : '') + (below / Math.pow(10, places)).toFixed(places);
      }
    }
    if (parseFloat(digits) === 0) digits = digits.replace('-', '');     /* never "-0" */
    return format.replace(m[0], digits);
  }

  /* ----------------------------------------------------------------------
   * Charts
   * -------------------------------------------------------------------- */

  var charts = [];        /* { canvas, src, chart } for every canvas on the page */
  var chartStamp = {};    /* data file -> the version of it that is drawn */

  /* The canvas is hidden rather than replaced: the next round of data may
     have something to draw on it. */
  function empty(canvas, message) {
    var box = canvas.parentNode;
    var note = box.querySelector('.chart-empty');
    if (!note) {
      note = document.createElement('div');
      note.className = 'chart-empty';
      box.appendChild(note);
    }
    note.innerHTML = '<i class="fa-regular fa-chart-bar"></i><span>' + message + '</span>';
    canvas.style.display = 'none';
  }

  function unempty(canvas) {
    var note = canvas.parentNode.querySelector('.chart-empty');
    if (note) note.parentNode.removeChild(note);
    canvas.style.display = '';
  }

  /* WeeWX emits [[epoch_ms, value], ...]. A series it has aggregated has a
     null for every empty bin. Today's is not aggregated, and has nothing at
     all where there were no records: see `max_gap` below. */
  function toPoints(rows) {
    if (!Array.isArray(rows)) return [];
    var out = [];
    for (var i = 0; i < rows.length; i++) {
      var r = rows[i];
      if (Array.isArray(r) && r.length >= 2 && r[0] !== null) {
        out.push({ x: r[0], y: r[1] === undefined ? null : r[1] });
      }
    }
    return out;
  }

  /* A null wherever two points are further apart than `maxGap` milliseconds,
     which is what breaks a line there. Chart.js can be given the distance
     instead, as `spanGaps`, but 4.5.1 then joins every gap on the chart once
     a point with no value comes just before one of them.

     The distance is between one row and the next, whether or not they hold
     a value. Series taken from the same records then get their nulls at the
     same places, and the tooltip, which pairs points by position, goes on
     showing one moment. */
  function withBreaks(points, maxGap) {
    var out = [];
    for (var i = 0; i < points.length; i++) {
      if (i && points[i].x - points[i - 1].x > maxGap) {
        out.push({ x: points[i - 1].x + 1, y: null });
      }
      out.push(points[i]);
    }
    return out;
  }

  function hasAnyValue(points) {
    for (var i = 0; i < points.length; i++) {
      if (points[i].y !== null) return true;
    }
    return false;
  }

  /*
   * Tick formatting.
   *
   * Chart.js's `time` scale needs a date adapter, and none is vendored here —
   * so the x axis is `linear` over epoch-milliseconds and the ticks are
   * formatted by hand. Fewer moving parts, one less library to ship.
   */
  function tickFormatter(period) {
    return function (value) {
      var d = new Date(value);
      if (period === 'day') {
        return d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
      }
      if (period === 'week') {
        return d.toLocaleDateString([], { weekday: 'short' });
      }
      if (period === 'year') {
        return d.toLocaleDateString([], { month: 'short' });
      }
      return d.toLocaleDateString([], { month: 'short', day: 'numeric' });
    };
  }

  function datasetsFor(canvas, payload) {
    var kind = canvas.getAttribute('data-chart') || 'line';
    /* A file that names a `max_gap` has its lines broken wherever two points
       are further apart than that many milliseconds. Without one, only a
       null in the file breaks a line. Bars have nothing to break. */
    var maxGap = kind === 'line' && typeof payload.max_gap === 'number' && payload.max_gap > 0 ? payload.max_gap : 0;
    var names = (canvas.getAttribute('data-series') || '').split(',');
    var colors = (canvas.getAttribute('data-colors') || '').split(',');
    var units = payload.units || {};
    var formats = payload.formats || {};
    var datasets = [];

    for (var i = 0; i < names.length; i++) {
      var name = names[i].trim();
      if (!name) continue;

      var points = toPoints((payload.series || {})[name]);
      if (!hasAnyValue(points)) continue;
      if (maxGap) points = withBreaks(points, maxGap);

      var accent = COLORS[(colors[i] || 'blue').trim()] || COLORS.blue;
      var label = name + (units[name] ? ' (' + units[name].trim() + ')' : '');

      datasets.push({
        label: label,
        data: points,
        /* How a value of this series is printed in the tooltip, where the
           file says: whole degrees, for a line drawn from the decimals. */
        valueFormat: formats[name],
        borderColor: accent,
        backgroundColor: kind === 'bar' ? accent : fade(accent, 0.14),
        borderWidth: kind === 'bar' ? 0 : 2,
        fill: kind === 'line' && names.length === 1,
        tension: 0.3,
        pointRadius: 0,
        pointHoverRadius: 4,
        spanGaps: false
      });
    }
    return datasets;
  }

  /* The same lines, read off the same way: a format that has changed changes
     the tooltip and the axis labels, which only a new chart takes up. */
  function sameSeries(a, b) {
    if (a.length !== b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].label !== b[i].label || a[i].valueFormat !== b[i].valueFormat) return false;
    }
    return true;
  }

  /* Whether every line on a chart is read off in whole numbers. Its axis is
     then labelled in whole numbers too, not 2.5 and 3.5. */
  function allWhole(datasets) {
    for (var i = 0; i < datasets.length; i++) {
      if (!/%\.0f/.test(datasets[i].valueFormat || '')) return false;
    }
    return datasets.length > 0;
  }

  /* Draw one chart, or give the one already drawn its newer data. */
  function draw(entry, payload) {
    var canvas = entry.canvas;
    var kind = canvas.getAttribute('data-chart') || 'line';
    var datasets = datasetsFor(canvas, payload);

    /* The same lines as before: move the points and nothing else, so the
       chart does not blink and a line the reader switched off stays off. */
    if (entry.chart && datasets.length && sameSeries(entry.chart.data.datasets, datasets)) {
      for (var i = 0; i < datasets.length; i++) {
        entry.chart.data.datasets[i].data = datasets[i].data;
      }
      entry.chart.update('none');
      return;
    }

    if (entry.chart) {
      entry.chart.destroy();
      entry.chart = null;
    }
    if (!datasets.length) {
      empty(canvas, 'No data for this period');
      return;
    }
    unempty(canvas);

    entry.chart = new Chart(canvas.getContext('2d'), {
      type: kind,
      data: { datasets: datasets },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        interaction: { mode: 'index', intersect: false },
        scales: {
          x: {
            type: 'linear',
            grid: { color: GRID, drawBorder: false },
            ticks: {
              color: MUTED,
              maxRotation: 0,
              autoSkipPadding: 24,
              callback: tickFormatter(payload.period)
            }
          },
          y: {
            grid: { color: GRID, drawBorder: false },
            ticks: allWhole(datasets) ? { color: MUTED, precision: 0 } : { color: MUTED },
            beginAtZero: kind === 'bar'
          }
        },
        plugins: {
          legend: {
            display: datasets.length > 1,
            labels: { color: TEXT, usePointStyle: true, boxWidth: 8 }
          },
          tooltip: {
            backgroundColor: SURFACE,
            borderColor: BORDER,
            borderWidth: 1,
            titleColor: TEXT,
            bodyColor: TEXT,
            padding: 10,
            callbacks: {
              title: function (items) {
                if (!items.length) return '';
                return new Date(items[0].parsed.x).toLocaleString();
              },
              label: function (item) {
                var text = printf(item.dataset.valueFormat, item.parsed.y);
                return item.dataset.label + ': ' + (text === null ? item.formattedValue : text);
              }
            }
          }
        }
      }
    });
  }

  /* Fetch each data file once and hand it to every chart drawn from it. */
  function loadCharts() {
    var bySrc = {};
    charts.forEach(function (entry) {
      (bySrc[entry.src] = bySrc[entry.src] || []).push(entry);
    });

    Object.keys(bySrc).forEach(function (src) {
      request(src, 'no-cache', 'json').then(function (got) {
        /* The week, month and year files are rebuilt hourly at most. */
        if (got.stamp && got.stamp === chartStamp[src]) return;
        chartStamp[src] = got.stamp;
        bySrc[src].forEach(function (entry) {
          draw(entry, got.data || {});
        });
      }).catch(function (err) {
        /* A chart already on screen is better left alone than blanked
           because one request failed. */
        bySrc[src].forEach(function (entry) {
          if (!entry.chart) empty(entry.canvas, 'Chart data unavailable');
        });
        if (window.console) console.error(err);
      });
    });
  }

  function renderCharts() {
    if (typeof Chart === 'undefined' || !window.fetch) return;

    Chart.defaults.font.family = getComputedStyle(document.body).fontFamily;
    Chart.defaults.color = MUTED;

    var canvases = document.querySelectorAll('canvas[data-chart]');
    Array.prototype.forEach.call(canvases, function (canvas) {
      var src = canvas.getAttribute('data-src');
      if (src) charts.push({ canvas: canvas, src: src, chart: null });
    });
    loadCharts();
  }

  /* ----------------------------------------------------------------------
   * Current readings
   *
   * An element marked data-live="<observation>" holds that reading and
   * nothing else. Its text is replaced with the reading as the report itself
   * would print it, which is how both data files carry it.
   *
   *   data-live-field="ordinal"    the compass point of a direction
   *   data-live-format="%.0f lx"   the bare number, formatted here
   *   data-live-band="uv"          also carries a band: its colour, and its
   *                                name in the .band-word element beside it
   *   data-live="time"             when the readings were taken
   * -------------------------------------------------------------------- */

  /* [from, class, name], highest first; the last band also takes whatever is
     below it. The templates work the same bands out for themselves. */
  var BANDS = {
    /* UV index, WHO scale: index.html.tmpl. */
    uv: [
      [11, 'uv-extreme', 'Extreme'],
      [8, 'uv-veryhigh', 'Very high'],
      [6, 'uv-high', 'High'],
      [3, 'uv-moderate', 'Moderate'],
      [0, 'uv-low', 'Low']
    ],
    /* Signal-to-noise in dB, this skin's own rule of thumb: station.html.tmpl. */
    snr: [
      [20, 'snr-strong', 'Strong'],
      [12, 'snr-fair', 'Fair'],
      [0, 'snr-weak', 'Weak']
    ]
  };

  /* Written only when it differs: rewriting the same text every few seconds
     would drop whatever the reader had selected. */
  function put(el, text) {
    if (el.textContent !== text) el.textContent = text;
  }

  function textOf(el, reading) {
    var field = el.getAttribute('data-live-field');
    if (field) return typeof reading[field] === 'string' ? reading[field] : null;

    var format = el.getAttribute('data-live-format');
    if (format) return printf(format, reading.raw);
    return typeof reading.text === 'string' ? reading.text : null;
  }

  function setBand(el, bands, value) {
    if (typeof value !== 'number') return;
    var band = bands[bands.length - 1];
    for (var i = bands.length - 1; i >= 0; i--) {         /* lowest band first */
      el.classList.remove(bands[i][1]);
      if (value >= bands[i][0]) band = bands[i];
    }
    el.classList.add(band[1]);

    var word = el.parentNode.querySelector('.band-word');
    if (!word) {
      word = document.createElement('span');
      word.className = 'band-word';
      el.parentNode.insertBefore(word, el.nextSibling);
    }
    put(word, band[2]);
  }

  /* A value's band word is as old as the value, and dims with it. */
  function setStale(el, on) {
    var both = [el];
    if (el.hasAttribute('data-live-band')) both.push(el.parentNode.querySelector('.band-word'));
    both.forEach(function (one) {
      if (!one) return;
      if (on) one.classList.add('live-stale');
      else one.classList.remove('live-stale');
    });
  }

  /* `dim` marks what this source has no reading for, for when the source is
     the stand-in and the rest of the page is older than it looks. */
  function fill(readings, timeText, dim) {
    var els = document.querySelectorAll('[data-live]');
    Array.prototype.forEach.call(els, function (el) {
      var name = el.getAttribute('data-live');
      if (name === 'time') {
        if (timeText) put(el, timeText);
        return;
      }
      var reading = readings[name];
      var text = reading ? textOf(el, reading) : null;
      if (text === null) {
        setStale(el, dim);
        return;
      }
      setStale(el, false);
      put(el, text);
      var bands = el.getAttribute('data-live-band');
      if (bands && BANDS.hasOwnProperty(bands)) setBand(el, BANDS[bands], reading.raw);
    });
  }

  /* ----------------------------------------------------------------------
   * Which source, and the banner that says so
   * -------------------------------------------------------------------- */

  function humanAge(seconds) {
    var d = Math.floor(seconds / 86400);
    var h = Math.floor((seconds % 86400) / 3600);
    var m = Math.floor((seconds % 3600) / 60);
    if (d > 0) return d + (d === 1 ? ' day, ' : ' days, ') + h + ' h';
    if (h > 0) return h + ' h ' + m + ' min';
    return m + ' min';
  }

  /* The time of day, with the date only when it is not today's. */
  function when(seconds) {
    var d = new Date(seconds * 1000);
    var time = d.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
    if (d.toDateString() === new Date().toDateString()) return time;
    return d.toLocaleDateString([], { month: 'short', day: 'numeric' }) + ', ' + time;
  }

  var shown = '';

  function banner(icon, title, detail) {
    var html = !title ? '' :
      '<span class="icon"><i class="fa-solid ' + icon + '"></i></span>' +
      '<span><strong>' + title + '</strong>' +
      '<span class="detail">' + detail + '</span></span>';
    if (html === shown) return;
    shown = html;
    host.className = html ? 'staleness-banner' : 'd-none';
    host.innerHTML = html;
  }

  function show() {
    if (!host) return;

    var t = now();
    var heard = Math.max(reportTime, live ? live.time : 0);   /* the radio's last word */
    var silent = t - heard;

    /* The feed runs a few seconds ahead of the report. One that has fallen
       behind it has stopped being written, and the page's own values are
       then the newer ones. */
    var feed = live && live.time >= reportTime - 60;

    if (heard && silent <= OUTAGE_AFTER) {
      banner();
      fill(feed ? live.obs : {}, feed ? live.time_text : null, false);
      return;
    }

    if (!reachable && heard) {
      fill(feed ? live.obs : {}, feed ? live.time_text : null, false);
      banner('fa-plug-circle-xmark', 'This page has lost touch with the station',
        'It cannot fetch new readings from the station&rsquo;s web server. ' +
        'What is shown was current at ' + when(heard) + '.');
      return;
    }

    var standIn = backup && t - backup.time <= BACKUP_MAX_AGE && backup.time - heard > BACKUP_LEAD;

    if (standIn) {
      fill(backup.obs, backup.time_text, true);
      banner('fa-tower-broadcast',
        heard ? 'Nothing from the sensor&rsquo;s radio for ' + humanAge(silent)
              : 'Nothing from the sensor&rsquo;s radio yet',
        'Current readings are Weather Underground&rsquo;s copy, taken at ' + when(backup.time) + '. ' +
        (heard ? 'Highs, lows, charts and anything shown dimmed stop at ' + when(heard) + ', when the radio was last heard.'
               : 'Highs, lows and charts start once the radio is heard.'));
      return;
    }

    fill(feed ? live.obs : {}, feed ? live.time_text : null, false);

    /* No time at all means the database has no records whatsoever. */
    if (!heard) {
      banner('fa-circle-exclamation', 'No observations in the database',
        'WeeWX has not recorded any data yet.');
      return;
    }
    banner('fa-triangle-exclamation', 'Data is ' + humanAge(silent) + ' old',
      'The last observation reached WeeWX at ' + when(heard) + '. ' +
      (backup ? 'Weather Underground has nothing newer either. ' : '') +
      'Values below are the most recent on record, not current conditions.');
  }

  /* ----------------------------------------------------------------------
   * Polling
   *
   * Two loops, both stopped while the tab is in the background: a quick one
   * for data/live.json, and a slow one for the page itself and the stand-in.
   * Neither rejects; a request that fails is simply tried again next time.
   * -------------------------------------------------------------------- */

  var liveTimer = null;
  var liveBusy = false;
  var pageTimer = null;
  var pageBusy = false;
  var backupDue = 0;

  /* Resolves with the number of seconds to wait before asking again. */
  function readLive() {
    return request('data/live.json', 'no-store', 'json').then(function (got) {
      var data = got.data;
      if (data && typeof data.time === 'number' && data.obs) live = data;
      return LIVE_EVERY;
    }, function () {
      /* Not there, or not reachable. If the feed is not installed there is
         nothing to wait for, and no point asking every few seconds. */
      return live ? LIVE_EVERY : Math.max(LIVE_EVERY, 60);
    });
  }

  function pollLive() {
    clearTimeout(liveTimer);
    if (liveBusy || document.hidden) return;
    liveBusy = true;
    readLive().then(function (wait) {
      liveBusy = false;
      show();
      liveTimer = setTimeout(pollLive, wait * 1000);
    });
  }

  function readBackup() {
    if (Date.now() < backupDue) return Promise.resolve();
    return request('data/wu.json', 'no-cache', 'json').then(function (got) {
      var data = got.data;
      backup = data && typeof data.time === 'number' && data.obs ? data : null;
    }, function () {
      /* What was read before still carries its own time. */
      backupDue = Date.now() + 120000;
    });
  }

  /* The page as WeeWX has generated it since: if it holds a newer record,
     take the contents of every data-slot from it. */
  function readPage() {
    return request(location.href.split('#')[0], 'no-cache', 'text').then(function (got) {
      var doc = new DOMParser().parseFromString(got.data, 'text/html');
      var marker = doc.getElementById('staleness');
      var time = marker ? parseInt(marker.getAttribute('data-obs-time'), 10) : NaN;
      if (isNaN(time) || time <= reportTime) return;
      /* The footer is the last thing written: without it the page is not
         all there, and next time it will be. */
      if (!doc.querySelector('[data-slot="generated"]')) return;

      var slots = document.querySelectorAll('[data-slot]');
      Array.prototype.forEach.call(slots, function (slot) {
        var fresh = doc.querySelector('[data-slot="' + slot.getAttribute('data-slot') + '"]');
        if (fresh && fresh.innerHTML !== slot.innerHTML) slot.innerHTML = fresh.innerHTML;
      });
      reportTime = time;
      /* A new page means a new archive record, and a new point on today's
         charts. The week, month and year files are asked after as well, and
         mostly answer that they have not changed. */
      loadCharts();
    }, function () {});
  }

  function pollPage() {
    clearTimeout(pageTimer);
    if (pageBusy || document.hidden) return;
    pageBusy = true;
    Promise.all([readPage(), readBackup()]).then(function () {
      pageBusy = false;
      show();
      pageTimer = setTimeout(pollPage, REFRESH_EVERY * 1000);
    });
  }

  /* -------------------------------------------------------------------- */

  function init() {
    renderCharts();
    if (!host) return;
    if (!window.fetch || !window.Promise) {
      show();
      return;
    }

    /* Both files before the first verdict, so that a page opened during an
       outage does not show one banner and then another. */
    liveBusy = pageBusy = true;
    Promise.all([LIVE_EVERY > 0 ? readLive() : null, readBackup()]).then(function (waits) {
      liveBusy = pageBusy = false;
      show();
      if (LIVE_EVERY > 0) liveTimer = setTimeout(pollLive, waits[0] * 1000);
      if (REFRESH_EVERY > 0) pageTimer = setTimeout(pollPage, REFRESH_EVERY * 1000);
    });

    /* The banner has to appear on a page that is only being looked at. Not
       while a request is out, though: a tab coming back from the background
       would show an outage for the moment it takes to learn there is none. */
    setInterval(function () {
      if (!document.hidden && !liveBusy && !pageBusy) show();
    }, 20000);

    /* A tab that was in the background did not poll; catch up at once. */
    document.addEventListener('visibilitychange', function () {
      if (document.hidden) return;
      if (LIVE_EVERY > 0) pollLive();
      if (REFRESH_EVERY > 0) pollPage();
    });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
