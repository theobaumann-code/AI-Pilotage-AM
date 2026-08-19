class AppSettingsController < ApplicationController
  before_action :require_admin!

  def update
    AppSetting.instance.update!(annee_en_cours: params[:annee_en_cours])
    redirect_to historique_path, notice: "Année en cours mise à jour."
  end
end
