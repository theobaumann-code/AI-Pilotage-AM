class User < ApplicationRecord
  # Access is provisioned by admins; Google is the only authentication strategy.
  devise :omniauthable, omniauth_providers: [ :google_oauth2 ]

  normalizes :email, with: ->(email) { email.strip.downcase }
  validates :email, presence: true, uniqueness: { case_sensitive: false }, format: { with: Devise.email_regexp }

  # Invalidate old password sessions, and SSO sessions after an email/access change.
  def authenticatable_salt
    "google-sso:#{email}:#{active?}:#{updated_at&.utc&.iso8601(6)}"
  end

  def sync_to_google_sheets
    GoogleSheetsSyncJob.enqueue
  end

  validates :name, presence: true

  # The Google Sheet export denormalizes each produit's AM name onto its row — a rename doesn't touch any
  # ProduitDeal itself, so it needs its own trigger to keep the sheet current.
  after_commit :sync_to_google_sheets, if: :saved_change_to_name?

  has_many :companies, dependent: :restrict_with_error
  # dependent: :restrict_with_error — mirrors the "one company = one AM" invariant: an AM with an active
  # portfolio can't simply be deleted (unlike the original's blind wipe); reassign or deactivate instead.

  scope :active, -> { where(active: true) }
  # Admins and KAMs — the managers who can be named "référent" on an at-risk company.
  scope :managers, -> { where(admin: true).or(where(kam: true)) }
  # Everyone who can own a portfolio or be picked in a table filter/select: active users minus "lecteurs",
  # who only sign in to consult and would just make those lists longer.
  scope :assignable, -> { active.where(reader: false) }

  # Admin/KAM always win over a stale reader flag (e.g. promoting a lecteur through the admin/KAM toggle
  # buttons, which only set their own flag) — a lecteur is by definition neither.
  before_save { self.reader = false if admin? || kam? }
  validate :reader_owns_no_company, if: :read_only?

  def active_for_authentication?
    super && active?
  end

  def inactive_message
    active? ? super : :deactivated
  end

  # Admin always wins if somehow both flags are set (shouldn't normally happen via the UI, which treats
  # them as separate toggles, but this keeps role/role_label well-defined regardless).
  def role
    return :admin if admin?
    return :kam if kam?
    return :reader if reader?
    :am
  end

  def role_label
    { admin: "Admin", kam: "KAM", reader: "Lecteur", am: "AM" }.fetch(role)
  end

  # Virtual attribute so the create/edit forms can offer one "Équipe" selector (AM/KAM/Admin/Lecteur)
  # instead of independent checkboxes — assignable like any other attribute (user.update(role: "KAM")). Any
  # value other than the known labels is treated as "AM", the safe default.
  def role=(label)
    self.admin = (label.to_s == "Admin")
    self.kam = (label.to_s == "KAM")
    self.reader = (label.to_s == "Lecteur")
  end

  # A "lecteur" can sign in and look at everything but change nothing — enforced server-side for every
  # non-GET request (see ApplicationController#block_read_only_users!), not just by hiding buttons.
  def read_only?
    role == :reader
  end

  # KAM has the same rights as admin everywhere in the app (see ApplicationController#require_admin! and
  # every current_user.privileged? check) — only the NRR/portfolio calculations themselves stay identical
  # for AM and KAM. Deliberately not folded into `admin?` itself: that column still needs to mean exactly
  # "is a real administrator" for the last-admin safeguard and the role badge.
  def privileged?
    admin? || kam?
  end

  private

  def reader_owns_no_company
    return unless companies.exists?
    errors.add(:base, "Un lecteur ne peut pas avoir de clients : réassignez d'abord les clients de #{name}.")
  end
end
