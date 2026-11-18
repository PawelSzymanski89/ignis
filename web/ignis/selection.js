// Selecting list rows for bulk actions. Within [data-selection]:
//   <input type="checkbox" data-select-all>  — checks / unchecks all [data-select] (indeterminate when some),
//   <input type="checkbox" data-select …>     — a row (name/form set by the app, e.g. name="sel_<id>" form="bulk"),
//   [data-selected-bar]                       — action bar: hidden when nothing is selected,
//   [data-selected-count]                     — number of selected rows.
// Without JS the bar is visible and checkboxes work normally — the action gets what was checked.
(function () {
  'use strict';
  function scope(z) {
    var all = z.querySelector('[data-select-all]');
    var bar = z.querySelector('[data-selected-bar]');
    var count = z.querySelector('[data-selected-count]');
    function rows() { return Array.prototype.slice.call(z.querySelectorAll('[data-select]')); }
    function refresh() {
      var w = rows(), n = w.filter(function (c) { return c.checked; }).length;
      if (count) count.textContent = String(n);
      if (bar) bar.hidden = n === 0;
      if (all) {
        all.checked = n > 0 && n === w.length;
        all.indeterminate = n > 0 && n < w.length;
      }
      w.forEach(function (c) {
        var tr = c.closest('tr');
        if (tr) tr.classList.toggle('selected', c.checked);
      });
    }
    if (all) {
      all.hidden = false;
      all.addEventListener('change', function () {
        rows().forEach(function (c) { c.checked = all.checked; });
        refresh();
      });
    }
    z.addEventListener('change', function (e) {
      if (e.target && e.target.hasAttribute('data-select')) refresh();
    });
    refresh();
  }
  function start() { Array.prototype.forEach.call(document.querySelectorAll('[data-selection]'), scope); }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start); else start();
})();
