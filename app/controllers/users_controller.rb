class UsersController < ApplicationController
  before_action :require_admin!

  # No hard delete: a User with active companies can't be destroyed (see User#companies,
  # dependent: :restrict_with_error) — deactivating is the safe equivalent of the original's "delete AM".
  def create
    user = User.new(user_params)
    if user.save
      redirect_back fallback_location: pilotage_path, notice: "#{user.name} ajouté. Communiquez-lui son email et son mot de passe pour se connecter."
    else
      redirect_back fallback_location: pilotage_path, alert: user.errors.full_messages.to_sentence
    end
  end

  # Three distinct forms post here under the same route: the admin-toggle button (a bare `admin` param),
  # the KAM-toggle button (a bare `kam` param), and the "modifier les identifiants" form (a nested `user`
  # param with email/password) — dispatch on which one actually showed up rather than giving them separate
  # actions, since all three are "update this AM".
  def update
    user = User.find(params[:id])

    if params[:user].present?
      update_credentials(user)
    elsif params.key?(:kam)
      update_kam_flag(user)
    else
      update_admin_flag(user)
    end
  rescue ActiveRecord::RecordNotFound
    redirect_back fallback_location: pilotage_path, alert: "AM introuvable."
  end

  def destroy
    user = User.find(params[:id])
    if user.admin? && User.where(admin: true, active: true).count <= 1
      return redirect_back fallback_location: pilotage_path, alert: "Impossible : il doit rester au moins un administrateur actif."
    end

    user.update!(active: false)
    redirect_back fallback_location: pilotage_path, notice: "#{user.name} désactivé."
  rescue ActiveRecord::RecordNotFound
    redirect_back fallback_location: pilotage_path, alert: "AM introuvable."
  end

  private

  # Guarded against removing the last active admin, so the app can never end up with nobody able to reach
  # admin-only actions (including this one).
  def update_admin_flag(user)
    new_admin = ActiveModel::Type::Boolean.new.cast(params[:admin])

    if user.admin? && !new_admin && User.where(admin: true, active: true).count <= 1
      return redirect_back fallback_location: pilotage_path, alert: "Impossible : il doit rester au moins un administrateur actif."
    end

    user.update!(admin: new_admin)
    redirect_back fallback_location: pilotage_path, notice: "#{user.name} est maintenant #{user.role_label}."
  end

  def update_kam_flag(user)
    new_kam = ActiveModel::Type::Boolean.new.cast(params[:kam])
    user.update!(kam: new_kam)
    redirect_back fallback_location: pilotage_path, notice: "#{user.name} est maintenant #{user.role_label}."
  end

  # There's no self-service "mot de passe oublié" (no mail delivery in production) — this is how an AM
  # gets back into their account: an admin sets a new email and/or password directly. Leaving the password
  # fields blank keeps the current password unchanged (only email is touched), instead of failing Devise's
  # presence validation on an empty password.
  def update_credentials(user)
    attrs = params.require(:user).permit(:email, :password, :password_confirmation)
    attrs = attrs.except(:password, :password_confirmation) if attrs[:password].blank?

    if user.update(attrs)
      redirect_back fallback_location: pilotage_path, notice: "Identifiants de #{user.name} mis à jour."
    else
      redirect_back fallback_location: pilotage_path, alert: user.errors.full_messages.to_sentence
    end
  end

  def user_params
    params.require(:user).permit(:name, :email, :password, :password_confirmation, :admin, :kam)
  end
end
