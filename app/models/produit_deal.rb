class ProduitDeal < Deal
  PRODUITS = ["Mutuelle", "Prévoyance"].freeze
  COLLEGES = ["Ensemble du personnel", "Non cadre", "Cadre"].freeze
  # Kept alphabetical (case-insensitive) so every select/filter built from this list reads that way too.
  ASSUREURS = ["AG2R", "Allianz", "Apicil", "Audiens", "AXA", "Gan", "Generali", "Groupama", "Harmonie",
               "Malakoff Humanis", "PanoCare", "Spvie", "Swiss Life", "Uniprévoyance"].freeze
  STATUTS_RENOUVELLEMENT = ["En cours", "Nouveau contrat", "Augmenté", "Augmentation particulière", "Churné"].freeze
  CHURNED = "Churné"

  validates :produit, inclusion: { in: PRODUITS }
  validates :college, presence: true, inclusion: { in: COLLEGES }
  validates :assureur, presence: true, inclusion: { in: ASSUREURS }
  validates :statut_renouvellement, inclusion: { in: STATUTS_RENOUVELLEMENT }
  validates :risque_churn, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }
  # Rule 1 (model-level mirror of the DB partial index): uniqueness scoped to produit, and — since
  # ArchiveEntry is a completely separate table/model, never a Deal — this can never see archived years,
  # exactly matching the original's "identifiant reuse after churn" allowance.
  validates :identifiant, uniqueness: { scope: :produit, case_sensitive: false }, allow_blank: true
  # Rule 2: at most one produit+collège+assureur combo per company — a company MAY have several
  # contracts for the same produit+collège as long as each is with a different insurer (e.g. Mutuelle/
  # Cadre with AXA and Mutuelle/Cadre with Allianz side by side). Only an exact duplicate is rejected.
  validates :college, uniqueness: { scope: [:company_id, :produit, :assureur] }, if: :college?

  before_validation :apply_business_rules
  after_commit :sync_to_google_sheets

  def churned?
    statut_renouvellement == CHURNED
  end

  # Renewal-only final ARR (no upsell mixed in — upsell revenue lives on separate UpsellDeal rows in this
  # schema, unlike the original where a stray statutSignature field on produit rows could theoretically
  # carry upsell amount too; that data-model wart is not reproduced here).
  def final_arr
    churned? ? 0 : arr.to_f * (1 + taux.to_f / 100)
  end

  private

  def sync_to_google_sheets
    GoogleSheetsSyncJob.perform_later
  end

  # Rule 4: churn always forces taux to 0. A produit that has already churned is a certainty, not a risk
  # estimate — its churn probability is pinned to 100 rather than left at whatever an AM last entered.
  def apply_business_rules
    if churned?
      self.taux = 0
      self.risque_churn = 100
    end
  end
end
