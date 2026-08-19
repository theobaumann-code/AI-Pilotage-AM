module ChartsHelper
  LINE_CHART_COLORS = ["#ff7b44", "#6d092a", "#1fa25e", "#b8720a", "#7c6b63"].freeze

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
      %(<text x="#{x_for.call(i)}" y="#{h - 8}" font-size="11" fill="#7c6b63" text-anchor="middle">#{y}</text>)
    }.join
    y_ticks = 4
    y_grid = (0..y_ticks).map do |i|
      t = min_t + (max_t - min_t) * i / y_ticks
      %(<text x="#{ml - 8}" y="#{y_for.call(t) + 4}" font-size="11" fill="#7c6b63" text-anchor="end">#{t.round}%</text>
        <line x1="#{ml}" y1="#{y_for.call(t)}" x2="#{w - mr}" y2="#{y_for.call(t)}" stroke="#ede0cc" stroke-width="1"/>)
    end.join
    zero_y = y_for.call(zero_line)

    svg = <<~SVG.html_safe
      <svg viewBox="0 0 #{w} #{h}" style="width:100%;max-width:#{w}px;height:auto;">
        #{y_grid}
        <line x1="#{ml}" y1="#{zero_y}" x2="#{w - mr}" y2="#{zero_y}" stroke="#7c6b63" stroke-width="1.5"/>
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
  def donut_chart(slices)
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
        concat " #{s[:label]} — #{tag.strong(s[:value])} (#{number_with_precision(pct, precision: 1)}%)".html_safe
      end
    end.join.html_safe

    content_tag(:div, style: "display:flex;align-items:center;gap:28px;flex-wrap:wrap;") do
      concat content_tag(:svg, circles, viewBox: "0 0 180 180", width: 180, height: 180)
      concat content_tag(:div, style: "display:flex;flex-direction:column;gap:10px;") {
        concat legend
        concat content_tag(:div, "Total : #{total} deal(s)", style: "font-size:12px;color:var(--text-muted);margin-top:4px;")
      }
    end
  end
end
