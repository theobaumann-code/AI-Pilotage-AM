# A fictitious person the projection plans to have next campaign. Their role sets their account ceiling, like a
# real user's. They can take over accounts that already have an AM in the BO, never the unassigned ones.
class Projection::Recruit < ApplicationRecord
  ROLES = { "AM" => :am, "KAM" => :kam, "TL AM" => :tl_am, "TL Customer Care" => :tl_csm, "Head of CSM" => :head_csm }.freeze

  has_many :moves, class_name: "Projection::Move", dependent: :delete_all

  normalizes :name, with: ->(name) { name.to_s.strip }
  validates :name, presence: true
  validates :role, inclusion: { in: ROLES.keys }

  def account_limit
    User::ACCOUNT_LIMITS.fetch(ROLES.fetch(role), User::DEFAULT_ACCOUNT_LIMIT)
  end
end
