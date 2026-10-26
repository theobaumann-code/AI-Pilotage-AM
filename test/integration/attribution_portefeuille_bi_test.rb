require "test_helper"

# "Attribution portefeuille", BI view (the default): next campaign's portfolios as the BO assigns them.
class AttributionPortefeuilleBiTest < ActionDispatch::IntegrationTest
  setup do
    @admin = User.create!(email: "admin-bi@example.com", name: "Admin Bi", admin: true, active: true)
    @am = User.create!(email: "am-bi@sidecare.com", name: "AM Bi", active: true)
    @n = 0
  end

  def account(**attrs)
    @n += 1
    BiAccount.create!({ kind: "set", bi_id: @n, name: "Compte Bi #{@n}", contracts_count: 1, user_pros_count: 2,
      synced_at: Time.current }.merge(attrs))
  end

  def rows
    @controller.instance_variable_get(:@rows).index_by { |r| r[:name] }
  end

  test "without any synced data, the page says so and offers the sync" do
    sign_in @admin
    get attribution_portefeuille_path
    assert_response :success
    assert_match "Aucune donnée BI synchronisée", @response.body
    assert_match "Synchroniser maintenant", @response.body
  end

  test "accounts land on the app user with the BO AM's e-mail; an unknown AM gets a Hors outil row" do
    account(am_email: "am-bi@sidecare.com", arr: 10_000, has_sante: true)
    account(name: "Sans Contrat Actif", am_email: "am-bi@sidecare.com", arr: 4_000, has_prevoyance: true, contracts_count: 0)
    account(am_email: "ancien@sidecare.com", am_name: "Ancien AM", arr: 6_000, has_sante: true)

    sign_in @admin
    get attribution_portefeuille_path
    assert_response :success
    am = rows["AM Bi"]
    assert_equal [ 1, 0, 10_000.0 ], [ am[:comptes], am[:churned], am[:arr] ], "the account without an active contract is dropped"
    assert_not_includes @controller.instance_variable_get(:@ent_pager).records.map { |r| r[:name] }, "Sans Contrat Actif"
    assert_no_match "Sans Contrat Actif", @response.body
    assert_equal [ 1, "Hors outil", 54 ], [ rows["Ancien AM"][:comptes], rows["Ancien AM"][:role], rows["Ancien AM"][:limit] ]
    assert_equal 16_000.0, @controller.instance_variable_get(:@totals)[:arr]
    assert_match "Dernière synchronisation BI", @response.body
    assert_no_match "tels que le BO les attribue", @response.body, "no intro text on the BI view"
    assert_no_match "dépasse", @response.body, "no over-ceiling banner on the BI view"
  end

  test "the accounts table shows ARR, risk and the missing risk as the upsell; filters still work" do
    account(name: "Sante Seule Bi", am_email: "am-bi@sidecare.com", arr: 8_000, has_sante: true, employees_count: 20)
    account(name: "Double Bi", am_email: "am-bi@sidecare.com", arr: 3_000, has_sante: true, has_prevoyance: true)

    sign_in @admin
    get attribution_portefeuille_path
    recs = @controller.instance_variable_get(:@ent_pager).records.index_by { |r| r[:name] }
    assert_equal [ "Santé", true, "Prévoyance" ], recs["Sante Seule Bi"].values_at(:risque, :upsell, :upsell_produit)
    assert_equal [ "Double risque", false ], recs["Double Bi"].values_at(:risque, :upsell)
    assert_match "Comptes suivis par un AM", @response.body
    assert_match "✓ Prévoyance", @response.body

    get attribution_portefeuille_path, params: { ent_upsell: "1" }
    assert_equal [ "Sante Seule Bi" ], @controller.instance_variable_get(:@ent_pager).records.map { |r| r[:name] }
  end

  test "the Comptes sans AM table lists unassigned accounts over the thresholds, biggest first" do
    account(name: "Gros Sans AM", arr: 7_000, has_prevoyance: true)
    account(name: "Petit Standard", kind: "user_pro", siren: "123456789", arr: 2_500, has_sante: true, has_standard_sante: true)
    account(name: "Petit Sur Mesure", arr: 2_500, has_sante: true)
    account(name: "Suivi", am_email: "am-bi@sidecare.com", arr: 50_000)

    sign_in @admin
    get attribution_portefeuille_path
    assert_equal [ "Gros Sans AM", "Petit Standard" ], @controller.instance_variable_get(:@sam_pager).records.map(&:name)
    html = @response.body[/id="sam-table-frame">.*?<\/turbo-frame>/m]
    assert_match "Comptes sans AM", html
    assert_match "SIREN 123456789", html
    assert_no_match "Petit Sur Mesure", html

    get attribution_portefeuille_path, params: { sam_q: "petit" }
    assert_equal [ "Petit Standard" ], @controller.instance_variable_get(:@sam_pager).records.map(&:name)
  end

  test "the raw view is one click away and keeps the current campaign's data" do
    Company.create!(name: "Client Brut", user: @am)
    sign_in @admin
    get attribution_portefeuille_path(vue: "brut")
    assert_response :success
    assert_match "données brutes", @response.body
    assert_match "Client Brut", @response.body
  end

  test "a manual sync reports BigQuery being unreachable instead of failing" do
    sign_in @admin
    post sync_bi_attribution_portefeuille_path
    assert_redirected_to attribution_portefeuille_path
    assert_match "Synchronisation BI impossible", flash[:alert]
  end

  test "only real admins can sync" do
    sign_in @am
    post sync_bi_attribution_portefeuille_path
    assert_redirected_to root_path
  end
end
