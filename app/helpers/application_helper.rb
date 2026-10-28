module ApplicationHelper
  NUMERIC_SORT_FIELDS = %i[
    arr_compte count arr_at_risk max_risque arr_initial churned upsold renewed_arr arr_final nrr
    arr taux risque_churn final_arr nombre_salaries upsell_amount probabilite_signature
    projection avg_increase_pct evolution_pct annee arr_renouvele other_impact comptes restant panier part
  ].freeze
  RENEWAL_STATUT_CLASS = {
    "Augmenté" => "statut-signed",
    "Augmentation particulière" => "statut-signed",
    "En cours" => "statut-inprogress",
    "Nouveau contrat" => "statut-newcontract",
    "Churné" => "statut-lost",
    # Deliberately not "statut-lost" (red) - this churn isn't counted against the AM (see
    # ProduitDeal::CHURNED_SUBI), so it gets the same neutral treatment as "not started" instead.
    "Churné (subi)" => "statut-notstarted"
  }.freeze

  SIGNATURE_STATUT_CLASS = {
    "Signé" => "statut-signed",
    "En cours" => "statut-inprogress",
    "Perdu" => "statut-lost",
    "Non démarré" => "statut-notstarted"
  }.freeze

  # A signed amount as the plain number an admin would type back ("3000", "-3000", "-3000.5").
  def impact_amount_value(amount)
    amount.to_d == amount.to_d.to_i ? amount.to_d.to_i : amount.to_d.to_f
  end

  def renewal_statut_class(statut)
    RENEWAL_STATUT_CLASS[statut]
  end

  # Row background for a produit deal or a HistoriqueQuery::Row - both respond to #churned?/#churn_subi?.
  def churn_row_class(record)
    return "churn-subi" if record.churn_subi?
    "churn-yes" if record.churned?
  end

  def signature_statut_class(statut)
    SIGNATURE_STATUT_CLASS[statut]
  end

  ROLE_BADGE_CLASS = { admin: "ok", kam: "kam", reader: "reader", am: "warn", tl_am: "tl", tl_csm: "tl", head_csm: "tl" }.freeze

  def role_badge_class(user)
    ROLE_BADGE_CLASS[user.role]
  end

  # Builds a query string for a sort/pagination link that preserves every other param currently on the
  # page (the other two tables' filters/sort/page, the AM selector...) while overriding just the ones
  # this particular link is changing.
  def table_query(overrides)
    request.query_parameters.merge(overrides.transform_keys(&:to_s))
  end

  # Vue globale's Équipe / AM filters of the summary cards, to put on an inline-edit form's URL: the response
  # refreshes those cards, and must compute them for the same filters as the page (see DealsController).
  def summary_filter_params
    params.permit(summary_ams: [], summary_roles: []).to_h.symbolize_keys
  end

  def table_query_path(overrides)
    "#{request.path}?#{table_query(overrides).to_query}"
  end

  # Hidden fields replaying every current query param except the ones listed - used inside a table's own
  # search/filter/page-size <form> so submitting it doesn't wipe out the other two tables' state (or the
  # AM selector), while still letting this form's own visible fields override this table's params.
  def preserved_query_fields(*exclude_keys)
    exclude = exclude_keys.map(&:to_s)
    kept = request.query_parameters.reject { |k, _| exclude.include?(k.to_s) }
    # A multi-value param (a checklist filter) must come back as name[] once per value - handing the array
    # to a single hidden field would fuse the values into one space-separated string ("AM A AM B").
    safe_join(kept.flat_map do |k, v|
      v.is_a?(Array) ? v.map { |item| hidden_field_tag("#{k}[]", item, id: nil) } : [ hidden_field_tag(k, v, id: nil) ]
    end)
  end

  # One sortable <th> for a TablePager-backed table: clicking it re-sorts by `field` (flipping direction
  # if already sorted by it), everything else on the page stays put. The sort icon (design system's
  # TableHeading + Link pattern: a right-hand action icon, Font Awesome regular to stay visually secondary)
  # only appears once actually sorted by this column - it's an active-state indicator, not decoration.
  def sortable_th(pager, field, label, col_class: nil)
    classes = [ "sortable", col_class, ("numeric" if NUMERIC_SORT_FIELDS.include?(field)) ].compact.join(" ")
    path = table_query_path(pager.sort_param => field, pager.dir_param => pager.next_dir(field))
    arrow = if pager.sorted_by?(field)
      content_tag(:i, "", class: "fa-regular #{pager.sort_dir == "asc" ? "fa-arrow-up-short-wide" : "fa-arrow-down-wide-short"} sort-arrow")
    end
    content_tag(:th, class: classes) do
      link_to(path) { safe_join([ label, arrow ]) }
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
          safe_join([ "Lignes par page :",
            select_tag(pager.size_param, options_for_select(TablePager::PAGE_SIZES, pager.page_size), onchange: "this.form.requestSubmit()") ])
        }
      ])
    end
  end

  # Sensitive inline-edit fields (contract ARR, external ID…) start locked (grayed, read-only) so a stray
  # click, scroll-wheel-over-number-input, or drag can't silently change them - a click unlocks the field,
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
