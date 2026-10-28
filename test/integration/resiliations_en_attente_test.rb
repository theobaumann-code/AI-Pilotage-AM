require "test_helper"

# Temporary "Suivi des résiliations" rubric: produits flagged "A résilier" or renewed as "Nouveau contrat", each with
# its latest 2026 BO termination on the same company, risk and collège.
class ResiliationsEnAttenteTest < ActionDispatch::IntegrationTest
  setup do
    @admin = User.create!(email: "admin-resil@example.com", name: "Admin Resil", admin: true, active: true)
    @kam = User.create!(email: "kam-resil@example.com", name: "KAM Resil", kam: true, active: true)
    @am = User.create!(email: "am-resil@example.com", name: "Am Suivi", active: true)
    acme = Company.create!(name: "ACME", user: @am)
    groupe = Company.create!(name: "Groupe Suivi", user: @am)
    @flagged = deal(acme, "Prévoyance", "Cadre", a_resilier: true)
    @nouveau = deal(acme, "Mutuelle", "Non cadre", statut_renouvellement: "Nouveau contrat")
    @without = deal(groupe, "Mutuelle", "Ensemble du personnel", a_resilier: true)
    deal(acme, "Mutuelle", "Cadre") # neither flagged nor a new contract: not followed

    BiAccount.create!(kind: "set", bi_id: 10, name: "Groupe Suivi", arr: 50_000, synced_at: Time.current)
    termination(1, social_name: "Acme SAS", product_type: 2, college_type: 1, operation_status: 5, created_on: Date.new(2026, 3, 1))
    termination(2, social_name: "ACME", name: "AXA - Prévoyance - Cadres", product_type: 2, college_type: 1,
      operation_status: 1, created_on: Date.new(2026, 9, 1))
    termination(3, social_name: "ACME", product_type: 2, college_type: 2, created_on: Date.new(2026, 10, 1)) # other collège
    termination(4, social_name: "ACME", product_type: 3, college_type: 2, operation_status: 8, created_on: Date.new(2026, 5, 1))
    termination(5, social_name: "Filiale", account_kind: "set", account_bi_id: 10, product_type: 2, college_type: 3) # other risk
  end

  def deal(company, produit, college, **attrs)
    ProduitDeal.create!({ company: company, produit: produit, college: college, assureur: "AXA", arr: 1_000, taux: 0,
      statut_renouvellement: "En cours" }.merge(attrs))
  end

  def termination(id, **attrs)
    BiPendingTermination.create!({ bi_id: id, account_kind: "user_pro", account_bi_id: 100 + id, user_pro_id: id,
      created_on: Date.new(2026, 10, 1), termination_date: Date.new(2026, 12, 31), synced_at: Time.current }.merge(attrs))
  end

  def listed
    @controller.instance_variable_get(:@pager).records.to_h { |r| [ r[:deal].id, r[:termination]&.bi_id ] }
  end

  test "follows only the flagged produits and new contracts, each with its latest matching termination" do
    sign_in @admin
    get resiliations_en_attente_path
    assert_response :success
    assert_equal({ @flagged.id => 2, @nouveau.id => 4, @without.id => nil }, listed,
      "same company by name, same risk (santé et prévoyance covers both) and collège; the latest one wins")
    assert_equal({ count: 3, with_termination: 2, without_termination: 1, arr: 3_000.0 },
      @controller.instance_variable_get(:@all_total))
    assert_match "En attente de signature", @response.body
    assert_match "Statut BO 8", @response.body
    assert_match "Aucune résiliation 2026 en cours", @response.body
  end

  test "a group is searched on every user pro of its company set" do
    filiale = Company.create!(name: "Filiale Nord", user: @am)
    produit = deal(filiale, "Mutuelle", "Cadre", a_resilier: true)
    termination(6, social_name: "Filiale Nord", account_kind: "set", account_bi_id: 10, product_type: 2, college_type: 1)
    termination(7, social_name: "Filiale Sud", account_kind: "set", account_bi_id: 10, product_type: 1, college_type: 1)
    sign_in @admin
    get resiliations_en_attente_path
    assert_equal 7, listed[produit.id], "the termination sits on another user pro of the group"
  end

  test "the BO refresh goes back to the page, filters kept, and reports BigQuery being unreachable" do
    sign_in @admin
    back = resiliations_en_attente_path(risques: [ "Mutuelle" ])
    post sync_resiliations_en_attente_path, headers: { "HTTP_REFERER" => "http://www.example.com#{back}" }
    assert_redirected_to "http://www.example.com#{back}"
    assert_match "Actualisation impossible", flash[:alert]
  end

  test "filters by team, risk, status and search" do
    sign_in @admin
    get resiliations_en_attente_path, params: { statuts: [ "Aucune résiliation 2026 en cours" ] }
    assert_equal [ @without.id ], listed.keys
    get resiliations_en_attente_path, params: { risques: [ "Prévoyance" ] }
    assert_equal [ @flagged.id ], listed.keys
    get resiliations_en_attente_path, params: { q: "groupe" }
    assert_equal [ @without.id ], listed.keys

    kam_produit = deal(Company.create!(name: "Client KAM", user: @kam), "Mutuelle", "Cadre", a_resilier: true)
    get resiliations_en_attente_path, params: { roles: [ "KAM" ] }
    assert_equal [ kam_produit.id ], listed.keys
    get resiliations_en_attente_path, params: { roles: [ "AM" ] }
    assert_equal [ @flagged.id, @nouveau.id, @without.id ].sort, listed.keys.sort
  end

  test "admins only, and the sidebar links to it" do
    sign_in @kam
    get resiliations_en_attente_path
    assert_redirected_to root_path

    sign_in @admin
    get resiliations_en_attente_path
    assert_select "a.app-nav-link.active", text: "Suivi des résiliations"
  end
end
