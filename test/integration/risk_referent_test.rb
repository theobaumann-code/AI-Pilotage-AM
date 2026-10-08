require "test_helper"

# "Référent" on Vue globale's Entreprises à risque: the manager (admin/KAM) following an at-risk company, to
# spread that follow-up across managers. Only admins/KAMs can assign one, and only admins/KAMs can be named.
class RiskReferentTest < ActionDispatch::IntegrationTest
  setup do
    @admin = User.create!(email: "admin-ref@example.com", name: "Admin Ref", admin: true, active: true)
    @kam = User.create!(email: "kam-ref@example.com", name: "KAM Ref", kam: true, active: true)
    @am = User.create!(email: "am-ref@example.com", name: "AM Ref", active: true)
    @company = Company.create!(name: "Client Référent", user: @am)
    @other = Company.create!(name: "Client Sans Référent", user: @am)
    [@company, @other].each_with_index do |c, i|
      ProduitDeal.create!(company: c, produit: "Mutuelle", identifiant: "ref-#{i}", college: "Cadre",
        assureur: "AXA", arr: 10_000, statut_renouvellement: "En cours", risque_churn: 30)
    end
  end

  def risk_table
    @response.body[/id="rque-table-frame">.*?<\/turbo-frame>/m]
  end

  test "an admin names a manager as référent, and it persists" do
    sign_in @admin
    patch company_path(@company), params: { company: { referent_id: @kam.id }, return_to: "/pilotage?rque_page=2" }
    assert_redirected_to "/pilotage?rque_page=2"
    assert_equal @kam, @company.reload.referent

    patch company_path(@company), params: { company: { referent_id: "" } }
    assert_nil @company.reload.referent
  end

  test "a KAM can assign too, but a regular AM cannot" do
    sign_in @kam
    patch company_path(@company), params: { company: { referent_id: @admin.id } }
    assert_equal @admin, @company.reload.referent

    sign_out @kam
    sign_in @am
    patch company_path(@company), params: { company: { referent_id: @am.id } }
    assert_equal @admin, @company.reload.referent, "an AM's attempt to change the référent is ignored"
  end

  test "only active admins or KAMs can be named" do
    sign_in @admin
    patch company_path(@company), params: { company: { referent_id: @am.id } }
    assert_nil @company.reload.referent
    assert_match "admin ou un KAM actif", flash[:alert].to_s

    @kam.update!(active: false)
    patch company_path(@company), params: { company: { referent_id: @kam.id } }
    assert_nil @company.reload.referent
  end

  test "the table offers admins and KAMs only, shows the current référent, and a regular AM sees plain text" do
    @company.update!(referent: @kam)
    sign_in @admin
    get pilotage_path
    assert_response :success
    select = risk_table[/<select[^>]*referent_id.*?<\/select>/m]
    assert_match "Admin Ref", select
    assert_match "KAM Ref", select
    assert_no_match ">AM Ref<", select
    assert_match(/selected="selected" value="#{@kam.id}"/, select)

    sign_out @admin
    sign_in @am
    get pilotage_path
    assert_no_match "referent_id", risk_table
    assert_match "KAM Ref", risk_table
  end

  test "a deactivated référent still shows as the current choice instead of vanishing" do
    @company.update!(referent: @kam)
    @kam.update!(active: false)
    sign_in @admin
    get pilotage_path
    assert_match(/selected="selected" value="#{@kam.id}"/, risk_table)
  end

  test "filterable by référent (including Non attribué), sortable, and exported" do
    @company.update!(referent: @kam)
    sign_in @admin

    get pilotage_path, params: { risque_referents: ["KAM Ref"] }
    assert_match "Client Référent", risk_table
    assert_no_match "Client Sans Référent", risk_table

    get pilotage_path, params: { risque_referents: ["Non attribué"] }
    assert_no_match "Client Référent", risk_table
    assert_match "Client Sans Référent", risk_table

    get pilotage_path, params: { rque_sort: "referent", rque_dir: "asc" }
    assert_response :success

    get export_risque_pilotage_path
    assert_match "Référent", @response.body
    assert_match(/Client Référent;.*;KAM Ref/, @response.body)

    get export_risque_pilotage_path, params: { risque_referents: ["KAM Ref"] }
    assert_no_match "Client Sans Référent", @response.body
  end
end
