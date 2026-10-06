module ChartsHelper
  LINE_CHART_COLORS = ["#ff7b44", "#6d092a", "#3ac26e", "#ffa656", "#3a99ff"].freeze

  # Hand-rolled SVG polylines (no charting library) — one line per series, x-axis is the given years.
  # A series stays in the legend even with zero data points, so a produit never silently disappears.
  def line_chart(years, series, zero_line)
    has_any_data = series.any? { |s| s[:points].any? { |p| !p.nil? } }
    return content_tag(:div, "Aucune donnée pour ce filtre.", class: "empty-state") if years.empty? || !has_any_data

    all_vals = series.flat_map { |s| s[:points].compact }
    min_t = [zero_line, *all_vals].min.to_f
    max_t = [zero_line, *all_vals].max.to_f
    if min_t == max_t
      min_t -= 5
      max_t += 5
    end
    pad = (max_t - min_t) * 0.15
    pad = 5.0 if pad.zero?
    min_t -= pad
    max_t += pad

    w = 640
    h = 260
    ml = 48
    mr = 20
    mt = 16
    mb = 32
    plot_w = w - ml - mr
    plot_h = h - mt - mb
    x_for = ->(i) { years.length == 1 ? ml + plot_w / 2.0 : ml + (i.to_f / (years.length - 1)) * plot_w }
    y_for = ->(t) { mt + plot_h - ((t - min_t) / (max_t - min_t)) * plot_h }

    lines_html = series.each_with_index.map do |s, si|
      color = LINE_CHART_COLORS[si % LINE_CHART_COLORS.size]
      seg = []
      seg_html = +""
      s[:points].each_with_index do |t, i|
        if !t.nil?
          seg << "#{x_for.call(i)},#{y_for.call(t)}"
        else
          seg_html << %(<polyline points="#{seg.join(' ')}" fill="none" stroke="#{color}" stroke-width="2.5"/>) if seg.length > 1
          seg = []
        end
      end
      seg_html << %(<polyline points="#{seg.join(' ')}" fill="none" stroke="#{color}" stroke-width="2.5"/>) if seg.length > 1
      dots = s[:points].each_with_index.map do |t, i|
        next "" if t.nil?
        %(<circle cx="#{x_for.call(i)}" cy="#{y_for.call(t)}" r="3.5" fill="#{color}"><title>#{s[:label]} #{years[i]} : #{number_with_precision(t, precision: 1)}%</title></circle>)
      end.join
      seg_html + dots
    end.join

    year_labels = years.each_with_index.map { |y, i|
      %(<text x="#{x_for.call(i)}" y="#{h - 8}" font-size="11" fill="#6f6f6f" text-anchor="middle">#{y}</text>)
    }.join
    y_ticks = 4
    y_grid = (0..y_ticks).map do |i|
      t = min_t + (max_t - min_t) * i / y_ticks
      %(<text x="#{ml - 8}" y="#{y_for.call(t) + 4}" font-size="11" fill="#6f6f6f" text-anchor="end">#{t.round}%</text>
        <line x1="#{ml}" y1="#{y_for.call(t)}" x2="#{w - mr}" y2="#{y_for.call(t)}" stroke="#e7e7e7" stroke-width="1"/>)
    end.join
    zero_y = y_for.call(zero_line)

    svg = <<~SVG.html_safe
      <svg viewBox="0 0 #{w} #{h}" style="width:100%;max-width:#{w}px;height:auto;">
        #{y_grid}
        <line x1="#{ml}" y1="#{zero_y}" x2="#{w - mr}" y2="#{zero_y}" stroke="#6d092a" stroke-width="1.5"/>
        #{lines_html}
        #{year_labels}
      </svg>
    SVG

    legend = series.each_with_index.map do |s, si|
      content_tag(:div, style: "display:flex;align-items:center;gap:6px;font-size:12px;") do
        concat content_tag(:span, "", style: "width:12px;height:3px;background:#{LINE_CHART_COLORS[si % LINE_CHART_COLORS.size]};display:inline-block;")
        concat " #{s[:label]}"
      end
    end.join.html_safe

    content_tag(:div) do
      concat svg
      concat content_tag(:div, legend, style: "display:flex;gap:16px;flex-wrap:wrap;margin-top:10px;")
    end
  end

  # Stacked SVG circles via stroke-dasharray/stroke-dashoffset — the same dependency-free donut technique
  # as the original app, so there is no charting library to port or keep in sync.
  #
  # value_format/total_label let this double as an ARR-weighted donut (Autres statistiques' répartitions)
  # instead of just a deal-count one (the renewal donut) — both default to the original plain-count display
  # so every existing call site keeps rendering exactly as before.
  def donut_chart(slices, value_format: ->(v) { v.to_s }, total_label: ->(total) { "Total : #{total} deal(s)" })
    total = slices.sum { |s| s[:value] }
    return content_tag(:div, "Aucune donnée pour ce filtre.", class: "empty-state") if total.zero?

    r = 70
    cx = 90
    cy = 90
    sw = 34
    circumference = 2 * Math::PI * r
    cumulative = 0.0

    circles = slices.select { |s| s[:value] > 0 }.map do |s|
      fraction = s[:value].to_f / total
      dash = fraction * circumference
      offset = -cumulative * circumference
      cumulative += fraction
      tag.circle(cx: cx, cy: cy, r: r, fill: "none", stroke: s[:color], "stroke-width": sw,
        "stroke-dasharray": "#{dash} #{circumference - dash}", "stroke-dashoffset": offset,
        transform: "rotate(-90 #{cx} #{cy})")
    end.join.html_safe

    legend = slices.map do |s|
      pct = s[:value].to_f / total * 100
      content_tag(:div, style: "display:flex;align-items:center;gap:8px;font-size:13px;") do
        concat content_tag(:span, "", style: "width:12px;height:12px;border-radius:3px;background:#{s[:color]};flex-shrink:0;")
        concat " #{s[:label]} — #{tag.strong(value_format.call(s[:value]))} (#{number_with_precision(pct, precision: 1)}%)".html_safe
      end
    end.join.html_safe

    content_tag(:div, style: "display:flex;align-items:center;gap:28px;flex-wrap:wrap;") do
      concat content_tag(:svg, circles, viewBox: "0 0 180 180", width: 180, height: 180)
      concat content_tag(:div, style: "display:flex;flex-direction:column;gap:10px;") {
        concat legend
        concat content_tag(:div, total_label.call(total), style: "font-size:12px;color:var(--text-muted);margin-top:4px;")
      }
    end
  end

  # One row per AM with two thin bars (projeté above, actuel below) on a shared scale that doesn't start at
  # zero — NRR values all sit near 100%, so a zero-based bar would make every AM look identical. A vertical
  # tick marks the target; the projeté bar is green/red against it, the actuel bar stays neutral.
  def nrr_by_am_chart(rows, target)
    return content_tag(:div, "Aucune donnée.", class: "empty-state") if rows.empty?

    values = rows.flat_map { |r| [r[:nrr], r[:nrr_actual]] } + [target]
    lo = ((values.min - 5) / 5.0).floor * 5
    hi = ((values.max + 5) / 5.0).ceil * 5
    pos = ->(v) { ((v - lo).to_f / (hi - lo) * 100).clamp(0, 100) }
    track = lambda do |value, color|
      content_tag(:div, class: "bar-track", style: "height:12px;margin:2px 0;") do
        concat content_tag(:div, "", class: "bar-fill", style: "width:#{pos.call(value)}%;background:#{color};")
        concat content_tag(:div, "", style: "position:absolute;top:-3px;bottom:-3px;width:2px;background:var(--burgundy);left:#{pos.call(target)}%;")
      end
    end

    content_tag(:div) do
      concat content_tag(:div, "Échelle de #{lo} % à #{hi} % — le trait bordeaux marque l'objectif (#{target} %). Barre du haut : projeté, barre du bas : actuel.",
        style: "font-size:12px;color:var(--text-muted);margin-bottom:12px;")
      rows.each do |r|
        concat(content_tag(:div, class: "bar-row") do
          concat content_tag(:div, r[:am], class: "bar-label")
          concat(content_tag(:div, style: "flex:1;") do
            concat track.call(r[:nrr], r[:nrr] >= target ? "var(--green)" : "var(--red)")
            concat track.call(r[:nrr_actual], "var(--text-muted)")
          end)
          concat(content_tag(:div, class: "bar-value", style: "min-width:120px;") do
            concat content_tag(:div, "Projeté #{number_with_precision(r[:nrr], precision: 1)} %")
            concat content_tag(:div, "Actuel #{number_with_precision(r[:nrr_actual], precision: 1)} %", style: "font-weight:400;color:var(--text-muted);")
          end)
        end)
      end
    end
  end

  # Horizontal bar rows (.bar-row/.bar-track/.bar-fill, already styled for the old per-AM NRR chart) reused
  # here for any "one row per category, one rate/amount" breakdown — contract-size buckets, churn rate by
  # segment, the upsell funnel. Bar width is row[:value]/max_value; value_format gets the whole row (not
  # just :value) so the trailing label can combine several of the row's own fields (e.g. count *and* ARR).
  def bar_rows(rows, value_format: ->(r) { r[:value].to_s })
    return content_tag(:div, "Aucune donnée pour ce filtre.", class: "empty-state") if rows.empty?

    max_value = rows.map { |r| r[:value].to_f }.max
    max_value = 1.0 if max_value.zero?

    content_tag(:div) do
      rows.each do |r|
        width = [r[:value].to_f / max_value * 100, 100].min
        concat(content_tag(:div, class: "bar-row") do
          concat content_tag(:div, r[:label], class: "bar-label")
          concat(content_tag(:div, class: "bar-track") do
            content_tag(:div, "", class: "bar-fill #{r[:status]}", style: "width:#{width}%")
          end)
          concat content_tag(:div, value_format.call(r), class: "bar-value")
        end)
      end
    end
  end
end
