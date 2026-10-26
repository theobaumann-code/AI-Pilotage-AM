# Next campaign's portfolios as the BO has them (bi_accounts) with the projection's what-ifs applied on top
# (Projection::Departure / Recruit / Move). Every account with an active contract that has an AM in the BO, sits in
# "Comptes sans AM", or carries a move is an Entry, with its BO holder and its projected holder; every person who
# holds - or could hold - a portfolio is a Holder, with their real and projected load.
#
# Holder keys: "user:<id>", "recruit:<id>", "hors:<email>" (a BO AM unknown to the app). Projected-only places:
# RESERVE (to reassign: taken off someone, or left by an AM who is leaving), DROP (no longer followed), and NONE
# (no AM in the BO and none given in the projection - the "Comptes sans AM" list).
class PortfolioProjection
  RESERVE = "reserve".freeze
  DROP = "drop".freeze
  NONE = "none".freeze
  PLACE_LABELS = { RESERVE => "À réattribuer", DROP => "Non accompagné", NONE => "Sans AM" }.freeze

  Holder = Struct.new(:key, :name, :role, :limit, :user, :recruit, :departing, keyword_init: true) do
    def recruit?
      recruit.present?
    end

    # A leaving AM keeps no capacity in the projection.
    def projected_limit
      departing ? 0 : limit
    end
  end

  Entry = Struct.new(:account, :bo_key, :key, :move, :status, keyword_init: true) do
    def account_key
      "#{account.kind}:#{account.bi_id}"
    end

    def moved?
      key != bo_key
    end
  end

  class Error < StandardError; end

  attr_reader :entries, :holders, :orphan_moves

  def initialize
    @departing_ids = Projection::Departure.pluck(:user_id).to_set
    @users = User.assignable.order(:name).to_a
    @users_by_email = @users.index_by { |u| u.email.downcase }
    @recruits = Projection::Recruit.order(:name).to_a
    moves = Projection::Move.includes(:user).index_by(&:key)

    sans_am_ids = BiAccount.sans_am.pluck(:id).to_set
    accounts = BiAccount.active.to_a.select { |a| a.am_email.present? || sans_am_ids.include?(a.id) || moves.key?(key_of(a)) }
    @entries = accounts.map { |account| build_entry(account, moves.delete(key_of(account))) }
    @orphan_moves = moves.values
    @holders = build_holders
  end

  def self.key_of(account)
    "#{account.kind}:#{account.bi_id}"
  end

  def key_of(account)
    self.class.key_of(account)
  end

  def holder(key)
    @holders_by_key ||= @holders.index_by(&:key)
    @holders_by_key[key]
  end

  # The name a holder key or place shows under.
  def label(key)
    PLACE_LABELS[key] || holder(key)&.name || key.to_s.delete_prefix("hors:")
  end

  # Accounts in someone's portfolio, the reserve or dropped - everything but the still-unassigned ones.
  def tracked_entries
    @entries.reject { |e| e.key == NONE }
  end

  # The "Comptes sans AM" list as the projection leaves it: unassigned in the BO and not given to anyone yet.
  def sans_am_entries
    @entries.select { |e| e.key == NONE }
  end

  # Who can be given accounts: real people still there, and - for accounts that already have an AM - recruits.
  def assignable_holders(recruits: true)
    @holders.select { |h| !h.departing && h.key.start_with?("user:", recruits ? "recruit:" : "user:") }
  end

  # Per holder: real (BO) and projected accounts / ARR, against their ceiling.
  def rows
    real = @entries.group_by(&:bo_key)
    projected = @entries.group_by(&:key)
    @holders.map do |h|
      real_accounts = real.fetch(h.key, [])
      projected_accounts = projected.fetch(h.key, [])
      comptes = projected_accounts.size
      { holder: h, real_comptes: real_accounts.size, real_arr: arr_of(real_accounts),
        comptes: comptes, arr: arr_of(projected_accounts), limit: h.projected_limit,
        remaining: h.projected_limit - comptes, over: comptes > h.projected_limit }
    end
  end

  def place_total(key)
    group = @entries.select { |e| e.key == key }
    { count: group.size, arr: arr_of(group) }
  end

  # Applies one bulk action to the accounts behind `keys` ("kind:bi_id"). action: "assign" (to `target`, a
  # holder key), "reserve", "drop" or "revert" (back to what the BO says). Returns { done:, skipped: } counts.
  def self.apply!(keys, action:, target: nil, by: nil)
    new.apply!(keys, action: action, target: target, by: by)
  end

  def apply!(keys, action:, target: nil, by: nil)
    by_key = @entries.index_by(&:account_key)
    selected = Array(keys).uniq.filter_map { |k| by_key[k] }
    raise Error, "Aucun compte sélectionné." if selected.empty?

    recipient = nil
    if action == "assign"
      recipient = holder(target)
      raise Error, "Destinataire introuvable." unless recipient && assignable_holders.include?(recipient)
    elsif %w[reserve drop revert].exclude?(action)
      raise Error, "Action inconnue."
    end

    done = skipped = 0
    Projection::Move.transaction do
      selected.each do |entry|
        if apply_one(entry, action, recipient, by)
          done += 1
        else
          skipped += 1
        end
      end
    end
    { done: done, skipped: skipped }
  end

  private

  def arr_of(entries)
    entries.sum { |e| e.account.arr.to_f }
  end

  def present_user?(key)
    id = key.delete_prefix("user:").to_i
    @users_ids ||= @users.map(&:id).to_set
    @users_ids.include?(id) && !@departing_ids.include?(id)
  end

  def bo_key_for(account)
    return NONE if account.am_email.blank?

    user = @users_by_email[account.am_email]
    user ? "user:#{user.id}" : "hors:#{account.am_email}"
  end

  def build_entry(account, move)
    bo_key = bo_key_for(account)
    key = if move
      case move.action
      when "assign" then move.user_id ? "user:#{move.user_id}" : "recruit:#{move.recruit_id}"
      when "reserve" then RESERVE
      else DROP
      end
    else
      bo_key
    end
    # An account whose holder is leaving (or no longer an active user) waits in the reserve.
    key = RESERVE if key.start_with?("user:") && !present_user?(key)
    Entry.new(account: account, bo_key: bo_key, key: key, move: move, status: move && status_of(move, account))
  end

  # Whether the BO has caught up with a move since it was made: :applied (it now names the same AM), :conflict
  # (it changed to someone else), or :pending (still as it was - the change remains to be made in the BO).
  def status_of(move, account)
    if move.action == "assign" && move.user && account.am_email == move.user.email.downcase
      :applied
    elsif account.am_email != move.original_am_email
      :conflict
    else
      :pending
    end
  end

  # AMs, KAMs and team leads (even empty), anyone with a real or projected account, the recruits, and the BO AMs
  # unknown to the app.
  def build_holders
    used = @entries.flat_map { |e| [ e.bo_key, e.key ] }.to_set
    people = @users.filter_map do |u|
      key = "user:#{u.id}"
      next unless u.role.in?([ :am, :kam, :tl_am, :tl_csm ]) || used.include?(key)

      Holder.new(key: key, name: u.name, role: u.role_label, limit: u.account_limit, user: u, departing: @departing_ids.include?(u.id))
    end
    recruits = @recruits.map do |r|
      Holder.new(key: "recruit:#{r.id}", name: r.name, role: r.role, limit: r.account_limit, recruit: r, departing: false)
    end
    hors = used.select { |k| k.start_with?("hors:") }.sort.map do |key|
      name = @entries.find { |e| e.bo_key == key }&.account&.am_name || key.delete_prefix("hors:")
      Holder.new(key: key, name: name, role: "Hors outil", limit: User::DEFAULT_ACCOUNT_LIMIT, departing: false)
    end
    people + recruits + hors
  end

  # Stores (or clears) the move that puts `entry` where the action says. A move matching the BO is no move: it is
  # deleted rather than kept, so "modifiés" only ever lists real differences. Returns false when the action can't
  # apply to this account (a recruit given an account with no AM in the BO, removing an unassigned one...).
  def apply_one(entry, action, recipient, by)
    account = entry.account
    bo_default = entry.bo_key.start_with?("user:") && !present_user?(entry.bo_key) ? RESERVE : entry.bo_key
    wanted = case action
    when "assign"
      return false if recipient.recruit? && entry.bo_key == NONE

      recipient.key
    when "reserve"
      return false if entry.bo_key == NONE

      RESERVE
    when "drop" then DROP
    else bo_default
    end

    existing = Projection::Move.find_by(kind: account.kind, bi_id: account.bi_id)
    if wanted == bo_default
      existing&.destroy!
      return true
    end

    move = existing || Projection::Move.new(kind: account.kind, bi_id: account.bi_id)
    move.assign_attributes(
      action: wanted.start_with?("user:", "recruit:") ? "assign" : wanted,
      user_id: wanted.start_with?("user:") ? wanted.delete_prefix("user:").to_i : nil,
      recruit_id: wanted.start_with?("recruit:") ? wanted.delete_prefix("recruit:").to_i : nil,
      original_am_email: account.am_email, created_by: by
    )
    move.save!
    true
  end
end
