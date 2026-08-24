require "test_helper"

class ProduitDealTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "am1@example.com", password: "password123", name: "AM Un", active: true)
    @company = Company.create!(name: "Cabinet Test", user: @user)
  end

  def build_deal(overrides = {})
    ProduitDeal.new({
      company: @company,
      produit: "Mutuelle",
      identifiant: "418123456",
      college: "Ensemble du personnel",
      assureur: "AXA",
      arr: 42_000,
      taux: 2,
      statut_renouvellement: "Augmenté"
    }.merge(overrides))
  end

  test "valid with all required fields" do
    assert build_deal.valid?
  end

  test "rejects a duplicate identifiant for the same produit" do
    build_deal.save!
    dup = build_deal(identifiant: "418123456", college: "Cadre") # different college, same produit+identifiant
    assert_not dup.valid?
    assert_includes dup.errors[:identifiant], "has already been taken"
  end

  test "allows the same identifiant on a different produit" do
    build_deal(produit: "Mutuelle").save!
    other_produit = build_deal(produit: "Prévoyance", college: "Cadre")
    assert other_produit.valid?
  end

  # This is the trickiest rule from the original app: identifiant uniqueness is scoped to ACTIVE data
  # only — an archived year (a completely separate ArchiveEntry row, not a Deal) must never block reuse
  # of the same identifiant by a brand new company in a later year (e.g. a company churned out, and a
  # different company later reuses the same external ID).
  test "allows reusing an identifiant that only exists in the archive, not in active deals" do
    ArchiveEntry.create!(
      year: 2025, am_name: @user.name, company_name: "Ancienne Entreprise",
      deal_type: "ProduitDeal", produit: "Mutuelle", identifiant: "418123456",
      college: "Ensemble du personnel", assureur: "AXA", statut_renouvellement: "Churné"
    )
    fresh = build_deal # same identifiant+produit as the archived row above, but NO active Deal uses it
    assert fresh.valid?, "identifiant reuse should be allowed once the prior deal is archived (not active)"
  end

  test "rejects a second produit+collège+assureur combo for the same company" do
    build_deal(college: "Cadre", assureur: "AXA").save!
    dup = build_deal(identifiant: "different-id", college: "Cadre", assureur: "AXA")
    assert_not dup.valid?
    assert_includes dup.errors[:college], "has already been taken"
  end

  test "allows a different collège for the same company+produit" do
    build_deal(college: "Cadre", identifiant: "id-1").save!
    other_college = build_deal(college: "Non cadre", identifiant: "id-2")
    assert other_college.valid?
  end

  # Rule change: a company may hold several contracts for the same produit+collège as long as each is
  # with a different insurer (e.g. split across two insurers for the same population segment).
  test "allows the same produit+collège for the same company when the assureur differs" do
    build_deal(college: "Cadre", assureur: "AXA", identifiant: "id-1").save!
    other_assureur = build_deal(college: "Cadre", assureur: "Allianz", identifiant: "id-2")
    assert other_assureur.valid?
  end

  test "churn always forces taux to 0" do
    deal = build_deal(taux: 15, statut_renouvellement: "Churné")
    deal.valid?
    assert_equal 0, deal.taux.to_i
  end

  test "taux is left untouched for non-churned statuses" do
    deal = build_deal(taux: 15, statut_renouvellement: "Nouveau contrat")
    deal.valid?
    assert_equal 15, deal.taux.to_i
  end

  test "final_arr excludes upsell and is 0 when churned" do
    deal = build_deal(arr: 10_000, taux: 0, statut_renouvellement: "Churné")
    assert_equal 0, deal.final_arr
  end

  test "final_arr applies the negotiated taux when not churned" do
    deal = build_deal(arr: 10_000, taux: 10, statut_renouvellement: "Augmenté")
    assert_in_delta 11_000, deal.final_arr, 0.01
  end

  test "rejects an unrecognized produit" do
    deal = build_deal(produit: "Autre")
    assert_not deal.valid?
  end
end
