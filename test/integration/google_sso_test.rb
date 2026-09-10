require "test_helper"

class GoogleSsoTest < ActionDispatch::IntegrationTest
  # OmniAuth mock responses and environment configuration are process-wide.
  parallelize(workers: 1)
  setup do
    @previous_test_mode = OmniAuth.config.test_mode
    @previous_domain = ENV["AUTH_ALLOWED_DOMAIN"]
    @previous_emails = ENV["AUTH_ALLOWED_EMAILS"]
    ENV["AUTH_ALLOWED_DOMAIN"] = "sidecare.com"
    ENV.delete("AUTH_ALLOWED_EMAILS")
    OmniAuth.config.test_mode = true
    @user = User.create!(email: "sso@sidecare.com", name: "AM SSO", active: true, admin: false)
  end

  teardown do
    OmniAuth.config.test_mode = @previous_test_mode
    OmniAuth.config.mock_auth[:google_oauth2] = nil
    ENV["AUTH_ALLOWED_DOMAIN"] = @previous_domain
    ENV["AUTH_ALLOWED_EMAILS"] = @previous_emails
  end

  test "verified existing AM signs in and returns to the requested page" do
    get pilotage_path
    assert_redirected_to new_user_session_path
    authenticate
    assert_redirected_to pilotage_path
    follow_redirect!
    assert_response :success
    assert_not @user.reload.admin?
    delete destroy_user_session_path
    get pilotage_path
    assert_redirected_to new_user_session_path
  end

  test "unknown Google account does not create a user" do
    assert_no_difference "User.count" do
      authenticate(email: "unknown@sidecare.com")
    end
    assert_denied
  end

  test "deactivated account is denied" do
    @user.update!(active: false)
    authenticate
    assert_denied
  end

  test "unverified email is denied" do
    authenticate(email_verified: false)
    assert_denied
  end

  test "missing email verification is denied" do
    authenticate(email_verified: nil)
    assert_denied
  end

  test "foreign Workspace and missing Workspace are denied" do
    [ "other.com", nil ].each do |domain|
      authenticate(hd: domain)
      assert_denied
    end
  end

  test "optional email allowlist restricts existing users" do
    ENV["AUTH_ALLOWED_EMAILS"] = "other@sidecare.com"
    authenticate
    assert_denied
  end

  test "email matching is normalized and admin rights are preserved" do
    @user.update!(admin: true)
    authenticate(email: "SSO@sidecare.com")
    assert_redirected_to root_path
    assert @user.reload.admin?
  end

  test "provider cancellation returns to sign in" do
    OmniAuth.config.mock_auth[:google_oauth2] = :access_denied
    get user_google_oauth2_omniauth_callback_path
    assert_redirected_to new_user_session_path
    follow_redirect!
    assert_select ".auth-message-alert", /échoué ou a été annulée/
  end

  test "login offers only Google and the legacy password endpoint is disabled" do
    get new_user_session_path
    assert_select "form[action=?][method=post] button[data-turbo=false]", user_google_oauth2_omniauth_authorize_path
    assert_select "input[type=password]", count: 0
    post "/users/sign_in", params: { user: { email: @user.email, password: "old-password" } }
    assert_response :not_found
    get pilotage_path
    assert_redirected_to new_user_session_path
  end

  test "deactivation revokes an existing SSO session" do
    authenticate
    @user.update!(active: false)
    get pilotage_path
    assert_redirected_to new_user_session_path
  end

  test "admin can create an AM without a password" do
    @user.update!(admin: true)
    authenticate
    assert_difference "User.count", 1 do
      post users_path, params: { user: { name: "New AM", email: "new-am@sidecare.com" } }
    end
    assert_redirected_to pilotage_path
    assert_equal "", User.find_by!(email: "new-am@sidecare.com").encrypted_password
  end

  test "OAuth callback rejects an invalid state before contacting Google" do
    OmniAuth.config.test_mode = false
    post user_google_oauth2_omniauth_authorize_path
    assert_response :redirect
    assert_match %r{https://accounts.google.com/}, response.location
    get user_google_oauth2_omniauth_callback_path, params: { code: "fake-code", state: "invalid-state" }
    assert_redirected_to new_user_session_path
    get pilotage_path
    assert_redirected_to new_user_session_path
  end

  test "OAuth initiation rejects requests without a CSRF token" do
    original = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    post user_google_oauth2_omniauth_authorize_path
    assert_response :unprocessable_entity
  ensure
    ActionController::Base.allow_forgery_protection = original
  end

  private

  def authenticate(**overrides)
    profile = { email: @user.email, email_verified: true, hd: "sidecare.com" }.merge(overrides)
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2", uid: "google-test-user", extra: { raw_info: profile }
    )
    get user_google_oauth2_omniauth_callback_path
  end

  def assert_denied
    assert_redirected_to new_user_session_path
    get pilotage_path
    assert_redirected_to new_user_session_path
  end
end
