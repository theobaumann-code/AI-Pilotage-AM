class ArchiveEntriesController < ApplicationController
  before_action :require_admin!

  # Only archived years are correctable here — the current, not-yet-closed year is edited from
  # "Mon portefeuille" instead (see HistoriqueQuery's is_live rows, which never hit this action).
  def update
    entry = ArchiveEntry.find(params[:id])
    entry.assign_attributes(entry_params)
    entry.taux = 0 if entry.statut_renouvellement == ProduitDeal::CHURNED
    entry.save!
    redirect_back fallback_location: historique_path, notice: "Modifié."
  rescue ActiveRecord::RecordNotFound
    redirect_back fallback_location: historique_path, alert: "Ligne archivée introuvable."
  end

  private

  def entry_params
    params.require(:archive_entry).permit(:arr, :taux, :statut_renouvellement)
  end
end
