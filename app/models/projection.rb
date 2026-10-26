# "Projection" of next campaign's portfolios: temporary what-ifs (AMs leaving, recruits, accounts moved) layered
# over the BI's real assignment (bi_accounts). Read by "Projection portefeuille" only - no other page depends on it,
# and nothing here is ever written back to the BO.
module Projection
  def self.table_name_prefix
    "projection_"
  end
end
