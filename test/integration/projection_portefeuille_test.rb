require "test_helper"

# "Projection portefeuille": what-ifs over the BI's assignment for next campaign, with bulk moves.
class ProjectionPortefeuilleTest < ActionDispatch::IntegrationTest
  setup do
    @admin = User.create!(email: "admin-proj@example.com", name: "Admin Proj", admin: true, active: true)
    @alice = User.create!(email: "alice@sidecare.com", name: "Alice", active: true)
    @bob = User.create!(email: "bob@sidecare.com", name: "Bob", active: true)
    @n = 0
    @a1 = account(am_email: "alice@sidecare.com", arr: 10_000)
    @a2 = account(am_email: "alice@sidecare.com", arr: 4_000)
    @b1 = account(am_email: "bob@sidecare.com", arr: 6_000)
    @free = account(arr: 8_000, has_sante: true, has_standard_sante: true)
    sign_in @admin
  end

  def account(**attrs)
    @n += 1
    BiAccount.create!({ kind: "set", bi_id: @n, name: "Compte Proj #{@n}", contracts_count: 1, synced_at: Time.current }.merge(attrs))
  end

  def key(account)
    "#{account.kind}:#{account.bi_id}"
  end

  def rows
    get projection_portefeuille_path
    @controller.instance_variable_get(:@rows).index_by { |r| r[:holder].name }
  end

  def owner_of(account)
    get projection_portefeuille_path
    projection = @controller.instance_variable_get(:@projection)
    entry = projection.entries.find { |e| e.account.id == account.id }
    projection.label(entry.key)
  end

  def bulk(action, keys: [], target: nil, **extra)
    post bulk_projection_portefeuille_path, params: { bulk_action: action, keys: keys, target: target, table: "comptes" }.merge(extra)
  end

  test "only real admins get in" do
    get projection_portefeuille_path
    assert_response :success
    assert_match "Projection #{AppSetting.instance.annee_en_cours + 1}", @response.body

    sign_out :user
    sign_in @alice
    get projection_portefeuille_path
    assert_redirected_to root_path
  end

  test "starts as the BO has it" do
    r = rows
    assert_equal [ 2, 2, 14_000.0 ], [ r["Alice"][:real_comptes], r["Alice"][:comptes], r["Alice"][:arr] ]
    assert_equal "Sans AM", owner_of(@free)
  end

  test "bulk-assign checked accounts, and back to the BO" do
    bulk("assign", keys: [ key(@a1), key(@a2) ], target: "user:#{@bob.id}")
    assert_redirected_to projection_portefeuille_path(anchor: "comptes")
    assert_match "2 comptes mis à jour", flash[:notice]
    r = rows
    assert_equal [ 0, 3, 20_000.0 ], [ r["Alice"][:comptes], r["Bob"][:comptes], r["Bob"][:arr] ]
    assert_equal [ 2, 1 ], [ r["Alice"][:real_comptes], r["Bob"][:real_comptes] ], "the BO side doesn't move"

    bulk("revert", keys: [ key(@a1) ])
    assert_equal "Alice", owner_of(@a1)
    assert_equal 1, Projection::Move.count

    bulk("assign", keys: [ key(@a2) ], target: "user:#{@alice.id}")
    assert_equal 0, Projection::Move.count, "a move back to the BO's AM is no move"
  end

  test "apply to every account of the filter, across pages" do
    bulk("reserve", all_filtered: "1", pc_owners: [ "Alice" ])
    assert_equal [ "À réattribuer", "À réattribuer", "Bob" ], [ owner_of(@a1), owner_of(@a2), owner_of(@b1) ]
    assert_equal 2, @controller.instance_variable_get(:@reserve)[:count]

    bulk("drop", all_filtered: "1", pc_owners: [ "À réattribuer" ])
    assert_equal "Non accompagné", owner_of(@a1)
    assert_equal 2, @controller.instance_variable_get(:@dropped)[:count]
  end

  test "a leaving AM's accounts wait in the reserve and they keep no capacity" do
    post toggle_departure_projection_portefeuille_path(user_id: @alice.id)
    r = rows
    assert r["Alice"][:holder].departing
    assert_equal [ 0, 0 ], [ r["Alice"][:comptes], r["Alice"][:limit] ]
    assert_equal "À réattribuer", owner_of(@a1)

    targets = @controller.instance_variable_get(:@targets).map(&:name)
    assert_not_includes targets, "Alice", "a leaving AM can't be given accounts"

    post toggle_departure_projection_portefeuille_path(user_id: @alice.id)
    assert_equal "Alice", owner_of(@a1)
  end

  test "a recruit takes accounts that have an AM in the BO, never unassigned ones" do
    post recruits_projection_portefeuille_path, params: { name: "Recrue AM 1", role: "AM" }
    recruit = Projection::Recruit.last
    assert_equal 54, recruit.account_limit

    bulk("assign", keys: [ key(@b1), key(@free) ], target: "recruit:#{recruit.id}")
    assert_match "1 compte mis à jour", flash[:notice]
    assert_match "1 ignoré", flash[:notice]
    assert_equal [ "Recrue AM 1", "Sans AM" ], [ owner_of(@b1), owner_of(@free) ]
    assert_equal 1, rows["Recrue AM 1"][:comptes]

    sans_am_targets = @controller.instance_variable_get(:@sans_am_targets).map(&:name)
    assert_not_includes sans_am_targets, "Recrue AM 1"

    delete recruit_projection_portefeuille_path(recruit_id: recruit.id)
    assert_equal "Bob", owner_of(@b1), "removing the recruit gives the account back to the BO's AM"
  end

  test "unassigned accounts can be given to a real AM in bulk from the Comptes sans AM table" do
    post bulk_projection_portefeuille_path, params: { bulk_action: "assign", table: "sans_am", all_filtered: "1", target: "user:#{@bob.id}" }
    assert_redirected_to projection_portefeuille_path(anchor: "sans_am")
    assert_equal "Bob", owner_of(@free)
    assert_empty @controller.instance_variable_get(:@ps_pager).records
  end

  test "a move tells whether the BO has caught up with it" do
    bulk("assign", keys: [ key(@a1) ], target: "user:#{@bob.id}")
    @a1.update!(am_email: "bob@sidecare.com")
    get projection_portefeuille_path
    entry = @controller.instance_variable_get(:@projection).entries.find { |e| e.account.id == @a1.id }
    assert_equal :applied, entry.status

    bulk("assign", keys: [ key(@a2) ], target: "user:#{@bob.id}")
    @a2.update!(am_email: "ancien@sidecare.com")
    get projection_portefeuille_path
    entry = @controller.instance_variable_get(:@projection).entries.find { |e| e.account.id == @a2.id }
    assert_equal :conflict, entry.status
  end

  test "the plan de mouvements lists every difference with the BO" do
    bulk("assign", keys: [ key(@a1) ], target: "user:#{@bob.id}")
    post toggle_departure_projection_portefeuille_path(user_id: @bob.id)
    get export_projection_portefeuille_path
    assert_response :success
    csv = @response.body
    assert_match "Compte Proj 1;Company set;;Alice;À réattribuer;Retiré à l'AM", csv, "assigned to a leaving AM: back to the reserve"
    assert_match "Compte Proj 3;Company set;;Bob;À réattribuer;AM sortant", csv
    assert_no_match "Compte Proj 2", csv
  end

  test "reset starts over from the BO, and no other page ever sees the projection" do
    bulk("drop", keys: [ key(@a1) ])
    post toggle_departure_projection_portefeuille_path(user_id: @bob.id)

    get attribution_portefeuille_path
    bi_rows = @controller.instance_variable_get(:@rows).index_by { |r| r[:name] }
    assert_equal [ 2, 1 ], [ bi_rows["Alice"][:comptes], bi_rows["Bob"][:comptes] ], "the BI view stays the BO's"

    delete projection_portefeuille_path
    assert_equal [ 0, 0, 0 ], [ Projection::Move.count, Projection::Departure.count, Projection::Recruit.count ]
  end

  test "the accounts table filters by AM concerned (either side) and by movement, bulk actions included" do
    bulk("assign", keys: [ key(@a1) ], target: "user:#{@bob.id}")     # Alice -> Bob
    bulk("reserve", keys: [ key(@a2) ])                                  # taken off Alice
    bulk("assign", keys: [ key(@free) ], target: "user:#{@alice.id}")   # unassigned -> Alice

    names = ->(params) {
      get projection_portefeuille_path(params)
      @controller.instance_variable_get(:@pc_pager).records.map { |e| e.account.name }.sort
    }
    assert_equal [ "Compte Proj 1", "Compte Proj 2", "Compte Proj 4" ], names.call(pc_concerned: [ "Alice" ]),
      "Alice's accounts in the BO (kept or lost) and the one she gains"
    assert_equal [ "Compte Proj 1", "Compte Proj 3" ], names.call(pc_concerned: [ "Bob" ])
    assert_equal [ "Compte Proj 1" ], names.call(pc_movements: [ "Réattribué" ])
    assert_equal [ "Compte Proj 2" ], names.call(pc_movements: [ "Retiré à l'AM" ])
    assert_equal [ "Compte Proj 4" ], names.call(pc_movements: [ "Attribué (était sans AM)" ])
    assert_equal [ "Compte Proj 3" ], names.call(pc_movements: [ ProjectionPortefeuilleController::NO_MOVEMENT ])
    assert_equal [ "Compte Proj 1", "Compte Proj 4" ], names.call(pc_concerned: [ "Alice" ], pc_movements: [ "Réattribué", "Attribué (était sans AM)" ])
    options = @controller.instance_variable_get(:@pc_concerned_options)
    assert_includes options, "Alice"
    assert_not_includes options, "À réattribuer", "places are not people"

    # "Tout le filtre" follows the new filters too, and the page comes back with them.
    bulk("revert", all_filtered: "1", pc_movements: [ "Retiré à l'AM" ])
    assert_redirected_to projection_portefeuille_path(pc_movements: [ "Retiré à l'AM" ], anchor: "comptes")
    assert_equal "Alice", owner_of(@a2)
  end

  test "the accounts table filters by ARR, minimum and / or maximum, bulk actions included" do
    names = ->(params) {
      get projection_portefeuille_path(params)
      @controller.instance_variable_get(:@pc_pager).records.map { |e| e.account.name }.sort
    }
    assert_equal [ "Compte Proj 1", "Compte Proj 3" ], names.call(pc_arr_min: "5000")
    assert_equal [ "Compte Proj 2", "Compte Proj 3" ], names.call(pc_arr_max: "8000")
    assert_equal [ "Compte Proj 3" ], names.call(pc_arr_min: "5 000", pc_arr_max: "6000"), "bounds included, spaces tolerated"
    assert_equal [ "Compte Proj 1", "Compte Proj 2", "Compte Proj 3" ], names.call(pc_arr_min: "abc"), "an unreadable bound is ignored"
    assert_match 'name="pc_arr_min"', @response.body

    bulk("reserve", all_filtered: "1", pc_arr_max: "5000")
    assert_redirected_to projection_portefeuille_path(pc_arr_max: "5000", anchor: "comptes")
    assert_equal [ "À réattribuer", "Alice", "Bob" ], [ owner_of(@a2), owner_of(@a1), owner_of(@b1) ]
  end

  test "a terminated account leaves the study, and can be brought back" do
    bulk("terminate", keys: [ key(@a1) ])
    assert_match "1 compte mis à jour", flash[:notice]
    r = rows
    assert_equal [ 2, 1, 4_000.0 ], [ r["Alice"][:real_comptes], r["Alice"][:comptes], r["Alice"][:arr] ], "out of Alice's projected portfolio"
    assert_equal [ 1, 10_000.0 ], @controller.instance_variable_get(:@terminated).values_at(:count, :arr)
    assert_equal 0, @controller.instance_variable_get(:@reserve)[:count], "not in the reserve either"
    listed = @controller.instance_variable_get(:@pc_pager).records.map { |e| e.account.name }
    assert_not_includes listed, "Compte Proj 1", "hidden from the accounts table by default"
    assert_not_includes @controller.instance_variable_get(:@pc_owner_options), "Résilié"

    # An unassigned account can be terminated from "Comptes sans AM" too, and leaves that list.
    post bulk_projection_portefeuille_path, params: { bulk_action: "terminate", table: "sans_am", keys: [ key(@free) ] }
    get projection_portefeuille_path
    assert_empty @controller.instance_variable_get(:@ps_pager).records

    get projection_portefeuille_path(pc_movements: [ "Résilié" ])
    assert_equal [ "Compte Proj 1", "Compte Proj 4" ], @controller.instance_variable_get(:@pc_pager).records.map { |e| e.account.name }.sort
    assert_match "Résilié", @response.body

    bulk("revert", all_filtered: "1", pc_movements: [ "Résilié" ])
    assert_equal [ "Alice", "Sans AM" ], [ owner_of(@a1), owner_of(@free) ]
    assert_equal 0, Projection::Move.count
  end

  test "small accounts with a sur-mesure health contract can be given to a team rather than an AM" do
    @a2.update!(has_sante: true, has_sur_mesure_sante: true)   # 4 000 € with Alice
    @free.update!(has_sur_mesure_sante: true)                  # 8 000 €, no AM

    post teams_projection_portefeuille_path, params: { name: "CSM Juniors" }
    team = Projection::Team.find_by!(name: "CSM Juniors")
    post teams_projection_portefeuille_path, params: { name: "csm juniors" }
    assert_equal 1, Projection::Team.count, "a team name is unique"

    get projection_portefeuille_path(pc_sm: "1", pc_arr_max: "5000")
    assert_equal [ "Compte Proj 2" ], @controller.instance_variable_get(:@pc_pager).records.map { |e| e.account.name }
    assert_match "Sur mesure mutuelle", @response.body
    assert_includes @controller.instance_variable_get(:@targets).map(&:name), "CSM Juniors"

    # Every account of the filter to the team, from the tracked table and from "Comptes sans AM".
    bulk("assign", all_filtered: "1", target: "team:#{team.id}", pc_sm: "1", pc_arr_max: "5000")
    post bulk_projection_portefeuille_path, params: { bulk_action: "assign", table: "sans_am", all_filtered: "1", ps_sm: "1", target: "team:#{team.id}" }
    assert_equal [ "CSM Juniors", "CSM Juniors", "Alice" ], [ owner_of(@a2), owner_of(@free), owner_of(@a1) ]

    r = rows
    assert_equal [ 2, 12_000.0, nil, nil, false ], r["CSM Juniors"].values_at(:comptes, :arr, :limit, :remaining, :over)
    assert_equal "Équipe", r["CSM Juniors"][:holder].role
    capacity = @controller.instance_variable_get(:@totals)
    assert_equal capacity[:capacity] - (r["Alice"][:comptes] + r["Bob"][:comptes]), capacity[:remaining], "a team doesn't use up the AMs' capacity"

    get projection_portefeuille_path(pc_movements: [ "Confié à une équipe" ])
    assert_equal [ "Compte Proj 2", "Compte Proj 4" ], @controller.instance_variable_get(:@pc_pager).records.map { |e| e.account.name }.sort

    delete team_projection_portefeuille_path(team_id: team.id)
    assert_equal [ "Alice", "Sans AM" ], [ owner_of(@a2), owner_of(@free) ], "removing the team gives the accounts back"
  end

  test "both tables filter by risk, bulk actions included" do
    @a1.update!(has_sante: true)
    @a2.update!(has_prevoyance: true)
    @b1.update!(has_sante: true, has_prevoyance: true)
    @free.update!(has_sante: true, has_prevoyance: true)

    names = ->(params, pager = :@pc_pager) {
      get projection_portefeuille_path(params)
      @controller.instance_variable_get(pager).records.map { |e| e.account.name }.sort
    }
    assert_equal [ "Compte Proj 1" ], names.call(pc_risques: [ "Santé" ])
    assert_equal [ "Compte Proj 2", "Compte Proj 3" ], names.call(pc_risques: [ "Prévoyance", "Double risque" ])
    assert_match 'name="pc_risques[]"', @response.body
    assert_equal [], names.call({ ps_risques: [ "Santé" ] }, :@ps_pager)
    assert_equal [ "Compte Proj 4" ], names.call({ ps_risques: [ "Double risque" ] }, :@ps_pager)

    bulk("reserve", all_filtered: "1", pc_risques: [ "Santé" ])
    assert_redirected_to projection_portefeuille_path(pc_risques: [ "Santé" ], anchor: "comptes")
    assert_equal [ "À réattribuer", "Alice", "Bob" ], [ owner_of(@a1), owner_of(@a2), owner_of(@b1) ]
  end

  test "the projected distribution shows each holder's average basket and upsell potential" do
    @a1.update!(has_sante: true, employees_count: 10)                       # missing prévoyance
    @a2.update!(has_sante: true, has_prevoyance: true, employees_count: 50) # nothing to sell
    bulk("assign", keys: [ key(@b1) ], target: "user:#{@alice.id}")
    @b1.update!(has_prevoyance: true, employees_count: 20)                  # missing mutuelle

    alice = rows["Alice"]
    assert_in_delta 20_000.0 / 3, alice[:basket], 0.01
    expected = UpsellDeal.rate_per_employee_for("Prévoyance") * 10 + UpsellDeal.rate_per_employee_for("Mutuelle") * 20
    assert_in_delta expected, alice[:upsell], 0.01
    assert_nil rows["Bob"][:basket], "no projected account, no basket"
    totals = @controller.instance_variable_get(:@totals)
    assert_in_delta expected, totals[:upsell], 0.01
    assert_in_delta 20_000.0 / 3, totals[:basket], 0.01
    assert_match "Panier moyen (€)", @response.body
    assert_match "Potentiel d&#39;upsell (€)", @response.body

    get projection_portefeuille_path(proj_sort: "upsell_amount", proj_dir: "desc")
    assert_equal "Alice", @controller.instance_variable_get(:@pager).records.first[:holder].name
  end

  test "an unknown action or recipient is refused" do
    bulk("assign", keys: [ key(@a1) ], target: "user:0")
    assert_equal "Destinataire introuvable.", flash[:alert]
    bulk("assign", keys: [], target: "user:#{@bob.id}")
    assert_equal "Aucun compte sélectionné.", flash[:alert]
  end
end
