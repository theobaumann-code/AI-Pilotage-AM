require "csv"

class ImportsController < ApplicationController
  before_action :require_kam_or_admin!

  def new
  end

  # Downloadable starting point for each import type, headers matching CsvImport's own column mapping
  # exactly — so a file built from this template is guaranteed to parse correctly.
  def template
    if params[:type] == "upsell"
      send_data upsell_template_csv, filename: "modele-import-upsells.csv", type: "text/csv; charset=utf-8"
    else
      send_data produit_template_csv, filename: "modele-import-produits.csv", type: "text/csv; charset=utf-8"
    end
  end

  # Preview never writes to the database — CsvImport#analyze is pure. The resolved CSV text (whether it
  # came from an upload or a paste) is echoed back in a hidden field so "Confirmer" can re-run the exact
  # same analysis right before applying it, instead of trusting stale state from this request.
  def preview
    @deal_type = params[:deal_type]
    @csv_text = import_text
    @result = CsvImport.new(text: @csv_text, deal_type: @deal_type).analyze
    render :new, formats: [:html]
  end

  def create
    @deal_type = params[:deal_type]
    @csv_text = params[:csv_text].to_s
    result = CsvImport.new(text: @csv_text, deal_type: @deal_type).analyze

    if result.apply!(admin_user: current_user)
      redirect_to portfolio_path, notice: "Import terminé : #{result.to_create.size} créé(s), #{result.to_update.size} mis à jour."
    else
      @result = result
      flash.now[:alert] = "Import impossible : vérifiez les erreurs ci-dessous."
      render :new, status: :unprocessable_entity, formats: [:html]
    end
  end

  private

  def import_text
    if params[:csv_file].present?
      params[:csv_file].read.force_encoding("UTF-8")
    else
      params[:csv_text].to_s
    end
  end

  def produit_template_csv
    CSV.generate(col_sep: ";") do |csv|
      csv << ["Nom", "Produit", "Identifiant", "ARR", "Taux de renouvellement négocié", "Statut de renouvellement",
              "Collège", "Assureur", "AM"]
      csv << ["Entreprise Exemple", ProduitDeal::PRODUITS.first, "ID-0001", "10000", "5", "En cours",
              ProduitDeal::COLLEGES.first, ProduitDeal::ASSUREURS.first, "Nom de l'AM"]
    end
  end

  def upsell_template_csv
    CSV.generate(col_sep: ";") do |csv|
      csv << ["Nom", "Produit", "Nb salariés", "% de chance", "Statut", "AM"]
      csv << ["Entreprise Exemple", UpsellDeal::PRODUITS.first, "20", "50", "En cours", "Nom de l'AM"]
    end
  end
end
