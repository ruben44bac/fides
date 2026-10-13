defmodule FidesWeb.PolicyFormTest do
  use ExUnit.Case, async: true

  alias FidesWeb.Money
  alias FidesWeb.PolicyForm

  @names [
    :history_window_days,
    :income_tolerance_percent,
    :countersign_above_minor,
    :review_above_amount_minor
  ]

  test "amounts go from units to minor units and back" do
    assert Money.parse("25000") == {:ok, 2_500_000}
    assert Money.parse("25000,5") == {:ok, 2_500_050}
    assert Money.parse(" 0.99 ") == {:ok, 99}
    assert Money.parse("") == :blank
    assert Money.parse(nil) == :blank
    assert Money.parse("25.000,00") == :error
    assert Money.parse("-5") == :error

    assert Money.units(2_500_000) == "25000"
    assert Money.units(2_500_050) == "25000.50"
    assert Money.units(5) == "0.05"
  end

  test "each threshold has a unit, a label and a way to show its value" do
    assert PolicyForm.unit(:countersign_above_minor) == :amount
    assert PolicyForm.unit(:income_tolerance_percent) == :percent
    assert PolicyForm.unit(:min_income_percent_of_amount) == :percent
    assert PolicyForm.unit(:history_window_days) == :days
    assert PolicyForm.unit(:min_income_months) == :months
    assert PolicyForm.unit(:approve_max_income_multiple) == :multiple
    assert PolicyForm.unit(:review_min_score) == :score

    assert PolicyForm.label(:countersign_above_minor) == "Countersign above"
    assert PolicyForm.label(:min_income_percent_of_amount) == "Minimum income share"
    assert PolicyForm.label(:approve_max_income_multiple) == "Approve up to"
    assert PolicyForm.label(:some_new_threshold_days) == "Some new threshold"
    assert PolicyForm.describe(:history_window_days) =~ "rejection of the same holder"
    assert PolicyForm.describe(:some_new_threshold_days) == nil
    assert PolicyForm.suffix(:countersign_above_minor, "EUR") == "EUR"
    assert PolicyForm.suffix(:income_tolerance_percent, "EUR") == "%"

    assert PolicyForm.format(:countersign_above_minor, 5_000_000, "EUR") == "EUR 50,000.00"
    assert PolicyForm.format(:income_tolerance_percent, 15, "EUR") == "15 %"
    assert PolicyForm.format(:history_window_days, 30, "EUR") == "30 days"
    assert PolicyForm.format(:review_min_score, 450, "BRL") == "450 points"
  end

  test "the parameters in force become the values to type, and back into parameters" do
    in_force = %{
      "history_window_days" => 30,
      "income_tolerance_percent" => 15,
      "countersign_above_minor" => 5_000_000,
      "review_above_amount_minor" => 2_000_000
    }

    values = PolicyForm.values(in_force, @names)

    assert values == %{
             "history_window_days" => "30",
             "income_tolerance_percent" => "15",
             "countersign_above_minor" => "50000",
             "review_above_amount_minor" => "20000"
           }

    assert {:ok, params} =
             PolicyForm.cast(%{values | "review_above_amount_minor" => "30000,50"}, @names)

    assert params == %{
             history_window_days: 30,
             income_tolerance_percent: 15,
             countersign_above_minor: 5_000_000,
             review_above_amount_minor: 3_000_050
           }
  end

  test "refuses what is not a threshold, and says so by threshold" do
    typed = %{
      "history_window_days" => "-1",
      "income_tolerance_percent" => "ten",
      "countersign_above_minor" => "",
      "review_above_amount_minor" => "20.000,00"
    }

    assert {:error, errors} = PolicyForm.cast(typed, @names)

    assert errors == [
             history_window_days: {"cannot be negative", []},
             income_tolerance_percent: {"must be a whole number", []},
             countersign_above_minor: {"is required", []},
             review_above_amount_minor: {"must be an amount such as 50000 or 50000.50", []}
           ]
  end

  test "the diff against the version in force marks what changes" do
    in_force = %{history_window_days: 30, income_tolerance_percent: 15}
    proposed = %{history_window_days: 30, income_tolerance_percent: 20}

    assert PolicyForm.diff(in_force, proposed, [:history_window_days, :income_tolerance_percent]) ==
             [
               %{name: :history_window_days, before: 30, after: 30, changed?: false},
               %{name: :income_tolerance_percent, before: 15, after: 20, changed?: true}
             ]

    # Without a version in force, everything is new
    assert [%{before: nil, changed?: true}, %{before: nil, changed?: true}] =
             PolicyForm.diff(nil, proposed, [:history_window_days, :income_tolerance_percent])
  end
end
