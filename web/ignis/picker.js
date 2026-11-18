// Picker: <select data-picker> with search (long lists — projects, countries…).
// The select stays in the form (value, change, works without JS); what is visible is a button
// with the current value and a panel: a search field (combobox) + a list (listbox).
// Keyboard: Enter/Space/↓ opens; in the field ↑↓ PgUp PgDn Home End, Enter chooses, Esc closes.
// Select attributes: aria-label (name), data-search (placeholder), data-empty ("No results").
(function () {
  'use strict';
  var counter = 0;
  var foldAccents = function (s) {
    return s.normalize('NFD').replace(/[\u0300-\u036f]/g, '').replace(/ł/g, 'l').replace(/Ł/g, 'L').toLowerCase(); // ł/Ł have no NFD decomposition
  };

  function picker(sel) {
    if (sel.dataset.pickerReady) return;
    sel.dataset.pickerReady = '1';
    var id = 'picker' + (++counter);
    var name = sel.getAttribute('aria-label') || '';
    var options = Array.prototype.map.call(sel.options, function (o, i) {
      return { i: i, text: o.textContent, key: foldAccents(o.textContent + ' ' + o.value) };
    });

    var root = document.createElement('div');
    root.className = 'picker';
    var btn = document.createElement('button');
    btn.type = 'button';
    btn.className = 'picker-button';
    btn.setAttribute('aria-haspopup', 'listbox');
    btn.setAttribute('aria-expanded', 'false');
    btn.setAttribute('aria-controls', id + '-panel');
    var label = document.createElement('span');
    btn.appendChild(label);
    if (name) btn.setAttribute('aria-label', name);

    var panel = document.createElement('div');
    panel.className = 'picker-panel';
    panel.id = id + '-panel';
    panel.hidden = true;
    var search = document.createElement('input');
    search.type = 'search';
    search.className = 'picker-search';
    search.autocomplete = 'off';
    search.spellcheck = false;
    search.placeholder = sel.dataset.search || '';
    search.setAttribute('role', 'combobox');
    search.setAttribute('aria-autocomplete', 'list');
    search.setAttribute('aria-expanded', 'true');
    search.setAttribute('aria-controls', id + '-list');
    if (name) search.setAttribute('aria-label', name);
    var list = document.createElement('ul');
    list.className = 'picker-list';
    list.id = id + '-list';
    list.setAttribute('role', 'listbox');
    if (name) list.setAttribute('aria-label', name);
    var status = document.createElement('div');
    status.className = 'picker-status';
    status.setAttribute('role', 'status');
    panel.appendChild(search);
    panel.appendChild(list);
    panel.appendChild(status);

    sel.hidden = true;
    sel.setAttribute('tabindex', '-1');
    sel.parentNode.insertBefore(root, sel.nextSibling);
    root.appendChild(btn);
    root.appendChild(panel);

    var visible = [];
    var active = -1;

    function refreshLabel() {
      var o = sel.options[sel.selectedIndex];
      label.textContent = o ? o.textContent : '';
    }

    function setActive(n) {
      var el = list.children;
      if (active >= 0 && el[active]) el[active].classList.remove('active');
      active = visible.length ? Math.max(0, Math.min(n, visible.length - 1)) : -1;
      if (active < 0) { search.removeAttribute('aria-activedescendant'); return; }
      el[active].classList.add('active');
      search.setAttribute('aria-activedescendant', el[active].id);
      el[active].scrollIntoView({ block: 'nearest' });
    }

    function filter() {
      var q = foldAccents(search.value.trim());
      visible = options.filter(function (o) { return !q || o.key.indexOf(q) >= 0; });
      list.textContent = '';
      var start = 0;
      visible.forEach(function (o, n) {
        var li = document.createElement('li');
        li.id = id + '-o' + o.i;
        li.setAttribute('role', 'option');
        li.textContent = o.text;
        var selected = o.i === sel.selectedIndex;
        li.setAttribute('aria-selected', selected ? 'true' : 'false');
        if (selected) start = n;
        li.addEventListener('mousedown', function (e) { e.preventDefault(); });
        li.addEventListener('click', function () { choose(o); });
        list.appendChild(li);
      });
      status.textContent = visible.length ? '' : (sel.dataset.empty || '—');
      status.classList.toggle('empty', !visible.length);
      active = -1;
      setActive(q ? 0 : start);
    }

    function open() {
      if (!panel.hidden) return;
      panel.style.setProperty('--picker-top', Math.max(8, btn.getBoundingClientRect().bottom + 6) + 'px');
      panel.hidden = false;
      btn.setAttribute('aria-expanded', 'true');
      root.classList.add('open');
      search.value = '';
      filter();
      search.focus();
    }

    function close(focus) {
      if (panel.hidden) return;
      panel.hidden = true;
      btn.setAttribute('aria-expanded', 'false');
      root.classList.remove('open');
      if (focus) btn.focus();
    }

    function choose(o) {
      close(true);
      if (o.i === sel.selectedIndex) return;
      sel.selectedIndex = o.i;
      refreshLabel();
      sel.dispatchEvent(new Event('change', { bubbles: true }));
    }

    btn.addEventListener('click', function () { if (panel.hidden) open(); else close(true); });
    btn.addEventListener('keydown', function (e) {
      if (e.key === 'ArrowDown' || e.key === 'ArrowUp') { e.preventDefault(); open(); }
    });
    search.addEventListener('input', filter);
    search.addEventListener('keydown', function (e) {
      var jump = Math.max(1, Math.floor(list.clientHeight / 36));
      switch (e.key) {
        case 'ArrowDown': e.preventDefault(); setActive(active + 1); break;
        case 'ArrowUp': e.preventDefault(); setActive(active - 1); break;
        case 'PageDown': e.preventDefault(); setActive(active + jump); break;
        case 'PageUp': e.preventDefault(); setActive(active - jump); break;
        case 'Home': if (!search.value) { e.preventDefault(); setActive(0); } break;
        case 'End': if (!search.value) { e.preventDefault(); setActive(visible.length - 1); } break;
        case 'Enter': e.preventDefault(); if (active >= 0) choose(visible[active]); break;
        case 'Escape': e.preventDefault(); close(true); break;
        case 'Tab': close(false); break;
      }
    });
    document.addEventListener('pointerdown', function (e) { if (!root.contains(e.target)) close(false); });
    root.addEventListener('focusout', function (e) { if (e.relatedTarget && !root.contains(e.relatedTarget)) close(false); });
    sel.addEventListener('change', refreshLabel);
    refreshLabel();
  }

  function start() { document.querySelectorAll('select[data-picker]').forEach(picker); }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start); else start();
  window.ignisPicker = picker;
})();
