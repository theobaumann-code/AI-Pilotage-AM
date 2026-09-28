# Admin-only bookkeeping for the "churn non accompagné" breakdown on Vue globale — one row per named
# company (or "Autre" for small accounts lumped together), summed into AppSetting#churn_non_accompagne.
# Plain full-page redirects throughout: this is low-frequency admin bookkeeping, not a table someone is
# rapidly editing row after row, so the inline-edit turbo_stream machinery elsewhere isn't warranted here.
class NonAccompagneChurnEntriesController < ApplicationController
  before_action :require_admin!

  def create
    NonAccompagneChurnEntry.create!(entry_params)
    redirect_to pilotage_path, notice: "Entrée de churn non accompagné ajoutée."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to pilotage_path, alert: e.record.errors.full_messages.to_sentence
  end

  def update
    entry = NonAccompagneChurnEntry.find(params[:id])
    entry.update!(entry_params)
    redirect_to pilotage_path, notice: "Entrée de churn non accompagné modifiée."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to pilotage_path, alert: e.record.errors.full_messages.to_sentence
  rescue ActiveRecord::RecordNotFound
    redirect_to pilotage_path, alert: "Entrée introuvable."
  end

  def destroy
    NonAccompagneChurnEntry.find(params[:id]).destroy
    redirect_to pilotage_path, notice: "Entrée de churn non accompagné supprimée."
  rescue ActiveRecord::RecordNotFound
    redirect_to pilotage_path, alert: "Entrée introuvable."
  end

  private

  def entry_params
    params.require(:non_accompagne_churn_entry).permit(:company_name, :amount)
  end
end
