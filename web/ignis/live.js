// Live view: <section id="x" data-live="5"> + inside it (or anywhere) <input type="checkbox" data-live-toggle="x">.
// When the toggle is checked: every N seconds it fetches the current URL and replaces the inside of [data-live-content] in the section
// with the same fragment from the response (on X-Ignis-Live the server returns just the content, without the panel shell; at least 5 s). Background tab = pause. Toggle state in sessionStorage (per path).
// Without JS the toggle is hidden (hidden in HTML, JS shows it) — the page works as usual.
(function () {
  'use strict';
  function start(section) {
    var p = document.querySelector('[data-live-toggle="' + section.id + '"]');
    if (!p) return;
    var wrapper = p.closest('[hidden]');
    if (wrapper) wrapper.hidden = false;
    var every = Math.max(5, parseInt(section.getAttribute('data-live'), 10) || 5) * 1000;
    var storageKey = 'live:' + location.pathname + ':' + section.id, timer = null, busy = false;
    var status = section.querySelector('[data-live-status]');
    function refresh() {
      if (busy || document.hidden) return;
      busy = true;
      fetch(location.href, { credentials: 'same-origin', headers: { 'X-Ignis-Live': '1' } })
        .then(function (r) { return r.ok ? r.text() : Promise.reject(r.status); })
        .then(function (html) {
          var fresh = new DOMParser().parseFromString(html, 'text/html').getElementById(section.id);
          var z = fresh && fresh.querySelector('[data-live-content]'), target = section.querySelector('[data-live-content]');
          // nodes from the DOMParser document are moved directly — innerHTML would parse them a second time (mXSS)
          if (z && target && !z.isEqualNode(target)) target.replaceChildren.apply(target, Array.prototype.slice.call(z.childNodes));
          if (status) status.textContent = new Date().toLocaleTimeString(document.documentElement.lang || undefined, { hour: '2-digit', minute: '2-digit', second: '2-digit' });
        })
        .catch(function () {})
        .then(function () { busy = false; });
    }
    function apply() {
      clearInterval(timer);
      timer = p.checked ? setInterval(refresh, every) : null;
      section.classList.toggle('live-on', p.checked);
      try { sessionStorage.setItem(storageKey, p.checked ? '1' : ''); } catch (e) {}
      if (p.checked) refresh();
    }
    try { p.checked = sessionStorage.getItem(storageKey) === '1'; } catch (e) {}
    p.addEventListener('change', apply);
    document.addEventListener('visibilitychange', function () { if (!document.hidden && p.checked) refresh(); });
    apply();
  }
  function init() { document.querySelectorAll('[data-live][id]').forEach(start); }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init); else init();
})();
