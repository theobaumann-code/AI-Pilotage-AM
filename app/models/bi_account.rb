# One account as the BI sees it, refreshed by BiPortfolioSync: a company set (kind "set"), or a user pro that
# belongs to no set (kind "user_pro"). Its AM is the set's "responsable AM" when there is a set, the user pro's
# own otherwise - read-only here, it changes in the BO. Feeds "Attribution portefeuille" for the next campaign.
class BiAccount < ApplicationRecord
  KINDS = { "set" => "Company set", "user_pro" => "Entreprise" }.freeze

  # "Comptes sans AM": unassigned accounts worth giving to an AM - over 2 000 € of ARR, and over 5 000 € unless
  # they hold at least one standard health product (any offer but "sur mesure").
  SANS_AM_MIN_ARR = 2_000
  SANS_AM_MIN_ARR_WITHOUT_STANDARD = 5_000

  # A client the AM still has to look after: at least one active health or provident contract. Accounts whose
  # contracts are all terminated are left out of the AMs' portfolios altogether.
  scope :active, -> { where("contracts_count > 0") }
  scope :with_am, -> { where.not(am_email: nil) }
  scope :without_am, -> { where(am_email: nil) }

  def self.last_synced_at
    maximum(:synced_at)
  end

  def self.sans_am
    without_am.where("arr > ?", SANS_AM_MIN_ARR)
      .where("arr >= ? OR has_standard_sante", SANS_AM_MIN_ARR_WITHOUT_STANDARD)
  end

  def kind_label
    KINDS.fetch(kind, kind)
  end

  def set?
    kind == "set"
  end

  def risque
    if has_sante && has_prevoyance then "Double risque"
    elsif has_sante then "Santé"
    elsif has_prevoyance then "Prévoyance"
    end
  end

  # The risk the account doesn't hold yet - what an AM can sell it on top.
  def upsell_produit
    if has_sante && !has_prevoyance then "Prévoyance"
    elsif has_prevoyance && !has_sante then "Mutuelle"
    end
  end

  def upsell?
    upsell_produit.present?
  end

  # Same per-employee formula as the upsells entered by hand (UpsellDeal), on the account's BO headcount.
  def upsell_amount
    return 0.0 unless upsell?

    (UpsellDeal.rate_per_employee_for(upsell_produit) * employees_count.to_i).round(2)
  end
end
