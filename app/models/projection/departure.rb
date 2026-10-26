# An app user who won't carry a portfolio next campaign: their BO accounts go back to the pool to reassign.
class Projection::Departure < ApplicationRecord
  belongs_to :user

  validates :user_id, uniqueness: true
end
