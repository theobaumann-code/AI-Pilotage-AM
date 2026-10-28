# Temporary "Suivi des résiliations" rubric (see ResiliationsEnAttenteController): a BO contract termination created
# in 2026, whatever its status, synced by BiPendingTerminationSync. Its account is the one "Attribution portefeuille"
# has (bi_accounts).
class BiPendingTermination < ApplicationRecord
  TYPES = { "InternalContract" => "Contrat SideCare", "ExternalContract" => "Contrat externe" }.freeze
  NO_TYPE = "Non renseigné".freeze
  PRODUCTS = { 1 => "Santé", 2 => "Prévoyance", 3 => "Santé et prévoyance", 4 => "Santé TNS", 5 => "Prévoyance TNS",
               6 => "RC" }.freeze
  OTHER_PRODUCT = "Autre".freeze
  # The BO's operation_status. Only 1 is known for sure; the others show their code until they are named.
  STATUSES = { 1 => "En attente de signature" }.freeze

  # A produit's risk and collège as the BO codes them (product_type, college_type). A "santé et prévoyance"
  # termination covers both risks.
  PRODUIT_TYPES = { "Mutuelle" => [ 1, 3, 4 ], "Prévoyance" => [ 2, 3, 5 ] }.freeze
  COLLEGE_TYPES = { "Cadre" => 1, "Non cadre" => 2, "Ensemble du personnel" => 3 }.freeze
  LEGAL_FORMS = /\b(sas|sasu|sarl|eurl|sa|sci|snc|selarl|scop)\b/

  def self.last_synced_at
    maximum(:synced_at)
  end

  # Each termination with its account (BiAccount, or nil when the BI has none for it).
  def self.with_accounts
    terminations = all.to_a
    accounts = BiAccount.where(bi_id: terminations.map(&:account_bi_id).uniq).index_by { |a| [ a.kind, a.bi_id ] }
    terminations.map { |t| [ t, accounts[[ t.account_kind, t.account_bi_id ]] ] }
  end

  # The produits carry no BO reference: a company is found by name, against a BO user pro's social name or its
  # account's (company set) name, accents, punctuation and legal form left aside.
  def self.name_key(name)
    I18n.transliterate(name.to_s).downcase.gsub(LEGAL_FORMS, "").gsub(/[^a-z0-9]/, "")
  end

  # { deal id => its latest 2026 termination on the same company, risk and collège (nil when there is none) }. A
  # name that matches one user pro of a group stands for the whole group: the termination is looked for on every
  # user pro of the company set.
  def self.latest_for(deals)
    accounts_by_name = Hash.new { |h, k| h[k] = Set.new }
    by_account = Hash.new { |h, k| h[k] = [] }
    with_accounts.each do |t, account|
      key = [ t.account_kind, t.account_bi_id ]
      by_account[key] << t
      [ t.social_name, account&.name ].map { |n| name_key(n) }.reject(&:blank?).each { |n| accounts_by_name[n] << key }
    end
    deals.to_h do |deal|
      accounts = accounts_by_name.fetch(name_key(deal.company.name), [])
      matches = accounts.flat_map { |key| by_account[key] }.select { |t| t.covers?(deal) }
      [ deal.id, matches.max_by { |t| [ t.created_on || Date.new(0), t.bi_id ] } ]
    end
  end

  def covers?(deal)
    PRODUIT_TYPES.fetch(deal.produit, []).include?(product_type) && COLLEGE_TYPES[deal.college] == college_type
  end

  def type_label
    TYPES.fetch(terminable_type, NO_TYPE)
  end

  def product_label
    PRODUCTS.fetch(product_type, OTHER_PRODUCT)
  end

  def status_label
    STATUSES.fetch(operation_status) { "Statut BO #{operation_status.nil? ? '?' : operation_status}" }
  end
end
