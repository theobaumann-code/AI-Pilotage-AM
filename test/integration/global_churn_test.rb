require "test_helper"

# Vue globale's "Produits churnés (tous AM)": lists every produit at status "Churné" so its churn reason
# (a select) and a free-text comment can be recorded per produit.
class GlobalChurnTest < ActionDispatch::IntegrationTest
  setup do
    @admin = User.create!(email: "admin-churn@example.com", name: "Admin Churn", admin: true, active: true)
    @am = User.create!(email: "am-churn@example.com", name: "AM Churn", admin: false, active: true)
    @other_am = User.create!(email: "other-churn@example.com", name: "Autre AM", admin: false, active: true)
    @company = Company.create!(name: "Client Churné", user: @am)
    @churned = ProduitDeal.create!(company: @company, produit: "Mutuelle", identifiant: "churn-1",
      college: "Cadre", assureur: "AXA", arr: 10_000, statut_renouvellement: "Churné")
    @active = ProduitDeal.create!(company: Company.create!(name: "Client Actif", user: @am), produit: "Mutuelle",
      identifiant: "churn-2", college: "Cadre", assureur: "AXA", arr: 5_000, statut_renouvellement: "En cours")
    @subi = ProduitDeal.create!(company: Company.create!(name: "Client Subi", user: @am), produit: "Mutuelle",
      identifiant: "churn-3", college: "Cadre", assureur: "AXA", arr: 5_000, statut_renouvellement: "Churné (subi)")
  end

  def churn_table(body)
    body[/id="gchurn-table-frame">.*?<\/turbo-frame>/m]
  end

  test "lists only produits whose status is Churné" do
    sign_in @am
    get pilotage_path
    assert_response :success
    assert_match "Client Churné", churn_table(@response.body)
    assert_no_match "Client Actif", churn_table(@response.body)
    assert_no_match "Client Subi", churn_table(@response.body)
  end

  test "filterable by AM, team, produit and raison" do
    @churned.update!(churn_reason: "Offre concurrente")
    sign_in @am

    get pilotage_path, params: { churn_ams: [@admin.name] }
    assert_no_match "Client Churné", churn_table(@response.body)

    get pilotage_path, params: { churn_roles: ["AM"], churn_produits: ["Mutuelle"], churn_raisons: ["Offre concurrente"] }
    assert_match "Client Churné", churn_table(@response.body)

    get pilotage_path, params: { churn_raisons: ["À qualifier"] }
    assert_no_match "Client Churné", churn_table(@response.body)
  end

  test "an admin records a reason and a comment from the table" do
    sign_in @admin
    patch deal_path(@churned), params: { deal: { churn_reason: "Tarif / hausse de prix", churn_comment: "Hausse de 12 % refusée" },
      row_context: "global_churn" }, headers: { "Accept" => "text/vnd.turbo-stream.html" }
    assert_response :success
    assert_match "churn_produit_deal_#{@churned.id}", @response.body

    @churned.reload
    assert_equal "Tarif / hausse de prix", @churned.churn_reason
    assert_equal "Hausse de 12 % refusée", @churned.churn_comment
  end

  test "the owning AM can qualify their own churn, but not someone else's" do
    sign_in @am
    patch deal_path(@churned), params: { deal: { churn_reason: "Autre" }, row_context: "global_churn" },
      headers: { "Accept" => "text/vnd.turbo-stream.html" }
    assert_equal "Autre", @churned.reload.churn_reason

    sign_out @am
    sign_in @other_am
    patch deal_path(@churned), params: { deal: { churn_reason: "Offre inadaptée" }, row_context: "global_churn" }
    assert_equal "Autre", @churned.reload.churn_reason
  end

  test "an unknown reason is rejected" do
    sign_in @admin
    patch deal_path(@churned), params: { deal: { churn_reason: "Parce que" }, row_context: "global_churn" },
      headers: { "Accept" => "text/vnd.turbo-stream.html" }
    assert_response :unprocessable_entity
    assert_nil @churned.reload.churn_reason
  end

  test "CSV export mirrors the table, with reason and comment" do
    @churned.update!(churn_reason: "Offre concurrente", churn_comment: "Parti chez Alan")
    sign_in @am
    get export_churn_pilotage_path
    assert_response :success
    assert_match "Raison du churn", @response.body
    assert_match "Client Churné", @response.body
    assert_match "Parti chez Alan", @response.body
    assert_no_match "Client Actif", @response.body
  end
end
