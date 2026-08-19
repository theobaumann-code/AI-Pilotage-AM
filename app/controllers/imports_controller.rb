class ImportsController < ApplicationController
  before_action :require_admin!

  def new
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
end
