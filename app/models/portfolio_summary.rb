# Ports computePortfolio(am) from the original app: AM-level (or, when constructed with User.all-derived
# companies, cross-AM) aggregate over produit + upsell deals. Deliberately a plain Ruby object, not an
# ActiveRecord model - this is pure aggregation over already-loaded deals, reused by both "Mon portefeuille"
# (Phase 2) and "Vue globale" (Phase 3).
class PortfolioSummary
  NRR_TARGET = 101
  # Portfolio-health budgets requested alongside the summary cards: churn should stay under 5.5% of the
  # initial ARR, and the ARR gained purely from renewal-rate increases should reach at least 5%.
  CHURN_LIMIT_PCT = 5.5
  RENEWAL_TARGET_PCT = 5.0

  attr_reader :companies, :user, :non_accompagne

  # `user:` scopes upsold/upsell-related figures to what's actually in that AM's pipeline right now (an
  # upsell explicitly reassigned to them counts here even for a company they don't own; one reassigned away
  # from them doesn't, even though the company is still theirs) - pass it for any single-AM summary. Omit
  # it for a cross-AM aggregate (e.g. Company.all): every upsell belongs to *someone* in that set either
  # way, so company-scoped and effective-ownership-scoped totals are the same sum.
  #
  # `non_accompagne:` optionally blends AppSetting's manually-tracked non-accompagné figures (ARR, churn,
  # churn projeté, taux de renouvellement) into arr_initial/churned/renewed_arr/renewal_gain/churn_projete
  # below, as if it were one more aggregate "deal" - see PilotageController, which passes this only for Vue
  # globale's top summary cards, gated by the Équipe filter's "Non accompagné" option. Every other
  # PortfolioSummary caller (Mon portefeuille, the AM roster) omits it and is completely unaffected.
  def initialize(companies, user: nil, non_accompagne: nil)
    @companies = companies.to_a
    @user = user
    @non_accompagne = non_accompagne
  end

  def produit_deals
    @produit_deals ||= companies.flat_map(&:produit_deals)
  end

  def upsell_deals
    @upsell_deals ||= if user
      company_ids = companies.map(&:id)
      UpsellDeal.where(user_id: user.id).or(UpsellDeal.where(user_id: nil, company_id: company_ids)).to_a
    else
      companies.flat_map(&:upsell_deals)
    end
  end

  def count
    produit_deals.size + upsell_deals.size
  end

  # Excludes "subi" churn (company liquidated or acquired, not lost to a competitor) from the denominator
  # every NRR/churn figure below is built on - see ProduitDeal::CHURNED_SUBI. Without this, a liquidated
  # client's original ARR would still drag NRR down even though `arr_final`/`churned` already don't count it.
  def arr_initial
    produit_deals.reject(&:churn_subi?).sum { |d| d.arr.to_f } + non_accompagne_arr
  end

  def churned
    produit_deals.select(&:churned?).reject(&:churn_subi?).sum { |d| d.arr.to_f } + non_accompagne_churn
  end

  # The ARR lost to "subi" churn - shown alongside the Churn card for visibility, but deliberately not
  # folded into `churned`/`arr_initial`/any NRR figure above.
  def churn_subi_amount
    produit_deals.select(&:churn_subi?).sum { |d| d.arr.to_f }
  end

  # Purely informational total (churned + churn_subi_amount) for AMs who want the full picture of ARR lost
  # this period regardless of cause. Deliberately not used anywhere else - churn_rate, churn_within_limit?,
  # arr_initial and every NRR figure must keep excluding "subi" churn, per churn_subi_amount above.
  def churn_with_subi
    churned + churn_subi_amount
  end

  # Only fully-signed upsells - the confirmed number behind the "Upsell" card. See `upsold` for the
  # probability-weighted projection behind "Upsell projeté".
  def upsold_actual
    upsell_deals.select(&:signed?).sum(&:upsell_amount)
  end

  # Projected, not actual-only: a signed upsell already carries probabilite_signature 100 (see UpsellDeal's
  # business rule), so it still contributes its full amount here - the only difference from `upsold_actual`
  # is that in-pipeline upsells contribute their probability-weighted share too, instead of $0 until signed.
  def upsold
    upsell_deals.sum(&:projection)
  end

  def renewed_arr
    produit_deals.reject(&:churned?).sum(&:final_arr) + non_accompagne_renewed_contribution
  end

  # "Autres impacts" (manual, one-off ARR impacts), each side counted on its own: "Validé" lines feed only
  # the actual figures (ARR final actuel, NRR actuel), "En cours" lines only the projected ones (ARR final
  # projeté, NRR projeté) - a line never counts on both sides, matching the Actuel / Projeté totals of the
  # "Autres impacts" section.
  def other_impacts
    @other_impacts ||= companies.flat_map(&:current_other_impacts)
  end

  def other_impacts_validated
    other_impacts.select(&:validated?).sum { |i| i.amount.to_f }
  end

  def other_impacts_pending
    other_impacts.reject(&:validated?).sum { |i| i.amount.to_f }
  end

  # Behind the "ARR final" card - renewed ARR plus only the upsells actually signed so far.
  def arr_final_actual
    renewed_arr + upsold_actual + other_impacts_validated
  end

  # The ARR the produits still alive are expected to end up with once renewed, each weighted by its chance of
  # surviving (1 − risque_churn): a produit at 10% risk contributes 90% of its renewed ARR - increase included -
  # because if it churns, the negotiated increase is lost along with the base. Only a manually tracked
  # non-accompagné churn projeté (an amount, with no per-contract risk) is subtracted as a lump sum.
  def renewed_arr_projected
    produit_deals.reject(&:churned?).sum(&:risk_adjusted_final_arr) + non_accompagne_renewed_contribution - non_accompagne_churn_projete
  end

  # Behind the "ARR final projeté" card (and so the projected NRR) - the risk-weighted renewed ARR plus every
  # upsell's probability-weighted projection. Forward-looking, unlike `arr_final_actual`: an account that might
  # churn counts only for its chance of staying, so its renewal-rate increase isn't counted as if it were certain.
  def arr_final
    renewed_arr_projected + upsold + other_impacts_pending
  end

  def nrr_actual
    arr_initial > 0 ? (arr_final_actual / arr_initial * 100) : 0
  end

  def nrr
    arr_initial > 0 ? (arr_final / arr_initial * 100) : 0
  end

  def nrr_actual_target_met?
    nrr_actual >= NRR_TARGET
  end

  def target_met?
    nrr >= NRR_TARGET
  end

  # The ARR gained (or lost) purely from renewal-rate negotiation - final_arr minus arr for every
  # non-churned produit deal, i.e. arr × taux/100 summed. Distinct from churn (ARR removed) and upsold
  # (ARR added from upsells): this isolates what the negotiated renewal rates themselves contributed.
  def renewal_gain
    produit_deals.reject(&:churned?).sum { |d| d.arr.to_f * d.taux.to_f / 100 } + non_accompagne_renewal_gain
  end

  # Risk-weighted ARR of produits that haven't churned yet (arr × risque_churn/100, summed) - the AM's own
  # estimate of what's likely to be lost next, distinct from `churned` (already lost). Already-churned
  # produits are excluded here since their loss is counted once, in `churned`, not twice.
  def churn_projete
    produit_deals.reject(&:churned?).sum { |d| d.arr.to_f * d.risque_churn.to_f / 100 } + non_accompagne_churn_projete
  end

  # Actual churn plus the projected risk on what's still active - the single figure the 5.5% budget is
  # meant to protect against going forward, not just what has already happened.
  def churn_total
    churned + churn_projete
  end

  def churn_limit
    arr_initial * CHURN_LIMIT_PCT / 100
  end

  # churned/churn_total re-expressed as a % of arr_initial, so the Churn cards can show a rate alongside
  # the raw € amount - same pattern as renewal_rate below.
  def churn_rate
    arr_initial > 0 ? (churned / arr_initial * 100) : 0
  end

  def churn_total_rate
    arr_initial > 0 ? (churn_total / arr_initial * 100) : 0
  end

  def churn_within_limit?
    churned <= churn_limit
  end

  def churn_total_within_limit?
    churn_total <= churn_limit
  end

  def renewal_target
    arr_initial * RENEWAL_TARGET_PCT / 100
  end

  def renewal_target_met?
    renewal_gain >= renewal_target
  end

  # Behind the "Taux de renouvellement" card - renewal_gain re-expressed as a % of arr_initial, so it reads
  # alongside NRR/churn as a rate rather than a raw € amount. Equivalent to renewal_target_met? at the 5%
  # mark, just expressed directly as a percentage instead of comparing two € figures.
  def renewal_rate
    arr_initial > 0 ? (renewal_gain / arr_initial * 100) : 0
  end

  # The projected counterpart of renewal_gain, like the projected NRR: each produit's negotiated increase is
  # weighted by its chance of staying (1 − risque_churn), since the increase on a contract that churns is never
  # collected. The non-accompagné gain has no per-contract risk and counts as is.
  def renewal_gain_projected
    produit_deals.reject(&:churned?).sum { |d| d.arr.to_f * d.taux.to_f / 100 * (1 - d.risque_churn.to_f / 100) } +
      non_accompagne_renewal_gain
  end

  def renewal_rate_projected
    arr_initial > 0 ? (renewal_gain_projected / arr_initial * 100) : 0
  end

  def renewal_target_met_projected?
    renewal_gain_projected >= renewal_target
  end

  private

  def non_accompagne_arr
    non_accompagne ? non_accompagne.arr_non_accompagne.to_f : 0
  end

  def non_accompagne_churn
    non_accompagne ? non_accompagne.churn_non_accompagne.to_f : 0
  end

  # No individual deals behind the non-accompagné book, so there's no risque_churn % to weight - just the
  # manually-tracked € figure, which is the whole year's expected churn of that book. What has already churned
  # (the "Détail churn" lines, in `churned`) is part of it: only the remainder is still projected, never below
  # zero - like a real deal moving from churn_projete to churned when it churns, so an actual churn within the
  # projection leaves churn_total unchanged instead of being counted twice. It feeds churn_projete and, via
  # arr_final, the projected NRR/ARR final cards only - the "actuel" variants never subtract churn_projete.
  def non_accompagne_churn_projete
    return 0 unless non_accompagne

    [ non_accompagne.churn_projete_non_accompagne.to_f - non_accompagne_churn, 0 ].max
  end

  # What's left of the non-accompagné book once its own actual churn comes out - never negative, in case
  # someone enters a churn figure larger than the ARR it's meant to be a share of.
  def non_accompagne_active_arr
    [ non_accompagne_arr - non_accompagne_churn, 0 ].max
  end

  # Treated like one more aggregate "deal": the still-active share of the non-accompagné book, grown by its
  # own taux de renouvellement - the same arr × (1 + taux/100) shape as ProduitDeal#final_arr.
  def non_accompagne_renewed_contribution
    return 0 unless non_accompagne
    non_accompagne_active_arr * (1 + non_accompagne.taux_renouvellement_non_accompagne.to_f / 100)
  end

  def non_accompagne_renewal_gain
    return 0 unless non_accompagne
    non_accompagne_active_arr * non_accompagne.taux_renouvellement_non_accompagne.to_f / 100
  end
end
