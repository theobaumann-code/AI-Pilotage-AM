class UpsellDeal < Deal
  PRODUITS = (ProduitDeal::PRODUITS + ["Mutuelle/Prévoyance"]).freeze
  STATUTS_SIGNATURE = ["Non démarré", "En cours", "Signé", "Perdu"].freeze
  SIGNE = "Signé"

  validates :produit, inclusion: { in: PRODUITS }
  validates :statut_signature, inclusion: { in: STATUTS_SIGNATURE }
  validates :nombre_salaries, numericality: { greater_than_or_equal_to: 0 }
  validates :probabilite_signature, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }

  before_validation :apply_business_rules

  def signed?
    statut_signature == SIGNE
  end

  private

  # Rule 5: marking an upsell "Signé" always forces probabilite_signature to 100.
  def apply_business_rules
    self.probabilite_signature = 100 if signed?
  end
end
