require "test_helper"

class PortfolioSummaryTest < ActiveSupport::TestCase
  setup do
    @am = User.create!(email: "am-summary@example.com", password: "password123", name: "AM Summary", active: true)
    @company = Company.create!(name: "Cabinet Summary", user: @am)
  end

  def summary
    PortfolioSummary.new(@am.companies.includes(:deals))
  end

  test "renewal_gain is the ARR delta from taux alone, excluding churned deals" do
    ProduitDeal.create!(company: @company, produit: "Mutuelle", identifiant: "1",
      college: "Cadre", assureur: "AXA", arr: 10_000, taux: 5, statut_renouvellement: "Augmenté")
    ProduitDeal.create!(company: @company, produit: "Prévoyance", identifiant: "2",
      college: "Cadre", assureur: "AXA", arr: 20_000, taux: 10, statut_renouvellement: "Churné")

    # 10_000 * 5% = 500 from the renewed deal; the churned deal (taux forced to 0 by the model callback,
    # and excluded anyway) contributes nothing.
    assert_in_delta 500, summary.renewal_gain, 0.01
  end

  test "churn_within_limit? compares churned ARR against 5.5% of the initial ARR" do
    ProduitDeal.create!(company: @company, produit: "Mutuelle", identifiant: "1",
      college: "Cadre", assureur: "AXA", arr: 100_000, taux: 0, statut_renouvellement: "En cours")
    ProduitDeal.create!(company: @company, produit: "Prévoyance", identifiant: "2",
      college: "Cadre", assureur: "AXA", arr: 5_000, taux: 0, statut_renouvellement: "Churné")

    # initial = 105_000, limit = 5.5% = 5_775 — 5_000 churned stays under it.
    assert summary.churn_within_limit?
    assert_in_delta 5_775, summary.churn_limit, 0.01
  end

  test "churn_within_limit? is false once churn exceeds the 5.5% budget" do
    ProduitDeal.create!(company: @company, produit: "Mutuelle", identifiant: "1",
      college: "Cadre", assureur: "AXA", arr: 100_000, taux: 0, statut_renouvellement: "En cours")
    ProduitDeal.create!(company: @company, produit: "Prévoyance", identifiant: "2",
      college: "Cadre", assureur: "AXA", arr: 10_000, taux: 0, statut_renouvellement: "Churné")

    # initial = 110_000, limit = 6_050 — 10_000 churned blows past it.
    assert_not summary.churn_within_limit?
  end

  test "renewal_target_met? compares the renewal gain against a 5% target of the initial ARR" do
    ProduitDeal.create!(company: @company, produit: "Mutuelle", identifiant: "1",
      college: "Cadre", assureur: "AXA", arr: 100_000, taux: 5, statut_renouvellement: "Augmenté")

    # initial = 100_000, target = 5_000, gain = 100_000 * 5% = 5_000 — exactly meets it.
    assert_in_delta 5_000, summary.renewal_target, 0.01
    assert summary.renewal_target_met?
  end

  test "with user:, upsold reflects effective ownership rather than company ownership" do
    other_am = User.create!(email: "other-summary@example.com", password: "password123", name: "Other Summary", active: true)
    own_upsell = UpsellDeal.create!(company: @company, produit: "Mutuelle", nombre_salaries: 10,
      probabilite_signature: 100, statut_signature: "Signé")
    reassigned_away = UpsellDeal.create!(company: @company, produit: "Prévoyance", nombre_salaries: 10,
      probabilite_signature: 100, statut_signature: "Signé", user: other_am)

    scoped = PortfolioSummary.new(@am.companies.includes(:deals), user: @am)
    assert_equal [own_upsell], scoped.upsell_deals
    assert_in_delta own_upsell.upsell_amount, scoped.upsold, 0.01

    # An upsell explicitly reassigned to other_am counts in *their* summary even though the company itself
    # still belongs to @am — no company of other_am's own is needed for it to show up.
    other_scoped = PortfolioSummary.new(other_am.companies.includes(:deals), user: other_am)
    assert_equal [reassigned_away], other_scoped.upsell_deals
  end

  test "without user:, upsold stays company-scoped (used for cross-AM aggregates)" do
    other_am = User.create!(email: "other-summary2@example.com", password: "password123", name: "Other Summary 2", active: true)
    UpsellDeal.create!(company: @company, produit: "Mutuelle", nombre_salaries: 10,
      probabilite_signature: 100, statut_signature: "Signé", user: other_am)

    unscoped = PortfolioSummary.new(@am.companies.includes(:deals))
    assert_equal 1, unscoped.upsell_deals.size, "company-scoped mode ignores the override entirely"
  end
end
