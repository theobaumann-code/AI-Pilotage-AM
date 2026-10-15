require "test_helper"

# Admins/KAMs rename a client straight from the "Évolution de l'ARR par client" table on Mon portefeuille.
class CompanyRenameTest < ActionDispatch::IntegrationTest
  setup do
    @admin = User.create!(email: "admin-rename@example.com", name: "Admin Rename", admin: true, active: true)
    @kam = User.create!(email: "kam-rename@example.com", name: "KAM Rename", kam: true, active: true)
    @am = User.create!(email: "am-rename@example.com", name: "AM Rename", active: true)
    @company = Company.create!(name: "Ancien Nom", user: @am)
    @other = Company.create!(name: "Autre Client", user: @am)
    ProduitDeal.create!(company: @company, produit: "Mutuelle", identifiant: "rn-1", college: "Cadre",
      assureur: "AXA", arr: 1_000, statut_renouvellement: "En cours")
  end

  def evolution_table
    @response.body[/id="evo-table-frame">.*?<\/turbo-frame>/m]
  end

  test "an admin renames a client and lands back on that AM's portfolio" do
    sign_in @admin
    patch company_path(@company, return_to: portfolio_path(user_id: @am.id)), params: { company: { name: "  Nouveau Nom  " } }
    assert_redirected_to portfolio_path(user_id: @am.id)
    assert_equal "Nouveau Nom", @company.reload.name, "surrounding spaces are trimmed"
    assert_equal @company, ProduitDeal.find_by(identifiant: "rn-1").company, "its deals follow"
  end

  test "a KAM can rename too, but a regular AM cannot, not even their own client" do
    sign_in @kam
    patch company_path(@company), params: { company: { name: "Renommé par KAM" } }
    assert_equal "Renommé par KAM", @company.reload.name

    sign_out @kam
    sign_in @am
    patch company_path(@company), params: { company: { name: "Renommé par AM" } }
    assert_equal "Renommé par KAM", @company.reload.name
  end

  test "a duplicate (case-insensitive) or blank name is refused with a message" do
    sign_in @admin
    patch company_path(@company), params: { company: { name: "autre client" } }
    assert_equal "Ancien Nom", @company.reload.name
    assert_match(/déjà|pris|taken/i, flash[:alert].to_s)

    patch company_path(@company), params: { company: { name: "   " } }
    assert_equal "Ancien Nom", @company.reload.name
    assert flash[:alert].present?
  end

  test "a rename carries over to the company's archived history instead of splitting it" do
    ArchiveEntry.create!(deal_type: "ProduitDeal", year: 2025, company_name: "Ancien Nom", am_name: @am.name,
      produit: "Mutuelle", assureur: "AXA", college: "Cadre", arr: 500, taux: 2, statut_renouvellement: "Augmenté")
    other_archive = ArchiveEntry.create!(deal_type: "ProduitDeal", year: 2025, company_name: "Autre Client", am_name: @am.name,
      produit: "Mutuelle", assureur: "AXA", college: "Cadre", arr: 500, taux: 2, statut_renouvellement: "Augmenté")

    sign_in @admin
    patch company_path(@company), params: { company: { name: "Nom Final" } }
    assert_equal ["Nom Final"], ArchiveEntry.where(arr: 500).where.not(id: other_archive.id).pluck(:company_name)
    assert_equal "Autre Client", other_archive.reload.company_name
  end

  test "the evolution table shows an editable name field to admins and plain text to AMs" do
    sign_in @admin
    get portfolio_path(user_id: @am.id)
    assert_match(/value="Ancien Nom" name="company\[name\]"/, evolution_table)
    assert_match(/data-turbo-frame="_top"/, evolution_table)

    sign_out @admin
    sign_in @am
    get portfolio_path
    assert_no_match 'name="company[name]"', evolution_table
    assert_match "Ancien Nom", evolution_table
  end

  test "the row still renders after an inline deal edit (turbo stream) with a working rename form" do
    sign_in @admin
    deal = ProduitDeal.find_by(identifiant: "rn-1")
    patch deal_path(deal, redirect_user_id: @am.id), params: { deal: { taux: 3 } },
      headers: { "Accept" => "text/vnd.turbo-stream.html" }
    assert_response :success
    assert_match(/return_to=%2Fportfolio%3Fuser_id%3D#{@am.id}/, @response.body)
    assert_match 'name="company[name]"', @response.body
  end
end
