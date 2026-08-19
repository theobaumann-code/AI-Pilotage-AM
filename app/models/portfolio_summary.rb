# Ports computePortfolio(am) from the original app: AM-level (or, when constructed with User.all-derived
# companies, cross-AM) aggregate over produit + upsell deals. Deliberately a plain Ruby object, not an
# ActiveRecord model — this is pure aggregation over already-loaded deals, reused by both "Mon portefeuille"
# (Phase 2) and "Vue globale" (Phase 3).
class PortfolioSummary
  NRR_TARGET = 101

  attr_reader :companies

  def initialize(companies)
    @companies = companies.to_a
  end

  def produit_deals
    @produit_deals ||= companies.flat_map(&:produit_deals)
  end

  def upsell_deals
    @upsell_deals ||= companies.flat_map(&:upsell_deals)
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
end
