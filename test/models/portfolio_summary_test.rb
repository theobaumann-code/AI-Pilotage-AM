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

    # initial = 105_000, limit = 5.5% = 5_775 - 5_000 churned stays under it.
    assert summary.churn_within_limit?
    assert_in_delta 5_775, summary.churn_limit, 0.01
  end

  test "churn_within_limit? is false once churn exceeds the 5.5% budget" do
    ProduitDeal.create!(company: @company, produit: "Mutuelle", identifiant: "1",
      college: "Cadre", assureur: "AXA", arr: 100_000, taux: 0, statut_renouvellement: "En cours")
    ProduitDeal.create!(company: @company, produit: "Prévoyance", identifiant: "2",
      college: "Cadre", assureur: "AXA", arr: 10_000, taux: 0, statut_renouvellement: "Churné")

    # initial = 110_000, limit = 6_050 - 10_000 churned blows past it.
    assert_not summary.churn_within_limit?
  end

  test "renewal_target_met? compares the renewal gain against a 5% target of the initial ARR" do
    ProduitDeal.create!(company: @company, produit: "Mutuelle", identifiant: "1",
      college: "Cadre", assureur: "AXA", arr: 100_000, taux: 5, statut_renouvellement: "Augmenté")

    # initial = 100_000, target = 5_000, gain = 100_000 * 5% = 5_000 - exactly meets it.
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
    assert_equal [ own_upsell ], scoped.upsell_deals
    assert_in_delta own_upsell.upsell_amount, scoped.upsold, 0.01

    # An upsell explicitly reassigned to other_am counts in *their* summary even though the company itself
    # still belongs to @am - no company of other_am's own is needed for it to show up.
    other_scoped = PortfolioSummary.new(other_am.companies.includes(:deals), user: other_am)
    assert_equal [ reassigned_away ], other_scoped.upsell_deals
  end

  test "without user:, upsold stays company-scoped (used for cross-AM aggregates)" do
    other_am = User.create!(email: "other-summary2@example.com", name: "Other Summary 2", active: true)
    UpsellDeal.create!(company: @company, produit: "Mutuelle", nombre_salaries: 10,
      probabilite_signature: 100, statut_signature: "Signé", user: other_am)

    unscoped = PortfolioSummary.new(@am.companies.includes(:deals))
    assert_equal 1, unscoped.upsell_deals.size, "company-scoped mode ignores the override entirely"
  end

  test "upsold is the probability-weighted projection across every upsell, not just signed ones" do
    signed = UpsellDeal.create!(company: @company, produit: "Mutuelle", nombre_salaries: 10,
      probabilite_signature: 100, statut_signature: "Signé")
    pipeline = UpsellDeal.create!(company: @company, produit: "Prévoyance", nombre_salaries: 5,
      probabilite_signature: 50, statut_signature: "En cours")

    # Signed contributes its full amount (probability already forced to 100), the in-pipeline one
    # contributes half its estimate - not $0, the way a signed-only total would.
    assert_in_delta signed.upsell_amount + pipeline.upsell_amount * 0.5, summary.upsold, 0.01
  end

  test "a lost upsell no longer counts in the projected upsell, even if it had a high chance before the decision" do
    kept = UpsellDeal.create!(company: @company, produit: "Mutuelle", nombre_salaries: 10,
      probabilite_signature: 50, statut_signature: "En cours")
    lost = UpsellDeal.create!(company: @company, produit: "Prévoyance", nombre_salaries: 5,
      probabilite_signature: 80, statut_signature: "En cours")
    assert_in_delta kept.upsell_amount * 0.5 + lost.upsell_amount * 0.8, summary.upsold, 0.01

    lost.update!(statut_signature: "Perdu")
    assert_in_delta kept.upsell_amount * 0.5, summary.upsold, 0.01
  end

  test "churn_projete is the risk-weighted ARR of produits that haven't churned yet" do
    ProduitDeal.create!(company: @company, produit: "Mutuelle", identifiant: "1",
      college: "Cadre", assureur: "AXA", arr: 10_000, taux: 0, statut_renouvellement: "En cours", risque_churn: 20)
    ProduitDeal.create!(company: @company, produit: "Prévoyance", identifiant: "2",
      college: "Cadre", assureur: "AXA", arr: 5_000, taux: 0, statut_renouvellement: "Churné", risque_churn: 40)

    # Only the non-churned deal counts (10_000 * 20%) - the churned one is already counted in `churned`,
    # not double-counted here even though its risque_churn was forced to 100 by the model callback.
    assert_in_delta 2_000, summary.churn_projete, 0.01
    assert_in_delta 5_000 + 2_000, summary.churn_total, 0.01
  end

  test "churn_total_within_limit? blends actual and projected churn against the 5.5% budget" do
    ProduitDeal.create!(company: @company, produit: "Mutuelle", identifiant: "1",
      college: "Cadre", assureur: "AXA", arr: 100_000, taux: 0, statut_renouvellement: "En cours", risque_churn: 10)

    # initial = 100_000, limit = 5_500; churned = 0, projected = 100_000 * 10% = 10_000 - over the limit
    # even though nothing has actually churned yet.
    assert summary.churn_within_limit?
    assert_not summary.churn_total_within_limit?
  end

  test "upsold_actual counts only signed upsells, unlike the probability-weighted upsold" do
    signed = UpsellDeal.create!(company: @company, produit: "Mutuelle", nombre_salaries: 10,
      probabilite_signature: 100, statut_signature: "Signé")
    pipeline = UpsellDeal.create!(company: @company, produit: "Prévoyance", nombre_salaries: 5,
      probabilite_signature: 50, statut_signature: "En cours")

    assert_in_delta signed.upsell_amount, summary.upsold_actual, 0.01
    assert_in_delta signed.upsell_amount + pipeline.upsell_amount * 0.5, summary.upsold, 0.01
  end

  test "arr_final_actual and nrr_actual use only signed upsells; arr_final/nrr use the projection" do
    ProduitDeal.create!(company: @company, produit: "Mutuelle", identifiant: "1",
      college: "Cadre", assureur: "AXA", arr: 100_000, taux: 0, statut_renouvellement: "En cours")
    pipeline = UpsellDeal.create!(company: @company, produit: "Prévoyance", nombre_salaries: 5,
      probabilite_signature: 50, statut_signature: "En cours")

    assert_in_delta 100_000, summary.arr_final_actual, 0.01
    assert_in_delta 100.0, summary.nrr_actual, 0.01
    assert_in_delta 100_000 + pipeline.projection, summary.arr_final, 0.01
    assert_in_delta (100_000 + pipeline.projection) / 100_000 * 100, summary.nrr, 0.01
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

  test "churn_rate and churn_total_rate express churned/churn_total as a % of arr_initial" do
    ProduitDeal.create!(company: @company, produit: "Mutuelle", identifiant: "1",
      college: "Cadre", assureur: "AXA", arr: 100_000, taux: 0, statut_renouvellement: "En cours", risque_churn: 10)
    ProduitDeal.create!(company: @company, produit: "Prévoyance", identifiant: "2",
      college: "Cadre", assureur: "AXA", arr: 10_000, taux: 0, statut_renouvellement: "Churné")

    # initial = 110_000; churned = 10_000 -> 9.09%; churn_projete = 100_000 * 10% = 10_000,
    # churn_total = 20_000 -> 18.18%.
    assert_in_delta 9.09, summary.churn_rate, 0.01
    assert_in_delta 18.18, summary.churn_total_rate, 0.01
  end

  test "churn_rate and churn_total_rate are 0 when arr_initial is 0" do
    assert_equal 0, summary.churn_rate
    assert_equal 0, summary.churn_total_rate
  end

  # "Subi" churn (company liquidated/acquired) must not move NRR at all - neither help nor hurt it - so it
  # has to come out of arr_initial (the denominator), not just out of churned/renewed_arr.
  test "Churné (subi) is excluded from arr_initial, churned and NRR entirely" do
    ProduitDeal.create!(company: @company, produit: "Mutuelle", identifiant: "1",
      college: "Cadre", assureur: "AXA", arr: 100_000, taux: 5, statut_renouvellement: "Augmenté")
    ProduitDeal.create!(company: @company, produit: "Prévoyance", identifiant: "2",
      college: "Cadre", assureur: "AXA", arr: 50_000, taux: 0, statut_renouvellement: "Churné (subi)")

    # arr_initial is 100_000 (the liquidated company's 50_000 is excluded), so NRR is computed purely off
    # the one real, controllable renewal - as if the "subi" deal never existed for this purpose.
    assert_in_delta 100_000, summary.arr_initial, 0.01
    assert_in_delta 0, summary.churned, 0.01
    assert_in_delta 105_000, summary.arr_final_actual, 0.01
    assert_in_delta 105.0, summary.nrr_actual, 0.01
  end

  test "churn_subi_amount reports the excluded ARR without folding it into churned" do
    ProduitDeal.create!(company: @company, produit: "Mutuelle", identifiant: "1",
      college: "Cadre", assureur: "AXA", arr: 20_000, taux: 0, statut_renouvellement: "Churné")
    ProduitDeal.create!(company: @company, produit: "Prévoyance", identifiant: "2",
      college: "Cadre", assureur: "AXA", arr: 50_000, taux: 0, statut_renouvellement: "Churné (subi)")

    assert_in_delta 20_000, summary.churned, 0.01
    assert_in_delta 50_000, summary.churn_subi_amount, 0.01
  end

  test "churn_with_subi sums churned and churn_subi_amount but never feeds into arr_initial, rate or NRR" do
    ProduitDeal.create!(company: @company, produit: "Mutuelle", identifiant: "1",
      college: "Cadre", assureur: "AXA", arr: 100_000, taux: 5, statut_renouvellement: "Augmenté")
    ProduitDeal.create!(company: @company, produit: "Prévoyance", identifiant: "2",
      college: "Cadre", assureur: "AXA", arr: 20_000, taux: 0, statut_renouvellement: "Churné")
    ProduitDeal.create!(company: @company, produit: "Mutuelle", identifiant: "3",
      college: "Non cadre", assureur: "AXA", arr: 50_000, taux: 0, statut_renouvellement: "Churné (subi)")

    assert_in_delta 70_000, summary.churn_with_subi, 0.01

    # The purely informational total must not leak into any of the figures it's displayed alongside:
    # arr_initial/churned/churn_rate/churn_within_limit?/nrr_actual are all computed exactly as if
    # churn_with_subi didn't exist (limit = 120_000 * 5.5% = 6_600, blown past by the 20_000 real churn
    # alone - the 50_000 "subi" deal must not make it look worse or better).
    assert_in_delta 120_000, summary.arr_initial, 0.01
    assert_in_delta 20_000, summary.churned, 0.01
    assert_in_delta (20_000.0 / 120_000 * 100), summary.churn_rate, 0.01
    assert_not summary.churn_within_limit?
    assert_in_delta 87.5, summary.nrr_actual, 0.01
  end

  NonAccompagne = Struct.new(:arr_non_accompagne, :churn_non_accompagne, :churn_projete_non_accompagne,
    :taux_renouvellement_non_accompagne)

  test "non_accompagne: blends the non-accompagné book into arr_initial/churned/renewed_arr like one more deal" do
    ProduitDeal.create!(company: @company, produit: "Mutuelle", identifiant: "1",
      college: "Cadre", assureur: "AXA", arr: 100_000, taux: 0, statut_renouvellement: "En cours")
    non_accompagne = NonAccompagne.new(50_000, 10_000, 0, 2.0)

    with_na = PortfolioSummary.new(@am.companies.includes(:deals), non_accompagne: non_accompagne)

    # arr_initial: 100_000 (real deal) + 50_000 (non accompagné) = 150_000.
    assert_in_delta 150_000, with_na.arr_initial, 0.01
    # churned: 0 (real deal) + 10_000 (non accompagné's own churn) = 10_000.
    assert_in_delta 10_000, with_na.churned, 0.01
    # renewed_arr: 100_000 (real deal, taux 0) + (50_000 - 10_000) * 1.02 = 100_000 + 40_800 = 140_800.
    assert_in_delta 140_800, with_na.renewed_arr, 0.01
  end

  test "non_accompagne: churn_projete_non_accompagne only affects the projected figures, not the actual ones" do
    ProduitDeal.create!(company: @company, produit: "Mutuelle", identifiant: "1",
      college: "Cadre", assureur: "AXA", arr: 100_000, taux: 0, statut_renouvellement: "En cours")
    non_accompagne = NonAccompagne.new(50_000, 0, 8_000, 0)

    with_na = PortfolioSummary.new(@am.companies.includes(:deals), non_accompagne: non_accompagne)

    assert_in_delta 8_000, with_na.churn_projete, 0.01
    # arr_final_actual (renewed_arr + upsold_actual) never subtracts churn_projete.
    assert_in_delta 150_000, with_na.arr_final_actual, 0.01
    # arr_final (projeté) does: 150_000 - 8_000 = 142_000.
    assert_in_delta 142_000, with_na.arr_final, 0.01
  end

  test "omitting non_accompagne: leaves every figure exactly as before (no accidental default blending)" do
    ProduitDeal.create!(company: @company, produit: "Mutuelle", identifiant: "1",
      college: "Cadre", assureur: "AXA", arr: 100_000, taux: 0, statut_renouvellement: "En cours")

    assert_in_delta 100_000, summary.arr_initial, 0.01
    assert_in_delta 0, summary.churned, 0.01
    assert_in_delta 100_000, summary.renewed_arr, 0.01
  end

  def deal(produit, arr:, taux: 0, risque: 0, statut: "En cours")
    @n = (@n || 0) + 1
    ProduitDeal.create!(company: @company, produit: produit, identifiant: "nrr-proj-#{@n}", college: "Cadre",
      assureur: ProduitDeal::ASSUREURS[@n % ProduitDeal::ASSUREURS.size], arr: arr, taux: taux,
      statut_renouvellement: statut, risque_churn: risque)
  end

  test "projected ARR final weights each produit by its chance of staying, so an increase on a contract that may churn isn't counted as certain" do
    deal("Mutuelle", arr: 100_000, taux: 10, risque: 20)

    # 110 000 once renewed, but a 20% chance of churning: 110 000 × 80% = 88 000 expected - not the 110 000 − 20 000
    # = 90 000 the old formula gave, which kept the whole increase.
    assert_in_delta 88_000, summary.renewed_arr_projected, 0.01
    assert_in_delta 88_000, summary.arr_final, 0.01
    assert_in_delta 88.0, summary.nrr, 0.001
    assert_in_delta 110_000, summary.arr_final_actual, 0.01, "the actual figures are untouched"
    assert_in_delta 110.0, summary.nrr_actual, 0.001
  end

  test "a produit certain to churn (100% risk) but not yet marked churned contributes nothing, increase included" do
    deal("Mutuelle", arr: 50_000, taux: 8, risque: 100)
    deal("Prévoyance", arr: 50_000, taux: 0, risque: 0)

    assert_in_delta 50_000, summary.arr_final, 0.01, "only the safe produit remains"
    assert_in_delta 50.0, summary.nrr, 0.001
    # before the fix the 8% (4 000) of a contract certain to be lost was still counted: 50 000 × 1.08 − 50 000 + 50 000 = 54 000
  end

  test "with no churn risk the projected figures are unchanged, and the risk-free produits are counted in full" do
    deal("Mutuelle", arr: 100_000, taux: 3, risque: 0)
    assert_in_delta 103_000, summary.arr_final, 0.01
    assert_in_delta 103.0, summary.nrr, 0.001
  end

  test "the projected NRR only moves with the increase of safe contracts: the riskier the contract, the less its increase counts" do
    deal("Mutuelle", arr: 100_000, taux: 10, risque: 0)
    safe = summary.nrr
    ProduitDeal.destroy_all
    @n = 0
    deal("Mutuelle", arr: 100_000, taux: 10, risque: 50)
    risky = summary.nrr
    assert_in_delta 110.0, safe, 0.001
    assert_in_delta 55.0, risky, 0.001
    assert_operator risky, :<, safe
  end

  test "the projected renewal rate weights each increase by the chance the contract stays, next to the actual rate" do
    deal("Mutuelle", arr: 100_000, taux: 10, risque: 20)
    deal("Prévoyance", arr: 100_000, taux: 4, risque: 0)
    deal("Mutuelle", arr: 100_000, taux: 8, risque: 100)
    s = summary

    # actual: every produit still alive at its entered rate - (10 000 + 4 000 + 8 000) / 300 000
    assert_in_delta 22_000, s.renewal_gain, 0.01
    assert_in_delta 22_000 / 300_000.0 * 100, s.renewal_rate, 0.001
    # projected: 10 000 × 80% + 4 000 × 100% + 8 000 × 0% = 12 000
    assert_in_delta 12_000, s.renewal_gain_projected, 0.01
    assert_in_delta 12_000 / 300_000.0 * 100, s.renewal_rate_projected, 0.001
    assert_operator s.renewal_rate_projected, :<, s.renewal_rate
  end

  test "renewal_target_met_projected? compares the projected gain with the 5% objective" do
    deal("Mutuelle", arr: 100_000, taux: 6, risque: 0)
    assert summary.renewal_target_met_projected?, "6% with no risk beats 5%"

    ProduitDeal.destroy_all
    @n = 0
    deal("Mutuelle", arr: 100_000, taux: 6, risque: 30)
    assert summary.renewal_target_met?, "the actual rate (6%) reaches the objective..."
    assert_not summary.renewal_target_met_projected?, "...but 6% × 70% = 4.2% no longer does once the churn risk is counted"
  end

  test "no churn risk: projected renewal rate equals the actual one; no ARR: zero" do
    deal("Mutuelle", arr: 50_000, taux: 3, risque: 0)
    assert_in_delta summary.renewal_rate, summary.renewal_rate_projected, 0.0001

    ProduitDeal.destroy_all
    assert_equal 0, summary.renewal_rate_projected
  end

  test "the churn figures are unchanged: churn projeté is still the base ARR at risk, not the increased ARR" do
    deal("Mutuelle", arr: 100_000, taux: 10, risque: 20)
    s = summary
    assert_in_delta 20_000, s.churn_projete, 0.01
    assert_in_delta 20_000, s.churn_total, 0.01
    assert_in_delta 20.0, s.churn_total_rate, 0.001
    assert_in_delta 0, s.churned, 0.01
  end

  test "already churned produits and the non-accompagné lump sum behave as before in the projected ARR" do
    deal("Mutuelle", arr: 40_000, taux: 5, risque: 10)
    deal("Prévoyance", arr: 10_000, taux: 0, statut: "Churné") # risque forced to 100, counted in churned
    setting = AppSetting.instance
    setting.update!(arr_non_accompagne: 20_000, churn_projete_non_accompagne: 1_000,
      taux_renouvellement_non_accompagne: 2)
    s = PortfolioSummary.new(@am.companies.includes(:deals), non_accompagne: setting)

    # accompagné: 40 000 × 1.05 × 90% = 37 800 ; non accompagné: 20 000 × 1.02 − 1 000 (manual churn projeté) = 19 400
    assert_in_delta 37_800 + 19_400, s.renewed_arr_projected, 0.01
    assert_in_delta 37_800 + 19_400, s.arr_final, 0.01
  end

  test "non_accompagne: an actual churn within the yearly projection moves from projected to actual, not on top" do
    deal("Mutuelle", arr: 100_000, taux: 0, risque: 0)
    projected_only = PortfolioSummary.new(@am.companies.includes(:deals),
      non_accompagne: NonAccompagne.new(50_000, 0, 8_000, 0))
    with_churn = PortfolioSummary.new(@am.companies.includes(:deals),
      non_accompagne: NonAccompagne.new(50_000, 2_300, 8_000, 0))

    assert_in_delta 2_300, with_churn.churned, 0.01
    assert_in_delta 5_700, with_churn.churn_projete, 0.01, "only the 8 000 € projection's remainder is still projected"
    assert_in_delta projected_only.churn_total, with_churn.churn_total, 0.01, "the projected total doesn't move"
    assert_in_delta projected_only.arr_final, with_churn.arr_final, 0.01, "nor does the projected ARR final"

    beyond = PortfolioSummary.new(@am.companies.includes(:deals),
      non_accompagne: NonAccompagne.new(50_000, 9_000, 8_000, 0))
    assert_in_delta 0, beyond.churn_projete, 0.01, "past the projection, nothing more is projected"
    assert_in_delta 9_000, beyond.churn_total, 0.01, "and the total follows the actual churn"
  end
end
