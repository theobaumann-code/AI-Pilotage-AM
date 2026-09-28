# One line of "churn non accompagné" — a named company, or "Autre" (any label works) as a catch-all for
# small accounts not worth tracking individually. AppSetting#churn_non_accompagne sums these instead of
# holding one lump figure, so Vue globale's total stays exact even as entries are added/removed/edited.
class NonAccompagneChurnEntry < ApplicationRecord
  validates :company_name, presence: true
  validates :amount, presence: true, numericality: { greater_than_or_equal_to: 0 }

  default_scope { order(:company_name) }
end
