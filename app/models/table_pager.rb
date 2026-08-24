# In-memory sort + paginate for one table on "Mon portefeuille". Each of the three tables gets its own
# instance with a distinct param prefix (e.g. "ren" for Renouvellement), so their sort/page state never
# collides in the query string — filtering/searching happens before this (see PortfolioController), this
# class only orders and slices whatever records it's handed.
class TablePager
  PAGE_SIZES = [10, 20, 50, 100].freeze
  DEFAULT_PAGE_SIZE = 10

  attr_reader :prefix, :page, :page_size, :sort_field, :sort_dir, :total_count, :total_pages

  def initialize(records, params:, prefix:, sort_procs:, default_sort:)
    @prefix = prefix
    @sort_procs = sort_procs
    requested_sort = params[sort_param].to_s.to_sym
    @sort_field = sort_procs.key?(requested_sort) ? requested_sort : default_sort
    @sort_dir = params[dir_param] == "desc" ? "desc" : "asc"
    @page_size = PAGE_SIZES.include?(params[size_param].to_i) ? params[size_param].to_i : DEFAULT_PAGE_SIZE

    sorted = records.sort_by(&@sort_procs.fetch(@sort_field))
    sorted = sorted.reverse if @sort_dir == "desc"
    @total_count = sorted.size
    @total_pages = [(@total_count.to_f / @page_size).ceil, 1].max
    @page = [[params[page_param].to_i, 1].max, @total_pages].min
    @records = sorted.each_slice(@page_size).to_a[@page - 1] || []
  end

  def records
    @records
  end

  def sort_param
    "#{prefix}_sort"
  end

  def dir_param
    "#{prefix}_dir"
  end

  def size_param
    "#{prefix}_size"
  end

  def page_param
    "#{prefix}_page"
  end

  def sorted_by?(field)
    sort_field == field.to_sym
  end

  # What clicking this column's header should switch sort_dir to: flip if already sorted by it, else
  # start ascending.
  def next_dir(field)
    sorted_by?(field) && sort_dir == "asc" ? "desc" : "asc"
  end

  # nil-safe sort key: strings compare case-insensitively, nils always sort last regardless of direction
  # (matches how the original app's manual sort handled missing values, e.g. a company with no produit
  # deals yet has no augmentation moyenne to rank by).
  def self.key(value)
    return [1, nil] if value.nil?
    value = value.downcase if value.is_a?(String)
    [0, value]
  end
end
