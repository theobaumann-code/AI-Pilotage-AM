class Deal < ApplicationRecord
  self.inheritance_column = :type

  # €/employee/year — identical rate table to the original UPSELL_RATE_PER_EMPLOYEE.
  UPSELL_RATE_PER_EMPLOYEE = {
    "Mutuelle" => 140.0,
    "Prévoyance" => 36.90,
    "Mutuelle/Prévoyance" => 176.90
  }.freeze

  belongs_to :company

  validates :produit, presence: true
  validates :arr, numericality: true
  validates :taux, numericality: true

  # Always derived, never stored authoritatively — matches computeUpsellAmount(c) in the original, which
  # recomputes from nombre_salaries × tarif[produit] every time rather than trusting a persisted value.
  def upsell_amount
    nombre_salaries.to_i * (UPSELL_RATE_PER_EMPLOYEE[produit] || 0)
  end

  def projection
    upsell_amount * (probabilite_signature.to_i / 100.0)
  end
end
