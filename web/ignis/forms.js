// Form behaviours without on* attributes (CSP script-src 'self'):
//   <select data-submit>            — changing the value submits the form (the "rows per page" pager),
//   <a href="/back" data-back>      — goes back in history, and without history follows href.
(function () {
  'use strict';
  document.addEventListener('change', function (e) {
    var s = e.target.closest && e.target.closest('[data-submit]');
    if (s && s.form) s.form.submit();
  });
  document.addEventListener('click', function (e) {
    var a = e.target.closest && e.target.closest('[data-back]');
    if (a && history.length > 1) { e.preventDefault(); history.back(); }
  });
})();
