require "test_helper"

class UpsellDealTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "am2@example.com", password: "password123", name: "AM Deux", active: true)
    @company = Company.create!(name: "Cabinet Upsell", user: @user)
  end

  def build_deal(overrides = {})
    UpsellDeal.new({
      company: @company,
      produit: "Mutuelle",
      nombre_salaries: 10,
      probabilite_signature: 50,
      statut_signature: "En cours"
    }.merge(overrides))
  end

  test "valid with all required fields" do
    assert build_deal.valid?
  end

  test "accepts the combined Mutuelle/Prévoyance produit (upsell-only)" do
    assert build_deal(produit: "Mutuelle/Prévoyance").valid?
  end

  test "marking Signé always forces probabilite_signature to 100" do
    deal = build_deal(probabilite_signature: 40, statut_signature: "Signé")
    deal.valid?
    assert_equal 100, deal.probabilite_signature
  end

  test "probabilite_signature is left untouched for non-signed statuses" do
    deal = build_deal(probabilite_signature: 40, statut_signature: "En cours")
    deal.valid?
    assert_equal 40, deal.probabilite_signature
  end

  test "upsell_amount is derived from nombre_salaries and the produit rate, never stored" do
    deal = build_deal(produit: "Mutuelle", nombre_salaries: 10)
    assert_in_delta 1_400.0, deal.upsell_amount, 0.01 # 10 × 140
  end

  test "identifiant uniqueness does not apply to upsells (no identifiant column meaning here)" do
    build_deal.save!
    assert build_deal.valid?, "a second upsell for the same company+produit should not collide on identifiant"
  end

  test "does not allow duplicate identifiants across produit deals to affect upsells" do
    ProduitDeal.create!(
      company: @company, produit: "Mutuelle", identifiant: "999",
      college: "Cadre", assureur: "AXA", statut_renouvellement: "En cours"
    )
    assert build_deal.valid?
  end
end
