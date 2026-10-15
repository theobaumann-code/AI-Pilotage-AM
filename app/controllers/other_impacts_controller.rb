# Manual "Autres impacts" on Mon portefeuille — admins and KAMs only (require_admin!, which also covers KAM).
# Rows are edited in place; every edit re-renders its row plus the AM's KPI cards and impact totals, since a
# "Validé" amount moves ARR final / NRR. The AM whose page it is travels as redirect_user_id (see
# ApplicationController#viewed_user), exactly like Mon portefeuille's deal rows.
class OtherImpactsController < ApplicationController
  include ActionView::RecordIdentifier

  before_action :require_admin!
  before_action :set_impact, only: [:update, :destroy]

  # Submitted by the "+ Autre impact" pop-up; the new line then lives in the "Autres impacts" table, where it
  # stays editable and deletable like any other.
  def create
    impact = OtherImpact.new(impact_params)
    if impact.save
      redirect_to back_path(anchor: "other-impacts"), notice: "Impact ajouté."
    else
      redirect_to back_path, alert: impact.errors.full_messages.to_sentence
    end
  end

  def update
    if @impact.update(impact_params)
      respond_to do |format|
        format.turbo_stream { render turbo_stream: update_streams }
        format.html { redirect_to back_path(anchor: "other-impacts"), notice: "Modifié." }
      end
    else
      message = @impact.errors.full_messages.to_sentence
      @impact.reload
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: [
            turbo_stream.replace(@impact, partial: "other_impacts/row", locals: row_locals),
            turbo_stream.replace("flash", partial: "shared/flash", locals: { notice: nil, alert: message })
          ], status: :unprocessable_entity
        end
        format.html { redirect_to back_path(anchor: "other-impacts"), alert: message }
      end
    end
  end

  def destroy
    @impact.destroy
    redirect_to back_path(anchor: "other-impacts"), notice: "Ligne supprimée."
  end

  private

  def set_impact
    @impact = OtherImpact.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    redirect_to back_path, alert: "Ligne introuvable."
  end

  def impact_params
    params.require(:other_impact).permit(:company_id, :produit, :amount, :comment, :statut)
  end

  def back_path(anchor: nil)
    portfolio_path(user_id: viewed_user.id, anchor: anchor)
  end

  def row_locals
    { impact: @impact, companies: viewed_user.companies.order(:name).to_a }
  end

  def update_streams
    owner = viewed_user
    summary = PortfolioSummary.new(owner.companies.includes(:produit_deals, :upsell_deals, :current_other_impacts), user: owner)
    # The KPI cards (which carry the "Autres impacts" card) and the client rows' "Autre impact" / "ARR final"
    # — both the client the line was on and the one it's on now, if it was moved.
    affected = Company.where(id: [@impact.company_id, @impact.company_id_before_last_save].compact.uniq)
      .includes(:produit_deals, :upsell_deals, :current_other_impacts)
    [
      turbo_stream.replace(@impact, partial: "other_impacts/row", locals: row_locals, method: :morph),
      turbo_stream.replace("portfolio-summary-cards", partial: "shared/summary_cards",
        locals: { summary: summary, dom_id: "portfolio-summary-cards" }, method: :morph),
      *affected.map { |company| turbo_stream.replace(company, partial: "companies/evolution_row", locals: { company: company }, method: :morph) }
    ]
  end
end
