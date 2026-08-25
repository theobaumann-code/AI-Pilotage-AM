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

  # Rule 5: marking an upsell "Signé" always forces probabilite_signature to 100. Moving back off "Signé"
  # must not leave that forced 100 behind — it was never a real probability the AM entered, and leaving it
  # in place silently overstates the projected ARR (100% of the deal) until someone notices and fixes it
  # by hand. Only reset on an actual transition away from "Signé", so editing any other field on an
  # already-non-signed upsell doesn't touch it.
  def apply_business_rules
    if signed?
      self.probabilite_signature = 100
    elsif statut_signature_changed? && statut_signature_was == SIGNE
      self.probabilite_signature = 0
    end
  end
end
