// Light/dark theme BEFORE the first paint — loaded synchronously in <head> (no defer).
// The localStorage keys are the ones the theme's main.js looks for; on the first visit — dark.
// We set the mode attribute here ourselves, so main.js can load with defer without a flash of light background.
(function () {
  try {
    var LS = localStorage, H = document.documentElement;
    // htmx snapshots from before historyCacheSize=0 (both layouts: panel and sign-in, also after sign-out)
    LS.removeItem('htmx-history-cache');
    if (!LS.getItem('ignis_theme')) {
      LS.setItem('ignis-dark', 'true');
      LS.setItem('ignis-menu', 'dark');
      LS.setItem('ignis-header', 'dark');
      LS.setItem('ignis_theme', '1');
    }
    if (LS.getItem('ignis-dark')) {
      H.setAttribute('data-theme-mode', 'dark');
      H.setAttribute('data-header-styles', LS.getItem('ignis-header') || 'dark');
      H.setAttribute('data-menu-styles', LS.getItem('ignis-menu') || 'dark');
    }
    H.setAttribute('data-page-style',
      LS.getItem('ignis-classic') ? 'classic' : LS.getItem('ignis-regular') ? 'regular' : 'modern');
    H.setAttribute('data-width', LS.getItem('ignis-boxed') ? 'boxed' : 'fullwidth');
  } catch (e) {}
})();
