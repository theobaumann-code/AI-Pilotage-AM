# A one-off, manually entered ARR impact on a client that fits none of the modelled categories (renewal
# rate, churn, upsell) — e.g. "-3000" for a contract amendment. Entered by admins/KAMs on Mon portefeuille.
#
# "Validé" impacts count only on the actual side (ARR final actuel, NRR actuel, the section's Actuel total);
# "En cours" ones only on the projected side (ARR final / NRR projeté, the section's Projeté total). Each row belongs to the year it was created in, so a year
# closure leaves last year's impacts out of the new year's figures without deleting anything.
class OtherImpact < ApplicationRecord
  PRODUITS = ["Mutuelle", "Prévoyance", "Les deux"].freeze
  STATUTS = ["En cours", "Validé"].freeze
  EN_COURS = "En cours"
  VALIDE = "Validé"

  belongs_to :company

  before_validation { self.annee ||= AppSetting.instance.annee_en_cours }

  validates :produit, inclusion: { in: PRODUITS }
  validates :statut, inclusion: { in: STATUTS }
  validate :amount_must_be_a_number

  scope :validated, -> { where(statut: VALIDE) }
  scope :pending, -> { where(statut: EN_COURS) }

  def validated?
    statut == VALIDE
  end

  # Free text typed by hand ("3000", "-3000", "3 000,50", "+500 €"): anything that isn't a plain number
  # once spaces, a currency sign, a leading "+" and a decimal comma are normalised is rejected, instead of
  # being silently read as 0.
  def amount=(value)
    @amount_input_invalid = false
    return super(value) unless value.is_a?(String)

    cleaned = value.gsub(/[[:space:]]/, "").delete("€").tr(",−", ".-").delete_prefix("+")
    if cleaned.empty?
      super(nil)
    elsif cleaned.match?(/\A-?\d+(\.\d+)?\z/)
      super(cleaned)
    else
      @amount_input_invalid = true
      super(nil)
    end
  end

  private

  def amount_must_be_a_number
    errors.add(:amount, "doit être un nombre en euros (ex : 3000 ou -3000)") if amount.nil? || @amount_input_invalid
  end
end
