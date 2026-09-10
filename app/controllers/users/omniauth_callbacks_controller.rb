module Users
  class OmniauthCallbacksController < Devise::OmniauthCallbacksController
    def google_oauth2
      auth = request.env["omniauth.auth"]
      profile = auth&.dig("extra", "raw_info")
      email = profile&.dig("email").to_s.strip.downcase
      domain = ENV.fetch("AUTH_ALLOWED_DOMAIN", "sidecare.com").strip.downcase
      allowed_emails = ENV.fetch("AUTH_ALLOWED_EMAILS", "").split(",").map { |value| value.strip.downcase }.reject(&:blank?)

      if auth&.provider == "google_oauth2" && profile&.dig("email_verified") == true &&
          domain.present? && profile&.dig("hd") == domain && email.end_with?("@#{domain}") &&
          (allowed_emails.empty? || allowed_emails.include?(email))
        user = User.active.find_by(email: email)
      end

      if user&.active_for_authentication?
        sign_in_and_redirect user, event: :authentication
      else
        redirect_to new_user_session_path, alert: "Ce compte Google n’est pas autorisé. Contactez un administrateur."
      end
    end

    def failure
      redirect_to new_user_session_path, alert: "La connexion Google a échoué ou a été annulée. Veuillez réessayer."
    end
  end
end
