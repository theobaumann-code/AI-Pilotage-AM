class UsersController < ApplicationController
  before_action :require_admin!

  # No hard delete: a User with active companies can't be destroyed (see User#companies,
  # dependent: :restrict_with_error) — deactivating is the safe equivalent of the original's "delete AM".
  def create
    user = User.new(user_params)
    if user.save
      redirect_to pilotage_path, notice: "#{user.name} ajouté. Il peut se connecter avec son compte Google professionnel."
    else
      redirect_to pilotage_path, alert: user.errors.full_messages.to_sentence
    end
  end

  # Three distinct forms post here under the same route: the admin-toggle button (a bare `admin` param),
  # the KAM-toggle button (a bare `kam` param), and the "modifier les identifiants" form (a nested `user`
  # param with name/email) — dispatch on which one actually showed up rather than giving them separate
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
    redirect_to pilotage_path, alert: "AM introuvable."
  end

  def destroy
    user = User.find(params[:id])
    if last_active_admin?(user)
      return redirect_to pilotage_path, alert: "Impossible : il doit rester au moins un administrateur actif."
    end

    user.update!(active: false)
    redirect_to pilotage_path, notice: "#{user.name} désactivé."
  rescue ActiveRecord::RecordNotFound
    redirect_to pilotage_path, alert: "AM introuvable."
  end

  private

  # True once `user` is the ONLY thing standing between the app and having zero active admins — checked
  # before any action (admin-toggle, role select in the edit panel, deactivation) that could remove admin
  # from them, so the app can never end up with nobody able to reach admin-only actions.
  def last_active_admin?(user)
    user.admin? && User.where(admin: true, active: true).count <= 1
  end

  def update_admin_flag(user)
    new_admin = ActiveModel::Type::Boolean.new.cast(params[:admin])

    if !new_admin && last_active_admin?(user)
      return redirect_to pilotage_path, alert: "Impossible : il doit rester au moins un administrateur actif."
    end

    user.update!(admin: new_admin)
    redirect_to pilotage_path, notice: "#{user.name} est maintenant #{user.role_label}."
  end

  # KAM has the same rights as admin (see ApplicationController#require_admin!) — no "last KAM" safeguard
  # is needed the way there is for admin, since a real admin (or another KAM) can always grant it back.
  def update_kam_flag(user)
    user.update!(kam: ActiveModel::Type::Boolean.new.cast(params[:kam]))
    redirect_to pilotage_path, notice: "#{user.name} est maintenant #{user.role_label}."
  end

  # Admins manage the Google email used to match an existing AM account, and now also the team (rôle)
  # right from the same panel — subject to the same last-admin safeguard as the dedicated toggle button.
  def update_credentials(user)
    attrs = params.require(:user).permit(:name, :email, :role)

    if attrs[:role].present? && attrs[:role] != "Admin" && last_active_admin?(user)
      return redirect_to pilotage_path, alert: "Impossible : il doit rester au moins un administrateur actif."
    end

    if user.update(attrs)
      redirect_to pilotage_path, notice: "Identifiants de #{user.name} mis à jour."
    else
      redirect_to pilotage_path, alert: user.errors.full_messages.to_sentence
    end
  end

  def user_params
    params.require(:user).permit(:name, :email, :admin, :kam, :role)
  end
end
