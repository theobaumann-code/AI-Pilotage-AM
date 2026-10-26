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
    get attribution_portefeuille_path(vue: "brut")
    assert_response :success
    assert_match "Attribution portefeuille", @response.body

    [ @kam, @am, @reader ].each do |user|
      sign_out :user
      sign_in user
      get attribution_portefeuille_path(vue: "brut")
      assert_response :redirect, "#{user.name} must not get in"
    end

    sign_out :user
    get attribution_portefeuille_path(vue: "brut")
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
    get attribution_portefeuille_path(vue: "brut")
    row = rows["AM Attr"]
    assert_equal 3, row[:comptes], "active + no-produit + mixed"
    assert_equal 2, row[:churned]
    assert_in_delta 12_000, row[:arr], 0.001, "10 000 + 2 000, the churned produits left out"
    assert_in_delta 4_000, row[:basket], 0.001
    assert_equal 51, row[:remaining]
    assert_not row[:over]
  end

  test "each role has its own ceiling: KAM 35, AM 54, TL AM 9, TL Customer Care 24 - over it is red, at it is fine" do
    tl_am = User.create!(email: "tlam-attr@example.com", name: "TL AM Attr", role: "TL AM", active: true)
    tl_csm = User.create!(email: "tlcsm-attr@example.com", name: "TL CC Attr", role: "TL Customer Care", active: true)
    36.times { account(@kam, arr: 100) }
    54.times { account(@am, arr: 100) }
    10.times { account(tl_am, arr: 100) }
    24.times { account(tl_csm, arr: 100) }

    sign_in @admin
    get attribution_portefeuille_path(vue: "brut")
    assert_response :success
    assert_equal [ 35, 54, 9, 24 ], [ rows["KAM Attr"][:limit], rows["AM Attr"][:limit], rows["TL AM Attr"][:limit], rows["TL CC Attr"][:limit] ]
    assert_equal [ 36, -1 ], [ rows["KAM Attr"][:comptes], rows["KAM Attr"][:remaining] ]
    assert rows["KAM Attr"][:over], "36 accounts is over a KAM's 35"
    assert rows["TL AM Attr"][:over], "10 accounts is over a TL AM's 9"
    assert_not rows["AM Attr"][:over], "54 is an AM's maximum, not over it"
    assert_not rows["TL CC Attr"][:over], "24 is a TL Customer Care's maximum"
    assert_equal [ 0, 0 ], [ rows["AM Attr"][:remaining], rows["TL CC Attr"][:remaining] ]

    assert_equal [ "KAM Attr", "TL AM Attr" ], @controller.instance_variable_get(:@over).map { |r| r[:user].name }.sort
    assert_match(/2 personnes dépassent leur plafond de comptes :/, @response.body)
    assert_match(/KAM Attr \(36 comptes pour 35 max, \+1\)/, @response.body)
    assert_match(/TL AM Attr \(10 comptes pour 9 max, \+1\)/, @response.body)
    assert_match "✗ +1 en trop", @response.body
    assert_match "row-over-capacity", @response.body
    assert_match "✓ 0 restant", @response.body

    totals = @controller.instance_variable_get(:@totals)
    assert_equal 124, totals[:comptes]
    assert_equal 35 + 54 + 9 + 24, totals[:capacity]
    assert_equal(-2, totals[:remaining], "the team as a whole is two accounts over")
  end

  test "nobody over their ceiling shows the all-clear" do
    account(@am)
    sign_in @admin
    get attribution_portefeuille_path(vue: "brut")
    assert_match "Personne ne dépasse son plafond de comptes", @response.body
    assert_empty @controller.instance_variable_get(:@over)
  end

  test "the list is AMs, KAMs and team leads (even empty ones) plus anyone with accounts; lecteurs and empty admins stay out" do
    User.create!(email: "tlam2-attr@example.com", name: "TL AM Vide", role: "TL AM", active: true)
    User.create!(email: "tlcsm2-attr@example.com", name: "TL CC Vide", role: "TL Customer Care", active: true)
    sign_in @admin
    get attribution_portefeuille_path(vue: "brut")
    assert_equal [ "AM Attr", "KAM Attr", "TL AM Vide", "TL CC Vide" ], rows.keys.sort, "empty ones listed with their full capacity"
    assert_equal 54, rows["AM Attr"][:remaining]
    assert_equal 35, rows["KAM Attr"][:remaining]
    assert_equal 9, rows["TL AM Vide"][:remaining]
    assert_equal 24, rows["TL CC Vide"][:remaining]
    assert_equal 35 + 54 + 9 + 24, @controller.instance_variable_get(:@totals)[:capacity]

    account(@admin)
    get attribution_portefeuille_path(vue: "brut")
    assert_includes rows.keys, "Admin Attr", "an admin who does carry accounts appears"
    assert_equal 54, rows["Admin Attr"][:limit], "an admin without a poste gets the default ceiling"
    assert_not_includes rows.keys, "Lecteur Attr"
  end

  test "sorted by number of accounts, most loaded first by default, and sortable" do
    3.times { account(@am) }
    5.times { account(@kam) }
    sign_in @admin

    get attribution_portefeuille_path(vue: "brut")
    assert_equal [ "KAM Attr", "AM Attr" ], @controller.instance_variable_get(:@pager).records.map { |r| r[:user].name }

    get attribution_portefeuille_path(vue: "brut"), params: { attr_sort: "comptes", attr_dir: "asc" }
    assert_equal [ "AM Attr", "KAM Attr" ], @controller.instance_variable_get(:@pager).records.map { |r| r[:user].name }
  end

  test "ARR share and the per-role capacity table, with each role's ceiling" do
    tl = User.create!(email: "tlcsm3-attr@example.com", name: "TL CC Attr", role: "TL Customer Care", active: true)
    account(@am, arr: 30_000)
    account(@kam, arr: 10_000)
    account(tl, arr: 10_000)
    sign_in @admin
    get attribution_portefeuille_path(vue: "brut")
    assert_in_delta 60.0, rows["AM Attr"][:part], 0.001
    assert_in_delta 20.0, rows["KAM Attr"][:part], 0.001

    by_role = @controller.instance_variable_get(:@by_role).index_by { |g| g[:role] }
    assert_equal [ 1, 54, 54, 1, 30_000 ], [ by_role["AM"][:people], by_role["AM"][:limit], by_role["AM"][:capacity], by_role["AM"][:comptes], by_role["AM"][:arr] ]
    assert_equal [ 1, 35, 35, 1 ], [ by_role["KAM"][:people], by_role["KAM"][:limit], by_role["KAM"][:capacity], by_role["KAM"][:comptes] ]
    assert_equal [ 1, 24, 24, 1 ], [ by_role["TL Customer Care"][:people], by_role["TL Customer Care"][:limit], by_role["TL Customer Care"][:capacity], by_role["TL Customer Care"][:comptes] ]
    assert_match "Capacité par rôle", @response.body
    assert_match "Plafond / pers.", @response.body
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
    get attribution_portefeuille_path(vue: "brut")
    assert_response :success
    rows = entreprises
    assert_equal 4, rows.size, "all companies, even one without produit"

    assert_equal [ @am, 10_000.0, "Santé" ], [ rows["Sante Seule"][:am], rows["Sante Seule"][:arr], rows["Sante Seule"][:risque] ]
    assert_equal [ @kam, 4_000.0, "Prévoyance" ], [ rows["Prevoyance Seule"][:am], rows["Prevoyance Seule"][:arr], rows["Prevoyance Seule"][:risque] ]
    assert_equal [ 25_000.0, "Double risque" ], [ rows["Double Risque"][:arr], rows["Double Risque"][:risque] ]
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
    get attribution_portefeuille_path(vue: "brut")
    rows = entreprises
    assert_equal [ 8_000.0, "Santé", false ], [ rows["Un Vivant Un Churne"][:arr], rows["Un Vivant Un Churne"][:risque], rows["Un Vivant Un Churne"][:churned] ]
    assert_equal [ 0.0, nil, true ], [ rows["Tout Churne"][:arr], rows["Tout Churne"][:risque], rows["Tout Churne"][:churned] ]
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
    get attribution_portefeuille_path(vue: "brut")
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
    get attribution_portefeuille_path(vue: "brut")
    assert_equal [ "Beta Ent", "Alpha Ent" ], @controller.instance_variable_get(:@ent_pager).records.map { |r| r[:company].name }

    get attribution_portefeuille_path(vue: "brut"), params: { ent_sort: "arr", ent_dir: "asc" }
    assert_equal [ "Alpha Ent", "Beta Ent" ], @controller.instance_variable_get(:@ent_pager).records.map { |r| r[:company].name }

    get attribution_portefeuille_path(vue: "brut"), params: { ent_q: "alp" }
    assert_equal [ "Alpha Ent" ], entreprises.keys
    get attribution_portefeuille_path(vue: "brut"), params: { ent_ams: [ @kam.name ] }
    assert_equal [ "Beta Ent" ], entreprises.keys
    get attribution_portefeuille_path(vue: "brut"), params: { ent_risques: [ "Santé" ] }
    assert_equal [ "Alpha Ent" ], entreprises.keys
    get attribution_portefeuille_path(vue: "brut"), params: { ent_risques: [ "Double risque", "Santé" ] }
    assert_equal [ "Alpha Ent", "Beta Ent" ], entreprises.keys.sort
    get attribution_portefeuille_path(vue: "brut"), params: { ent_upsell: "1" }
    assert_equal [ "Beta Ent" ], entreprises.keys
    assert_match(/<strong>1<\/strong> entreprise/, table(@response.body))
  end

  test "the Entreprises table is paginated and has its own filter controls" do
    60.times { |i| deal(Company.create!(name: "Pagine #{i}", user: @am), "Mutuelle", arr: 100 + i) }
    sign_in @admin
    get attribution_portefeuille_path(vue: "brut")
    pager = @controller.instance_variable_get(:@ent_pager)
    assert_equal [ 50, 60, 2 ], [ pager.records.size, pager.total_count, pager.total_pages ]
    html = table(@response.body)
    assert_match 'name="ent_q"', html
    assert_match 'name="ent_ams[]"', html
    assert_match 'name="ent_risques[]"', html
    assert_match 'name="ent_upsell"', html
    get attribution_portefeuille_path(vue: "brut"), params: { ent_page: 2 }
    assert_equal 10, @controller.instance_variable_get(:@ent_pager).records.size
  end
end
