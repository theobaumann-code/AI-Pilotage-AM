# A team the projection can give accounts to instead of an AM - e.g. "CSM Juniors" for the small accounts with a
# sur-mesure health contract. No account ceiling: a team's capacity isn't one person's portfolio. Unlike a recruit,
# it can take unassigned accounts ("Comptes sans AM") too.
class Projection::Team < ApplicationRecord
  has_many :moves, class_name: "Projection::Move", dependent: :delete_all

  normalizes :name, with: ->(name) { name.to_s.strip }
  validates :name, presence: true, uniqueness: { case_sensitive: false }
end
