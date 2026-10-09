class DealsController < ApplicationController
  include ActionView::RecordIdentifier

  before_action :require_admin!, only: [:reassign_am]
  before_action :set_deal, only: [:update, :destroy, :reassign_am]

  def create
    company = resolve_company
    if company.nil?
      return redirect_to fallback_redirect_path, alert: "Impossible de déterminer le client."
    end

    deal = deal_class.new(create_params)
    deal.company = company

    if deal.save
      notice = deal.is_a?(UpsellDeal) ? "Upsell ajouté." : "Produit ajouté."
      redirect_to fallback_redirect_path, notice: notice
    else
      redirect_to fallback_redirect_path, alert: deal.errors.full_messages.to_sentence
    end
  end

  # Inline edits respond with turbo_streams that replace this row and whatever aggregates depend on it, all
  # in place — so changing a field never scrolls the page back to the top, loses whatever the admin had
  # scrolled/filtered to, or leaves the totals momentarily inconsistent with the row that just changed.
  # Which aggregates depend on where the edit came from: Mon portefeuille (the default) also carries the
  # company's "Évolution ARR" row and that AM's own summary cards; Vue globale's cross-AM upsells table
  # (row_context=global) instead carries the page-wide summary cards, since there's no single "viewed AM".
  # Either way this is the AM's real record being updated, so it's already what they'll see next time they
  # open Mon portefeuille themselves — no separate sync step needed.
  # A plain redirect (still used for non-Turbo requests, e.g. Turbo failing to load/intercept the
  # submission) reloads the whole page. Must land back on whichever page the edit actually came from:
  # row_context=global/global_produit rows never carry redirect_user_id (there's no single "viewed AM" on
  # Vue globale), so falling back to portfolio_path(user_id: nil) would silently bounce the admin/KAM to
  # their OWN "Mon portefeuille" instead of back to Vue globale — indistinguishable, from their side, from
  # "editing this table just doesn't work".
  def update
    if @deal.update(update_params)
      respond_to do |format|
        format.turbo_stream { render turbo_stream: update_streams }
        format.html { redirect_to fallback_redirect_path, notice: "Modifié." }
      end
    else
      error_message = @deal.errors.full_messages.to_sentence
      @deal.reload
      respond_to do |format|
        format.turbo_stream { render turbo_stream: error_streams(error_message), status: :unprocessable_entity }
        format.html { redirect_to fallback_redirect_path, alert: error_message }
      end
    end
  end

  # A produit deal never moves alone — it's part of the company's official contract, so reassigning one
  # reassigns the whole company (all its produits) via Company#reassign_am!, exactly as if done from
  # scratch. An upsell is one AM's pipeline opportunity, not part of the contract, so it moves by itself:
  # sets Deal#user directly, leaving the company (and its produits, and any of its OTHER upsells that
  # already had their own override) completely untouched. Either way this is a rare, bulk-ish admin action,
  # not a routine field edit — a full-page redirect (like the admin-toggle/deactivate buttons) is simpler
  # and more correct here than trying to enumerate every row a reassignment could affect via turbo_stream.
  def reassign_am
    new_user = User.assignable.find(params[:user_id])

    if @deal.is_a?(ProduitDeal)
      @deal.company.reassign_am!(new_user)
      notice = "Tous les produits de #{@deal.company.name} ont été réaffectés à #{new_user.name}."
    else
      @deal.update!(user: new_user)
      notice = "L'upsell #{@deal.produit} de #{@deal.company.name} a été réaffecté à #{new_user.name}."
    end

    redirect_back fallback_location: portfolio_path, notice: notice
  rescue ActiveRecord::RecordNotFound
    redirect_back fallback_location: portfolio_path, alert: "AM introuvable."
  end

  # Produit deals carry official contract data (identifiant, ARR) and are locked to admins for deletion;
  # upsell deals are an AM's own working pipeline, so the owning AM may delete their own mistakes too.
  def destroy
    if @deal.is_a?(ProduitDeal)
      require_admin!
      return if performed?
    else
      scoped_company(@deal.company_id)
    end

    @deal.destroy
    redirect_to portfolio_path(user_id: params[:redirect_user_id]), notice: "Supprimé."
  end

  private

  def set_deal
    @deal = Deal.find(params[:id])
    scoped_company(@deal.company_id)
  rescue ActiveRecord::RecordNotFound
    redirect_to portfolio_path, alert: "Élément introuvable."
  end

  def update_streams
    if params[:row_context] == "global"
      [
        turbo_stream.replace(@deal, partial: "pilotage/global_upsell_row", locals: { deal: @deal }, method: :morph),
        turbo_stream.replace("global-summary-cards", partial: "shared/summary_cards",
          locals: { summary: PortfolioSummary.new(Company.includes(:produit_deals, :upsell_deals)), dom_id: "global-summary-cards" }, method: :morph)
      ]
    elsif params[:row_context] == "global_churn"
      [turbo_stream.replace(dom_id(@deal, :churn), partial: "pilotage/churned_produit_row", locals: { deal: @deal }, method: :morph)]
    elsif params[:row_context] == "global_produit"
      [
        turbo_stream.replace(@deal, partial: "pilotage/global_produit_row", locals: { deal: @deal }, method: :morph),
        turbo_stream.replace("global-summary-cards", partial: "shared/summary_cards",
          locals: { summary: PortfolioSummary.new(Company.includes(:produit_deals, :upsell_deals)), dom_id: "global-summary-cards" }, method: :morph)
      ]
    else
      owner = viewed_user
      [
        turbo_stream.replace(@deal, partial: row_partial, locals: { deal: @deal }, method: :morph),
        turbo_stream.replace(@deal.company, partial: "companies/evolution_row", locals: { company: @deal.company }, method: :morph),
        turbo_stream.replace("portfolio-summary-cards", partial: "shared/summary_cards",
          locals: { summary: PortfolioSummary.new(owner.companies.includes(:produit_deals, :upsell_deals)), dom_id: "portfolio-summary-cards" }, method: :morph)
      ]
    end
  end

  # A rejected inline edit must still hand Turbo a real body to swap in — an empty 422 (the previous
  # behavior) leaves a turbo-frame-scoped form with nothing to match against its enclosing frame, and Turbo
  # blanks the whole frame ("Content missing") instead of just that row. Reverting @deal before rendering
  # means the row shows its last valid value again, with the actual reason surfaced via the flash instead.
  def row_partial
    case params[:row_context]
    when "global" then "pilotage/global_upsell_row"
    when "global_produit" then "pilotage/global_produit_row"
    when "global_churn" then "pilotage/churned_produit_row"
    else @deal.is_a?(UpsellDeal) ? "deals/upsell_row" : "deals/produit_row"
    end
  end

  # Shared by create (whose "+ Nouveau produit"/"+ Nouvel upsell" forms carry return_to=pilotage when
  # opened from Vue globale — see pilotage/show.html.erb) and update's row_context=global/global_produit
  # case above.
  def fallback_redirect_path
    if params[:return_to] == "pilotage" || %w[global global_produit global_churn].include?(params[:row_context])
      pilotage_path
    else
      portfolio_path(user_id: params[:redirect_user_id])
    end
  end

  def error_streams(message)
    [
      turbo_stream.replace(params[:row_context] == "global_churn" ? dom_id(@deal, :churn) : @deal,
        partial: row_partial, locals: { deal: @deal }, method: :morph),
      turbo_stream.replace("flash", partial: "shared/flash", locals: { notice: nil, alert: message })
    ]
  end

  def deal_class
    params[:type] == "upsell" ? UpsellDeal : ProduitDeal
  end

  def deal_label
    params[:type] == "upsell" ? "Upsell" : "Produit"
  end

  # Existing companies carry their AM via Company#user, so picking one already fixes the AM — no separate
  # mismatch check needed (unlike the original, which had to validate a client-side AM field by hand).
  def resolve_company
    if params[:company_id].present?
      scoped_company(params[:company_id])
    elsif params[:new_company_name].present?
      owner = if current_user.privileged? && params[:new_company_user_id].present?
        User.assignable.find(params[:new_company_user_id])
      else
        current_user
      end
      Company.find_or_create_by_name!(params[:new_company_name], user: owner)
    end
  rescue ActiveRecord::RecordNotFound
    nil
  end

  # Whoever adds a client enters its full contract data up front (identifiant, ARR...) — the admin-only
  # lock only kicks in afterwards, to protect already-entered contract data from casual edits.
  def create_params
    fields = deal_class == UpsellDeal ? upsell_fields : produit_fields
    params.require(:deal).permit(*fields)
  end

  def update_params
    fields = @deal.is_a?(UpsellDeal) ? upsell_fields : produit_fields
    fields = fields - admin_only_fields unless current_user.privileged?
    params.require(:deal).permit(*fields)
  end

  def produit_fields
    [:produit, :college, :assureur, :arr, :taux, :identifiant, :statut_renouvellement, :risque_churn,
     :churn_reason, :churn_comment]
  end

  def upsell_fields
    [:produit, :college, :nombre_salaries, :probabilite_signature, :statut_signature]
  end

  # Contract-of-record fields on a produit deal (identifiant, ARR, and the choices that define the
  # contract itself) stay admin-only; taux/statut_renouvellement/risque_churn remain open to the owning AM.
  # An upsell isn't a contract of record — it's the owning AM's own pipeline opportunity (see #destroy),
  # so nothing about it is locked to admins/KAM at this level; Vue globale's own privileged?-gated forms
  # are the only thing standing between a regular AM and someone else's upsell.
  def admin_only_fields
    @deal.is_a?(UpsellDeal) ? [] : [:produit, :college, :assureur, :arr, :identifiant]
  end
end
