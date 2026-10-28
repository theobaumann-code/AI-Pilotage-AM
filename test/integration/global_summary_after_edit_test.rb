require "test_helper"

# Vue globale's summary cards are refreshed by every inline edit of its produit / upsell tables. They must show
# exactly what reloading the page would - non-accompagné book and Équipe / AM filters included.
class GlobalSummaryAfterEditTest < ActionDispatch::IntegrationTest
  setup do
    @admin = User.create!(email: "admin-gsum@example.com", name: "Admin Gsum", admin: true, active: true)
    @am = User.create!(email: "am-gsum@example.com", name: "AM Gsum", active: true)
    @kam = User.create!(email: "kam-gsum@example.com", name: "KAM Gsum", kam: true, active: true)
    @deal = ProduitDeal.create!(company: Company.create!(name: "Client Gsum", user: @am), produit: "Mutuelle",
      identifiant: "gsum-1", college: "Cadre", assureur: "AXA", arr: 10_000, taux: 4, statut_renouvellement: "En cours", risque_churn: 10)
    ProduitDeal.create!(company: Company.create!(name: "Client Kam Gsum", user: @kam), produit: "Mutuelle",
      identifiant: "gsum-2", college: "Cadre", assureur: "AXA", arr: 30_000, taux: 0, statut_renouvellement: "Churné")
    @upsell = UpsellDeal.create!(company: @deal.company, produit: "Prévoyance", nombre_salaries: 10, probabilite_signature: 50,
      statut_signature: "En cours")
    AppSetting.instance.update!(arr_non_accompagne: 50_000, churn_projete_non_accompagne: 2_000, taux_renouvellement_non_accompagne: 3)
    NonAccompagneChurnEntry.create!(company_name: "Perdu NA", amount: 1_000)
    sign_in @admin
  end

  # The cards' visible text (figures, rates, badges), whitespace-normalised.
  def cards_text(html)
    fragment = Nokogiri::HTML(html).at_css("#global-summary-cards")
    fragment.text.squish
  end

  def page_cards(filters)
    get pilotage_path(filters)
    cards_text(@response.body)
  end

  # Edits a field that doesn't move any figure, then returns the refreshed cards from the Turbo Stream response.
  def cards_after_edit(deal, row_context, filters, field)
    patch deal_path(deal), params: { deal: field, row_context: row_context }.merge(filters),
      headers: { "Accept" => "text/vnd.turbo-stream.html" }
    assert_response :success
    cards_text(@response.body.scan(/<template>(.*?)<\/template>/m).flatten.find { |t| t.include?("global-summary-cards") })
  end

  test "after a produit edit, the cards still include the non-accompagné book" do
    before = page_cards({})
    assert_not_equal page_cards(summary_roles: [ "Admin", "KAM", "AM" ]), before, "sanity: the non-accompagné book weighs"
    assert_equal before, cards_after_edit(@deal, "global_produit", {}, { identifiant: "gsum-1-bis" })
  end

  test "after a produit edit, the cards keep the Équipe filter of the page" do
    filters = { summary_roles: [ "AM" ] }
    before = page_cards(filters)
    assert_not_equal page_cards({}), before, "sanity: the filter changes the figures"
    assert_equal before, cards_after_edit(@deal, "global_produit", filters, { identifiant: "gsum-1-bis" })
  end

  test "after an upsell edit, the cards keep the AM filter and the non-accompagné choice" do
    filters = { summary_ams: [ @am.name ], summary_roles: [ "AM", "Non accompagné" ] }
    before = page_cards(filters)
    assert_equal before, cards_after_edit(@upsell, "global", filters, { nombre_salaries: 10 })
  end

  test "the row forms carry the page's filters, so the refresh knows them" do
    get pilotage_path(summary_roles: [ "AM" ])
    assert_match %r{/deals/#{@deal.id}\?row_context=global_produit&amp;summary_roles%5B%5D=AM}, @response.body
    assert_match %r{/deals/#{@upsell.id}\?row_context=global&amp;summary_roles%5B%5D=AM}, @response.body
  end
end
