require "test_helper"

class UpsellDealTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "am2@example.com", name: "AM Deux", active: true)
    @company = Company.create!(name: "Cabinet Upsell", user: @user)
  end

  def build_deal(overrides = {})
    UpsellDeal.new({
      company: @company,
      produit: "Mutuelle",
      college: "Ensemble du personnel",
      nombre_salaries: 10,
      probabilite_signature: 50,
      statut_signature: "En cours"
    }.merge(overrides))
  end

  test "valid with all required fields" do
    assert build_deal.valid?
  end

  test "college must be one of ProduitDeal's known values" do
    assert_not build_deal(college: "Bogus").valid?
    assert build_deal(college: "Cadre").valid?
  end

  test "college defaults to the same catalog's first entry when left unset, instead of failing presence" do
    deal = UpsellDeal.new(company: @company, produit: "Mutuelle", nombre_salaries: 10,
      probabilite_signature: 50, statut_signature: "En cours")
    assert_equal ProduitDeal::COLLEGES.first, deal.college
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

  test "moving off Signé resets the forced 100 back to 0 instead of leaving it stuck" do
    deal = build_deal(probabilite_signature: 40, statut_signature: "Signé")
    deal.save!
    assert_equal 100, deal.probabilite_signature

    deal.update!(statut_signature: "En cours")
    assert_equal 0, deal.probabilite_signature
  end

  test "editing another field on an already-non-signed upsell does not touch probabilite_signature" do
    deal = build_deal(probabilite_signature: 40, statut_signature: "En cours")
    deal.save!

    deal.update!(nombre_salaries: 12)
    assert_equal 40, deal.probabilite_signature
  end

  test "arr is computed as nombre_salaries × rate × commission, per produit" do
    mutuelle = build_deal(produit: "Mutuelle", nombre_salaries: 10)
    mutuelle.save!
    assert_in_delta 10 * 140.0 * 0.07, mutuelle.arr, 0.01 # 98.00

    prevoyance = build_deal(produit: "Prévoyance", nombre_salaries: 10)
    prevoyance.save!
    assert_in_delta 10 * 36.0 * 0.07, prevoyance.arr, 0.01 # 25.20

    combined = build_deal(produit: "Mutuelle/Prévoyance", nombre_salaries: 10)
    combined.save!
    assert_in_delta 10 * (140.0 + 36.0) * 0.07, combined.arr, 0.01 # 123.20
  end

  test "a larger headcount always yields a larger arr for the same produit — the whole point of the switch away from Bonus Tracker" do
    smaller = build_deal(produit: "Mutuelle/Prévoyance", nombre_salaries: 140)
    smaller.save!
    larger = build_deal(produit: "Mutuelle/Prévoyance", nombre_salaries: 300)
    larger.save!

    assert larger.arr > smaller.arr
  end

  test "arr recomputes on every save, regardless of statut_signature — every upsell gets a real, comparable figure" do
    deal = build_deal(produit: "Mutuelle", nombre_salaries: 10, statut_signature: "Perdu")
    deal.save!
    assert_in_delta 10 * 140.0 * 0.07, deal.arr, 0.01

    deal.update!(nombre_salaries: 20)
    assert_in_delta 20 * 140.0 * 0.07, deal.arr, 0.01
  end

  test "upsell_amount reads the computed arr, and the deal is always arr_estimable? under the new formula" do
    deal = build_deal(produit: "Mutuelle", nombre_salaries: 10)
    deal.save!
    assert_in_delta deal.arr, deal.upsell_amount, 0.01
    assert deal.arr_estimable?
    assert_match "10 salarié(s)", deal.arr_estimation_reference
    assert_equal "generique-par-salarie-v1", deal.arr_estimation_formula_version
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
