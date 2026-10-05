class AddChurnReasonToDeals < ActiveRecord::Migration[8.1]
  def change
    add_column :deals, :churn_reason, :string
    add_column :deals, :churn_comment, :text
  end
end
