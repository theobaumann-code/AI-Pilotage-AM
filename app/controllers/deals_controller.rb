class DealsController < ApplicationController
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

  def update
    if @deal.update(update_params)
      redirect_to portfolio_path(user_id: params[:redirect_user_id]), notice: "Modifié."
    else
      redirect_to portfolio_path(user_id: params[:redirect_user_id]), alert: @deal.errors.full_messages.to_sentence
    end
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
      Company.find_or_create_by!(name: params[:new_company_name].strip) { |c| c.user = owner }
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
