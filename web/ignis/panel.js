// Panel script (layout _layout.html) — replaces the earlier inline scripts.
// Wave effect, light/dark toggle, full screen, htmx navigation, [data-confirm] confirmations
// and the file drop zone (.file-drop). Tabs, accordions, modals and dropdowns — bootstrap.bundle.
(function () {
  'use strict';

  if (window.Waves) { Waves.attach('.btn-wave', ['waves-light']); Waves.init(); }

  // Theme link-buttons (href="#") must not scroll to the top or append "#" to the URL.
  document.addEventListener('click', function (e) {
    var a = e.target.closest && e.target.closest('a[href="#"]');
    if (a) e.preventDefault();
  });

  // Action confirmation: <button data-confirm="Are you sure?"> — also works in content loaded by htmx.
  document.addEventListener('click', function (e) {
    var el = e.target.closest && e.target.closest('[data-confirm]');
    if (el && !confirm(el.dataset.confirm)) { e.preventDefault(); e.stopImmediatePropagation(); }
  }, true);

  // LIGHT/DARK toggle — the same localStorage keys as theme.js and the theme's main.js.
  var toggleButton = document.querySelector('.layout-setting');
  if (toggleButton) toggleButton.addEventListener('click', function () {
    var H = document.documentElement, dark = H.getAttribute('data-theme-mode') === 'dark';
    var mode = dark ? 'light' : 'dark';
    H.setAttribute('data-theme-mode', mode);
    H.setAttribute('data-header-styles', mode);
    H.setAttribute('data-menu-styles', mode);
    try {
      if (dark) {
        localStorage.removeItem('ignis-dark');
        localStorage.removeItem('ignis-menu');
        localStorage.removeItem('ignis-header');
      } else {
        localStorage.setItem('ignis-dark', 'true');
        localStorage.setItem('ignis-menu', 'dark');
        localStorage.setItem('ignis-header', 'dark');
      }
    } catch (e) {}
  });

  var fullscreen = document.querySelector('.header-fullscreen');
  if (fullscreen) fullscreen.addEventListener('click', function () {
    if (document.fullscreenElement) { document.exitFullscreen(); }
    else { document.documentElement.requestFullscreen(); }
  });

  // Drop zone: puts the file into the <input> and leaves submitting to the form (POST → redirect).
  // data-suffix — text after the file name (e.g. "save the section to upload").
  function dropZone(s) {
    var input = s.querySelector('input[type="file"]'), label = s.querySelector('.file-name');
    if (!input || input.disabled || s.dataset.ready) return;
    s.dataset.ready = '1';
    function show() {
      var n = input.files.length;
      if (!n) return;
      label.textContent = n === 1
        ? input.files[0].name + ' (' + Math.round(input.files[0].size / 1024) + ' KB)' +
          (s.dataset.suffix ? ' — ' + s.dataset.suffix : '')
        : n + ' files selected';
      label.classList.add('text-success');
    }
    s.addEventListener('click', function (e) { if (e.target !== input) input.click(); });
    input.addEventListener('change', show);
    ['dragenter', 'dragover'].forEach(function (z) {
      s.addEventListener(z, function (e) { e.preventDefault(); s.classList.add('over'); });
    });
    ['dragleave', 'drop'].forEach(function (z) {
      s.addEventListener(z, function (e) { e.preventDefault(); s.classList.remove('over'); });
    });
    s.addEventListener('drop', function (e) {
      if (e.dataTransfer.files.length) { input.files = e.dataTransfer.files; show(); }
    });
  }
  function dropZones(root) { root.querySelectorAll('.file-drop').forEach(dropZone); }
  dropZones(document);

  // Navigation without reload: menu and top bar stay, only #content is swapped.
  if (!window.htmx) return;
  function markActive() {
    var path = location.pathname;
    document.querySelectorAll('.side-menu__item[hx-get]').forEach(function (a) {
      a.classList.toggle('active', a.getAttribute('hx-get') === path);
    });
  }
  // Tab title from the menu item label; brand from data-brand (site data does not go into JS code).
  document.body.addEventListener('htmx:afterSwap', function (e) {
    dropZones(e.target);
    if (e.target.id !== 'content') return;
    markActive();
    var current = document.querySelector('.side-menu__item.active .side-menu__label');
    if (current) document.title = current.textContent.trim() + ' — ' + (document.body.dataset.brand || '');
    window.scrollTo({ top: 0, behavior: 'instant' });
  });
  window.addEventListener('popstate', markActive);
  // Error (≥400) = full navigation to the requested URL — the server shows the error page.
  document.body.addEventListener('htmx:beforeSwap', function (e) {
    if (e.detail.xhr.status >= 400) { e.detail.shouldSwap = false; window.location = e.detail.pathInfo.requestPath; }
  });
})();
