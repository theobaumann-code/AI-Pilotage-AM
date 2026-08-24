class Company < ApplicationRecord
  belongs_to :user

  has_many :deals, dependent: :destroy
  has_many :produit_deals, -> { where(type: "ProduitDeal") }, class_name: "ProduitDeal", inverse_of: :company
  has_many :upsell_deals, -> { where(type: "UpsellDeal") }, class_name: "UpsellDeal", inverse_of: :company

  validates :name, presence: true, uniqueness: { case_sensitive: false }

  # A plain find_or_create_by!(name: ...) looks up by an exact, case-sensitive match — given the model's
  # own uniqueness rule (and its "lower(name)" DB index) is case-insensitive, that mismatch meant a name
  # differing only by case from an existing company (e.g. a CSV row spelling it "CARON SERVICES" against
  # an existing "Caron Services") would miss the lookup, then fail to insert a "duplicate" instead of
  # attaching to the company that was actually already there.
  def self.find_or_create_by_name!(name, user:)
    name = name.to_s.strip
    find_by("lower(name) = ?", name.downcase) || create!(name: name, user: user)
  end

  # The only way a company's AM ever changes — Deal never carries its own AM field, so this single
  # assignment is what "one company = one AM" means structurally (see original's reassignClientAM,
  # which had to manually walk every deal; here there's nothing else to update).
  def reassign_am!(new_user)
    update!(user: new_user)
  end

  # ---------- "Évolution de l'ARR par client" row math (computeClientEvolution in the original) ----------
  # Ported 1:1: produit deals drive arr_initial/churned/renewal math, upsold comes only from SIGNED upsell
  # deals, and avg_increase_pct is ARR-weighted across produit deals only (upsells never contribute a taux).

  def arr_initial
    produit_deals.sum(:arr).to_f
  end

  def churned_arr
    produit_deals.select(&:churned?).sum { |d| d.arr.to_f }
  end

  def upsold_arr
    upsell_deals.select(&:signed?).sum(&:upsell_amount)
  end

  def final_arr
    produit_deals.sum(&:final_arr) + upsold_arr
  end

  def evolution_pct
    arr_initial > 0 ? (final_arr - arr_initial) / arr_initial * 100 : nil
  end

  def avg_increase_pct
    return nil if arr_initial <= 0

    weighted = produit_deals.sum { |d| d.taux.to_f * d.arr.to_f }
    weighted / arr_initial
  end
end
