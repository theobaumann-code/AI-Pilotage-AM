class UsersController < ApplicationController
  before_action :require_admin!

  # No hard delete: a User with active companies can't be destroyed (see User#companies,
  # dependent: :restrict_with_error) — deactivating is the safe equivalent of the original's "delete AM".
  def create
    user = User.new(user_params)
    if user.save
      redirect_to pilotage_path, notice: "#{user.name} ajouté. Communiquez-lui son email et son mot de passe pour se connecter."
    else
      redirect_to pilotage_path, alert: user.errors.full_messages.to_sentence
    end
  end

  # Toggles a user's admin flag. Guarded against removing the last active admin, so the app can never end
  # up with nobody able to reach admin-only actions (including this one).
  def update
    user = User.find(params[:id])
    new_admin = ActiveModel::Type::Boolean.new.cast(params[:admin])

    if user.admin? && !new_admin && User.where(admin: true, active: true).count <= 1
      return redirect_to pilotage_path, alert: "Impossible : il doit rester au moins un administrateur actif."
    end

    user.update!(admin: new_admin)
    redirect_to pilotage_path, notice: "#{user.name} est maintenant #{user.admin? ? "administrateur" : "AM classique"}."
  rescue ActiveRecord::RecordNotFound
    redirect_to pilotage_path, alert: "AM introuvable."
  end

  def destroy
    user = User.find(params[:id])
    if user.admin? && User.where(admin: true, active: true).count <= 1
      return redirect_to pilotage_path, alert: "Impossible : il doit rester au moins un administrateur actif."
    end

    user.update!(active: false)
    redirect_to pilotage_path, notice: "#{user.name} désactivé."
  rescue ActiveRecord::RecordNotFound
    redirect_to pilotage_path, alert: "AM introuvable."
  end

  private

  def user_params
    params.require(:user).permit(:name, :email, :password, :password_confirmation, :admin)
  end
end
