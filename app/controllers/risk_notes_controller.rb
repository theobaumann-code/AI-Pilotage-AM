# Rescue-effort log on "Entreprises à risque" (Vue globale) — open to every authenticated user (not
# privileged-gated like the deal-edit forms there): logging what's being tried for an at-risk client is
# collaborative record-keeping, not a change to anyone's contract/portfolio data. Deleting an entry is
# narrower — only its own author or an admin/KAM, so one person's log can't be wiped by someone else.
# Plain redirect_back (not turbo_stream): this is occasional note-taking, not a table edited row after row.
class RiskNotesController < ApplicationController
  def create
    company = Company.find(params[:company_id])
    RiskNote.create!(company: company, user: current_user, content: params.dig(:risk_note, :content))
    redirect_back fallback_location: pilotage_path, notice: "Commentaire ajouté."
  rescue ActiveRecord::RecordInvalid => e
    redirect_back fallback_location: pilotage_path, alert: e.record.errors.full_messages.to_sentence
  rescue ActiveRecord::RecordNotFound
    redirect_back fallback_location: pilotage_path, alert: "Entreprise introuvable."
  end

  def destroy
    note = RiskNote.find(params[:id])
    unless current_user.privileged? || note.user == current_user
      return redirect_back fallback_location: pilotage_path, alert: "Tu ne peux supprimer que tes propres commentaires."
    end

    note.destroy
    redirect_back fallback_location: pilotage_path, notice: "Commentaire supprimé."
  rescue ActiveRecord::RecordNotFound
    redirect_back fallback_location: pilotage_path, alert: "Commentaire introuvable."
  end
end
