(function () {
  'use strict';
  var API_URL = 'api/status';
  var REFRESH_MS = 30000;
  var STATUS_TEXT = { operational: 'Operational', degraded: 'Degraded', major_outage: 'Major outage', unknown: 'Unknown' };
  var lastData = null;
  var lastUpdated = null;
  var STALE_AFTER_S = 180;
  var FETCH_TIMEOUT_MS = 10000;
  var timer = null;

  function known(s) { return Object.prototype.hasOwnProperty.call(STATUS_TEXT, s); }

  function $(id) { return document.getElementById(id); }

  function el(tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text !== undefined && text !== null) e.textContent = text;
    return e;
  }

  function statusClass(s) { return known(s) ? s : 'unknown'; }

  function pad(n) { return (n < 10 ? '0' : '') + n; }

  // unix seconds -> "HH:MM"
  function formatClock(sec) {
    var d = new Date(sec * 1000);
    return pad(d.getHours()) + ':' + pad(d.getMinutes());
  }

  // unix seconds -> "2026-10-09 14:05" local time
  function formatTime(sec) {
    var d = new Date(sec * 1000);
    return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate()) + ' ' + formatClock(sec);
  }

  function dayPercent(d) { return d.total > 0 ? 100 * d.ok / d.total : null; }

  function barClass(d) {
    if (!d || !d.total) return 'bar';
    if (d.ok >= d.total) return 'bar up';
    return d.ok / d.total >= 0.99 ? 'bar part' : 'bar down';
  }

  function barTitle(d) {
    var p = dayPercent(d);
    return d.day + ': ' + (p === null ? 'no data' : (p >= 100 ? '100%' : p.toFixed(2) + '%'));
  }

  function renderBars(c) {
    var days = c.days || [];
    var wrap = el('div', 'bars');
    wrap.setAttribute('role', 'img');
    var up = c.uptime_90d;
    wrap.setAttribute('aria-label', c.name + ': ' + (up === null || up === undefined
      ? 'no uptime data for the last ' + days.length + ' days'
      : up + '% uptime over the last ' + days.length + ' days'));
    days.forEach(function (d) {
      var b = el('div', barClass(d));
      b.title = barTitle(d);
      wrap.appendChild(b);
    });
    return wrap;
  }

  function renderComponent(c) {
    var box = el('div', 'comp');
    var row = el('div', 'row');
    row.appendChild(el('span', null, c.name));
    var st = el('span', 'st ' + statusClass(c.status), STATUS_TEXT[statusClass(c.status)]);
    if (c.detail) st.title = c.detail;
    row.appendChild(st);
    box.appendChild(row);
    box.appendChild(renderBars(c));
    var legend = el('div', 'legend');
    legend.appendChild(el('span', null, (c.days ? c.days.length : 90) + ' days ago'));
    var up = c.uptime_90d;
    legend.appendChild(el('span', null, up === null || up === undefined ? '' : up + '% uptime'));
    legend.appendChild(el('span', null, 'Today'));
    box.appendChild(legend);
    return box;
  }

  function renderGroup(g) {
    var box = el('section', 'group');
    var h = el('h2');
    h.appendChild(el('span', null, g.name));
    h.appendChild(el('span', 'st ' + statusClass(g.status), STATUS_TEXT[statusClass(g.status)]));
    box.appendChild(h);
    (g.components || []).forEach(function (c) { box.appendChild(renderComponent(c)); });
    return box;
  }

  function renderIncident(i) {
    var box = el('div', 'inc');
    var b = el('b', null, i.title + (i.component ? ' (' + i.component + ')' : ''));
    b.appendChild(el('span', 'tag' + (i.resolved ? '' : ' open'), i.resolved ? 'Resolved' : 'Ongoing'));
    box.appendChild(b);
    box.appendChild(el('span', 'when', 'Started ' + formatTime(i.started) +
      (i.resolved ? ' · resolved ' + formatTime(i.resolved) : '')));
    return box;
  }

  function render(data) {
    var title = data.title || 'Status';
    document.title = title;
    $('title').textContent = title;
    var banner = $('banner');
    var o = data.overall || {};
    banner.className = 'banner ' + statusClass(o.status);
    banner.textContent = o.text || STATUS_TEXT[statusClass(o.status)];

    var groups = $('groups');
    groups.textContent = '';
    (data.groups || []).forEach(function (g) { groups.appendChild(renderGroup(g)); });

    var incs = $('incidents');
    incs.textContent = '';
    if (data.incidents && data.incidents.length) {
      data.incidents.forEach(function (i) { incs.appendChild(renderIncident(i)); });
    } else {
      incs.appendChild(el('p', 'muted', 'No incidents recorded.'));
    }

    var when = data.generated_at ? formatTime(data.generated_at) : formatTime(Date.now() / 1000);
    $('updated').textContent = 'Updated ' + when;
  }

  function showNotice(show, text) {
    var n = $('notice');
    if (show) {
      n.textContent = text || ('Status data could not be refreshed · last updated ' +
        (lastUpdated ? formatClock(lastUpdated) : 'never'));
    }
    n.hidden = !show;
  }

  function fetchStatus() {
    var opts = { cache: 'no-store', headers: { Accept: 'application/json' } };
    // Do not hang forever on a stalled connection (older browsers without AbortSignal.timeout: no timeout).
    if (typeof AbortSignal !== 'undefined' && AbortSignal.timeout) opts.signal = AbortSignal.timeout(FETCH_TIMEOUT_MS);
    var now = Date.now() / 1000;
    return fetch(API_URL, opts)
      .then(function (r) {
        if (!r.ok) throw new Error('HTTP ' + r.status);
        // Server time from the Date header, so a wrong clock on the visitor's device cannot fake staleness.
        var d = Date.parse(r.headers.get('Date'));
        if (!isNaN(d)) now = d / 1000;
        return r.json();
      })
      .then(function (data) {
        render(data);
        lastData = data;
        lastUpdated = Date.now() / 1000;
        // The server may answer from its last good copy while the monitor itself is down: say so.
        var age = data.generated_at ? now - data.generated_at : 0;
        showNotice(age > STALE_AFTER_S, 'The status monitor is not reporting. Showing the last known data from ' +
          formatClock(data.generated_at) + '.');
      })
      .catch(function () {
        showNotice(true);
        if (!lastData) {
          $('banner').className = 'banner unknown';
          $('banner').textContent = 'Status unavailable';
        }
      });
  }

  function init() {
    var g = $('groups');
    for (var k = 0; k < 2; k++) g.appendChild(el('div', 'skeleton'));
    fetchStatus().then(function () {
      // remove skeletons if first load failed (render() clears them on success)
      if (!lastData) g.textContent = '';
    });
    schedule();
    // No polling in a hidden tab; refresh as soon as it becomes visible again.
    document.addEventListener('visibilitychange', function () {
      if (document.hidden) { clearInterval(timer); timer = null; return; }
      fetchStatus();
      schedule();
    });
  }

  function schedule() {
    if (timer === null && !document.hidden) timer = setInterval(fetchStatus, REFRESH_MS);
  }

  init();
})();
