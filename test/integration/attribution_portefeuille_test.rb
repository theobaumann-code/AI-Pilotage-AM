require "test_helper"

# "Attribution portefeuille": per-person number of accounts and ARR against the 54-account ceiling, admins only.
class AttributionPortefeuilleTest < ActionDispatch::IntegrationTest
  setup do
    @admin = User.create!(email: "admin-attr@example.com", name: "Admin Attr", admin: true, active: true)
    @kam = User.create!(email: "kam-attr@example.com", name: "KAM Attr", kam: true, active: true)
    @am = User.create!(email: "am-attr@example.com", name: "AM Attr", active: true)
    @reader = User.create!(email: "reader-attr@example.com", name: "Lecteur Attr", role: "Lecteur", active: true)
    @n = 0
  end

  def account(owner, name: nil, arr: 1_000, statut: "En cours", produits: 1)
    @n += 1
    company = Company.create!(name: name || "Compte Attr #{@n}", user: owner)
    produits.times do |i|
      ProduitDeal.create!(company: company, produit: ProduitDeal::PRODUITS[i], identifiant: "attr-#{@n}-#{i}", college: "Cadre",
        assureur: "AXA", arr: arr, statut_renouvellement: statut)
    end
    company
  end

  def rows
    @controller.instance_variable_get(:@rows).index_by { |r| r[:user].name }
  end

  test "only real admins can open it: KAMs, AMs, lecteurs and visitors are turned away" do
    sign_in @admin
    get attribution_portefeuille_path
    assert_response :success
    assert_match "Attribution portefeuille", @response.body

    [@kam, @am, @reader].each do |user|
      sign_out :user
      sign_in user
      get attribution_portefeuille_path
      assert_response :redirect, "#{user.name} must not get in"
    end

    sign_out :user
    get attribution_portefeuille_path
    assert_redirected_to new_user_session_path
  end

  test "the sidebar link is shown to admins only" do
    sign_in @admin
    get pilotage_path
    assert_match "Attribution portefeuille", @response.body

    sign_out :user
    sign_in @kam
    get pilotage_path
    assert_no_match "Attribution portefeuille", @response.body
  end

  test "accounts are clients not fully churned; ARR is that of the produits still alive" do
    account(@am, arr: 10_000)                                          # active
    account(@am, arr: 5_000, statut: "Churné")                         # fully churned: out
    account(@am, arr: 7_000, statut: "Churné (subi)")                  # suffered churn: out too
    Company.create!(name: "Client sans produit Attr", user: @am)       # no produit yet: still an account
    mixed = account(@am, arr: 2_000, produits: 2)                      # one alive produit + one churned
    mixed.produit_deals.where(produit: "Prévoyance").first.update!(statut_renouvellement: "Churné")

    sign_in @admin
    get attribution_portefeuille_path
    row = rows["AM Attr"]
    assert_equal 3, row[:comptes], "active + no-produit + mixed"
    assert_equal 2, row[:churned]
    assert_in_delta 12_000, row[:arr], 0.001, "10 000 + 2 000, the churned produits left out"
    assert_in_delta 4_000, row[:basket], 0.001
    assert_equal 51, row[:remaining]
    assert_not row[:over]
  end

  test "someone over 54 accounts is in the red, listed in the banner, and 54 exactly is fine" do
    55.times { account(@kam, arr: 100) }
    54.times { account(@am, arr: 100) }

    sign_in @admin
    get attribution_portefeuille_path
    assert_response :success
    kam_row = rows["KAM Attr"]
    am_row = rows["AM Attr"]
    assert kam_row[:over]
    assert_equal [55, -1], [kam_row[:comptes], kam_row[:remaining]]
    assert_not am_row[:over], "54 is the maximum, not over it"
    assert_equal 0, am_row[:remaining]

    assert_equal 1, @controller.instance_variable_get(:@over).size
    assert_match(/1 personne dépasse les 54 comptes :[\s\S]*KAM Attr \(55 comptes, \+1\)/, @response.body)
    assert_match "✗ +1 en trop", @response.body
    assert_match "row-over-capacity", @response.body
    assert_match "✓ 0 restant", @response.body

    totals = @controller.instance_variable_get(:@totals)
    assert_equal 109, totals[:comptes]
    assert_equal 108, totals[:capacity]
    assert_equal(-1, totals[:remaining], "the team as a whole is one account over")
  end

  test "nobody over the ceiling shows the all-clear" do
    account(@am)
    sign_in @admin
    get attribution_portefeuille_path
    assert_match "Personne ne dépasse les 54 comptes", @response.body
    assert_empty @controller.instance_variable_get(:@over)
  end

  test "the list is AMs and KAMs (even empty ones) plus anyone with accounts; lecteurs and empty admins stay out" do
    sign_in @admin
    get attribution_portefeuille_path
    assert_equal ["AM Attr", "KAM Attr"], rows.keys.sort, "empty AM and KAM listed with their full capacity"
    assert_equal 54, rows["AM Attr"][:remaining]
    assert_equal 108, @controller.instance_variable_get(:@totals)[:capacity]

    account(@admin)
    get attribution_portefeuille_path
    assert_includes rows.keys, "Admin Attr", "an admin who does carry accounts appears"
    assert_not_includes rows.keys, "Lecteur Attr"
  end

  test "sorted by number of accounts, most loaded first by default, and sortable" do
    3.times { account(@am) }
    5.times { account(@kam) }
    sign_in @admin

    get attribution_portefeuille_path
    assert_equal ["KAM Attr", "AM Attr"], @controller.instance_variable_get(:@pager).records.map { |r| r[:user].name }

    get attribution_portefeuille_path, params: { attr_sort: "comptes", attr_dir: "asc" }
    assert_equal ["AM Attr", "KAM Attr"], @controller.instance_variable_get(:@pager).records.map { |r| r[:user].name }
  end

  test "ARR share and the per-role capacity table" do
    account(@am, arr: 30_000)
    account(@kam, arr: 10_000)
    sign_in @admin
    get attribution_portefeuille_path
    assert_in_delta 75.0, rows["AM Attr"][:part], 0.001
    assert_in_delta 25.0, rows["KAM Attr"][:part], 0.001

    by_role = @controller.instance_variable_get(:@by_role).index_by { |g| g[:role] }
    assert_equal [1, 54, 1, 30_000], [by_role["AM"][:people], by_role["AM"][:capacity], by_role["AM"][:comptes], by_role["AM"][:arr]]
    assert_equal [1, 54, 1], [by_role["KAM"][:people], by_role["KAM"][:capacity], by_role["KAM"][:comptes]]
    assert_match "Capacité par rôle", @response.body
  end
end
