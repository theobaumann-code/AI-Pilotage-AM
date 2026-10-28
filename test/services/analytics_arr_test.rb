require "test_helper"

# The Ruby half of the Analytics ARR engine: the choice between invoice and estimate, the expected affiliates, and
# the "Facturé" / "Estimé" / "Mixte" labels.
class AnalyticsArrTest < ActiveSupport::TestCase
  TODAY = "2026-10-28".freeze

  def engine_row(**attrs)
    { "contract_id" => 1, "contract_type" => AnalyticsArr::HEALTH, "start_date" => "2025-01-01",
      "visible_employees" => 100, "effective_salaries" => 100, "group_risk_visibles" => 100, "group_risk_signed" => 100,
      "total_commission_rate" => 0.1, "source_detail" => "fee", "calculation_confidence" => "medium",
      "pricing_reference" => "Tarif simple du contrat", "pricing_sample_size" => 0, "pricing_reference_groups" => 0,
      "monthly_premium_per_employee" => 50.0, "months_invoiced" => 0, "invoice_affiliates" => 0,
      "factured_primes_annualisees" => nil, "factured_arr" => nil, "invoice_reference" => nil, "invoice_period" => nil,
      "has_readiness" => false, "observed_on" => TODAY, "recorded_people" => 0, "unresolved_people" => 0,
      "census_affiliated" => 0, "census_exempt" => 0, "census_complete" => false, "confirmed_mature" => false,
      "confirmed_affiliated" => 0, "confirmed_exempt" => 0 }.merge(attrs.stringify_keys)
  end

  def invoiced(**attrs)
    engine_row(months_invoiced: 3, invoice_affiliates: 90, factured_primes_annualisees: 60_000.0, factured_arr: 6_000.0,
               invoice_reference: "Contrat #1 : période complète terminée le 2026-09-30.", has_readiness: true,
               billed_population_usable: true, readiness_eligible: true, readiness_reason: "Période mature M+2 ; prix hors proratas disponible",
               billed_people: 90, full_people: 90, partial_people: 0, annual_price: 660.0, maturity_basis: "age", **attrs)
  end

  test "without invoice, visible employees are converted into affiliates and priced" do
    r = AnalyticsArr.contract(engine_row, today: TODAY)
    affiliates = 100 * 0.80 / 0.9885
    assert_equal [ "estimation", "fee", "high" ], [ r[:source], r[:source_detail], r[:confidence] ]
    assert_in_delta affiliates * 600 * 0.1, r[:arr], 0.01
  end

  test "a mature invoice covering the expected affiliates is the ARR" do
    r = AnalyticsArr.contract(invoiced, today: TODAY)
    assert_equal [ "invoice", "very_high", 6_000.0 ], [ r[:source], r[:confidence], r[:arr] ]
  end

  test "an invoice billing fewer people than expected projects its price on the expected affiliates" do
    r = AnalyticsArr.contract(invoiced(billed_people: 40, full_people: 40, invoice_affiliates: 40), today: TODAY)
    assert_equal [ "estimation", "invoice_projection" ], [ r[:source], r[:source_detail] ]
    assert_in_delta 100 * 0.80 / 0.9885 * 660 * 0.1, r[:arr], 0.01
  end

  test "a complete health census replaces the conversion rate" do
    row = engine_row(census_complete: true, recorded_people: 100, census_affiliated: 70, census_exempt: 30)
    r = AnalyticsArr.contract(row, today: TODAY)
    assert_in_delta 70 * 600 * 0.1, r[:arr], 0.01
    assert r[:population_projections].last[:observed_population]
  end

  test "before coverage starts, sparse visibles fall back to signed employees" do
    row = engine_row(start_date: "2027-01-01", visible_employees: 10, group_risk_visibles: 10, effective_salaries: 100)
    assert_in_delta 100 * 0.80 * 600 * 0.1, AnalyticsArr.contract(row, today: TODAY)[:arr], 0.01
  end

  test "without any price nor invoice the contract is not estimable" do
    r = AnalyticsArr.contract(engine_row(source_detail: "none", monthly_premium_per_employee: nil), today: TODAY)
    assert_equal [ nil, "none", "very_low" ], [ r[:arr], r[:source_detail], r[:confidence] ]
  end

  test "an account says how its ARR was obtained, as Analytics does" do
    billed = AnalyticsArr.contract(invoiced, today: TODAY)
    estimated = AnalyticsArr.contract(engine_row(contract_id: 2), today: TODAY)

    invoice = AnalyticsArr.source_label(AnalyticsArr.account_calculation([ billed ]))
    assert_equal [ "Facturé", "ok" ], [ invoice[:compact], invoice[:css] ]

    estimate = AnalyticsArr.source_label(AnalyticsArr.account_calculation([ estimated ]))
    assert_equal [ "Estimé", "Est. tarifs du contrat", "élevée" ], estimate.values_at(:compact, :label, :reliability)
    assert_match "visibles × 80,93 % affiliés", estimate[:title]

    mixed = AnalyticsArr.account_calculation([ billed, estimated ])
    assert_equal "mixed", mixed["source"]
    assert_equal "Mixte tarifs du contrat", AnalyticsArr.source_label(mixed)[:label]
  end

  test "the account's reliability is the one of the majority of its ARR" do
    assert_equal "high", AnalyticsArr.majority_confidence({ "high" => 60.0, "low" => 40.0 }, %w[high low])
    assert_equal "low", AnalyticsArr.majority_confidence({}, %w[high low])
  end
end
