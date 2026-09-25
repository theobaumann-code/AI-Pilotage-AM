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

// Keeps a checklist-filter dropdown's open/closed state (see shared/_checklist_filter.html.erb) tracked
// in its own hidden field, so the NEXT form submission — whether it's another checkbox in this same
// filter, or something unrelated like the table's search box — carries forward what the user actually did
// (open or closed) instead of the server re-inferring "open" purely from "something is selected", which
// used to reopen a filter the user had deliberately closed as soon as any other control in the same form
// triggered a reload. The native "toggle" event on <details> doesn't bubble, but it does fire during the
// capture phase on ancestors, so one delegated listener here covers every filter on the page without
// needing to re-attach after each Turbo navigation.
document.addEventListener("toggle", (event) => {
  const details = event.target;
  if (!(details instanceof HTMLDetailsElement) || !details.classList.contains("checklist-filter")) return;
  const openField = details.querySelector("[data-checklist-open-field]");
  if (openField) openField.value = details.open ? "1" : "0";
}, true);
