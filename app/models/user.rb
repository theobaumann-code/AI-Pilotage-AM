class User < ApplicationRecord
  # No :registerable — AM accounts are created by an admin (via the "+ Nouvel AM" flow), never via public
  # self-signup, matching how the original tool's AM list was always admin-managed.
  # No :recoverable — there's no mail delivery in production to actually send a reset link (Devise turned
  # a misconfigured send into a 500). An admin can change an AM's email/password directly instead (Vue
  # globale → AM), which also makes account recovery a normal admin action rather than a self-serve flow
  # that needs real SMTP.
  devise :database_authenticatable,
         :rememberable, :validatable

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
