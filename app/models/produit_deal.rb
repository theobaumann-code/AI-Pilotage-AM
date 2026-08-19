class ProduitDeal < Deal
  PRODUITS = ["Mutuelle", "Prévoyance"].freeze
  COLLEGES = ["Ensemble du personnel", "Non cadre", "Cadre"].freeze
  ASSUREURS = ["AXA", "Allianz", "Gan", "Generali", "Groupama", "Malakoff Humanis", "PanoCare", "Swiss Life"].freeze
  STATUTS_RENOUVELLEMENT = ["En cours", "Nouveau contrat", "Augmenté", "Augmentation particulière", "Churné"].freeze
  CHURNED = "Churné"

  validates :produit, inclusion: { in: PRODUITS }
  validates :college, presence: true, inclusion: { in: COLLEGES }
  validates :assureur, presence: true, inclusion: { in: ASSUREURS }
  validates :statut_renouvellement, inclusion: { in: STATUTS_RENOUVELLEMENT }
  # Rule 1 (model-level mirror of the DB partial index): uniqueness scoped to produit, and — since
  # ArchiveEntry is a completely separate table/model, never a Deal — this can never see archived years,
  # exactly matching the original's "identifiant reuse after churn" allowance.
  validates :identifiant, uniqueness: { scope: :produit, case_sensitive: false }, allow_blank: true
  # Rule 2: at most one produit+collège combo per company.
  validates :college, uniqueness: { scope: [:company_id, :produit] }, if: :college?

  before_validation :apply_business_rules

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

  # Rule 4: churn always forces taux to 0.
  def apply_business_rules
    self.taux = 0 if churned?
  end
end
