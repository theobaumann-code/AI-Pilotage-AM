class AppSettingsController < ApplicationController
  before_action :require_admin!

  def update
    if params[:annee_en_cours].present?
      AppSetting.instance.update!(annee_en_cours: params[:annee_en_cours])
      redirect_to historique_path, notice: "Année en cours mise à jour."
    else
      AppSetting.instance.update!(arr_non_accompagne: params[:arr_non_accompagne])
      redirect_to pilotage_path, notice: "ARR non accompagné mis à jour."
    end
  end
end
