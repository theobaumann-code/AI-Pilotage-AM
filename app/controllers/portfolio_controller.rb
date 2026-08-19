class PortfolioController < ApplicationController
  def show
    @companies = viewed_user.companies.includes(:deals).order(:name)
    @summary = PortfolioSummary.new(@companies)
    @produit_deals = @companies.flat_map(&:produit_deals).sort_by { |d| d.company.name }
    @upsell_deals = @companies.flat_map(&:upsell_deals).sort_by { |d| d.company.name }
    @viewable_ams = current_user.admin? ? User.active.order(:name) : nil
    @selectable_companies = current_user.admin? ? Company.order(:name) : current_user.companies.order(:name)
  end
end
