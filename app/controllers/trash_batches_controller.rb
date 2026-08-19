class TrashBatchesController < ApplicationController
  before_action :require_admin!

  # Moving a year to the trash never touches the active portfolio — only ArchiveEntry rows for that
  # year change hands, matching the original's "supprimer l'année de l'historique" (reversible via restore).
  def create
    year = params[:year].to_i
    entries = ArchiveEntry.where(year: year).to_a
    if entries.empty?
      return redirect_to historique_path, alert: "Aucune donnée archivée pour l'année #{year}."
    end

    batch = TrashBatch.create!(year: year, deleted_at: Time.current, deleted_by: current_user)
    ArchiveEntry.where(id: entries.map(&:id)).update_all(trash_batch_id: batch.id)
    redirect_to historique_path, notice: "Année #{year} déplacée vers la corbeille (#{entries.size} ligne(s))."
  end

  def restore
    batch = TrashBatch.find(params[:id])
    year = batch.year
    batch.restore!
    redirect_to historique_path, notice: "Année #{year} restaurée."
  end

  def destroy
    batch = TrashBatch.find(params[:id])
    year = batch.year
    batch.purge!
    redirect_to historique_path, notice: "Année #{year} supprimée définitivement de la corbeille."
  end
end
