require "test_helper"

class RiskNoteTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "am-risknote@example.com", name: "AM Risk Note", active: true)
    @company = Company.create!(name: "Cabinet Risk Note", user: @user)
  end

  test "requires content" do
    note = RiskNote.new(company: @company, user: @user, content: "")
    assert_not note.valid?
    assert_includes note.errors[:content], "can't be blank"
  end

  test "most recent entries come first" do
    older = RiskNote.create!(company: @company, user: @user, content: "Premier appel client")
    older.update_column(:created_at, 2.days.ago)
    newer = RiskNote.create!(company: @company, user: @user, content: "Proposition de remise envoyée")
    newer.update_column(:created_at, 1.day.ago)

    assert_equal [newer, older], @company.risk_notes.to_a
  end
end
