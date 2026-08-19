class UsersController < ApplicationController
  before_action :require_admin!

  # No hard delete: a User with active companies can't be destroyed (see User#companies,
  # dependent: :restrict_with_error) — deactivating is the safe equivalent of the original's "delete AM".
  def create
    user = User.new(user_params)
    user.password = user.password_confirmation = SecureRandom.hex(12)
    if user.save
      redirect_to pilotage_path, notice: "#{user.name} ajouté. Il doit utiliser \"Mot de passe oublié\" à la connexion pour définir son mot de passe."
    else
      redirect_to pilotage_path, alert: user.errors.full_messages.to_sentence
    end
  end

  def destroy
    user = User.find(params[:id])
    user.update!(active: false)
    redirect_to pilotage_path, notice: "#{user.name} désactivé."
  rescue ActiveRecord::RecordNotFound
    redirect_to pilotage_path, alert: "AM introuvable."
  end

  private

  def user_params
    params.require(:user).permit(:name, :email)
  end
end
