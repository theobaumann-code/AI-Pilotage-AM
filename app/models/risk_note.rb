# One dated entry in an at-risk company's rescue-effort log ("Entreprises à risque" on Vue globale) —
# append-only history, not a single overwritable field, so nothing written by a previous AM/admin is ever
# silently lost when someone else logs the next step.
class RiskNote < ApplicationRecord
  belongs_to :company
  belongs_to :user

  validates :content, presence: true

  default_scope { order(created_at: :desc) }
end
