class Deal < ApplicationRecord
  self.inheritance_column = :type

  # €/employee/year — identical rate table to the original UPSELL_RATE_PER_EMPLOYEE.
  UPSELL_RATE_PER_EMPLOYEE = {
    "Mutuelle" => 140.0,
    "Prévoyance" => 36.90,
    "Mutuelle/Prévoyance" => 176.90
  }.freeze

  belongs_to :company
  # Owner override — see the AddUserToDeals migration. Only ever set on UpsellDeal; a ProduitDeal's
  # effective_user is always its company's owner (produits move as a whole with the company, never alone).
  belongs_to :user, optional: true

  validates :produit, presence: true
  validates :arr, numericality: true
  validates :taux, numericality: true

  # Who this deal actually belongs to right now: the override if one was set (an upsell explicitly
  # reassigned to a different AM than its company), otherwise the company's own AM.
  def effective_user
    user || company.user
  end

  # Always derived, never stored authoritatively — matches computeUpsellAmount(c) in the original, which
  # recomputes from nombre_salaries × tarif[produit] every time rather than trusting a persisted value.
  def upsell_amount
    nombre_salaries.to_i * (UPSELL_RATE_PER_EMPLOYEE[produit] || 0)
  end

  def projection
    upsell_amount * (probabilite_signature.to_i / 100.0)
  end
end
