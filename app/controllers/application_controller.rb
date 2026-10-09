class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  before_action :authenticate_user!
  before_action :block_read_only_users!

  private

  # "Lecteurs" can look at everything but change nothing: every request that isn't a plain read (anything
  # other than GET/HEAD — inline edits, form posts, deletes, imports) is refused here, before any action
  # runs, so no individual controller has to remember to check. Signing out (a DELETE on a Devise
  # controller) stays allowed, otherwise a lecteur couldn't leave.
  def block_read_only_users!
    return if devise_controller? || request.get? || request.head?
    return unless current_user&.read_only?

    redirect_back fallback_location: pilotage_path, alert: "Accès en lecture seule : modification impossible.",
      status: :see_other
  end
  # Shared gate for the ~15 admin-only actions from the original app (add/delete AM, add/delete produit
  # deal, identifiant/arr fields, CSV import, year close, trash restore/purge, archived-row editing...).
  # KAM has the exact same rights as admin (User#privileged?) — only the NRR/portfolio math stays identical
  # between AM and KAM, everything else that's admin-gated is equally open to both.
  def require_admin!
    return if current_user.privileged?

    redirect_back fallback_location: root_path, alert: "Réservé aux administrateurs et aux KAM."
  end

  # The AM whose portfolio is being viewed: always current_user for a regular AM (real per-user isolation,
  # stronger than the original which let anyone switch AM from a dropdown); an admin may additionally view
  # any other AM's portfolio via ?user_id= (the initial GET) or ?redirect_user_id= (the PATCH an inline
  # edit submits — same AM, different param name because it round-trips through deal/archive-entry update
  # forms baked into that AM's row). Both must resolve to the same id, or a turbo_stream response re-renders
  # a row's own next edit-form URL using the wrong one (falls back to current_user, i.e. the admin's own
  # portfolio) — the row silently starts editing the admin's data instead of the AM being viewed.
  def viewed_user
    candidate_id = params[:user_id] || params[:redirect_user_id]
    if current_user.privileged? && candidate_id.present?
      User.active.find(candidate_id)
    else
      current_user
    end
  rescue ActiveRecord::RecordNotFound
    current_user
  end
  helper_method :viewed_user

  # A numeric filter bound from the query string — nil when blank or not a number, so a typo never raises
  # and simply leaves that side of the range open. Accepts a comma as decimal separator.
  def numeric_param(value)
    Float(value.to_s.strip.tr(",", "."))
  rescue ArgumentError
    nil
  end

  # A non-admin AM must always be restricted to their own companies, even for actions that aren't
  # admin-gated in the original (e.g. deleting an upsell) — the original never needed this because it had
  # no real multi-user isolation at all; this is a deliberate strengthening, not a behavior port.
  def scoped_company(id)
    scope = current_user.privileged? ? Company.all : current_user.companies
    scope.find(id)
  end
end
