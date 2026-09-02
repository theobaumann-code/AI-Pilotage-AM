class CompaniesController < ApplicationController
  before_action :require_admin!, only: [:destroy]
  before_action :require_kam_or_admin!, only: [:reassign_am]

  def destroy
    company = Company.find(params[:id])
    company.destroy
    redirect_to portfolio_path, notice: "Client supprimé."
  rescue ActiveRecord::RecordNotFound
    redirect_to portfolio_path, alert: "Client introuvable."
  end

  def reassign_am
    company = Company.find(params[:id])
    new_user = User.active.find(params[:user_id])
    company.reassign_am!(new_user)
    redirect_to portfolio_path, notice: "#{company.name} réassigné à #{new_user.name}."
  rescue ActiveRecord::RecordNotFound
    redirect_to portfolio_path, alert: "Client ou AM introuvable."
  end
end
