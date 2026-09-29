# Rescue-effort log on "Entreprises à risque" (Vue globale) — open to every authenticated user (not
# privileged-gated like the deal-edit forms there): logging what's being tried for an at-risk client is
# collaborative record-keeping, not a change to anyone's contract/portfolio data. Deleting an entry is
# narrower — only its own author or an admin/KAM, so one person's log can't be wiped by someone else.
# Plain redirect (not turbo_stream): this is occasional note-taking, not a table edited row after row.
class RiskNotesController < ApplicationController
  def create
    company = Company.find(params[:company_id])
    RiskNote.create!(company: company, user: current_user, content: params.dig(:risk_note, :content))
    redirect_to return_path, notice: "Commentaire ajouté."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to return_path, alert: e.record.errors.full_messages.to_sentence
  rescue ActiveRecord::RecordNotFound
    redirect_to return_path, alert: "Entreprise introuvable."
  end

  def destroy
    note = RiskNote.find(params[:id])
    unless current_user.privileged? || note.user == current_user
      return redirect_to return_path, alert: "Tu ne peux supprimer que tes propres commentaires."
    end

    note.destroy
    redirect_to return_path, notice: "Commentaire supprimé."
  rescue ActiveRecord::RecordNotFound
    redirect_to return_path, alert: "Commentaire introuvable."
  end

  private

  # The risk note panel carries the current filtered/paginated Vue globale URL through as return_to (see
  # pilotage/_risk_note_panel.html.erb) — redirect_back's Referer-header approach turned out not to
  # reliably survive a real form submit, silently dropping the admin's filters. Only accepts a same-app
  # path (never an absolute/protocol-relative URL) to rule out this becoming an open redirect.
  def return_path
    candidate = params[:return_to].to_s
    candidate.start_with?("/") && !candidate.start_with?("//") ? candidate : pilotage_path
  end
end
