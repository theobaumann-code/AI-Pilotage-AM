class User < ApplicationRecord
  # No :registerable — AM accounts are created by an admin (via the "+ Nouvel AM" flow), never via public
  # self-signup, matching how the original tool's AM list was always admin-managed.
  devise :database_authenticatable,
         :recoverable, :rememberable, :validatable

  validates :name, presence: true

  has_many :companies, dependent: :restrict_with_error
  # dependent: :restrict_with_error — mirrors the "one company = one AM" invariant: an AM with an active
  # portfolio can't simply be deleted (unlike the original's blind wipe); reassign or deactivate instead.

  scope :active, -> { where(active: true) }

  def active_for_authentication?
    super && active?
  end

  def inactive_message
    active? ? super : :deactivated
  end
end
