/* Dark Admin — shared behaviour. No jQuery; Bootstrap 5 handles its own widgets. */
(function () {
  'use strict';

  /* ----------------------------------------------------------------------
     Highlight the sidebar link for the current page.
     ---------------------------------------------------------------------- */
  function markActiveNav() {
    var here = (location.pathname.split('/').pop() || 'index.html').toLowerCase();

    document.querySelectorAll('.side-nav .nav-link').forEach(function (link) {
      var target = (link.getAttribute('href') || '').split('/').pop().toLowerCase();
      var active = target === here;
      link.classList.toggle('active', active);
      if (active) {
        link.setAttribute('aria-current', 'page');
      } else {
        link.removeAttribute('aria-current');
      }
    });
  }

  /* ----------------------------------------------------------------------
     Click-to-sort tables. Replaces the ShieldUI grid's sorting.
     Mark up as <table class="table sortable"> with <th data-sort="number">
     or data-sort="text" on the sortable headers.
     ---------------------------------------------------------------------- */
  function enableSortableTables() {
    document.querySelectorAll('table.sortable').forEach(function (table) {
      var body = table.tBodies[0];
      if (!body) return;

      table.querySelectorAll('th[data-sort]').forEach(function (th, index) {
        th.tabIndex = 0;
        th.setAttribute('role', 'columnheader');
        th.setAttribute('aria-sort', 'none');

        function sort() {
          var descending = th.getAttribute('aria-sort') === 'ascending';
          var numeric = th.dataset.sort === 'number';

          table.querySelectorAll('th[data-sort]').forEach(function (other) {
            other.setAttribute('aria-sort', 'none');
          });
          th.setAttribute('aria-sort', descending ? 'descending' : 'ascending');

          var rows = Array.prototype.slice.call(body.rows);
          rows.sort(function (a, b) {
            var x = (a.cells[index].dataset.value || a.cells[index].textContent).trim();
            var y = (b.cells[index].dataset.value || b.cells[index].textContent).trim();
            var result = numeric
              ? parseFloat(x.replace(/[^0-9.\-]/g, '')) - parseFloat(y.replace(/[^0-9.\-]/g, ''))
              : x.localeCompare(y, undefined, { sensitivity: 'base' });
            return descending ? -result : result;
          });
          rows.forEach(function (row) { body.appendChild(row); });
        }

        th.addEventListener('click', sort);
        th.addEventListener('keydown', function (event) {
          if (event.key === 'Enter' || event.key === ' ') {
            event.preventDefault();
            sort();
          }
        });
      });
    });
  }

  /* ----------------------------------------------------------------------
     Chart.js dark defaults, applied once if Chart.js is on the page.
     ---------------------------------------------------------------------- */
  function applyChartDefaults() {
    if (typeof Chart === 'undefined') return;

    var styles = getComputedStyle(document.documentElement);
    var muted = styles.getPropertyValue('--da-muted').trim() || '#888';

    Chart.defaults.color = muted;
    Chart.defaults.font.family = styles.getPropertyValue('--bs-body-font-family').trim() ||
      'system-ui, -apple-system, "Segoe UI", Roboto, sans-serif';
    Chart.defaults.borderColor = 'rgba(255, 255, 255, 0.12)';
    Chart.defaults.maintainAspectRatio = false;

    // Small round swatches instead of Chart.js's wide hollow rectangles.
    Chart.defaults.plugins.legend.labels.color = muted;
    Chart.defaults.plugins.legend.labels.usePointStyle = true;
    Chart.defaults.plugins.legend.labels.pointStyle = 'circle';
    Chart.defaults.plugins.legend.labels.boxWidth = 8;
    Chart.defaults.plugins.legend.labels.boxHeight = 8;
    Chart.defaults.plugins.legend.labels.padding = 16;

    Chart.defaults.plugins.tooltip.usePointStyle = true;
    Chart.defaults.plugins.tooltip.backgroundColor =
      styles.getPropertyValue('--da-surface-2').trim() || '#1c2027';
    Chart.defaults.plugins.tooltip.titleColor = '#fff';
    Chart.defaults.plugins.tooltip.bodyColor = muted;
    Chart.defaults.plugins.tooltip.borderColor = 'rgba(255, 255, 255, 0.12)';
    Chart.defaults.plugins.tooltip.borderWidth = 1;
    Chart.defaults.plugins.tooltip.padding = 10;
    Chart.defaults.plugins.tooltip.cornerRadius = 8;
  }

  document.addEventListener('DOMContentLoaded', function () {
    markActiveNav();
    enableSortableTables();
    applyChartDefaults();
  });
})();
