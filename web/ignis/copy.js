// Copy to clipboard: <button type="button" data-copy="text"> or data-copy-from="#id" (value/textContent of the element).
// After copying, the button label changes for 1.5 s to data-copied ("✓" by default); the message for screen readers
// goes through a shared aria-live region. Without JS the button is hidden (hidden in HTML) — the text is visible for selection anyway.
(function () {
  'use strict';
  var live;
  function announce(t) {
    if (!live) {
      live = document.createElement('div');
      live.setAttribute('aria-live', 'polite');
      live.className = 'sr-only';
      live.style.cssText = 'position:absolute;width:1px;height:1px;overflow:hidden;clip:rect(0 0 0 0)';
      document.body.appendChild(live);
    }
    live.textContent = '';
    setTimeout(function () { live.textContent = t; }, 30);
  }
  function textOf(b) {
    if (b.hasAttribute('data-copy')) return b.getAttribute('data-copy');
    var e = document.querySelector(b.getAttribute('data-copy-from'));
    return e ? ('value' in e ? e.value : e.textContent) : '';
  }
  function init() {
    document.querySelectorAll('[data-copy], [data-copy-from]').forEach(function (b) { b.hidden = false; });
    document.addEventListener('click', function (ev) {
      var b = ev.target.closest && ev.target.closest('[data-copy], [data-copy-from]');
      if (!b || !navigator.clipboard) return;
      ev.preventDefault();
      navigator.clipboard.writeText(textOf(b)).then(function () {
        var ok = b.getAttribute('data-copied') || '✓';
        // the original nodes (icon + text) are put aside and put back — without parsing HTML again
        if (!b._label) b._label = Array.prototype.slice.call(b.childNodes);
        b.textContent = ok;
        announce(ok);
        clearTimeout(b._timer);
        b._timer = setTimeout(function () { b.replaceChildren.apply(b, b._label); b._label = null; }, 1500);
      });
    });
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init); else init();
})();
