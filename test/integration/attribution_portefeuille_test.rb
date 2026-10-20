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

  def entreprises
    @controller.instance_variable_get(:@ent_pager).records.index_by { |r| r[:company].name }
  end

  def table(body)
    body[/id="ent-table-frame">.*?<\/turbo-frame>/m]
  end

  def deal(company, produit, arr: 1_000, statut: "En cours")
    @n += 1
    ProduitDeal.create!(company: company, produit: produit, identifiant: "ent-#{@n}", college: "Cadre", assureur: "AXA",
      arr: arr, statut_renouvellement: statut)
  end

  test "the Entreprises table lists every company with its AM, ARR stake, risk covered and upsell opportunity" do
    sante = Company.create!(name: "Sante Seule", user: @am)
    deal(sante, "Mutuelle", arr: 10_000)
    prev = Company.create!(name: "Prevoyance Seule", user: @kam)
    deal(prev, "Prévoyance", arr: 4_000)
    double = Company.create!(name: "Double Risque", user: @am)
    deal(double, "Mutuelle", arr: 20_000)
    deal(double, "Prévoyance", arr: 5_000)
    Company.create!(name: "Sans Produit", user: @am)

    sign_in @admin
    get attribution_portefeuille_path
    assert_response :success
    rows = entreprises
    assert_equal 4, rows.size, "all companies, even one without produit"

    assert_equal [@am, 10_000.0, "Santé"], [rows["Sante Seule"][:am], rows["Sante Seule"][:arr], rows["Sante Seule"][:risque]]
    assert_equal [@kam, 4_000.0, "Prévoyance"], [rows["Prevoyance Seule"][:am], rows["Prevoyance Seule"][:arr], rows["Prevoyance Seule"][:risque]]
    assert_equal [25_000.0, "Double risque"], [rows["Double Risque"][:arr], rows["Double Risque"][:risque]]
    assert_nil rows["Sans Produit"][:risque]

    html = table(@response.body)
    assert_match "Enjeu ARR", html
    assert_match "Risque couvert", html
    assert_match "Opportunité d'upsell", html
    assert_match(/Double Risque[\s\S]*?AM Attr[\s\S]*?25,000 €[\s\S]*?Double risque/, html)
  end

  test "the stake counts produits still alive, a fully churned company is flagged and shows no risk" do
    mixed = Company.create!(name: "Un Vivant Un Churne", user: @am)
    deal(mixed, "Mutuelle", arr: 8_000)
    deal(mixed, "Prévoyance", arr: 3_000, statut: "Churné")
    gone = Company.create!(name: "Tout Churne", user: @am)
    deal(gone, "Mutuelle", arr: 9_000, statut: "Churné (subi)")

    sign_in @admin
    get attribution_portefeuille_path
    rows = entreprises
    assert_equal [8_000.0, "Santé", false], [rows["Un Vivant Un Churne"][:arr], rows["Un Vivant Un Churne"][:risque], rows["Un Vivant Un Churne"][:churned]]
    assert_equal [0.0, nil, true], [rows["Tout Churne"][:arr], rows["Tout Churne"][:risque], rows["Tout Churne"][:churned]]
    assert_match(/Tout Churne<\/strong>\s*<span class="badge ko"[^>]*>Churné/, table(@response.body))
  end

  test "an upsell opportunity is an open upsell (Non démarré / En cours), not a signed or lost one" do
    open_co = Company.create!(name: "Upsell Ouvert", user: @am)
    started = Company.create!(name: "Upsell Non Demarre", user: @am)
    signed = Company.create!(name: "Upsell Signe", user: @am)
    lost = Company.create!(name: "Upsell Perdu", user: @am)
    none = Company.create!(name: "Sans Upsell", user: @am)
    { open_co => "En cours", started => "Non démarré", signed => "Signé", lost => "Perdu" }.each do |company, statut|
      deal(company, "Mutuelle")
      UpsellDeal.create!(company: company, produit: "Prévoyance", nombre_salaries: 10, probabilite_signature: 40, statut_signature: statut)
    end
    deal(none, "Mutuelle")

    sign_in @admin
    get attribution_portefeuille_path
    rows = entreprises
    assert rows["Upsell Ouvert"][:upsell]
    assert rows["Upsell Non Demarre"][:upsell]
    assert_not rows["Upsell Signe"][:upsell]
    assert_not rows["Upsell Perdu"][:upsell]
    assert_not rows["Sans Upsell"][:upsell]
    assert_operator rows["Upsell Ouvert"][:upsell_amount], :>, 0
    assert_match(/Upsell Ouvert[\s\S]*?✓ Oui/, table(@response.body))

    total = @controller.instance_variable_get(:@ent_total)
    assert_equal 2, total[:upsell]
  end

  test "the table filters by name, AM, risk and upsell, and sorts biggest stake first by default" do
    a = Company.create!(name: "Alpha Ent", user: @am)
    deal(a, "Mutuelle", arr: 1_000)
    b = Company.create!(name: "Beta Ent", user: @kam)
    deal(b, "Mutuelle", arr: 9_000)
    deal(b, "Prévoyance", arr: 1_000)
    UpsellDeal.create!(company: b, produit: "Mutuelle", nombre_salaries: 5, probabilite_signature: 10, statut_signature: "En cours")

    sign_in @admin
    get attribution_portefeuille_path
    assert_equal ["Beta Ent", "Alpha Ent"], @controller.instance_variable_get(:@ent_pager).records.map { |r| r[:company].name }

    get attribution_portefeuille_path, params: { ent_sort: "arr", ent_dir: "asc" }
    assert_equal ["Alpha Ent", "Beta Ent"], @controller.instance_variable_get(:@ent_pager).records.map { |r| r[:company].name }

    get attribution_portefeuille_path, params: { ent_q: "alp" }
    assert_equal ["Alpha Ent"], entreprises.keys
    get attribution_portefeuille_path, params: { ent_ams: [@kam.name] }
    assert_equal ["Beta Ent"], entreprises.keys
    get attribution_portefeuille_path, params: { ent_risques: ["Santé"] }
    assert_equal ["Alpha Ent"], entreprises.keys
    get attribution_portefeuille_path, params: { ent_risques: ["Double risque", "Santé"] }
    assert_equal ["Alpha Ent", "Beta Ent"], entreprises.keys.sort
    get attribution_portefeuille_path, params: { ent_upsell: "1" }
    assert_equal ["Beta Ent"], entreprises.keys
    assert_match(/<strong>1<\/strong> entreprise/, table(@response.body))
  end

  test "the Entreprises table is paginated and has its own filter controls" do
    60.times { |i| deal(Company.create!(name: "Pagine #{i}", user: @am), "Mutuelle", arr: 100 + i) }
    sign_in @admin
    get attribution_portefeuille_path
    pager = @controller.instance_variable_get(:@ent_pager)
    assert_equal [50, 60, 2], [pager.records.size, pager.total_count, pager.total_pages]
    html = table(@response.body)
    assert_match 'name="ent_q"', html
    assert_match 'name="ent_ams[]"', html
    assert_match 'name="ent_risques[]"', html
    assert_match 'name="ent_upsell"', html
    get attribution_portefeuille_path, params: { ent_page: 2 }
    assert_equal 10, @controller.instance_variable_get(:@ent_pager).records.size
  end
end
