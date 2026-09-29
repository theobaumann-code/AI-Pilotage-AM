require "test_helper"

# Vue globale gained its own "Import en masse (CSV)" / "+ Nouveau produit" / "+ Nouvel upsell" toolbar,
# mirroring Mon portefeuille's — privileged (admin/KAM) only, since creating from here means picking a
# company out of every AM's book. Each of these forms carries return_to=pilotage so DealsController and
# ImportsController land the admin back on Vue globale afterward instead of their own Mon portefeuille
# (see DealsController#fallback_redirect_path).
class PilotageToolbarTest < ActionDispatch::IntegrationTest
  setup do
    @admin = User.create!(email: "admin-toolbar@example.com", name: "Admin Toolbar", admin: true, active: true)
    @am = User.create!(email: "am-toolbar@example.com", name: "AM Toolbar", admin: false, active: true)
    @company = Company.create!(name: "Client Toolbar", user: @am)
  end

  test "an admin sees the Import/Nouveau produit/Nouvel upsell toolbar on Vue globale" do
    sign_in @admin
    get pilotage_path
    assert_response :success
    assert_match "Import en masse (CSV)", @response.body
    assert_match "+ Nouveau produit", @response.body
    assert_match "+ Nouvel upsell", @response.body
  end

  test "a non-admin AM does not see that toolbar on Vue globale" do
    sign_in @am
    get pilotage_path
    assert_response :success
    assert_no_match "+ Nouveau produit", @response.body
    assert_no_match "+ Nouvel upsell", @response.body
  end

  test "creating a produit from Vue globale (return_to=pilotage) redirects back to Vue globale" do
    sign_in @admin
    post deals_path(type: "produit", return_to: "pilotage"),
      params: { company_id: @company.id, deal: { produit: "Mutuelle", college: "Cadre", assureur: "AXA",
        identifiant: "toolbar-1", arr: 1_000, taux: 0, statut_renouvellement: "En cours" } }
    assert_redirected_to pilotage_path
    assert ProduitDeal.exists?(identifiant: "toolbar-1")
  end

  test "creating an upsell from Vue globale (return_to=pilotage) redirects back to Vue globale" do
    sign_in @admin
    post deals_path(type: "upsell", return_to: "pilotage"),
      params: { company_id: @company.id, deal: { produit: "Mutuelle", college: "Cadre",
        nombre_salaries: 5, probabilite_signature: 20, statut_signature: "Non démarré" } }
    assert_redirected_to pilotage_path
  end

  test "a failed creation from Vue globale still redirects back to Vue globale, not Mon portefeuille" do
    sign_in @admin
    post deals_path(type: "produit", return_to: "pilotage"),
      params: { company_id: @company.id, deal: { produit: "Pas un produit valide", college: "Cadre",
        assureur: "AXA", identifiant: "toolbar-invalid", arr: 1_000, taux: 0, statut_renouvellement: "En cours" } }
    assert_redirected_to pilotage_path
    assert_not ProduitDeal.exists?(identifiant: "toolbar-invalid")
  end
end
