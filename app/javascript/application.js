// Configure your import map in config/importmap.rb. Read more: https://github.com/rails/importmap-rails
import "@hotwired/turbo-rails"
import "controllers"

// Opens one of a page's shared "reassign the AM" panels (see shared/_reassign_am_panel.html.erb),
// retargeting its form to the clicked row's deal before showing it — same one-panel-per-table trick as
// the AM credentials panel, kept outside .table-scroll so it isn't clipped by that container's overflow.
window.openReassignPanel = function (panelId, formId, nameSpanId, url, label) {
  const form = document.getElementById(formId);
  form.action = url;
  document.getElementById(nameSpanId).textContent = label;
  const panel = document.getElementById(panelId);
  panel.style.display = "block";
  panel.scrollIntoView({ block: "center", behavior: "smooth" });
};
