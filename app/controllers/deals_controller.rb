class DealsController < ApplicationController
  before_action :require_kam_or_admin!, only: [:reassign_am]
  before_action :set_deal, only: [:update, :destroy]

  def create
    company = resolve_company
    if company.nil?
      return redirect_to portfolio_path(user_id: params[:redirect_user_id]), alert: "Impossible de déterminer le client."
    end

    deal = deal_class.new(create_params)
    deal.company = company

    if deal.save
      redirect_to portfolio_path(user_id: params[:redirect_user_id]), notice: "#{deal_label} ajouté."
    else
      redirect_to portfolio_path(user_id: params[:redirect_user_id]), alert: deal.errors.full_messages.to_sentence
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
  # A plain redirect (still used for non-Turbo requests) reloads the whole page.
  def update
    if @deal.update(update_params)
      respond_to do |format|
        format.turbo_stream { render turbo_stream: update_streams }
        format.html { redirect_to portfolio_path(user_id: params[:redirect_user_id]), notice: "Modifié." }
      end
    else
      respond_to do |format|
        format.turbo_stream { head :unprocessable_entity }
        format.html { redirect_to portfolio_path(user_id: params[:redirect_user_id]), alert: @deal.errors.full_messages.to_sentence }
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
  # Deliberately not scoped through set_deal/scoped_company: a KAM reassigning a deal is, by definition,
  # very often acting on a company they don't themselves own — require_kam_or_admin! is the only gate this
  # action needs, same as it's the only thing standing between a plain AM and this action entirely.
  def reassign_am
    deal = Deal.find(params[:id])
    new_user = User.active.find(params[:user_id])

    if deal.is_a?(ProduitDeal)
      deal.company.reassign_am!(new_user)
      notice = "Tous les produits de #{deal.company.name} ont été réaffectés à #{new_user.name}."
    else
      deal.update!(user: new_user)
      notice = "L'upsell #{deal.produit} de #{deal.company.name} a été réaffecté à #{new_user.name}."
    end

    redirect_back fallback_location: portfolio_path, notice: notice
  rescue ActiveRecord::RecordNotFound
    redirect_back fallback_location: portfolio_path, alert: "Élément ou AM introuvable."
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
        turbo_stream.replace(@deal, partial: "pilotage/global_upsell_row", locals: { deal: @deal }),
        turbo_stream.replace("global-summary-cards", partial: "shared/summary_cards",
          locals: { summary: PortfolioSummary.new(Company.all), dom_id: "global-summary-cards" })
      ]
    else
      row_partial = @deal.is_a?(UpsellDeal) ? "deals/upsell_row" : "deals/produit_row"
      owner = viewed_user
      [
        turbo_stream.replace(@deal, partial: row_partial, locals: { deal: @deal }),
        turbo_stream.replace(@deal.company, partial: "companies/evolution_row", locals: { company: @deal.company }),
        turbo_stream.replace("portfolio-summary-cards", partial: "shared/summary_cards",
          locals: { summary: PortfolioSummary.new(owner.companies.includes(:deals)), dom_id: "portfolio-summary-cards" })
      ]
    end
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
      owner = if current_user.admin? && params[:new_company_user_id].present?
        User.active.find(params[:new_company_user_id])
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
    fields = fields - admin_only_fields unless current_user.admin?
    params.require(:deal).permit(*fields)
  end

  def produit_fields
    [:produit, :college, :assureur, :arr, :taux, :identifiant, :statut_renouvellement]
  end

  def upsell_fields
    [:produit, :nombre_salaries, :probabilite_signature, :statut_signature]
  end

  # Contract-of-record fields on a produit deal (identifiant, ARR, and the choices that define the
  # contract itself) stay admin-only; taux/statut_renouvellement remain open to the owning AM.
  def admin_only_fields
    [:produit, :college, :assureur, :arr, :identifiant]
  end
end
