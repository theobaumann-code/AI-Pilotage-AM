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

  # The Google Sheet export denormalizes each produit's AM name onto its row - a rename doesn't touch any
  # ProduitDeal itself, so it needs its own trigger to keep the sheet current.
  after_commit :sync_to_google_sheets, if: :saved_change_to_name?

  has_many :companies, dependent: :restrict_with_error
  # dependent: :restrict_with_error - mirrors the "one company = one AM" invariant: an AM with an active
  # portfolio can't simply be deleted (unlike the original's blind wipe); reassign or deactivate instead.

  scope :active, -> { where(active: true) }
  # Admins and KAMs - the managers who can be named "référent" on an at-risk company.
  scope :managers, -> { where(admin: true).or(where(kam: true)) }
  # Everyone who can own a portfolio or be picked in a table filter/select: active users minus "lecteurs",
  # who only sign in to consult and would just make those lists longer.
  scope :assignable, -> { active.where(reader: false) }

  # Admin/KAM always win over a stale reader flag (e.g. promoting a lecteur through the admin/KAM toggle
  # buttons, which only set their own flag) - a lecteur is by definition neither.
  before_save { self.reader = false if admin? || kam? }
  validate :reader_owns_no_company, if: :read_only?

  # A lead's "poste" rides on rights that must match it: TL AM and Head of CSM = admin rights, TL Customer Care =
  # plain user rights (neither admin, KAM nor lecteur). If the rights are changed so they no longer match (admin
  # taken away from a TL AM, a TL Customer Care promoted...), the poste is dropped rather than left lying.
  before_validation :align_poste_with_rights

  POSTE_TL_AM = "TL AM".freeze
  POSTE_TL_CSM = "TL Customer Care".freeze
  POSTE_HEAD_CSM = "Head of CSM".freeze
  POSTES = [ POSTE_TL_AM, POSTE_TL_CSM, POSTE_HEAD_CSM ].freeze
  ADMIN_POSTES = [ POSTE_TL_AM, POSTE_HEAD_CSM ].freeze

  # Maximum number of client accounts one person can carry, by role - an unlisted role (AM, admin...) gets the
  # default. Used by "Attribution portefeuille".
  DEFAULT_ACCOUNT_LIMIT = 54
  ACCOUNT_LIMITS = { kam: 35, tl_am: 9, tl_csm: 24, head_csm: 4 }.freeze

  ROLE_LABELS = { admin: "Admin", kam: "KAM", reader: "Lecteur", am: "AM", tl_am: "TL AM", tl_csm: "TL Customer Care",
                  head_csm: "Head of CSM" }.freeze
  # Roles that carry admin rights, as the "Équipe" selector labels them.
  ADMIN_ROLE_LABELS = [ "Admin", ROLE_LABELS[:tl_am], ROLE_LABELS[:head_csm] ].freeze
  # Who carries a portfolio of their own (listed in "Attribution portefeuille" even without any account yet).
  PORTFOLIO_ROLES = [ :am, :kam, :tl_am, :tl_csm, :head_csm ].freeze

  def active_for_authentication?
    super && active?
  end

  def inactive_message
    active? ? super : :deactivated
  end

  # Admin always wins if somehow both flags are set (shouldn't normally happen via the UI, which treats
  # them as separate toggles, but this keeps role/role_label well-defined regardless).
  def role
    return :tl_am if poste == POSTE_TL_AM && admin?
    return :head_csm if poste == POSTE_HEAD_CSM && admin?
    return :admin if admin?
    return :kam if kam?
    return :reader if reader?
    return :tl_csm if poste == POSTE_TL_CSM
    :am
  end

  def role_label
    ROLE_LABELS.fetch(role)
  end

  # The "Équipe" a user belongs to in the Équipe filters (Admin / KAM / AM): the team leads sit with the AMs, so
  # nobody has to pick their role separately - only role_label (badges, Gestion des droits) tells them apart.
  def team_label
    [ :tl_am, :tl_csm, :head_csm ].include?(role) ? ROLE_LABELS[:am] : role_label
  end

  def account_limit
    ACCOUNT_LIMITS.fetch(role, DEFAULT_ACCOUNT_LIMIT)
  end

  # Virtual attribute so the create/edit forms can offer one "Équipe" selector (AM/KAM/Admin/TL AM/
  # TL Customer Care/Lecteur) instead of independent checkboxes - assignable like any other attribute
  # (user.update(role: "KAM")). "TL AM" and "Head of CSM" mean admin rights plus the poste; "TL Customer Care"
  # plain user rights plus the poste. Any value other than the known labels is treated as "AM", the safe default.
  def role=(label)
    label = label.to_s
    self.admin = ADMIN_ROLE_LABELS.include?(label)
    self.kam = (label == "KAM")
    self.reader = (label == "Lecteur")
    self.poste = { ROLE_LABELS[:tl_am] => POSTE_TL_AM, ROLE_LABELS[:tl_csm] => POSTE_TL_CSM,
                   ROLE_LABELS[:head_csm] => POSTE_HEAD_CSM }[label]
  end

  # A "lecteur" can sign in and look at everything but change nothing - enforced server-side for every
  # non-GET request (see ApplicationController#block_read_only_users!), not just by hiding buttons.
  def read_only?
    role == :reader
  end

  # KAM has the same rights as admin everywhere in the app (see ApplicationController#require_admin! and
  # every current_user.privileged? check) - only the NRR/portfolio calculations themselves stay identical
  # for AM and KAM. Deliberately not folded into `admin?` itself: that column still needs to mean exactly
  # "is a real administrator" for the last-admin safeguard and the role badge.
  def privileged?
    admin? || kam?
  end

  private

  def align_poste_with_rights
    self.poste = nil if ADMIN_POSTES.include?(poste) && !admin?
    self.poste = nil if poste == POSTE_TL_CSM && (admin? || kam? || reader?)
    self.poste = nil unless POSTES.include?(poste)
  end

  def reader_owns_no_company
    return unless companies.exists?
    errors.add(:base, "Un lecteur ne peut pas avoir de clients : réassignez d'abord les clients de #{name}.")
  end
end
