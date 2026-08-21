Rails.application.routes.draw do
  devise_for :users
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  resource :portfolio, only: [:show], controller: "portfolio"
  resource :pilotage, only: [:show], controller: "pilotage"
  resources :companies, only: [:create, :destroy] do
    member { patch :reassign_am }
  end
  resources :deals, only: [:create, :update, :destroy]
  resources :users, only: [:create, :update, :destroy]
  resource :historique, only: [:show], controller: "historique"
  resources :archive_entries, only: [:update]
  resources :trash_batches, only: [:create, :destroy] do
    member { patch :restore }
  end
  resource :year_closure, only: [:create], controller: "year_closures"
  resource :app_setting, only: [:update], controller: "app_settings"
  get "import" => "imports#new", as: :new_import
  post "import/preview" => "imports#preview", as: :preview_import
  post "import" => "imports#create", as: :import

  # Defines the root path route ("/")
  root "portfolio#show"
end
