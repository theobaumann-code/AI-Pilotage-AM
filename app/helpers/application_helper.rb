module ApplicationHelper
  RENEWAL_STATUT_CLASS = {
    "Augmenté" => "statut-signed",
    "Augmentation particulière" => "statut-signed",
    "En cours" => "statut-inprogress",
    "Nouveau contrat" => "statut-notstarted",
    "Churné" => "statut-lost"
  }.freeze

  SIGNATURE_STATUT_CLASS = {
    "Signé" => "statut-signed",
    "En cours" => "statut-inprogress",
    "Perdu" => "statut-lost",
    "Non démarré" => "statut-notstarted"
  }.freeze

  def renewal_statut_class(statut)
    RENEWAL_STATUT_CLASS[statut]
  end

  def signature_statut_class(statut)
    SIGNATURE_STATUT_CLASS[statut]
  end

  # Builds a query string for a sort/pagination link that preserves every other param currently on the
  # page (the other two tables' filters/sort/page, the AM selector...) while overriding just the ones
  # this particular link is changing.
  def table_query(overrides)
    request.query_parameters.merge(overrides.transform_keys(&:to_s))
  end

  def table_query_path(overrides)
    "#{request.path}?#{table_query(overrides).to_query}"
  end

  # Hidden fields replaying every current query param except the ones listed — used inside a table's own
  # search/filter/page-size <form> so submitting it doesn't wipe out the other two tables' state (or the
  # AM selector), while still letting this form's own visible fields override this table's params.
  def preserved_query_fields(*exclude_keys)
    exclude = exclude_keys.map(&:to_s)
    safe_join(request.query_parameters.reject { |k, _| exclude.include?(k.to_s) }.map { |k, v| hidden_field_tag(k, v, id: nil) })
  end

  # One sortable <th> for a TablePager-backed table: clicking it re-sorts by `field` (flipping direction
  # if already sorted by it), everything else on the page stays put.
  def sortable_th(pager, field, label, col_class: nil)
    classes = ["sortable", col_class].compact.join(" ")
    path = table_query_path(pager.sort_param => field, pager.dir_param => pager.next_dir(field))
    arrow = pager.sorted_by?(field) ? (pager.sort_dir == "asc" ? "▲" : "▼") : ""
    content_tag(:th, class: classes) do
      link_to(path) { safe_join([label, content_tag(:span, arrow, class: "sort-arrow")]) }
    end
  end

  def pagination_controls(pager)
    content_tag(:div, class: "pagination-bar") do
      safe_join([
        link_to("‹ Précédent", table_query_path(pager.page_param => pager.page - 1),
          class: "button page-btn#{" disabled" if pager.page <= 1}"),
        content_tag(:span, "Page #{pager.page} / #{pager.total_pages} (#{pluralize(pager.total_count, "résultat")})", class: "page-info"),
        link_to("Suivant ›", table_query_path(pager.page_param => pager.page + 1),
          class: "button page-btn#{" disabled" if pager.page >= pager.total_pages}")
      ])
    end
  end

  # Auto-submits the enclosing form shortly after the user stops typing, so a table's search box filters
  # live (inside its turbo-frame) without waiting for Enter or a button click.
  def live_search_field(name, value, placeholder: "Rechercher une entreprise…")
    search_field_tag(name, value, placeholder: placeholder, class: "table-search",
      oninput: "clearTimeout(this._debounce); this._debounce = setTimeout(() => this.form.requestSubmit(), 350);")
  end

  def page_size_select(pager)
    form_with url: request.path, method: :get do
      safe_join([
        preserved_query_fields(pager.size_param, pager.page_param),
        content_tag(:label, class: "page-size-label") {
          safe_join(["Lignes par page :",
            select_tag(pager.size_param, options_for_select(TablePager::PAGE_SIZES, pager.page_size), onchange: "this.form.requestSubmit()")])
        }
      ])
    end
  end

  # Sensitive inline-edit fields (contract ARR, external ID…) start locked (grayed, read-only) so a stray
  # click, scroll-wheel-over-number-input, or drag can't silently change them — a click unlocks the field,
  # and the actual change still requires confirming, with an easy revert on cancel.
  def locked_field_attrs(confirm_message)
    {
      class: "field-locked",
      readonly: true,
      onclick: "if(this.readOnly){this.readOnly=false;this.classList.remove('field-locked');this.select&&this.select();}",
      onchange: "if(confirm(#{confirm_message.to_json})){this.form.requestSubmit();}else{this.value=this.defaultValue;this.readOnly=true;this.classList.add('field-locked');}"
    }
  end
end
