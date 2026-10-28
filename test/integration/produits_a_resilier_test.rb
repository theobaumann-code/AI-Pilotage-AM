require "test_helper"

# "A résilier" box of the produits à renouveler tables (Mon portefeuille and Vue globale): a flag the AM ticks,
# saved on change, shown in the CSV exports, with no effect on any figure.
class ProduitsAResilierTest < ActionDispatch::IntegrationTest
  setup do
    @admin = User.create!(email: "admin-resil-p@example.com", name: "Admin Resil P", admin: true, active: true)
    @am = User.create!(email: "am-resil-p@example.com", name: "AM Resil P", active: true)
    @company = Company.create!(name: "Client Resil P", user: @am)
    @deal = ProduitDeal.create!(company: @company, produit: "Mutuelle", identifiant: "resil-p-1", college: "Cadre",
      assureur: "AXA", arr: 10_000, taux: 2, statut_renouvellement: "En cours")
  end

  test "an AM ticks the box on Mon portefeuille, and the figures don't move" do
    sign_in @am
    get portfolio_path
    assert_select "table.renewal-table th", text: "A résilier"
    assert_select "##{ActionView::RecordIdentifier.dom_id(@deal)} input[type=checkbox][name='deal[a_resilier]']"
    before = PortfolioSummary.new(@am.companies, user: @am).arr_final

    patch deal_path(@deal), params: { deal: { a_resilier: "1" } }, headers: { "Accept" => "text/vnd.turbo-stream.html" }
    assert_response :success
    assert @deal.reload.a_resilier
    assert_select "##{ActionView::RecordIdentifier.dom_id(@deal)} input[type=checkbox][name='deal[a_resilier]'][checked]"
    assert_in_delta before, PortfolioSummary.new(@am.companies, user: @am).arr_final, 0.001

    patch deal_path(@deal), params: { deal: { a_resilier: "0" } }, headers: { "Accept" => "text/vnd.turbo-stream.html" }
    assert_not @deal.reload.a_resilier
  end

  test "the Vue globale table has the box, editable by admins and read-only for an AM" do
    @deal.update!(a_resilier: true)
    sign_in @admin
    get pilotage_path
    table = @response.body[/id="gprod-table-frame">.*?<\/turbo-frame>/m]
    assert_match "A résilier", table
    assert_match(/type="checkbox"[^>]*checked="checked" name="deal\[a_resilier\]"/, table)

    sign_in @am
    get pilotage_path
    table = @response.body[/id="gprod-table-frame">.*?<\/turbo-frame>/m]
    assert_no_match 'name="deal[a_resilier]"', table
    assert_match "Oui", table
  end

  test "both CSV exports carry the column" do
    @deal.update!(a_resilier: true)
    sign_in @am
    get export_produits_portfolio_path
    assert_match "A résilier", @response.body
    assert_match(/;Oui;/, @response.body)

    get export_produits_pilotage_path
    assert_match "A résilier", @response.body
    assert_match(/;Oui;/, @response.body)
  end
end
