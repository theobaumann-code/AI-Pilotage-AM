class User < ApplicationRecord
  # Access is provisioned by admins; Google is the only authentication strategy.
  devise :omniauthable, omniauth_providers: [ :google_oauth2 ]

  normalizes :email, with: ->(email) { email.strip.downcase }
  validates :email, presence: true, uniqueness: { case_sensitive: false }, format: { with: Devise.email_regexp }

  # Invalidate old password sessions, and SSO sessions after an email/access change.
  def authenticatable_salt
    "google-sso:#{email}:#{active?}:#{updated_at&.utc&.iso8601(6)}"
  end

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
