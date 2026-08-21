require "csv"

# Ports the original's bulk CSV import: analyze() is a pure, side-effect-free preview (never touches the
# database) and apply! is the only method that writes, wrapped in one transaction so a partial failure can
# never leave the portfolio half-imported. The controller re-runs analyze on the same CSV text for both the
# preview screen and the final "Confirmer" submit, rather than persisting parsed state between requests.
class CsvImport
  PendingCreate = Struct.new(:company_name, :am_name, :attrs, keyword_init: true)
  PendingUpdate = Struct.new(:deal_id, :company_name, :am_name, :existing_am_name, :attrs, keyword_init: true)

  PRODUIT_HEADER_MAP = {
    "nom" => :nom, "nomduclient" => :nom, "client" => :nom, "nomclient" => :nom,
    "am" => :am, "amresponsable" => :am,
    "produit" => :produit,
    "identifiant" => :identifiant, "siren" => :identifiant, "identifiantexterne" => :identifiant, "identifiantsiren" => :identifiant,
    "arr" => :arr,
    "tauxderenouvellementnegocie" => :taux, "tauxrenouvellementnegocie" => :taux, "tauxrenouvellement" => :taux, "taux" => :taux,
    "statutderenouvellement" => :statut_renouvellement, "statutrenouvellement" => :statut_renouvellement,
    "college" => :college,
    "assureur" => :assureur,
    "churn" => :churn
  }.freeze

  UPSELL_HEADER_MAP = {
    "nom" => :nom, "nomduclient" => :nom, "client" => :nom, "nomclient" => :nom,
    "am" => :am, "amresponsable" => :am,
    "produit" => :produit,
    "nbsalaries" => :nombre_salaries, "nombresalaries" => :nombre_salaries, "salaries" => :nombre_salaries, "effectif" => :nombre_salaries,
    "pourcentagedechance" => :probabilite_signature, "dechance" => :probabilite_signature,
    "probabilitedesignature" => :probabilite_signature, "probabilitesignature" => :probabilite_signature,
    "chance" => :probabilite_signature, "proba" => :probabilite_signature, "pourcentage" => :probabilite_signature,
    "statutsignature" => :statut_signature, "statut" => :statut_signature
  }.freeze

  attr_reader :errors, :warnings, :to_create, :to_update, :deal_type, :conflict

  def initialize(text:, deal_type:)
    @text = text.to_s
    @deal_type = deal_type == "upsell" ? "upsell" : "produit"
    @errors = []
    @warnings = []
    @to_create = []
    @to_update = []
    @conflict = false
  end

  def analyze
    rows = parse_csv(@text)
    if rows.length < 2
      @errors << "Le fichier doit contenir un en-tête et au moins une ligne de données."
      return self
    end
    deal_type == "upsell" ? analyze_upsell(rows) : analyze_produit(rows)
    check_company_am_conflict
    self
  end

  def valid_for_apply?
    !@conflict && (to_create.any? || to_update.any?)
  end

  def apply!(admin_user:)
    return false unless valid_for_apply?

    ActiveRecord::Base.transaction do
      to_update.each do |u|
        deal = Deal.find(u.deal_id)
        company = deal.company
        deal.update!(u.attrs)
        reassign_company(company, u.am_name) if u.am_name && company.user.name != u.am_name
      end
      to_create.each do |c|
        am = User.active.find_by(name: c.am_name)
        company = Company.find_or_create_by!(name: c.company_name) { |co| co.user = am }
        reassign_company(company, c.am_name) if company.user.name != c.am_name
        klass = deal_type == "upsell" ? UpsellDeal : ProduitDeal
        klass.create!(c.attrs.merge(company: company))
      end
    end
    true
  end

  private

  def reassign_company(company, am_name)
    am = User.active.find_by(name: am_name)
    company.reassign_am!(am) if am
  end

  # A CSV row that assigns a different AM to a company already targeted earlier in the same file makes the
  # whole import ambiguous — rejected outright rather than silently picking one AM over the other.
  def check_company_am_conflict
    seen = {}
    conflict = false
    to_update.each do |u|
      next if u.company_name.blank?
      if seen.key?(u.company_name) && seen[u.company_name] != u.am_name
        conflict = true
      end
      seen[u.company_name] = u.am_name
    end
    to_create.each do |c|
      next if c.company_name.blank?
      if seen.key?(c.company_name) && seen[c.company_name] != c.am_name
        conflict = true
      end
      seen[c.company_name] = c.am_name
    end
    if conflict
      @conflict = true
      @errors << "Une entreprise semble être attribuée à plusieurs AM différents dans ce fichier."
    end
  end

  # ---------- CSV parsing / normalization ----------

  def parse_csv(text)
    first_line = text.split(/\r?\n/, 2).first.to_s
    delim = first_line.count(";") >= first_line.count(",") ? ";" : ","
    CSV.parse(text, col_sep: delim, skip_blanks: true, liberal_parsing: true)
  rescue CSV::MalformedCSVError
    []
  end

  def normalize_header(h)
    h.to_s.unicode_normalize(:nfd).gsub(/[̀-ͯ]/, "").downcase.gsub(/[^a-z0-9]/, "")
  end

  def normalize_loose(s)
    s.to_s.unicode_normalize(:nfd).gsub(/[̀-ͯ]/, "").downcase.gsub(/\s/, "")
  end

  def normalize_number(v)
    return nil if v.nil?
    t = v.to_s.strip
    return nil if t.empty?
    cleaned = t.gsub(/\s/, "").gsub("€", "").sub(",", ".")
    Float(cleaned, exception: false)
  end

  def normalize_bool(v)
    return nil if v.nil?
    t = v.to_s.strip.downcase
    return nil if t.empty?
    return "Oui" if %w[oui yes true 1 y].include?(t)
    return "Non" if %w[non no false 0 n].include?(t)
    nil
  end

  def resolve_row_am(am_raw, idx, row_label)
    raw = am_raw.to_s.strip
    if raw.empty?
      @errors << "Ligne #{idx + 2} (#{row_label}) : AM manquant — ligne ignorée."
      return nil
    end
    matched = @active_am_names ||= User.active.pluck(:name)
    found = matched.find { |am| normalize_loose(am) == normalize_loose(raw) }
    unless found
      @errors << "Ligne #{idx + 2} (#{row_label}) : AM \"#{raw}\" non reconnu (attendu : #{matched.join(" / ")}). Ligne ignorée."
    end
    found
  end

  # ---------- Produit ----------

  def analyze_produit(rows)
    headers = rows[0].map { |h| normalize_header(h) }
    columns = headers.map { |h| PRODUIT_HEADER_MAP[h] }
    unless columns.include?(:identifiant)
      @errors << 'Le fichier doit contenir une colonne "Identifiant" (ID externe) : c\'est la seule clé de correspondance acceptée.'
      return
    end
    unless columns.include?(:am)
      @errors << 'Le fichier doit contenir une colonne "AM".'
      return
    end

    pending_updates_by_key = {}
    pending_creates_by_key = {}

    rows[1..].each_with_index do |r, idx|
      next if r.all? { |v| v.to_s.strip.empty? }
      obj = {}
      columns.each_with_index { |field, j| obj[field] = r[j] if field }

      key_val = obj[:identifiant].to_s.strip
      if key_val.empty?
        @errors << "Ligne #{idx + 2} : clé de correspondance (identifiant) manquante — ligne ignorée."
        next
      end
      row_label = obj[:nom].to_s.strip.presence || key_val

      row_am = resolve_row_am(obj[:am], idx, row_label)
      next unless row_am

      produit_val = nil
      if obj[:produit].to_s.strip.present?
        raw_produit = obj[:produit].to_s.strip
        produit_val = ProduitDeal::PRODUITS.find { |p| normalize_loose(p) == normalize_loose(raw_produit) }
        unless produit_val
          @errors << "Ligne #{idx + 2} (#{row_label}) : le produit \"#{raw_produit}\" n'est pas reconnu (seuls #{ProduitDeal::PRODUITS.join(" / ")} sont acceptés). Ligne ignorée."
          next
        end
      end

      match_key = [key_val.downcase, produit_val].freeze
      existing = ProduitDeal.where("lower(identifiant) = ?", key_val.downcase)
      existing = existing.where(produit: produit_val) if produit_val
      existing = existing.first

      attrs = {}
      nom_val = obj[:nom].to_s.strip.presence
      attrs[:produit] = produit_val if produit_val
      attrs[:identifiant] = obj[:identifiant].to_s.strip if obj[:identifiant].to_s.strip.present?
      arr_val = normalize_number(obj[:arr])
      attrs[:arr] = arr_val if arr_val
      taux_val = normalize_number(obj[:taux])
      attrs[:taux] = taux_val if taux_val

      raw_assureur = obj[:assureur].to_s.strip
      if raw_assureur.present?
        assureur_val = ProduitDeal::ASSUREURS.find { |a| normalize_loose(a) == normalize_loose(raw_assureur) }
        if assureur_val
          attrs[:assureur] = assureur_val
        else
          @warnings << "Ligne #{idx + 2} (#{row_label}) : assureur \"#{raw_assureur}\" non reconnu (attendu : #{ProduitDeal::ASSUREURS.join(" / ")}) — valeur ignorée pour cette ligne."
        end
      end

      raw_college = obj[:college].to_s.strip
      if raw_college.present?
        college_val = ProduitDeal::COLLEGES.find { |c| normalize_loose(c) == normalize_loose(raw_college) }
        if college_val
          attrs[:college] = college_val
        else
          @warnings << "Ligne #{idx + 2} (#{row_label}) : collège \"#{raw_college}\" non reconnu (attendu : #{ProduitDeal::COLLEGES.join(" / ")}) — valeur ignorée pour cette ligne."
        end
      end

      raw_statut = obj[:statut_renouvellement].to_s.strip
      if raw_statut.present?
        statut_val = ProduitDeal::STATUTS_RENOUVELLEMENT.find { |s| normalize_loose(s) == normalize_loose(raw_statut) }
        if statut_val
          attrs[:statut_renouvellement] = statut_val
        else
          @warnings << "Ligne #{idx + 2} (#{row_label}) : statut de renouvellement \"#{raw_statut}\" non reconnu (attendu : #{ProduitDeal::STATUTS_RENOUVELLEMENT.join(" / ")}) — valeur ignorée pour cette ligne."
        end
      elsif (churn_val = normalize_bool(obj[:churn]))
        attrs[:statut_renouvellement] = churn_val == "Oui" ? ProduitDeal::CHURNED : "En cours"
      end

      attrs[:taux] = 0 if attrs[:statut_renouvellement] == ProduitDeal::CHURNED

      if existing
        if (pending = pending_updates_by_key[match_key])
          pending.attrs.merge!(attrs)
          pending.am_name = row_am
        else
          pending_updates_by_key[match_key] = PendingUpdate.new(
            deal_id: existing.id, company_name: existing.company.name, am_name: row_am,
            existing_am_name: existing.company.user.name, attrs: attrs
          )
          @to_update << pending_updates_by_key[match_key]
        end
      elsif (pending = pending_creates_by_key[match_key])
        pending.attrs.merge!(attrs)
        pending.company_name = nom_val || pending.company_name
      else
        created = PendingCreate.new(
          company_name: nom_val || "Nouveau client", am_name: row_am,
          attrs: { produit: produit_val || ProduitDeal::PRODUITS.first, identifiant: key_val, arr: 0, taux: 0,
                   college: ProduitDeal::COLLEGES.first, assureur: ProduitDeal::ASSUREURS.first,
                   statut_renouvellement: "En cours" }.merge(attrs)
        )
        pending_creates_by_key[match_key] = created
        @to_create << created
      end
    end
  end

  # ---------- Upsell ----------

  def analyze_upsell(rows)
    headers = rows[0].map { |h| normalize_header(h) }
    columns = headers.map { |h| UPSELL_HEADER_MAP[h] }
    unless columns.include?(:nom) && columns.include?(:produit)
      @errors << 'Le fichier doit contenir au minimum les colonnes "Nom" et "Produit".'
      return
    end
    unless columns.include?(:am)
      @errors << 'Le fichier doit contenir une colonne "AM".'
      return
    end

    upsell_produits = UpsellDeal::PRODUITS
    pending_updates_by_key = {}
    pending_creates_by_key = {}

    rows[1..].each_with_index do |r, idx|
      next if r.all? { |v| v.to_s.strip.empty? }
      obj = {}
      columns.each_with_index { |field, j| obj[field] = r[j] if field }

      nom_val = obj[:nom].to_s.strip
      if nom_val.empty?
        @errors << "Ligne #{idx + 2} : nom manquant — ligne ignorée."
        next
      end
      raw_produit = obj[:produit].to_s.strip
      if raw_produit.empty?
        @errors << "Ligne #{idx + 2} (#{nom_val}) : produit manquant — ligne ignorée."
        next
      end
      produit_val = upsell_produits.find { |p| normalize_loose(p) == normalize_loose(raw_produit) }
      unless produit_val
        @errors << "Ligne #{idx + 2} (#{nom_val}) : le produit \"#{raw_produit}\" n'est pas reconnu (seuls #{upsell_produits.join(" / ")} sont acceptés). Ligne ignorée."
        next
      end

      row_am = resolve_row_am(obj[:am], idx, nom_val)
      next unless row_am

      match_key = [nom_val.downcase, produit_val].freeze
      existing = UpsellDeal.joins(:company)
        .where("lower(companies.name) = ?", nom_val.downcase)
        .where(produit: produit_val).first

      attrs = { produit: produit_val }
      salaries_val = normalize_number(obj[:nombre_salaries])
      attrs[:nombre_salaries] = salaries_val.to_i if salaries_val
      proba_val = normalize_number(obj[:probabilite_signature])
      attrs[:probabilite_signature] = proba_val.to_i if proba_val
      raw_statut = obj[:statut_signature].to_s.strip
      if raw_statut.present?
        statut_val = UpsellDeal::STATUTS_SIGNATURE.find { |s| normalize_loose(s) == normalize_loose(raw_statut) }
        if statut_val
          attrs[:statut_signature] = statut_val
        else
          @warnings << "Ligne #{idx + 2} (#{nom_val}) : statut \"#{raw_statut}\" non reconnu (attendu : #{UpsellDeal::STATUTS_SIGNATURE.join(" / ")}) — valeur ignorée pour cette ligne."
        end
      end
      attrs[:probabilite_signature] = 100 if attrs[:statut_signature] == UpsellDeal::SIGNE

      if existing
        if (pending = pending_updates_by_key[match_key])
          pending.attrs.merge!(attrs)
          pending.am_name = row_am
        else
          pending_updates_by_key[match_key] = PendingUpdate.new(
            deal_id: existing.id, company_name: existing.company.name, am_name: row_am,
            existing_am_name: existing.company.user.name, attrs: attrs
          )
          @to_update << pending_updates_by_key[match_key]
        end
      elsif (pending = pending_creates_by_key[match_key])
        pending.attrs.merge!(attrs)
      else
        created = PendingCreate.new(
          company_name: nom_val, am_name: row_am,
          attrs: { nombre_salaries: 0, probabilite_signature: 0, statut_signature: "Non démarré" }.merge(attrs)
        )
        pending_creates_by_key[match_key] = created
        @to_create << created
      end
    end
  end
end
