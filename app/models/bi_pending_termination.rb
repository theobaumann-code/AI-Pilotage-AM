# Temporary "Résiliations en attente" rubric (see ResiliationsEnAttenteController): a BO contract termination waiting
# for the client's signature, synced by BiPendingTerminationSync. Its AM is the one of the account it belongs to, as
# "Attribution portefeuille" has it (bi_accounts).
class BiPendingTermination < ApplicationRecord
  TYPES = { "InternalContract" => "Contrat SideCare", "ExternalContract" => "Contrat externe" }.freeze
  NO_TYPE = "Non renseigné".freeze
  PRODUCTS = { 1 => "Santé", 2 => "Prévoyance", 4 => "Santé TNS", 5 => "Prévoyance TNS", 6 => "RC" }.freeze
  OTHER_PRODUCT = "Autre".freeze

  def self.last_synced_at
    maximum(:synced_at)
  end

  # Each termination with its account (BiAccount, or nil when the BI has none for it).
  def self.with_accounts
    terminations = all.to_a
    accounts = BiAccount.where(bi_id: terminations.map(&:account_bi_id).uniq).index_by { |a| [ a.kind, a.bi_id ] }
    terminations.map { |t| [ t, accounts[[ t.account_kind, t.account_bi_id ]] ] }
  end

  def type_label
    TYPES.fetch(terminable_type, NO_TYPE)
  end

  def product_label
    PRODUCTS.fetch(product_type, OTHER_PRODUCT)
  end
end
