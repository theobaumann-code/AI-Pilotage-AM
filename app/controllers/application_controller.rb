class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  before_action :authenticate_user!

  private

  # Shared gate for the ~15 admin-only actions from the original app (add/delete AM, add/delete produit
  # deal, identifiant/arr fields, CSV import, year close, trash restore/purge, archived-row editing...).
  def require_admin!
    return if current_user.admin?

    redirect_back fallback_location: root_path, alert: "Réservé aux administrateurs."
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
    if current_user.admin? && candidate_id.present?
      User.active.find(candidate_id)
    else
      current_user
    end
  rescue ActiveRecord::RecordNotFound
    current_user
  end
  helper_method :viewed_user

  # A non-admin AM must always be restricted to their own companies, even for actions that aren't
  # admin-gated in the original (e.g. deleting an upsell) — the original never needed this because it had
  # no real multi-user isolation at all; this is a deliberate strengthening, not a behavior port.
  def scoped_company(id)
    scope = current_user.admin? ? Company.all : current_user.companies
    scope.find(id)
  end
end
