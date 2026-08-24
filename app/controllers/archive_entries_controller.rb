class ArchiveEntriesController < ApplicationController
  before_action :require_admin!

  # Only archived years are correctable here — the current, not-yet-closed year is edited from
  # "Mon portefeuille" instead (see HistoriqueQuery's is_live rows, which never hit this action).
  #
  # Responds with a turbo_stream that swaps just this row back in — with filters/années/scroll position
  # all still exactly as the admin left them, unlike redirect_back's full-page reload.
  def update
    entry = ArchiveEntry.find(params[:id])
    entry.assign_attributes(entry_params)
    entry.taux = 0 if entry.statut_renouvellement == ProduitDeal::CHURNED
    entry.save!
    row = HistoriqueQuery::Row.from_archive_entry(entry)
    respond_to do |format|
      format.turbo_stream { render turbo_stream: turbo_stream.replace(row.dom_id, partial: "historique/row", locals: { r: row }) }
      format.html { redirect_back fallback_location: historique_path, notice: "Modifié." }
    end
  rescue ActiveRecord::RecordNotFound
    redirect_back fallback_location: historique_path, alert: "Ligne archivée introuvable."
  end

  private

  def entry_params
    params.require(:archive_entry).permit(:arr, :taux, :statut_renouvellement)
  end
end
