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
  # Role hierarchy is AM < KAM < admin, but it's derived from two independent booleans (admin, kam) rather
  # than stored directly — admin always wins if both are set, so these scopes exclude admins explicitly
  # rather than assuming the flags are mutually exclusive. Used to partition "Résultats AM" from
  # "Résultats KAM": each roster only ever shows users whose *effective* role matches.
  scope :ams, -> { where(kam: false, admin: false) }
  scope :kams, -> { where(kam: true, admin: false) }

  def active_for_authentication?
    super && active?
  end

  def inactive_message
    active? ? super : :deactivated
  end

  def role
    return :admin if admin?
    return :kam if kam?
    :am
  end

  def role_label
    { admin: "Admin", kam: "KAM", am: "AM" }.fetch(role)
  end

  # KAM's one elevation over a plain AM: CSV import and reassigning a produit/upsell to another AM (see
  # ApplicationController#require_kam_or_admin!) — everything else administrative stays admin-only.
  def kam_or_admin?
    admin? || kam?
  end
end
