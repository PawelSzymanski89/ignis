// Row action menu: <details class="row-menu">. Without JS it works like a plain details.
// With JS: one open at a time, a click outside the menu and Esc close it (focus returns to "⋯"), ↑↓ move between items.
// The list is position: fixed at "⋯", so a scrolled table (.table-wrap) does not clip it; on scroll it follows "⋯".
(function () {
  'use strict';
  function place(d) {
    var l = d.querySelector('.row-menu-list'), r = d.querySelector('summary').getBoundingClientRect();
    if (!l) return;
    l.style.position = 'fixed'; l.style.right = 'auto';
    var w = l.offsetWidth, h = l.offsetHeight;
    l.style.left = Math.max(8, Math.min(r.right - w, window.innerWidth - w - 8)) + 'px';
    l.style.top = (r.bottom + 4 + h > window.innerHeight - 8 && r.top - 4 - h > 8 ? r.top - 4 - h : r.bottom + 4) + 'px';
  }
  function repositionOpen(e) {
    if (e && e.target.closest && e.target.closest('.row-menu-list')) return;
    document.querySelectorAll('details.row-menu[open]').forEach(place);
  }
  window.addEventListener('resize', repositionOpen);
  document.addEventListener('scroll', repositionOpen, true);
  function items(d) { return Array.prototype.slice.call(d.querySelectorAll('.row-menu-list button, .row-menu-list a, .row-menu-list select')); }
  document.addEventListener('toggle', function (e) {
    var d = e.target;
    if (!d.classList || !d.classList.contains('row-menu') || !d.open) return;
    document.querySelectorAll('details.row-menu[open]').forEach(function (x) { if (x !== d) x.open = false; });
    place(d);
    var p = items(d); if (p.length) p[0].focus({ preventScroll: true });
  }, true);
  document.addEventListener('click', function (e) {
    document.querySelectorAll('details.row-menu[open]').forEach(function (d) { if (!d.contains(e.target)) d.open = false; });
  });
  document.addEventListener('keydown', function (e) {
    var d = e.target.closest && e.target.closest('details.row-menu[open]');
    if (!d) return;
    if (e.key === 'Escape') { d.open = false; d.querySelector('summary').focus(); e.preventDefault(); return; }
    if (e.key !== 'ArrowDown' && e.key !== 'ArrowUp' || e.target.tagName === 'SELECT') return;
    var p = items(d), i = p.indexOf(e.target);
    if (i < 0) return;
    p[(i + (e.key === 'ArrowDown' ? 1 : p.length - 1)) % p.length].focus({ preventScroll: true }); e.preventDefault();
  });
})();
