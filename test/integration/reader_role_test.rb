require "test_helper"

# "Lecteur": can sign in and consult everything, can change nothing (enforced server-side on every non-GET
# request), and doesn't show up in any table filter/select — they're consultative accounts, not people
# anyone is assigned to.
class ReaderRoleTest < ActionDispatch::IntegrationTest
  setup do
    @admin = User.create!(email: "admin-reader@example.com", name: "Admin Lecture", admin: true, active: true)
    @am = User.create!(email: "am-reader@example.com", name: "AM Lecture", active: true)
    @reader = User.create!(email: "reader@example.com", name: "Zoé Lectrice", role: "Lecteur", active: true)
    @company = Company.create!(name: "Client Lecture", user: @am)
    @deal = ProduitDeal.create!(company: @company, produit: "Mutuelle", identifiant: "rd-1", college: "Cadre",
      assureur: "AXA", arr: 10_000, taux: 2, statut_renouvellement: "En cours", risque_churn: 20)
  end

  test "the role is labelled Lecteur, read-only, and neither admin nor privileged" do
    assert_equal :reader, @reader.role
    assert_equal "Lecteur", @reader.role_label
    assert @reader.read_only?
    assert_not @reader.privileged?
    assert_not @am.read_only?
    assert_not @admin.read_only?
  end

  test "a lecteur can browse Vue globale and exports, and lands there instead of an empty portfolio" do
    sign_in @reader
    get pilotage_path
    assert_response :success
    assert_match "Client Lecture", @response.body
    assert_no_match "Mon portefeuille", @response.body

    get portfolio_path
    assert_redirected_to pilotage_path

    get export_produits_pilotage_path
    assert_response :success
    get autres_statistiques_path
    assert_response :success
    get historique_path
    assert_response :success
  end

  test "every kind of write is refused for a lecteur and changes nothing" do
    sign_in @reader

    assert_no_difference "RiskNote.count" do
      post risk_notes_path, params: { company_id: @company.id, risk_note: { content: "Je ne devrais pas pouvoir" } }
    end
    assert_response :redirect
    assert_match "lecture seule", flash[:alert].to_s

    patch company_path(@company), params: { company: { risque_manque_offres: "1" } }
    assert_not @company.reload.risque_manque_offres?

    patch deal_path(@deal), params: { deal: { risque_churn: 90 }, row_context: "global_produit" },
      headers: { "Accept" => "text/vnd.turbo-stream.html" }
    assert_equal 20, @deal.reload.risque_churn

    assert_no_difference "ProduitDeal.count" do
      post deals_path, params: { type: "produit", company_id: @company.id,
        deal: { produit: "Prévoyance", college: "Cadre", assureur: "AXA", arr: 1, identifiant: "rd-new" } }
    end

    assert_no_difference "User.count" do
      post users_path, params: { user: { name: "X", email: "x@example.com", role: "Admin" } }
    end
    assert_no_difference "Company.count" do
      delete company_path(@company)
    end
  end

  test "a lecteur can still sign out" do
    sign_in @reader
    delete destroy_user_session_path
    assert_redirected_to root_path
  end

  test "lecteurs are left out of every AM filter and select, while real users stay" do
    sign_in @admin

    get pilotage_path
    assert_response :success
    assert_no_match "Zoé Lectrice", @response.body
    assert_match "AM Lecture", @response.body

    get portfolio_path
    assert_no_match "Zoé Lectrice", @response.body

    get historique_path
    assert_no_match "Zoé Lectrice", @response.body

    get autres_statistiques_path
    assert_no_match "Zoé Lectrice", @response.body
  end

  test "Gestion des droits still lists lecteurs so they can be managed, with their own badge" do
    sign_in @admin
    get gestion_droits_path
    assert_match "Zoé Lectrice", @response.body
    assert_match(/badge reader">Lecteur/, @response.body)
    assert_match "Lecteur", @response.body[/id="edit-am-role".*?<\/select>/m]
  end

  test "an admin can create a lecteur, and switch someone to or from that role" do
    sign_in @admin
    post users_path, params: { user: { name: "Nouveau Lecteur", email: "nouveau-lecteur@example.com", role: "Lecteur" } }
    created = User.find_by!(email: "nouveau-lecteur@example.com")
    assert created.read_only?

    patch user_path(created), params: { user: { name: created.name, email: created.email, role: "KAM" } }
    assert created.reload.kam?
    assert_not created.reader?

    patch user_path(created), params: { user: { name: created.name, email: created.email, role: "Lecteur" } }
    assert created.reload.read_only?
  end

  test "promoting a lecteur with the admin/KAM toggle makes them a real admin/KAM, no longer read-only" do
    sign_in @admin
    patch user_path(@reader), params: { admin: "1" }
    assert @reader.reload.admin?
    assert_not @reader.reader?
    assert_not @reader.read_only?
  end

  test "someone who owns clients can't be made a lecteur, and no client can be assigned to one" do
    sign_in @admin
    patch user_path(@am), params: { user: { name: @am.name, email: @am.email, role: "Lecteur" } }
    assert_not @am.reload.read_only?
    assert_match "réassignez", flash[:alert].to_s

    patch reassign_am_company_path(@company), params: { user_id: @reader.id }
    assert_equal @am, @company.reload.user

    assert_not Company.new(name: "Direct", user: @reader).valid?
  end

  test "a deactivated lecteur can't sign in any more than any other deactivated user" do
    @reader.update!(active: false)
    assert_not @reader.active_for_authentication?
  end
end
