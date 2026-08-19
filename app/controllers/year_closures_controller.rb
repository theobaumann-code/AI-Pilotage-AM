class YearClosuresController < ApplicationController
  before_action :require_admin!

  # Archives every active deal under the current year, then reconducts the portfolio: churned produits and
  # every upsell (a one-off event) drop out entirely; renewed produits carry forward at their new ARR base
  # with taux reset to 0. Nothing here is reachable outside this one transaction, so a failure leaves the
  # portfolio untouched.
  def create
    setting = AppSetting.instance
    year = setting.annee_en_cours

    ActiveRecord::Base.transaction do
      Deal.includes(:company).find_each { |deal| archive_deal(deal, year) }

      UpsellDeal.destroy_all
      ProduitDeal.where(statut_renouvellement: ProduitDeal::CHURNED).destroy_all
      ProduitDeal.where.not(statut_renouvellement: ProduitDeal::CHURNED).find_each do |deal|
        new_arr = deal.final_arr
        deal.update!(arr: new_arr, taux: 0, statut_renouvellement: "En cours")
      end

      setting.update!(annee_en_cours: year + 1)
    end

    redirect_to historique_path, notice: "Année #{year} clôturée. Portefeuille reconduit sur #{year + 1}."
  end

  private

  def archive_deal(deal, year)
    company = deal.company
    ArchiveEntry.create!(
      year: year, user: company.user, am_name: company.user.name, company_name: company.name,
      deal_type: deal.type, produit: deal.produit, arr: deal.arr, taux: deal.taux,
      identifiant: deal.identifiant, college: deal.college, assureur: deal.assureur,
      statut_renouvellement: deal.statut_renouvellement, nombre_salaries: deal.nombre_salaries,
      probabilite_signature: deal.probabilite_signature, statut_signature: deal.statut_signature,
      upsell_amount: deal.is_a?(UpsellDeal) ? deal.upsell_amount : 0
    )
  end
end
