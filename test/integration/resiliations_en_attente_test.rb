require "test_helper"

# Temporary "Résiliations en attente" rubric: BO terminations waiting for signature on accounts that have an AM.
class ResiliationsEnAttenteTest < ActionDispatch::IntegrationTest
  setup do
    @admin = User.create!(email: "admin-resil@example.com", name: "Admin Resil", admin: true, active: true)
    @kam = User.create!(email: "kam-resil@example.com", name: "KAM Resil", kam: true, active: true)
    @with_am = BiAccount.create!(kind: "set", bi_id: 10, name: "Groupe Suivi", am_email: "am@sidecare.com", am_name: "Am Suivi",
      arr: 50_000, synced_at: Time.current)
    @other_am = BiAccount.create!(kind: "user_pro", bi_id: 20, name: "Solo", am_email: "kam@sidecare.com", am_name: "Kam Deux",
      arr: 8_000, synced_at: Time.current)
    BiAccount.create!(kind: "user_pro", bi_id: 30, name: "Sans AM", arr: 9_000, synced_at: Time.current)
    termination(1, "set", 10, social_name: "Filiale A", name: "AXA - Prévoyance - Cadres", terminable_type: "InternalContract",
      product_type: 2, contract_arr: 4_000)
    termination(2, "set", 10, social_name: "Filiale B", name: "Generali - Santé", terminable_type: "ExternalContract", product_type: 1)
    termination(3, "user_pro", 20, social_name: "Solo SAS", name: "Swiss - Santé", terminable_type: "InternalContract",
      product_type: 1, contract_arr: 1_500)
    termination(4, "user_pro", 30, social_name: "Sans AM SAS", name: "Hors périmètre", terminable_type: "InternalContract", product_type: 1)
    termination(5, "user_pro", 99, social_name: "Inconnu", name: "Compte absent de la BI", product_type: 6)
  end

  def termination(id, kind, account_id, **attrs)
    BiPendingTermination.create!({ bi_id: id, account_kind: kind, account_bi_id: account_id, user_pro_id: id,
      created_on: Date.new(2026, 10, id), termination_date: Date.new(2026, 12, 31), synced_at: Time.current }.merge(attrs))
  end

  def listed
    @controller.instance_variable_get(:@pager).records.map { |r| r[:termination].bi_id }.sort
  end

  test "lists only the terminations of accounts with an AM, with their totals" do
    sign_in @admin
    get resiliations_en_attente_path
    assert_response :success
    assert_equal [ 1, 2, 3 ], listed, "no AM, or no account in the BI: left out"
    assert_equal({ count: 3, accounts: 2, arr: 5_500.0 }, @controller.instance_variable_get(:@all_total))
    assert_match "Contrat SideCare", @response.body
    assert_match "Contrat externe", @response.body
    assert_match "Am Suivi", @response.body
    assert_no_match "Hors périmètre", @response.body
  end

  test "filters by AM, type, product and search" do
    sign_in @admin
    get resiliations_en_attente_path, params: { ams: [ "Kam Deux" ] }
    assert_equal [ 3 ], listed
    get resiliations_en_attente_path, params: { types: [ "Contrat externe" ] }
    assert_equal [ 2 ], listed
    get resiliations_en_attente_path, params: { products: [ "Santé" ] }
    assert_equal [ 2, 3 ], listed
    get resiliations_en_attente_path, params: { q: "filiale" }
    assert_equal [ 1, 2 ], listed
    assert_equal 4_000.0, @controller.instance_variable_get(:@total)[:arr]
  end

  test "admins only, and the sidebar links to it" do
    sign_in @kam
    get resiliations_en_attente_path
    assert_redirected_to root_path

    sign_in @admin
    get resiliations_en_attente_path
    assert_select "a.app-nav-link.active", text: "Résiliations en attente"
  end
end
