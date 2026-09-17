require "test_helper"

class PortfolioSummaryTest < ActiveSupport::TestCase
  setup do
    @am = User.create!(email: "am-summary@example.com", name: "AM Summary", active: true)
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
    other_am = User.create!(email: "other-summary@example.com", name: "Other Summary", active: true)
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
    other_am = User.create!(email: "other-summary2@example.com", name: "Other Summary 2", active: true)
    UpsellDeal.create!(company: @company, produit: "Mutuelle", nombre_salaries: 10,
      probabilite_signature: 100, statut_signature: "Signé", user: other_am)

    unscoped = PortfolioSummary.new(@am.companies.includes(:deals))
    assert_equal 1, unscoped.upsell_deals.size, "company-scoped mode ignores the override entirely"
  end

  test "upsold is the probability-weighted projection across every upsell, not just signed ones" do
    UpsellDeal.create!(company: @company, produit: "Mutuelle", nombre_salaries: 10,
      probabilite_signature: 100, statut_signature: "Signé", arr: 1_000)
    UpsellDeal.create!(company: @company, produit: "Prévoyance", nombre_salaries: 5,
      probabilite_signature: 50, statut_signature: "En cours", arr: 2_000)

    # Signed contributes its full amount (probability already forced to 100), the in-pipeline one
    # contributes half its estimate — not $0, the way a signed-only total would.
    assert_in_delta 1_000 + 1_000, summary.upsold, 0.01
  end

  test "churn_projete is the risk-weighted ARR of produits that haven't churned yet" do
    ProduitDeal.create!(company: @company, produit: "Mutuelle", identifiant: "1",
      college: "Cadre", assureur: "AXA", arr: 10_000, taux: 0, statut_renouvellement: "En cours", risque_churn: 20)
    ProduitDeal.create!(company: @company, produit: "Prévoyance", identifiant: "2",
      college: "Cadre", assureur: "AXA", arr: 5_000, taux: 0, statut_renouvellement: "Churné", risque_churn: 40)

    # Only the non-churned deal counts (10_000 * 20%) — the churned one is already counted in `churned`,
    # not double-counted here even though its risque_churn was forced to 100 by the model callback.
    assert_in_delta 2_000, summary.churn_projete, 0.01
    assert_in_delta 5_000 + 2_000, summary.churn_total, 0.01
  end

  test "churn_total_within_limit? blends actual and projected churn against the 5.5% budget" do
    ProduitDeal.create!(company: @company, produit: "Mutuelle", identifiant: "1",
      college: "Cadre", assureur: "AXA", arr: 100_000, taux: 0, statut_renouvellement: "En cours", risque_churn: 10)

    # initial = 100_000, limit = 5_500; churned = 0, projected = 100_000 * 10% = 10_000 — over the limit
    # even though nothing has actually churned yet.
    assert summary.churn_within_limit?
    assert_not summary.churn_total_within_limit?
  end

  test "upsold_actual counts only signed upsells, unlike the probability-weighted upsold" do
    UpsellDeal.create!(company: @company, produit: "Mutuelle", nombre_salaries: 10,
      probabilite_signature: 100, statut_signature: "Signé", arr: 1_000)
    UpsellDeal.create!(company: @company, produit: "Prévoyance", nombre_salaries: 5,
      probabilite_signature: 50, statut_signature: "En cours", arr: 2_000)

    assert_in_delta 1_000, summary.upsold_actual, 0.01
    assert_in_delta 1_000 + 1_000, summary.upsold, 0.01
  end

  test "arr_final_actual and nrr_actual use only signed upsells; arr_final/nrr use the projection" do
    ProduitDeal.create!(company: @company, produit: "Mutuelle", identifiant: "1",
      college: "Cadre", assureur: "AXA", arr: 100_000, taux: 0, statut_renouvellement: "En cours")
    UpsellDeal.create!(company: @company, produit: "Prévoyance", nombre_salaries: 5,
      probabilite_signature: 50, statut_signature: "En cours", arr: 2_000)

    assert_in_delta 100_000, summary.arr_final_actual, 0.01
    assert_in_delta 100.0, summary.nrr_actual, 0.01
    assert_in_delta 101_000, summary.arr_final, 0.01
    assert_in_delta 101.0, summary.nrr, 0.01
  end

  test "arr_final/nrr subtract projected churn risk, unlike arr_final_actual/nrr_actual" do
    ProduitDeal.create!(company: @company, produit: "Mutuelle", identifiant: "1",
      college: "Cadre", assureur: "AXA", arr: 100_000, taux: 0, statut_renouvellement: "En cours", risque_churn: 10)

    # renewed_arr = 100_000 (nothing churned yet), churn_projete = 100_000 * 10% = 10_000.
    # arr_final_actual/nrr_actual ignore that risk entirely; arr_final/nrr must bake it in.
    assert_in_delta 100_000, summary.arr_final_actual, 0.01
    assert_in_delta 100.0, summary.nrr_actual, 0.01
    assert_in_delta 90_000, summary.arr_final, 0.01
    assert_in_delta 90.0, summary.nrr, 0.01
  end

  test "renewal_rate is renewal_gain expressed as a % of arr_initial" do
    ProduitDeal.create!(company: @company, produit: "Mutuelle", identifiant: "1",
      college: "Cadre", assureur: "AXA", arr: 100_000, taux: 5, statut_renouvellement: "Augmenté")

    assert_in_delta 5.0, summary.renewal_rate, 0.01
    assert summary.renewal_target_met?
  end
end
