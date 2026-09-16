namespace :upsell_arr do
  desc "Recalculate every active upsell with Bonus Tracker's BO-backed estimator"
  task refresh: :environment do
    UpsellDeal.includes(company: :produit_deals).find_each do |deal|
      result = BonusTrackerUpsellEstimator.refresh!(deal)
      puts "#{deal.id}\t#{deal.company.name}\t#{result ? result.arr : 'non estimable'}"
    end
  end
end
