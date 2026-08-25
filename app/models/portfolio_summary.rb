# Ports computePortfolio(am) from the original app: AM-level (or, when constructed with User.all-derived
# companies, cross-AM) aggregate over produit + upsell deals. Deliberately a plain Ruby object, not an
# ActiveRecord model — this is pure aggregation over already-loaded deals, reused by both "Mon portefeuille"
# (Phase 2) and "Vue globale" (Phase 3).
class PortfolioSummary
  NRR_TARGET = 101
  # Portfolio-health budgets requested alongside the summary cards: churn should stay under 5.5% of the
  # initial ARR, and the ARR gained purely from renewal-rate increases should reach at least 5%.
  CHURN_LIMIT_PCT = 5.5
  RENEWAL_TARGET_PCT = 5.0

  attr_reader :companies, :user

  # `user:` scopes upsold/upsell-related figures to what's actually in that AM's pipeline right now (an
  # upsell explicitly reassigned to them counts here even for a company they don't own; one reassigned away
  # from them doesn't, even though the company is still theirs) — pass it for any single-AM summary. Omit
  # it for a cross-AM aggregate (e.g. Company.all): every upsell belongs to *someone* in that set either
  # way, so company-scoped and effective-ownership-scoped totals are the same sum.
  def initialize(companies, user: nil)
    @companies = companies.to_a
    @user = user
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

  def arr_initial
    produit_deals.sum { |d| d.arr.to_f }
  end

  def churned
    produit_deals.select(&:churned?).sum { |d| d.arr.to_f }
  end

  def upsold
    upsell_deals.select(&:signed?).sum(&:upsell_amount)
  end

  def renewed_arr
    produit_deals.reject(&:churned?).sum(&:final_arr)
  end

  def arr_final
    renewed_arr + upsold
  end

  def nrr
    arr_initial > 0 ? (arr_final / arr_initial * 100) : 0
  end

  def target_met?
    nrr >= NRR_TARGET
  end

  # The ARR gained (or lost) purely from renewal-rate negotiation — final_arr minus arr for every
  # non-churned produit deal, i.e. arr × taux/100 summed. Distinct from churn (ARR removed) and upsold
  # (ARR added from upsells): this isolates what the negotiated renewal rates themselves contributed.
  def renewal_gain
    produit_deals.reject(&:churned?).sum { |d| d.arr.to_f * d.taux.to_f / 100 }
  end

  def churn_limit
    arr_initial * CHURN_LIMIT_PCT / 100
  end

  def churn_within_limit?
    churned <= churn_limit
  end

  def renewal_target
    arr_initial * RENEWAL_TARGET_PCT / 100
  end

  def renewal_target_met?
    renewal_gain >= renewal_target
  end
end
