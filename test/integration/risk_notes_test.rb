require "test_helper"

# Rescue-effort log on "Entreprises à risque" — any signed-in user can add an entry (collaborative
# record-keeping, not a portfolio/contract edit), but only its own author or an admin/KAM can delete one.
class RiskNotesTest < ActionDispatch::IntegrationTest
  setup do
    @am = User.create!(email: "am-risknotes@example.com", name: "AM RiskNotes", admin: false, active: true)
    @other_am = User.create!(email: "other-am-risknotes@example.com", name: "Other AM RiskNotes", admin: false, active: true)
    @admin = User.create!(email: "admin-risknotes@example.com", name: "Admin RiskNotes", admin: true, active: true)
    @company = Company.create!(name: "Client RiskNotes", user: @am)
  end

  test "any signed-in user can add a note to an at-risk company" do
    sign_in @other_am
    assert_difference "RiskNote.count", 1 do
      post risk_notes_path, params: { company_id: @company.id, risk_note: { content: "Appel prévu jeudi" } }
    end

    note = RiskNote.last
    assert_equal @other_am, note.user
    assert_equal "Appel prévu jeudi", note.content
    assert_redirected_to pilotage_path
  end

  test "an empty note is rejected instead of being silently created" do
    sign_in @am
    assert_no_difference "RiskNote.count" do
      post risk_notes_path, params: { company_id: @company.id, risk_note: { content: "" } }
    end
  end

  test "the note's own author can delete it" do
    note = RiskNote.create!(company: @company, user: @am, content: "À relancer")
    sign_in @am

    assert_difference "RiskNote.count", -1 do
      delete risk_note_path(note)
    end
  end

  test "an admin can delete someone else's note" do
    note = RiskNote.create!(company: @company, user: @am, content: "À relancer")
    sign_in @admin

    assert_difference "RiskNote.count", -1 do
      delete risk_note_path(note)
    end
  end

  test "a different regular AM cannot delete someone else's note" do
    note = RiskNote.create!(company: @company, user: @am, content: "À relancer")
    sign_in @other_am

    assert_no_difference "RiskNote.count" do
      delete risk_note_path(note)
    end
  end

  test "the risk table shows the comment count and an existing note's content" do
    ProduitDeal.create!(company: @company, produit: "Mutuelle", identifiant: "risknote-1",
      college: "Cadre", assureur: "AXA", arr: 10_000, taux: 0, statut_renouvellement: "En cours", risque_churn: 20)
    RiskNote.create!(company: @company, user: @am, content: "Rendez-vous prévu la semaine prochaine")

    sign_in @admin
    get pilotage_path
    assert_response :success
    section = @response.body[/id="rque-table-frame">.*?<\/turbo-frame>/m]
    assert_match "💬 1", section
    assert_match "Rendez-vous prévu la semaine prochaine", section
  end
end
