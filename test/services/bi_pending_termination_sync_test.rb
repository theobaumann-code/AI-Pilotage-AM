require "test_helper"

class BiPendingTerminationSyncTest < ActiveSupport::TestCase
  FakeClient = Struct.new(:rows) do
    attr_reader :sql

    def query(sql)
      @sql = sql
      rows
    end
  end

  def row(id, **attrs)
    { "bi_id" => id, "name" => "AXA - Prévoyance", "terminable_type" => "InternalContract", "terminable_id" => 77,
      "product_type" => 2, "user_pro_id" => 5, "social_name" => "Client", "account_kind" => "set", "account_bi_id" => 9,
      "created_on" => "2026-10-27", "termination_date" => "2026-12-31", "contract_arr" => 1234.567 }.merge(attrs)
  end

  test "replaces every termination with what the BI returns" do
    BiPendingTermination.create!(bi_id: 999, account_kind: "set", account_bi_id: 1, synced_at: 1.day.ago)
    client = FakeClient.new([ row(1), row(2, "terminable_type" => "ExternalContract", "contract_arr" => nil) ])

    assert_equal 2, BiPendingTerminationSync.new(client: client).sync!
    assert_equal [ 1, 2 ], BiPendingTermination.order(:bi_id).pluck(:bi_id)
    first = BiPendingTermination.find_by!(bi_id: 1)
    assert_equal [ 1234.57, Date.new(2026, 12, 31), "Contrat SideCare", "Prévoyance" ],
      [ first.contract_arr.to_f, first.termination_date, first.type_label, first.product_label ]
    assert_nil BiPendingTermination.find_by!(bi_id: 2).contract_arr
    assert_match "WHERE t.operation_status = 1", client.sql
    assert_match "1 + 0.1532", client.sql, "health ARR is net"
  end

  test "an empty answer means no termination waiting: the table is emptied" do
    BiPendingTermination.create!(bi_id: 1, account_kind: "set", account_bi_id: 1, synced_at: 1.day.ago)
    assert_equal 0, BiPendingTerminationSync.new(client: FakeClient.new([])).sync!
    assert_equal 0, BiPendingTermination.count
  end
end
