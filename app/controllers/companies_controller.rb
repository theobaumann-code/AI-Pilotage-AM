class CompaniesController < ApplicationController
  before_action :require_admin!, only: [:destroy, :reassign_am]

  # Scoped to "Entreprises à risque" (Vue globale) on purpose, not a general company-edit endpoint: any
  # signed-in user may flag a company as at-risk for lack of offers (risque_manque_offres), the same
  # collaborative-record-keeping spirit as that table's risk notes; naming its référent (the manager
  # following the deal) is a workload-distribution decision, so it stays with admins/KAMs.
  def update
    company = Company.find(params[:id])
    permitted = [:risque_manque_offres]
    permitted << :referent_id if current_user.privileged?
    company.update!(params.require(:company).permit(*permitted))
    redirect_to return_path, notice: "Mis à jour."
  rescue ActiveRecord::RecordNotFound
    redirect_to return_path, alert: "Client introuvable."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to return_path, alert: e.record.errors.full_messages.to_sentence
  end

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

  private

  # Mirrors RiskNotesController#return_path — the checkbox lives inside the same filtered/paginated
  # "Entreprises à risque" table, and only a same-app path is ever honored (never an open redirect).
  def return_path
    candidate = params[:return_to].to_s
    candidate.start_with?("/") && !candidate.start_with?("//") ? candidate : pilotage_path
  end
end
